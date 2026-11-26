package ai.tos.mode.data

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.KSerializer
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import java.security.MessageDigest
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** An error from the cell (platform or PostgREST), or from the network with [code] `network`. */
class CellException(val status: Int, val code: String, override val message: String) : Exception(message) {
    val isNetwork: Boolean get() = code == NETWORK
    val isSignedOut: Boolean get() = code == SIGNED_OUT

    val userMessage: String
        get() = when {
            isNetwork -> "Can't reach Silicon Mode. Check your connection."
            isSignedOut -> "Your session ended. Sign in again."
            status == 429 -> "Too many requests. Try again in a moment."
            else -> message
        }

    companion object {
        const val NETWORK = "network"
        const val SIGNED_OUT = "signed_out"
    }
}

/**
 * A thin Silicon Cell client (docs/research/cells.md §2–§3): the session's access token with
 * serialized refreshes, and authenticated REST/RPC calls with `apikey` + `Authorization: Bearer`.
 * No `Origin` header is ever sent (native clients must not).
 */
class CellClient(
    private val http: OkHttpClient,
    private val sessions: SessionStore,
    val baseUrl: String,
    private val publishableKey: String,
    appVersion: String,
) {
    /** Called (on the caller's thread) when the cell says the session is gone for good. */
    var onSessionEnded: () -> Unit = {}

    private val userAgent = "SiliconMode/$appVersion (Android)"
    private val json = "application/json; charset=utf-8".toMediaType()

    // One refresh at a time per app process: refresh tokens are single use, and reusing one under
    // a different Idempotency-Key revokes the session (refresh_token_reuse).
    private val refreshLock = Mutex()

    // ---------------- auth ----------------

    /** A valid access token, refreshed first when fewer than 60 s remain. */
    suspend fun accessToken(): String {
        val session = sessions.current ?: throw signedOut()
        if (session.secondsLeft() > REFRESH_MARGIN_S) return session.accessToken
        return refresh(session).accessToken
    }

    /**
     * Rotates [stale]'s refresh token. Serialized by a Mutex; if another caller already rotated it,
     * the newer session is returned without a second call. A lost response is retried with the
     * same `Idempotency-Key: refresh:<sha256 hex>` (derived from the token), which the cell treats
     * as the same refresh.
     */
    suspend fun refresh(stale: CellSession, force: Boolean = false): CellSession = refreshLock.withLock {
        val now = sessions.current ?: throw signedOut()
        if (now.refreshToken != stale.refreshToken) return@withLock now
        if (!force && now.secondsLeft() > REFRESH_MARGIN_S) return@withLock now
        val body = buildJsonObject { put("refresh_token", now.refreshToken) }.toString()
        val request = baseRequest("auth/refresh")
            .header("Idempotency-Key", refreshIdempotencyKey(now.refreshToken))
            .post(body.toRequestBody(json))
            .build()
        val (status, text) = execute(request)
        if (status in 200..299) {
            val r = ModeJson.decodeFromString(RefreshResponse.serializer(), text)
            val renewed = CellSession(
                accessToken = r.accessToken,
                refreshToken = r.refreshToken,
                expiresAt = r.expiresAt ?: (System.currentTimeMillis() / 1000 + (r.expiresIn ?: 1800)),
                user = r.user ?: now.user,
            )
            sessions.save(renewed)
            return@withLock renewed
        }
        val error = parseError(status, text)
        if (status == 401 || status == 400 || status == 403) {
            // cell_session_required / refresh_token_reuse / invalid: this session is over.
            Log.i(TAG, "Refresh rejected (${error.code}); signing out")
            sessions.clear()
            onSessionEnded()
            throw signedOut()
        }
        throw error
    }

    /** `GET /auth/user`. */
    suspend fun user(): CellUser = send(
        { baseRequest("auth/user").get() },
        UserEnvelope.serializer(),
    ).user

    /** `GET /auth/user` with an explicit token (validating a session before storing it). */
    suspend fun user(accessToken: String): CellUser {
        val request = baseRequest("auth/user").header("Authorization", "Bearer $accessToken").get().build()
        val (status, text) = execute(request)
        if (status !in 200..299) throw parseError(status, text)
        return ModeJson.decodeFromString(UserEnvelope.serializer(), text).user
    }

    /** `POST /auth/sign-out` (best effort; the caller clears local state either way). */
    suspend fun signOut() {
        val session = sessions.current ?: return
        val request = baseRequest("auth/sign-out")
            .header("Authorization", "Bearer ${session.accessToken}")
            .post("{}".toRequestBody(json))
            .build()
        runCatching { execute(request) }
    }

    // ---------------- REST ----------------

    suspend fun <T> get(pathAndQuery: String, serializer: KSerializer<T>): T =
        send({ baseRequest("rest/v1/$pathAndQuery").get() }, serializer)

    suspend fun <T> rpc(fn: String, args: JsonObject, serializer: KSerializer<T>): T =
        send({ baseRequest("rest/v1/rpc/$fn").post(args.toString().toRequestBody(json)) }, serializer)

    suspend fun patch(pathAndQuery: String, body: JsonObject) {
        sendRaw {
            baseRequest("rest/v1/$pathAndQuery")
                .header("Prefer", "return=minimal")
                .patch(body.toString().toRequestBody(json))
        }
    }

    suspend fun delete(pathAndQuery: String) {
        sendRaw { baseRequest("rest/v1/$pathAndQuery").header("Prefer", "return=minimal").delete() }
    }

    private suspend fun <T> send(build: () -> Request.Builder, serializer: KSerializer<T>): T {
        val text = sendRaw(build)
        return try {
            ModeJson.decodeFromString(serializer, text)
        } catch (e: Exception) {
            throw CellException(200, "decode", "Unexpected response from Silicon Mode (${e.javaClass.simpleName})")
        }
    }

    /** Sends an authenticated request; one forced refresh + retry on a 401. */
    private suspend fun sendRaw(build: () -> Request.Builder): String {
        val token = accessToken()
        val (status, text) = execute(build().header("Authorization", "Bearer $token").build())
        if (status in 200..299) return text
        if (status == 401) {
            val stale = sessions.current ?: throw signedOut()
            val renewed = refresh(stale, force = true)
            val (s2, t2) = execute(build().header("Authorization", "Bearer ${renewed.accessToken}").build())
            if (s2 in 200..299) return t2
            throw parseError(s2, t2)
        }
        throw parseError(status, text)
    }

    private fun baseRequest(path: String): Request.Builder = Request.Builder()
        .url(baseUrl.trimEnd('/') + "/" + path)
        .header("apikey", publishableKey)
        .header("Accept", "application/json")
        .header("User-Agent", userAgent)

    private suspend fun execute(request: Request): Pair<Int, String> = withContext(Dispatchers.IO) {
        try {
            if (BuildConfigLog) Log.d(TAG, "→ ${request.method} ${request.url.encodedPath}")
            http.newCall(request).await().use { response ->
                if (BuildConfigLog) Log.d(TAG, "← ${response.code} ${request.url.encodedPath}")
                response.code to (response.body?.string().orEmpty())
            }
        } catch (e: IOException) {
            Log.i(TAG, "✕ ${request.url.encodedPath}: ${e.javaClass.simpleName}")
            throw CellException(0, CellException.NETWORK, "Network error (${e.javaClass.simpleName})")
        }
    }

    private fun parseError(status: Int, text: String): CellException {
        val obj = runCatching { ModeJson.parseToJsonElement(text).jsonObject }.getOrNull()
        // Platform errors: {"error":{"code","message","hint"}}; PostgREST: {"code","message",…}.
        val inner = (obj?.get("error") as? JsonObject) ?: obj
        val code = (inner?.get("code") as? JsonPrimitive)?.contentOrNull ?: "http_$status"
        val message = (inner?.get("message") as? JsonPrimitive)?.contentOrNull ?: "Request failed ($status)"
        return CellException(status, code, message)
    }

    private fun signedOut() = CellException(401, CellException.SIGNED_OUT, "Signed out")

    companion object {
        private const val TAG = "ModeCell"
        /** Request lines (method, path, status — never headers or bodies) in debug builds only. */
        private val BuildConfigLog = ai.tos.mode.BuildConfig.DEBUG
        private const val REFRESH_MARGIN_S = 60L

        /** `refresh:<lowercase hex sha256(refresh_token)>`, the same derivation as the JS and Rust clients. */
        fun refreshIdempotencyKey(refreshToken: String): String =
            "refresh:" + MessageDigest.getInstance("SHA-256").digest(refreshToken.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }
    }
}

/** Suspends on an OkHttp call; cancelling the coroutine cancels the call. */
suspend fun Call.await(): Response = suspendCancellableCoroutine { cont ->
    cont.invokeOnCancellation { runCatching { cancel() } }
    enqueue(object : Callback {
        override fun onFailure(call: Call, e: IOException) {
            if (cont.isActive) cont.resumeWithException(e)
        }

        override fun onResponse(call: Call, response: Response) {
            if (cont.isActive) cont.resume(response) else response.close()
        }
    })
}
