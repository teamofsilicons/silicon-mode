package ai.tos.mode.ui.home

import ai.tos.mode.data.AgentEvent
import ai.tos.mode.data.AgentSession
import ai.tos.mode.data.Providers
import ai.tos.mode.ui.Format
import ai.tos.mode.ui.theme.Motion
import ai.tos.mode.ui.theme.Night
import ai.tos.mode.ui.theme.SiIcons
import ai.tos.mode.ui.theme.SiliconType
import ai.tos.mode.ui.theme.SmoothShape
import ai.tos.mode.ui.theme.pressable
import ai.tos.mode.ui.theme.reduceMotion
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.StartOffset
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.keyframes
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

private fun glyph(kind: String): Pair<String, Color> = when (kind) {
    "user" -> "›" to Night.lavender
    "assistant" -> "✦" to Night.peach
    "tool_call" -> "→" to Night.accent
    "tool_result" -> "←" to Night.muted
    "status" -> "•" to Night.secondary
    "error" -> "✕" to Night.danger
    "question" -> "?" to Night.warning
    "answer" -> "✓" to Night.success
    else -> "·" to Night.faint
}

/**
 * The live tail: the Mac's last events as a terminal on the night palette, newest at the bottom
 * like `tail -f`. New lines unfold in with a brief highlight. Tapping an agent above filters it.
 */
@Composable
fun TailCard(
    events: List<AgentEvent>,
    sessions: Map<String, AgentSession>,
    filter: AgentSession?,
    onClearFilter: () -> Unit,
    maxLines: Int = 14,
) {
    val shown = remember(events, filter) {
        events.asSequence().filter { filter == null || it.sessionId == filter.id }.sortedBy { it.id }.toList().takeLast(maxLines)
    }
    // Lines present when the card first appears do not animate; later arrivals do.
    val known = remember { HashSet<Long>() }
    val primed = remember { booleanArrayOf(false) }
    val shape = SmoothShape(22.dp)
    Column(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(Night.background)
            .border(1.dp, Night.border, shape)
            .padding(start = 14.dp, end = 14.dp, top = 12.dp, bottom = 14.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            listOf(Color(0xFFFF5F57), Color(0xFFFEBC2E), Color(0xFF28C840)).forEach {
                Box(Modifier.size(8.dp).clip(CircleShape).background(it.copy(alpha = 0.8f)))
                Spacer(Modifier.width(5.dp))
            }
            Spacer(Modifier.width(6.dp))
            Text("tail -f", style = SiliconType.monoSmall, color = Night.faint, modifier = Modifier.weight(1f))
            if (filter != null) {
                Row(
                    Modifier.clip(SmoothShape(8.dp)).background(Night.surface).pressable(onClick = onClearFilter).padding(start = 8.dp, end = 4.dp, top = 3.dp, bottom = 3.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(Modifier.size(6.dp).clip(CircleShape).background(Color(Providers.info(filter.provider).color)))
                    Spacer(Modifier.width(6.dp))
                    Text(
                        filter.title?.takeIf { it.isNotBlank() } ?: Providers.info(filter.provider).name,
                        style = SiliconType.monoSmall, color = Night.secondary, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.width(140.dp),
                    )
                    Icon(SiIcons.Close, "Show every agent", tint = Night.muted, modifier = Modifier.size(14.dp))
                }
            }
        }
        Spacer(Modifier.height(10.dp))
        if (shown.isEmpty()) {
            Text("waiting for events…", style = SiliconType.mono, color = Night.faint)
        }
        shown.forEach { event ->
            key(event.id) {
                val isNew = primed[0] && event.id !in known
                TailLine(event, sessions[event.sessionId], isNew)
            }
        }
        Cursor()
    }
    SideEffect {
        shown.forEach { known += it.id }
        primed[0] = true
    }
}

@Composable
private fun TailLine(event: AgentEvent, session: AgentSession?, animate: Boolean) {
    val still = reduceMotion()
    val visible = remember { MutableTransitionState(!animate || still).apply { targetState = true } }
    val highlight = remember { Animatable(if (animate && !still) 1f else 0f) }
    LaunchedEffect(Unit) { if (highlight.value > 0f) highlight.animateTo(0f, tween(1400, easing = Motion.standard)) }
    val (g, color) = glyph(event.kind)
    AnimatedVisibility(
        visibleState = visible,
        enter = expandVertically(Motion.sizeSpring, expandFrom = Alignment.Top) + fadeIn(tween(260, easing = Motion.enter)),
    ) {
        Row(
            Modifier
                .fillMaxWidth()
                .drawBehind { if (highlight.value > 0f) drawRect(Night.accent.copy(alpha = 0.16f * highlight.value)) }
                .padding(vertical = 2.dp),
            verticalAlignment = Alignment.Top,
        ) {
            Text(Format.clock(event.at), style = SiliconType.monoSmall.copy(fontFeatureSettings = "tnum"), color = Night.faint, modifier = Modifier.padding(top = 2.dp))
            Spacer(Modifier.width(8.dp))
            Box(Modifier.padding(top = 6.dp).size(6.dp).clip(CircleShape).background(Color(Providers.info(session?.provider ?: "").color)))
            Spacer(Modifier.width(7.dp))
            Text(g, style = SiliconType.mono, color = color, modifier = Modifier.width(12.dp))
            Spacer(Modifier.width(4.dp))
            Text(
                event.summary,
                style = SiliconType.mono,
                color = if (event.kind == "error") Night.danger else Night.secondary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
        }
    }
}

@Composable
private fun Cursor() {
    val still = reduceMotion()
    val alpha = if (still) null else rememberInfiniteTransition(label = "cursor").animateFloat(
        initialValue = 1f,
        targetValue = 0f,
        animationSpec = infiniteRepeatable(
            keyframes { durationMillis = 1060; 1f at 0; 1f at 529; 0f at 530; 0f at 1059 },
            RepeatMode.Restart,
            StartOffset(0),
        ),
        label = "blink",
    )
    Row(Modifier.padding(top = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Text("❯", style = SiliconType.mono, color = Night.accent)
        Spacer(Modifier.width(6.dp))
        Box(Modifier.size(width = 7.dp, height = 14.dp).graphicsLayer { this.alpha = alpha?.value ?: 1f }.background(Night.secondary))
    }
}
