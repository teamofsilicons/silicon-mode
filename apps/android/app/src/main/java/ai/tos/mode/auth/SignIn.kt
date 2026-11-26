package ai.tos.mode.auth

import ai.tos.mode.BuildConfig
import ai.tos.mode.data.AppPrefs
import ai.tos.mode.data.CellClient
import ai.tos.mode.data.CellException
import ai.tos.mode.data.CellSession
import ai.tos.mode.data.SessionStore
import android.content.ActivityNotFoundException
import android.content.Context
import android.net.Uri
import androidx.browser.customtabs.CustomTabColorSchemeParams
import androidx.browser.customtabs.CustomTabsIntent
import androidx.core.graphics.toColorInt
import kotlinx.coroutines.flow.MutableStateFlow
import java.net.URLDecoder

/** What the sign-in redirect carried. Pure (no Android types) so it is unit tested. */
sealed interface CallbackResult {
    data class Tokens(val accessToken: String, val refreshToken: String, val expiresAt: Long) : CallbackResult
    data class Denied(val error: String) : CallbackResult
    data object Malformed : CallbackResult
}

object CallbackParser {
    /**
     * Parses `#access_token=…&refresh_token=csr_…&expires_at=<unix>` (token mode) or
     * `?error=access_denied` from the redirect's [fragment] / [query].
     */
    fun parse(fragment: String?, query: String?): CallbackResult {
        val params = decode(fragment) + decode(query)
        params["error"]?.let { return CallbackResult.Denied(it) }
        val access = params["access_token"]?.takeIf { it.isNotBlank() } ?: return CallbackResult.Malformed
        val refresh = params["refresh_token"]?.takeIf { it.isNotBlank() } ?: return CallbackResult.Malformed
        val expiresAt = params["expires_at"]?.toLongOrNull()
            ?: params["expires_in"]?.toLongOrNull()?.let { System.currentTimeMillis() / 1000 + it }
            ?: (System.currentTimeMillis() / 1000 + 1800)
        return CallbackResult.Tokens(access, refresh, expiresAt)
    }

    private fun decode(raw: String?): Map<String, String> {
        if (raw.isNullOrBlank()) return emptyMap()
        return raw.removePrefix("#").removePrefix("?").split('&').mapNotNull { pair ->
            if (pair.isEmpty()) return@mapNotNull null
            val i = pair.indexOf('=')
            val key = if (i < 0) pair else pair.substring(0, i)
            val value = if (i < 0) "" else pair.substring(i + 1)
            // Fragments are not form-encoded: a literal '+' stays a '+'.
            fun dec(s: String) = URLDecoder.decode(s.replace("+", "%2B"), "UTF-8")
            runCatching { dec(key) to dec(value) }.getOrNull()
        }.toMap()
    }
}

/**
 * Hosted Silicon Cell sign-in (docs/research/cells.md §2.3): a Custom Tab opens
 * `/auth/sign-in?redirect_to=https://mode.teamofsilicons.com/auth/android&session=token&app=silicon-mode`;
 * the cell runs Silicon Accounts (PKCE between cell and Accounts) and redirects with the tokens in
 * the URL fragment; the bounce page forwards them to `ai.tos.mode://auth/callback#…`
 * (or Android delivers the https App Link directly once assetlinks.json is served).
 */
class SignIn(
    private val cell: CellClient,
    private val sessions: SessionStore,
    private val prefs: AppPrefs,
) {
    val busy = MutableStateFlow(false)
    val message = MutableStateFlow<String?>(null)

    fun signInUrl(): Uri = Uri.parse(BuildConfig.CELL_URL.trimEnd('/') + "/auth/sign-in").buildUpon()
        .appendQueryParameter("redirect_to", BuildConfig.SIGN_IN_REDIRECT)
        .appendQueryParameter("session", "token")
        .appendQueryParameter("app", BuildConfig.CELL_APP)
        .build()

    /** Opens the sign-in page. Returns an error message, or null when the page opened. */
    fun start(context: Context): String? {
        prefs.pendingSignInAt = System.currentTimeMillis()
        val light = CustomTabColorSchemeParams.Builder()
            .setToolbarColor("#FCFCFC".toColorInt())
            .setNavigationBarColor("#FCFCFC".toColorInt())
            .build()
        val dark = CustomTabColorSchemeParams.Builder()
            .setToolbarColor("#141414".toColorInt())
            .setNavigationBarColor("#141414".toColorInt())
            .build()
        return try {
            CustomTabsIntent.Builder()
                .setDefaultColorSchemeParams(light)
                .setColorSchemeParams(CustomTabsIntent.COLOR_SCHEME_DARK, dark)
                .setShowTitle(true)
                .setShareState(CustomTabsIntent.SHARE_STATE_OFF)
                .build()
                .launchUrl(context, signInUrl())
            null
        } catch (e: ActivityNotFoundException) {
            "Install a web browser to sign in with Silicon Accounts."
        }
    }

    sealed interface Result {
        data object Success : Result
        data class Failure(val message: String) : Result
        data object Cancelled : Result
        data object NotOurs : Result
    }

    fun isCallback(uri: Uri): Boolean =
        (uri.scheme == SCHEME && uri.host == "auth" && uri.path == "/callback") ||
            (uri.scheme == "https" && uri.host == Uri.parse(BuildConfig.SIGN_IN_REDIRECT).host &&
                uri.path == Uri.parse(BuildConfig.SIGN_IN_REDIRECT).path)

    /** Completes sign-in from the redirect [uri]: validates the tokens with `/auth/user`, then stores them. */
    suspend fun complete(uri: Uri): Result {
        if (!isCallback(uri)) return Result.NotOurs
        // A callback nobody asked for could sign this phone into someone else's account. Release
        // builds only accept one shortly after the person tapped "Continue"; debug builds also accept
        // one delivered over adb (docs/ANDROID.md, testing without a browser).
        val startedAt = prefs.pendingSignInAt
        val fresh = startedAt > 0 && System.currentTimeMillis() - startedAt < PENDING_WINDOW_MS
        if (!fresh && !BuildConfig.DEBUG) return Result.Failure("This sign-in link has expired. Try again.")
        return when (val parsed = CallbackParser.parse(uri.encodedFragment, uri.encodedQuery)) {
            is CallbackResult.Denied -> {
                prefs.pendingSignInAt = 0
                if (parsed.error == "access_denied") Result.Cancelled else Result.Failure("Sign-in failed (${parsed.error}).")
            }
            CallbackResult.Malformed -> Result.Failure("Silicon Accounts did not return a session. Try again.")
            is CallbackResult.Tokens -> try {
                val user = cell.user(parsed.accessToken)
                // Signing in again replaces the current session: end the old one on the cell first.
                if (sessions.current != null && sessions.current?.refreshToken != parsed.refreshToken) cell.signOut()
                sessions.save(CellSession(parsed.accessToken, parsed.refreshToken, parsed.expiresAt, user))
                prefs.pendingSignInAt = 0
                Result.Success
            } catch (e: CellException) {
                Result.Failure(if (e.isNetwork) e.userMessage else "That session was not accepted (${e.code}). Try again.")
            }
        }
    }

    companion object {
        const val SCHEME = "ai.tos.mode"
        private const val PENDING_WINDOW_MS = 15 * 60 * 1000L
    }
}
