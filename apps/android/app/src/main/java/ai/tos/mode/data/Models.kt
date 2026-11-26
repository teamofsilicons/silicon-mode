package ai.tos.mode.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.longOrNull
import java.time.Instant
import java.time.LocalDate
import java.time.OffsetDateTime
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeFormatterBuilder
import java.time.temporal.ChronoField

/** One JSON configuration for the cell's REST and realtime payloads. */
val ModeJson = Json {
    ignoreUnknownKeys = true
    explicitNulls = false
    coerceInputValues = true
    isLenient = true
}

// ---------- auth ----------

/** `GET /auth/user` → `{"user":{…}}`, also embedded in `/auth/refresh` responses. */
@Serializable
data class CellUser(
    val uuid: String,
    val kind: String? = null,
    val id: String? = null,
    @SerialName("display_name") val displayName: String? = null,
    @SerialName("pfp_url") val pfpUrl: String? = null,
    val app: String? = null,
) {
    /** "Shubham" or "c:shubham" or the short uuid, whichever exists. */
    val label: String get() = displayName?.takeIf { it.isNotBlank() } ?: id ?: uuid.take(8)
}

@Serializable
data class UserEnvelope(val user: CellUser)

/** `POST /auth/refresh` (and `POST /auth/silicon`) response. */
@Serializable
data class RefreshResponse(
    @SerialName("access_token") val accessToken: String,
    @SerialName("refresh_token") val refreshToken: String,
    @SerialName("expires_at") val expiresAt: Long? = null,
    @SerialName("expires_in") val expiresIn: Long? = null,
    val user: CellUser? = null,
)

// ---------- tables (backend/migrations/0001_init.sql) ----------

@Serializable
data class Device(
    val id: String,
    val kind: String = "mac",
    val name: String = "Mac",
    val model: String? = null,
    @SerialName("os_version") val osVersion: String? = null,
    @SerialName("app_version") val appVersion: String? = null,
    val timezone: String? = null,
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("last_seen_at") val lastSeenAt: String? = null,
    @SerialName("revoked_at") val revokedAt: String? = null,
)

@Serializable
data class DeviceStatus(
    @SerialName("device_id") val deviceId: String,
    val mode: String = "off",
    @SerialName("mode_since") val modeSince: String? = null,
    @SerialName("lid_angle") val lidAngle: Double? = null,
    @SerialName("silicon_angle") val siliconAngle: Double? = null,
    val caffeinated: Boolean = false,
    val face: String? = null,
    @SerialName("agents_working") val agentsWorking: Int = 0,
    @SerialName("agents_waiting") val agentsWaiting: Int = 0,
    @SerialName("agents_finished") val agentsFinished: Int = 0,
    @SerialName("questions_pending") val questionsPending: Int = 0,
    val online: Boolean = true,
    @SerialName("updated_at") val updatedAt: String? = null,
)

@Serializable
data class AgentSession(
    val id: String,
    @SerialName("device_id") val deviceId: String,
    val provider: String,
    @SerialName("provider_session_id") val providerSessionId: String = "",
    val title: String? = null,
    val cwd: String? = null,
    val project: String? = null,
    val model: String? = null,
    val state: String = "working",
    @SerialName("waiting_reason") val waitingReason: String? = null,
    @SerialName("started_at") val startedAt: String? = null,
    @SerialName("last_event_at") val lastEventAt: String? = null,
    @SerialName("ended_at") val endedAt: String? = null,
)

@Serializable
data class AgentEvent(
    val id: Long,
    @SerialName("device_id") val deviceId: String,
    @SerialName("session_id") val sessionId: String,
    val seq: Long = 0,
    val at: String,
    val kind: String = "log",
    val summary: String = "",
    val detail: JsonElement? = null,
)

@Serializable
data class QuestionOption(
    val id: String,
    val label: String = id,
    val role: String? = null,
)

@Serializable
data class Question(
    val id: String,
    @SerialName("device_id") val deviceId: String,
    @SerialName("session_id") val sessionId: String? = null,
    val kind: String = "question",
    val title: String = "",
    val body: String? = null,
    val options: List<QuestionOption> = emptyList(),
    @SerialName("allow_text") val allowText: Boolean = false,
    val state: String = "pending",
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("expires_at") val expiresAt: String? = null,
)

@Serializable
data class Answer(
    val id: String,
    @SerialName("question_id") val questionId: String,
    @SerialName("device_id") val deviceId: String,
    @SerialName("option_id") val optionId: String? = null,
    val text: String? = null,
    @SerialName("answered_from") val answeredFrom: String = "web",
    @SerialName("answered_by") val answeredBy: String? = null,
    @SerialName("created_at") val createdAt: String? = null,
)

/** `rpc/answer_question` → `{ok:true, answer_id}` or `{ok:false, reason}`. */
@Serializable
data class AnswerResult(
    val ok: Boolean,
    @SerialName("answer_id") val answerId: String? = null,
    val reason: String? = null,
)

/** One row of `rpc/usage_heatmap`: a local hour of one day. */
@Serializable
data class HeatCell(
    @SerialName("local_date") val localDate: String,
    @SerialName("local_hour") val localHour: Int,
    @SerialName("agent_seconds") val agentSeconds: Long = 0,
    @SerialName("max_concurrent") val maxConcurrent: Int = 0,
    @SerialName("sessions_started") val sessionsStarted: Long = 0,
    val devices: Long = 0,
)

/** A `usage_hourly` row, read for the per-provider and Silicon Mode totals. */
@Serializable
data class UsageRow(
    @SerialName("device_id") val deviceId: String,
    @SerialName("local_date") val localDate: String,
    @SerialName("local_hour") val localHour: Int,
    @SerialName("agent_seconds") val agentSeconds: Long = 0,
    @SerialName("silicon_mode_seconds") val siliconModeSeconds: Long = 0,
    @SerialName("by_provider") val byProvider: JsonObject = JsonObject(emptyMap()),
) {
    fun providerSeconds(): Map<String, Long> = byProvider.mapNotNull { (k, v) ->
        (v as? JsonPrimitive)?.longOrNull?.let { k to it }
    }.toMap()
}

// ---------- time ----------

object Times {
    // Postgres/PostgREST write "2026-11-26T15:30:00.123456+00:00"; realtime rows may omit the
    // colon in the offset or use a space instead of the T. Accept all of them.
    private val tolerant: DateTimeFormatter = DateTimeFormatterBuilder()
        .appendPattern("yyyy-MM-dd")
        .optionalStart().appendLiteral('T').optionalEnd()
        .optionalStart().appendLiteral(' ').optionalEnd()
        .appendPattern("HH:mm:ss")
        .optionalStart().appendFraction(ChronoField.NANO_OF_SECOND, 0, 9, true).optionalEnd()
        .optionalStart().appendOffset("+HH:MM", "Z").optionalEnd()
        .optionalStart().appendOffset("+HHMM", "Z").optionalEnd()
        .optionalStart().appendOffset("+HH", "Z").optionalEnd()
        .toFormatter()

    fun parse(value: String?): Instant? {
        if (value.isNullOrBlank()) return null
        return runCatching { OffsetDateTime.parse(value).toInstant() }.getOrNull()
            ?: runCatching { Instant.parse(value) }.getOrNull()
            ?: runCatching { OffsetDateTime.parse(value, tolerant).toInstant() }.getOrNull()
    }

    fun date(value: String): LocalDate? = runCatching { LocalDate.parse(value.take(10)) }.getOrNull()
}
