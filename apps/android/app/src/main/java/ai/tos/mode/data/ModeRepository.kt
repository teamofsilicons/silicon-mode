package ai.tos.mode.data

import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.time.LocalDate

/** A Mac on the account with its latest Silicon Mode status. */
data class MacItem(val device: Device, val status: DeviceStatus?)

/** What one Mac is doing: its agents, tail log and pending questions. */
data class DeviceFeed(
    val sessions: List<AgentSession> = emptyList(),
    val events: List<AgentEvent> = emptyList(),
    val questions: List<Question> = emptyList(),
    val loaded: Boolean = false,
)

/** Where an answer stands, per question id. */
sealed interface AnswerState {
    data class Sending(val optionId: String?) : AnswerState
    /** Answered from this phone. */
    data class Sent(val label: String) : AnswerState
    /** Someone (the Mac, the web, another phone) answered first. */
    data class Elsewhere(val from: String?) : AnswerState
    data object Expired : AnswerState
    data class Failed(val message: String) : AnswerState
}

data class StatsState(
    val loading: Boolean = false,
    val error: String? = null,
    /** null = every Mac together. */
    val deviceId: String? = null,
    val summary: StatsSummary = StatsSummary.Empty,
    val loaded: Boolean = false,
)

/**
 * The app's view of the account: REST snapshots (on start, resume and pull-to-refresh) kept live
 * by realtime row changes (docs/research/cells.md §9.3). Main-thread only.
 */
class ModeRepository(
    private val api: ModeApi,
    private val prefs: AppPrefs,
    private val realtime: Realtime,
    private val scope: CoroutineScope,
) {
    private val _macs = MutableStateFlow<List<MacItem>>(emptyList())
    val macs: StateFlow<List<MacItem>> = _macs.asStateFlow()

    private val _selectedId = MutableStateFlow(prefs.selectedDeviceId)
    val selectedId: StateFlow<String?> = _selectedId.asStateFlow()

    private val _feeds = MutableStateFlow<Map<String, DeviceFeed>>(emptyMap())
    val feeds: StateFlow<Map<String, DeviceFeed>> = _feeds.asStateFlow()

    private val _answers = MutableStateFlow<Map<String, AnswerState>>(emptyMap())
    val answers: StateFlow<Map<String, AnswerState>> = _answers.asStateFlow()

    private val _loaded = MutableStateFlow(false)
    val loaded: StateFlow<Boolean> = _loaded.asStateFlow()

    private val _refreshing = MutableStateFlow(false)
    val refreshing: StateFlow<Boolean> = _refreshing.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    private val _stats = MutableStateFlow(StatsState())
    val stats: StateFlow<StatsState> = _stats.asStateFlow()

    /** Questions whose outcome was shown and that stay hidden until the Mac resolves them. */
    private val retired = mutableSetOf<String>()
    private val retiring = mutableSetOf<String>()

    private var refreshJob: Job? = null
    private var statsJob: Job? = null

    init {
        scope.launch { realtime.changes.collect { apply(it) } }
        scope.launch { realtime.resync.collect { refreshAll() } }
        // Every (re)connect gets a fresh REST snapshot: it covers whatever happened while the
        // socket was down and recovers a launch that started without a network.
        scope.launch {
            var previous = realtime.status.value
            realtime.status.collect { status ->
                if (status == Realtime.Status.Live && previous != Realtime.Status.Live) refreshAll()
                previous = status
            }
        }
    }

    // ---------------- loading ----------------

    /** Re-reads everything over REST. Safe to call often; concurrent calls coalesce. */
    fun refreshAll(userInitiated: Boolean = false): Job {
        refreshJob?.takeIf { it.isActive }?.let { return it }
        return scope.launch {
            if (userInitiated) _refreshing.value = true
            try {
                loadMacs()
                selectedId.value?.let { loadFeed(it) }
                _error.value = null
                if (_stats.value.loaded || userInitiated) loadStats(_stats.value.deviceId)
            } catch (e: CellException) {
                if (!e.isSignedOut) _error.value = e.userMessage
                Log.i(TAG, "Refresh failed: ${e.code} ${e.message}")
            } finally {
                if (ai.tos.mode.BuildConfig.DEBUG) Log.d(TAG, "Refreshed: ${_macs.value.size} Macs, feed ${selectedId.value?.let { _feeds.value[it]?.sessions?.size }}")
                _loaded.value = true
                _refreshing.value = false
            }
        }.also { refreshJob = it }
    }

    private suspend fun loadMacs() = coroutineScope {
        val devices = async { api.macs() }
        val statuses = async { api.statuses() }
        val byId = statuses.await().associateBy { it.deviceId }
        val list = devices.await().map { MacItem(it, byId[it.id]) }
        _macs.value = sortMacs(list)
        val current = _selectedId.value
        if (current == null || list.none { it.device.id == current }) {
            // Prefer a Mac that is in Silicon Mode right now, then the most recently seen.
            val pick = list.firstOrNull { it.status?.mode in ACTIVE_MODES } ?: list.firstOrNull()
            setSelected(pick?.device?.id)
        }
        updateSubscriptions()
    }

    private suspend fun loadFeed(deviceId: String) = coroutineScope {
        val sessions = async { api.sessions(deviceId) }
        val events = async { api.events(deviceId) }
        val questions = async { api.pendingQuestions(deviceId) }
        val open = async { api.openAnswers(deviceId) }
        val pendingOnServer = questions.await()
        val pending = pendingOnServer.map { it.id }.toSet()
        // A question stays pending until its Mac applies the answer. One that already has an
        // answer (from here, the web, another phone) is settled for us: don't offer it again.
        val answered = open.await().map { it.questionId }.toSet()
        // Cards that already showed their outcome stay hidden; forget ids the server dropped.
        retired.retainAll(pending + retiring)
        val visible = pendingOnServer.filterNot { it.id in retired || (it.id in answered && it.id !in retiring && _answers.value[it.id] == null) }
        val feed = DeviceFeed(sessions.await(), events.await(), visible, loaded = true)
        _feeds.update { it + (deviceId to feed) }
        _answers.update { states -> states.filter { (id, s) -> id in pending || s is AnswerState.Sent || s is AnswerState.Elsewhere } }
    }

    fun select(deviceId: String) {
        if (deviceId == _selectedId.value) return
        setSelected(deviceId)
        updateSubscriptions()
        scope.launch {
            try {
                loadFeed(deviceId)
            } catch (e: CellException) {
                if (!e.isSignedOut) _error.value = e.userMessage
            }
        }
    }

    private fun setSelected(id: String?) {
        _selectedId.value = id
        prefs.selectedDeviceId = id
    }

    fun loadStats(deviceId: String? = _stats.value.deviceId) {
        statsJob?.cancel()
        _stats.update { it.copy(loading = true, deviceId = deviceId, error = null) }
        statsJob = scope.launch {
            try {
                val today = LocalDate.now()
                val summary = coroutineScope {
                    val cells = async { api.heatmap(STATS_DAYS, deviceId) }
                    val usage = async { api.usage(today.minusDays(WINDOW_DAYS - 1L), deviceId) }
                    StatsMath.summarize(cells.await(), usage.await(), today, WINDOW_DAYS, STATS_DAYS)
                }
                _stats.value = StatsState(loading = false, deviceId = deviceId, summary = summary, loaded = true)
            } catch (e: CellException) {
                _stats.update { it.copy(loading = false, error = if (e.isSignedOut) null else e.userMessage) }
            }
        }
    }

    // ---------------- answering ----------------

    fun answer(question: Question, optionId: String?, text: String?, phoneDeviceId: String?) {
        val current = _answers.value[question.id]
        if (current is AnswerState.Sending || current is AnswerState.Sent) return
        val label = optionId?.let { id -> question.options.firstOrNull { it.id == id }?.label } ?: text?.trim().orEmpty()
        _answers.update { it + (question.id to AnswerState.Sending(optionId)) }
        scope.launch {
            val next = try {
                val result = api.answer(question.id, optionId, text?.trim()?.takeIf { it.isNotEmpty() }, phoneDeviceId)
                when {
                    result.ok -> AnswerState.Sent(label)
                    result.reason == "expired" -> AnswerState.Expired
                    result.reason == "invalid_option" -> AnswerState.Failed("That option is no longer offered.")
                    result.reason == "not_found" -> AnswerState.Elsewhere(null)
                    else -> AnswerState.Elsewhere(if (result.reason == "resolved_on_mac") "mac" else null)
                }
            } catch (e: CellException) {
                AnswerState.Failed(e.userMessage)
            }
            _answers.update { it + (question.id to next) }
            if (next !is AnswerState.Failed) retireQuestion(question.deviceId, question.id)
        }
    }

    fun dismissFailure(questionId: String) {
        _answers.update { if (it[questionId] is AnswerState.Failed) it - questionId else it }
    }

    /** Leaves a resolved card up long enough to read its outcome, then removes it. */
    private fun retireQuestion(deviceId: String, questionId: String) {
        if (!retiring.add(questionId)) return
        scope.launch {
            delay(RETIRE_MS)
            retiring -= questionId
            retired += questionId
            _feeds.update { feeds ->
                val feed = feeds[deviceId] ?: return@update feeds
                feeds + (deviceId to feed.copy(questions = feed.questions.filterNot { it.id == questionId }))
            }
        }
    }

    // ---------------- realtime ----------------

    private fun updateSubscriptions() {
        val subs = mutableListOf(
            RealtimeSub("device_status", "device_status"),
            RealtimeSub("devices", "devices", filters = listOf(Triple("kind", "eq", "mac"))),
        )
        _selectedId.value?.let { id ->
            val f = listOf(Triple("device_id", "eq", id))
            subs += RealtimeSub("sessions:$id", "agent_sessions", filters = f)
            subs += RealtimeSub("events:$id", "events", events = listOf("INSERT"), filters = f)
            subs += RealtimeSub("questions:$id", "questions", filters = f)
            subs += RealtimeSub("answers:$id", "answers", events = listOf("INSERT"), filters = f)
        }
        realtime.setSubscriptions(subs)
    }

    private fun apply(change: RowChange) {
        val row = change.new ?: change.old ?: return
        try {
            when (change.table) {
                "device_status" -> {
                    val status = decode(row, DeviceStatus.serializer()) ?: return
                    // Keep the order stable while live (the picker must not jump); it is re-sorted on refresh.
                    _macs.update { list -> list.map { if (it.device.id == status.deviceId) it.copy(status = status) else it } }
                }
                "devices" -> {
                    // Every Mac flush bumps last_seen_at: apply those in place. Only a new Mac,
                    // or a removed/revoked selected one, needs a fresh snapshot.
                    val device = decode(row, Device.serializer())
                    val id = device?.id ?: (row["id"] as? JsonPrimitive)?.content ?: return
                    val known = _macs.value.any { it.device.id == id }
                    when {
                        change.operation == "DELETE" || device?.revokedAt != null -> {
                            _macs.update { list -> list.filterNot { it.device.id == id } }
                            if (_selectedId.value == id) refreshAll()
                        }
                        !known -> if (device?.kind == "mac") refreshAll()
                        device != null -> _macs.update { list -> list.map { if (it.device.id == id) it.copy(device = device) else it } }
                    }
                }
                "agent_sessions" -> {
                    val session = decode(row, AgentSession.serializer()) ?: return
                    updateFeed(session.deviceId) { feed ->
                        val rest = feed.sessions.filterNot { it.id == session.id }
                        val sessions = if (change.operation == "DELETE") rest else listOf(session) + rest
                        feed.copy(sessions = sessions.sortedByDescending { Times.parse(it.lastEventAt) })
                    }
                }
                "events" -> {
                    if (change.operation != "INSERT") return
                    val event = decode(row, AgentEvent.serializer()) ?: return
                    updateFeed(event.deviceId) { feed ->
                        if (feed.events.any { it.id == event.id }) feed
                        else feed.copy(events = (listOf(event) + feed.events).sortedByDescending { it.id }.take(MAX_EVENTS))
                    }
                }
                "questions" -> {
                    val question = decode(row, Question.serializer()) ?: return
                    if (change.operation == "DELETE" || question.state != "pending") {
                        // Resolved somewhere. Keep this phone's own outcome; otherwise say who did.
                        if (_answers.value[question.id] !is AnswerState.Sent) {
                            val outcome = if (question.state == "expired") AnswerState.Expired
                            else AnswerState.Elsewhere(if (question.state == "resolved_on_mac") "mac" else null)
                            val known = _feeds.value[question.deviceId]?.questions?.any { it.id == question.id } == true
                            if (known) {
                                _answers.update { if (it[question.id] is AnswerState.Elsewhere) it else it + (question.id to outcome) }
                                retireQuestion(question.deviceId, question.id)
                            }
                        }
                        return
                    }
                    if (question.id in retired) return
                    updateFeed(question.deviceId) { feed ->
                        val rest = feed.questions.filterNot { it.id == question.id }
                        feed.copy(questions = (rest + question).sortedBy { Times.parse(it.createdAt) })
                    }
                }
                "answers" -> {
                    val answer = decode(row, Answer.serializer()) ?: return
                    val mine = answer.answeredBy != null && answer.answeredBy == prefs.phoneDeviceId
                    val state = _answers.value[answer.questionId]
                    if (mine || state is AnswerState.Sending || state is AnswerState.Sent) return
                    val known = _feeds.value[answer.deviceId]?.questions?.any { it.id == answer.questionId } == true
                    if (!known) return
                    _answers.update { it + (answer.questionId to AnswerState.Elsewhere(answer.answeredFrom)) }
                    retireQuestion(answer.deviceId, answer.questionId)
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Could not apply a ${change.table} change: ${e.javaClass.simpleName}")
        }
    }

    private fun updateFeed(deviceId: String, transform: (DeviceFeed) -> DeviceFeed) {
        _feeds.update { feeds ->
            val feed = feeds[deviceId] ?: return@update feeds
            feeds + (deviceId to transform(feed))
        }
    }

    private fun <T> decode(row: JsonObject, serializer: kotlinx.serialization.KSerializer<T>): T? =
        runCatching { ModeJson.decodeFromJsonElement(serializer, row) }.getOrNull()

    fun clear() {
        refreshJob?.cancel()
        statsJob?.cancel()
        _macs.value = emptyList()
        _feeds.value = emptyMap()
        _answers.value = emptyMap()
        retired.clear()
        retiring.clear()
        _stats.value = StatsState()
        _selectedId.value = null
        _loaded.value = false
        _error.value = null
        realtime.setSubscriptions(emptyList())
    }

    /** A stable order (the Mac you connected first comes first): live flushes never reshuffle it. */
    private fun sortMacs(list: List<MacItem>): List<MacItem> = list.sortedWith(
        compareBy<MacItem> { Times.parse(it.device.createdAt) ?: java.time.Instant.MAX }.thenBy { it.device.name },
    )

    companion object {
        private const val TAG = "ModeRepo"
        val ACTIVE_MODES = setOf("active", "locked", "panic", "arming")
        const val MAX_EVENTS = 80
        const val RETIRE_MS = 1_800L
        const val STATS_DAYS = 182
        const val WINDOW_DAYS = 30
    }
}
