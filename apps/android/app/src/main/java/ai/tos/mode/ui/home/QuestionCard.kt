package ai.tos.mode.ui.home

import ai.tos.mode.data.AgentSession
import ai.tos.mode.data.AnswerState
import ai.tos.mode.data.Providers
import ai.tos.mode.data.Question
import ai.tos.mode.data.QuestionOption
import ai.tos.mode.ui.Format
import ai.tos.mode.ui.components.ButtonKind
import ai.tos.mode.ui.components.IconBubble
import ai.tos.mode.ui.components.ProviderMark
import ai.tos.mode.ui.components.SiButton
import ai.tos.mode.ui.components.SiCard
import ai.tos.mode.ui.theme.Motion
import ai.tos.mode.ui.theme.SiIcons
import ai.tos.mode.ui.theme.Silicon
import ai.tos.mode.ui.theme.SiliconType
import ai.tos.mode.ui.theme.SmoothShape
import ai.tos.mode.ui.theme.pressable
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import java.time.Instant

private fun kindLabel(kind: String) = when (kind) {
    "permission" -> "Permission"
    "plan" -> "Plan"
    "input" -> "Input"
    else -> "Question"
}

private fun isAllow(option: QuestionOption): Boolean {
    val role = option.role?.lowercase().orEmpty()
    val id = option.id.lowercase()
    return role in setOf("allow", "approve", "primary", "accept", "yes") || id.startsWith("allow") || id == "approve" || id == "yes"
}

private fun isDeny(option: QuestionOption): Boolean {
    val role = option.role?.lowercase().orEmpty()
    val id = option.id.lowercase()
    return role in setOf("deny", "reject", "destructive", "cancel", "no") || id.startsWith("deny") || id == "reject" || id == "no"
}

/** One accent button (the first "allow"), red for deny, quiet for the rest. */
private fun buttonKind(option: QuestionOption, options: List<QuestionOption>): ButtonKind = when {
    isDeny(option) -> ButtonKind.Danger
    isAllow(option) && options.firstOrNull(::isAllow)?.id == option.id -> ButtonKind.Accent
    else -> ButtonKind.Secondary
}

/**
 * A question or permission an agent is waiting on. Options become buttons; free text when the
 * agent accepts it. The first answer wins (`rpc/answer_question`): when the Mac, the web or another
 * phone got there first the card says so and steps away.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun QuestionCard(
    question: Question,
    session: AgentSession?,
    state: AnswerState?,
    now: Instant,
    macName: String,
    onAnswer: (Question, String?, String?) -> Unit,
    onDismissFailure: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val c = Silicon.colors
    val haptics = LocalHapticFeedback.current
    val focus = androidx.compose.ui.platform.LocalFocusManager.current
    var text by rememberSaveable(question.id) { mutableStateOf("") }
    var expanded by rememberSaveable(question.id) { mutableStateOf(false) }
    val resolved = state is AnswerState.Sent || state is AnswerState.Elsewhere || state == AnswerState.Expired
    val border by animateColorAsState(
        when (state) {
            is AnswerState.Sent -> c.success.copy(alpha = 0.45f)
            is AnswerState.Elsewhere, AnswerState.Expired -> c.border
            else -> c.warning.copy(alpha = 0.38f)
        },
        Motion.moderate(), label = "qBorder",
    )
    val fade by animateFloatAsState(if (state is AnswerState.Elsewhere || state == AnswerState.Expired) 0.7f else 1f, Motion.moderate(), label = "qFade")

    SiCard(
        modifier.fillMaxWidth().graphicsLayer { alpha = fade },
        borderColor = border,
        elevation = 8.dp,
        padding = PaddingValues(16.dp),
    ) {
        Column(Modifier.animateContentSize(Motion.sizeSpring)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                session?.let { ProviderMark(it.provider, 22.dp); Spacer(Modifier.width(8.dp)) }
                Text(kindLabel(question.kind).uppercase(), style = SiliconType.eyebrow, color = c.warning)
                val origin = session?.let { it.title?.takeIf { t -> t.isNotBlank() } ?: it.project ?: Providers.info(it.provider).name }
                if (origin != null) {
                    Text(
                        "  ·  $origin",
                        style = SiliconType.hint,
                        color = c.textMuted,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                } else Spacer(Modifier.weight(1f))
                Text(Format.ago(question.createdAt, now), style = SiliconType.hint.copy(fontFeatureSettings = "tnum"), color = c.textFaint)
            }
            Spacer(Modifier.height(10.dp))
            Text(question.title, style = SiliconType.h3.copy(fontWeight = androidx.compose.ui.text.font.FontWeight(600)), color = c.foreground)
            question.body?.takeIf { it.isNotBlank() }?.let { body ->
                Spacer(Modifier.height(8.dp))
                val code = question.kind == "permission"
                Text(
                    body,
                    style = if (code) SiliconType.mono else SiliconType.small,
                    color = c.textSecondary,
                    maxLines = if (expanded) 60 else 5,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(SmoothShape(10.dp))
                        .then(if (code) Modifier.background(c.surfaceMuted).padding(10.dp) else Modifier)
                        .pressable(pressedScale = 1f, haptic = false) { expanded = !expanded },
                )
            }
            Spacer(Modifier.height(14.dp))
            AnimatedContent(
                targetState = resolved,
                transitionSpec = { (fadeIn(Motion.enterTween()) + scaleIn(Motion.slow(), initialScale = 0.92f)) togetherWith fadeOut(Motion.exitTween()) },
                label = "qOutcome",
            ) { done ->
                if (done) Outcome(state, macName)
                else Column {
                    if (state is AnswerState.Failed) {
                        Row(
                            Modifier.fillMaxWidth().clip(SmoothShape(10.dp)).background(c.danger.copy(alpha = 0.08f))
                                .pressable(haptic = false) { onDismissFailure(question.id) }.padding(10.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(SiIcons.Alert, null, tint = c.danger, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(8.dp))
                            Text(state.message, style = SiliconType.hint, color = c.danger, modifier = Modifier.weight(1f))
                            Text("Retry", style = SiliconType.caption, color = c.danger)
                        }
                        Spacer(Modifier.height(10.dp))
                    }
                    val sending = state as? AnswerState.Sending
                    if (question.options.isNotEmpty()) {
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            question.options.forEach { option ->
                                SiButton(
                                    option.label,
                                    onClick = {
                                        haptics.performHapticFeedback(HapticFeedbackType.Confirm)
                                        onAnswer(question, option.id, null)
                                    },
                                    kind = buttonKind(option, question.options),
                                    compact = true,
                                    loading = sending?.optionId == option.id,
                                    enabled = sending == null,
                                )
                            }
                        }
                    }
                    if (question.allowText) {
                        if (question.options.isNotEmpty()) Spacer(Modifier.height(10.dp))
                        AnswerField(
                            value = text,
                            onValueChange = { text = it },
                            enabled = sending == null,
                            sending = sending != null && sending.optionId == null,
                            onSend = {
                                if (text.isNotBlank()) {
                                    focus.clearFocus()
                                    haptics.performHapticFeedback(HapticFeedbackType.Confirm)
                                    onAnswer(question, null, text)
                                }
                            },
                        )
                    }
                    if (question.options.isEmpty() && !question.allowText) {
                        Text("Answer this one on $macName.", style = SiliconType.hint, color = c.textMuted)
                    }
                }
            }
        }
    }
}

@Composable
private fun AnswerField(value: String, onValueChange: (String) -> Unit, enabled: Boolean, sending: Boolean, onSend: () -> Unit) {
    val c = Silicon.colors
    val canSend = value.isNotBlank() && enabled
    val sendBg by animateColorAsState(if (canSend) c.accent else c.surfacePressed, Motion.fast(), label = "sendBg")
    Row(
        Modifier.fillMaxWidth().clip(SmoothShape(14.dp)).background(c.surfaceMuted).padding(start = 14.dp, end = 5.dp, top = 5.dp, bottom = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.weight(1f).heightIn(min = 36.dp), contentAlignment = Alignment.CenterStart) {
            if (value.isEmpty()) Text("Type an answer…", style = SiliconType.small, color = c.textFaint)
            BasicTextField(
                value = value,
                onValueChange = onValueChange,
                enabled = enabled,
                textStyle = SiliconType.small.copy(color = c.foreground),
                cursorBrush = SolidColor(c.accent),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                keyboardActions = KeyboardActions(onSend = { onSend() }),
                maxLines = 5,
                modifier = Modifier.fillMaxWidth(),
            )
        }
        Spacer(Modifier.width(6.dp))
        Box(
            Modifier.size(36.dp).clip(CircleShape).background(sendBg).pressable(enabled = canSend, pressedScale = 0.9f, onClick = onSend),
            contentAlignment = Alignment.Center,
        ) {
            if (sending) androidx.compose.material3.CircularProgressIndicator(color = c.accentForeground, strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
            else Icon(SiIcons.Send, "Send", tint = if (canSend) c.accentForeground else c.textFaint, modifier = Modifier.size(18.dp))
        }
    }
}

@Composable
private fun Outcome(state: AnswerState?, macName: String) {
    val c = Silicon.colors
    val (icon, tint, title, detail) = when (state) {
        is AnswerState.Sent -> Quad(SiIcons.Check, c.success, "Sent to $macName", state.label.takeIf { it.isNotBlank() })
        is AnswerState.Elsewhere -> Quad(
            SiIcons.Done, c.textMuted,
            when (state.from) {
                "mac" -> "Answered on the Mac"
                "web" -> "Answered on the web"
                "iphone" -> "Answered on iPhone"
                "android" -> "Answered on another phone"
                else -> "Answered elsewhere"
            },
            "Someone got there first.",
        )
        AnswerState.Expired -> Quad(SiIcons.Clock, c.textMuted, "This question expired", null)
        else -> Quad(SiIcons.Done, c.textMuted, "Resolved", null)
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        IconBubble(icon, tint, tint.copy(alpha = 0.12f), 34.dp)
        Spacer(Modifier.width(12.dp))
        Column {
            Text(title, style = SiliconType.label, color = if (state is AnswerState.Sent) c.success else c.textSecondary)
            detail?.let { Text(it, style = SiliconType.hint, color = c.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis) }
        }
    }
}

private data class Quad<A, B, C, D>(val a: A, val b: B, val c: C, val d: D)
