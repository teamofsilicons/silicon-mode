package ai.tos.mode.data

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.util.Log
import kotlinx.coroutines.CompletableJob
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.util.concurrent.TimeUnit
import kotlin.random.Random

/** A table-change subscription (docs/research/cells.md §5). */
data class RealtimeSub(
    val id: String,
    val table: String,
    val events: List<String>? = null,
    val filters: List<Triple<String, String, String>> = emptyList(),
)

/** A row change delivered by the cell. */
data class RowChange(
    val subscription: String,
    val table: String,
    val operation: String,
    val old: JsonObject?,
    val new: JsonObject?,
)

/** A frame from the realtime socket, parsed. Kept free of Android types for unit tests. */
sealed interface RealtimeFrame {
    data class Ready(val connectionId: String?) : RealtimeFrame
    data class Subscribed(val id: String, val cursor: Long?) : RealtimeFrame
    data class Change(val eventId: String?, val cursor: Long?, val change: RowChange) : RealtimeFrame
    data class Error(val code: String, val message: String?, val id: String?) : RealtimeFrame
    data object Pong : RealtimeFrame
    data object Other : RealtimeFrame

    companion object {
        fun parse(text: String): RealtimeFrame {
            val frame = ModeJson.parseToJsonElement(text).jsonObject
            fun str(o: JsonObject, k: String) = (o[k] as? JsonPrimitive)?.contentOrNull
            fun long(o: JsonObject, k: String) = (o[k] as? JsonPrimitive)?.longOrNull
            return when (str(frame, "type")) {
                "ready" -> Ready(str(frame, "connection_id"))
                "subscribed" -> Subscribed(str(frame, "id").orEmpty(), long(frame, "cursor"))
                "change" -> Change(
                    eventId = str(frame, "event_id"),
                    cursor = long(frame, "cursor"),
                    change = RowChange(
                        subscription = str(frame, "subscription").orEmpty(),
                        table = str(frame, "table").orEmpty(),
                        operation = str(frame, "operation").orEmpty(),
                        old = frame["old"] as? JsonObject,
                        new = frame["new"] as? JsonObject,
                    ),
                )
                "error" -> Error(str(frame, "code").orEmpty(), str(frame, "message"), str(frame, "id"))
                "pong" -> Pong
                else -> Other
            }
        }

        fun authenticate(apikey: String, accessToken: String): String = buildJsonObject {
            put("type", "authenticate")
            put("apikey", apikey)
            put("access_token", accessToken)
        }.toString()

        fun subscribe(sub: RealtimeSub, after: Long?): String = buildJsonObject {
            put("type", "subscribe")
            put("id", sub.id)
            put("schema", "public")
            put("table", sub.table)
            sub.events?.let { events -> put("events", JsonArray(events.map { JsonPrimitive(it) })) }
            if (sub.filters.isNotEmpty()) {
                put(
                    "filters",
                    buildJsonArray {
                        sub.filters.forEach { (column, op, value) ->
                            add(buildJsonObject { put("column", column); put("op", op); put("value", value) })
                        }
                    },
                )
            }
            if (after != null) put("after", after)
        }.toString()

        fun unsubscribe(id: String): String = buildJsonObject { put("type", "unsubscribe"); put("id", id) }.toString()
    }
}

/**
 * The cell's realtime socket: authenticate within 5 s, table-change subscriptions filtered by
 * device_id (RLS applied server side), saved cursors so a reconnect resumes where it left off,
 * pings every 25 s, and reconnects with jittered backoff from 0.5 s to 30 s — immediately when
 * the network comes back. Close codes per §5: 4401 refresh once then reconnect, 4404/1008 stop,
 * 4429 back off.
 */
class Realtime(
    context: Context,
    http: OkHttpClient,
    private val cell: CellClient,
    private val sessions: SessionStore,
    private val publishableKey: String,
    private val scope: CoroutineScope,
) {
    enum class Status { Offline, Connecting, Live }

    private val client = http.newBuilder()
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .build()
    private val url = cell.baseUrl.trimEnd('/').replaceFirst(Regex("^http"), "ws") + "/realtime/v1/websocket"

    private val _changes = MutableSharedFlow<RowChange>(extraBufferCapacity = 512)
    val changes: SharedFlow<RowChange> = _changes.asSharedFlow()

    /** Emitted when the server could not resume (cursor expired): re-read through REST. */
    private val _resync = MutableSharedFlow<Unit>(extraBufferCapacity = 4)
    val resync: SharedFlow<Unit> = _resync.asSharedFlow()

    private val _status = MutableStateFlow(Status.Offline)
    val status: StateFlow<Status> = _status.asStateFlow()

    // Main-thread state.
    private val holders = mutableSetOf<String>()
    private var desired: Map<String, RealtimeSub> = emptyMap()
    private val active = mutableSetOf<String>()
    private val cursors = mutableMapOf<String, Long>()
    private val seen = LinkedHashSet<String>()
    private var socket: WebSocket? = null
    private var ready = false
    private var loop: Job? = null
    private var attempt = 0
    private var wake: CompletableJob = Job()
    private var nonce = 0L

    init {
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        runCatching {
            connectivity.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    scope.launch { attempt = 0; wake.complete() }
                }
            })
        }
    }

    /** Keeps the socket open on behalf of [reason] until [release] is called with it. */
    fun hold(reason: String) = scope.launch {
        holders += reason
        ensureLoop()
    }

    fun release(reason: String) = scope.launch {
        holders -= reason
        if (holders.isEmpty()) stop()
    }

    /** Replaces the wanted subscriptions; the live socket is updated in place. */
    fun setSubscriptions(subs: List<RealtimeSub>) = scope.launch {
        val next = subs.associateBy { it.id }
        val ws = socket
        if (ws != null && ready) {
            (active - next.keys).forEach { id -> ws.send(RealtimeFrame.unsubscribe(id)); active -= id }
            (next.keys - active).forEach { id -> ws.send(RealtimeFrame.subscribe(next.getValue(id), cursors[id])); active += id }
        }
        // Cursors of subscriptions that are gone are useless (another device, another account).
        cursors.keys.retainAll(next.keys)
        desired = next
    }

    /** Drops the connection and every cursor (sign-out, account switch). */
    fun reset() = scope.launch {
        socket?.cancel()
        socket = null
        ready = false
        active.clear()
        cursors.clear()
        seen.clear()
        attempt = 0
        wake.complete()
    }

    private fun ensureLoop() {
        if (loop?.isActive == true) return
        loop = scope.launch {
            var refreshedFor401 = false
            while (isActive && holders.isNotEmpty()) {
                if (sessions.current == null) {
                    _status.value = Status.Offline
                    awaitWake(Long.MAX_VALUE)
                    continue
                }
                val token = try {
                    cell.accessToken()
                } catch (e: CellException) {
                    _status.value = Status.Offline
                    if (e.isSignedOut) awaitWake(Long.MAX_VALUE) else awaitWake(backoff())
                    continue
                }
                val closed = Job()
                var closeCode = 0
                _status.value = Status.Connecting
                ready = false
                active.clear()
                val ws = client.newWebSocket(
                    Request.Builder().url(url).header("User-Agent", "SiliconMode (Android)").build(),
                    Listener(token, closed) { code -> closeCode = code },
                )
                socket = ws
                val pinger = launch {
                    while (isActive) {
                        delay(PING_MS)
                        ws.send(buildJsonObject { put("type", "ping"); put("nonce", ++nonce) }.toString())
                    }
                }
                closed.join()
                pinger.cancel()
                if (socket === ws) socket = null
                ready = false
                active.clear()
                _status.value = Status.Offline
                if (holders.isEmpty()) break
                when (closeCode) {
                    4401 -> {
                        // Credentials expired or revoked: refresh once, then reconnect at once.
                        if (!refreshedFor401) {
                            refreshedFor401 = true
                            sessions.current?.let { runCatching { cell.refresh(it, force = true) } }
                            continue
                        }
                        awaitWake(backoff())
                    }
                    4404, 1008 -> {
                        Log.w(TAG, "Realtime stopped by the server ($closeCode)")
                        awaitWake(Long.MAX_VALUE)
                    }
                    4429 -> awaitWake(MAX_BACKOFF_MS + Random.nextLong(0, 5_000))
                    else -> awaitWake(backoff())
                }
                if (closeCode != 4401) refreshedFor401 = false
            }
            _status.value = Status.Offline
        }
    }

    private fun backoff(): Long {
        val base = (INITIAL_BACKOFF_MS shl attempt.coerceAtMost(6)).coerceAtMost(MAX_BACKOFF_MS)
        attempt++
        return base + Random.nextLong(0, base / 3 + 1)
    }

    private suspend fun awaitWake(timeoutMs: Long) {
        wake = Job()
        withTimeoutOrNull(timeoutMs) { wake.join() }
    }

    private fun stop() {
        loop?.cancel()
        loop = null
        socket?.close(1000, null)
        socket = null
        ready = false
        active.clear()
        _status.value = Status.Offline
    }

    private fun onFrame(ws: WebSocket, frame: RealtimeFrame) {
        if (ws !== socket) return
        if (ai.tos.mode.BuildConfig.DEBUG) {
            when (frame) {
                is RealtimeFrame.Subscribed -> Log.d(TAG, "subscribed ${frame.id.substringBefore(':')} @${frame.cursor}")
                is RealtimeFrame.Change -> Log.d(TAG, "change ${frame.change.table} ${frame.change.operation} @${frame.cursor}")
                is RealtimeFrame.Ready -> Log.d(TAG, "ready")
                is RealtimeFrame.Error -> Log.d(TAG, "error ${frame.code} ${frame.id?.substringBefore(':')}: ${frame.message}")
                else -> Unit
            }
        }
        when (frame) {
            is RealtimeFrame.Ready -> {
                ready = true
                attempt = 0
                _status.value = Status.Live
                desired.values.forEach { sub ->
                    ws.send(RealtimeFrame.subscribe(sub, cursors[sub.id]))
                    active += sub.id
                }
            }
            is RealtimeFrame.Subscribed -> frame.cursor?.let { c -> if (frame.id in desired) cursors[frame.id] = maxOf(c, cursors[frame.id] ?: 0) }
            is RealtimeFrame.Change -> {
                val sub = frame.change.subscription
                frame.cursor?.let { c -> if (sub in desired) cursors[sub] = maxOf(c, cursors[sub] ?: 0) }
                val id = frame.eventId
                if (id != null) {
                    if (!seen.add(id)) return
                    if (seen.size > 1024) seen.iterator().let { it.next(); it.remove() }
                }
                _changes.tryEmit(frame.change)
            }
            is RealtimeFrame.Error -> {
                Log.i(TAG, "Realtime error ${frame.code}")
                if (frame.code == "cursor_expired") {
                    // History is kept 24 h: start fresh and re-read the snapshot over REST.
                    val ids = frame.id?.let { listOf(it) } ?: desired.keys.toList()
                    ids.forEach { cursors.remove(it) }
                    ids.mapNotNull { desired[it] }.forEach { sub ->
                        ws.send(RealtimeFrame.unsubscribe(sub.id))
                        ws.send(RealtimeFrame.subscribe(sub, null))
                    }
                    _resync.tryEmit(Unit)
                }
            }
            RealtimeFrame.Pong, RealtimeFrame.Other -> Unit
        }
    }

    private inner class Listener(
        private val token: String,
        private val closed: CompletableJob,
        private val onCode: (Int) -> Unit,
    ) : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            // Credentials go in the first frame, never in the URL.
            webSocket.send(RealtimeFrame.authenticate(publishableKey, token))
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            val frame = try {
                RealtimeFrame.parse(text)
            } catch (e: Exception) {
                Log.w(TAG, "Ignoring an unreadable realtime frame: ${e.javaClass.simpleName}")
                return
            }
            scope.launch { onFrame(webSocket, frame) }
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            scope.launch { onCode(code) }
            webSocket.close(1000, null)
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            scope.launch { onCode(code); closed.complete() }
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            Log.i(TAG, "Realtime connection dropped: ${t.javaClass.simpleName}")
            scope.launch {
                if (response?.code == 401) onCode(4401)
                closed.complete()
            }
        }
    }

    private companion object {
        const val TAG = "ModeRealtime"
        const val PING_MS = 25_000L
        const val INITIAL_BACKOFF_MS = 500L
        const val MAX_BACKOFF_MS = 30_000L
    }
}
