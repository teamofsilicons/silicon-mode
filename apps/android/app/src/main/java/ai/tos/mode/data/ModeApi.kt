package ai.tos.mode.data

import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.time.Instant
import java.time.LocalDate

/** The Silicon Mode data contract (backend/migrations/0001_init.sql, docs/research/cells.md §9). */
class ModeApi(private val cell: CellClient) {

    /** Every Mac on the account (several Macs stay separate). */
    suspend fun macs(): List<Device> = cell.get(
        "devices?select=id,kind,name,model,os_version,app_version,timezone,created_at,last_seen_at,revoked_at" +
            "&kind=eq.mac&revoked_at=is.null&order=last_seen_at.desc",
        ListSerializer(Device.serializer()),
    )

    /** One row per device (RLS limits it to this account). */
    suspend fun statuses(): List<DeviceStatus> =
        cell.get("device_status?select=*", ListSerializer(DeviceStatus.serializer()))

    suspend fun sessions(deviceId: String, limit: Int = 50): List<AgentSession> = cell.get(
        "agent_sessions?select=id,device_id,provider,provider_session_id,title,cwd,project,model,state," +
            "waiting_reason,started_at,last_event_at,ended_at&device_id=eq.$deviceId&order=last_event_at.desc&limit=$limit",
        ListSerializer(AgentSession.serializer()),
    )

    suspend fun events(deviceId: String, limit: Int = 60): List<AgentEvent> = cell.get(
        "events?select=id,device_id,session_id,seq,at,kind,summary,detail&device_id=eq.$deviceId&order=at.desc,id.desc&limit=$limit",
        ListSerializer(AgentEvent.serializer()),
    )

    suspend fun pendingQuestions(deviceId: String): List<Question> = cell.get(
        "questions?select=id,device_id,session_id,kind,title,body,options,allow_text,state,created_at,expires_at" +
            "&device_id=eq.$deviceId&state=eq.pending&order=created_at.asc",
        ListSerializer(Question.serializer()),
    )

    /** Answers the Mac has not applied yet: their questions are settled as far as a phone is concerned. */
    suspend fun openAnswers(deviceId: String): List<Answer> = cell.get(
        "answers?select=id,question_id,device_id,option_id,text,answered_from,answered_by,created_at" +
            "&device_id=eq.$deviceId&consumed_at=is.null&order=created_at.desc&limit=100",
        ListSerializer(Answer.serializer()),
    )

    /** The answer to [questionId], if any (one per question: first answer wins). */
    suspend fun answerFor(questionId: String): Answer? = cell.get(
        "answers?select=id,question_id,device_id,option_id,text,answered_from,answered_by,created_at" +
            "&question_id=eq.$questionId&limit=1",
        ListSerializer(Answer.serializer()),
    ).firstOrNull()

    /** `rpc/usage_heatmap`: rows = (local_date, local_hour); missing hours are zero. */
    suspend fun heatmap(days: Int, deviceId: String?): List<HeatCell> = cell.get(
        "rpc/usage_heatmap?p_days=$days" + (deviceId?.let { "&p_device=$it" } ?: ""),
        ListSerializer(HeatCell.serializer()),
    )

    /** Raw hourly rows since [since] (per-provider seconds and Silicon Mode time). */
    suspend fun usage(since: LocalDate, deviceId: String?): List<UsageRow> = cell.get(
        "usage_hourly?select=device_id,local_date,local_hour,agent_seconds,silicon_mode_seconds,by_provider" +
            "&local_date=gte.$since" + (deviceId?.let { "&device_id=eq.$it" } ?: "") +
            "&order=local_date.asc,local_hour.asc&limit=10000",
        ListSerializer(UsageRow.serializer()),
    )

    /** First answer wins; `{ok:false, reason}` says this phone lost the race. */
    suspend fun answer(questionId: String, optionId: String?, text: String?, byDevice: String?): AnswerResult =
        cell.rpc(
            "answer_question",
            buildJsonObject {
                put("p_question", questionId)
                put("p_option", optionId?.let { JsonPrimitive(it) } ?: JsonNull)
                put("p_text", text?.let { JsonPrimitive(it) } ?: JsonNull)
                put("p_from", "android")
                put("p_by", byDevice?.let { JsonPrimitive(it) } ?: JsonNull)
            },
            AnswerResult.serializer(),
        )

    /** Registers (or refreshes) this phone as a `devices` row of kind `android`; returns its id. */
    suspend fun registerPhone(installId: String, name: String, model: String?, osVersion: String?, appVersion: String, timezone: String?): String =
        cell.rpc(
            "register_device",
            buildJsonObject {
                put("p_install_id", installId)
                put("p_kind", "android")
                put("p_name", name.take(120))
                put("p_model", model?.take(80)?.let { JsonPrimitive(it) } ?: JsonNull)
                put("p_os_version", osVersion?.take(40)?.let { JsonPrimitive(it) } ?: JsonNull)
                put("p_app_version", appVersion.take(40))
                put("p_timezone", timezone?.take(64)?.let { JsonPrimitive(it) } ?: JsonNull)
            },
            String.serializer(),
        )

    /** Marks this phone's device row revoked on sign-out (register_device un-revokes it). */
    suspend fun revokePhone(deviceId: String) {
        cell.patch("devices?id=eq.$deviceId", buildJsonObject { put("revoked_at", Instant.now().toString()) })
    }
}
