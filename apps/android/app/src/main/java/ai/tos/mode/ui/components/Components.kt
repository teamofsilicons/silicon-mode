package ai.tos.mode.ui.components

import ai.tos.mode.data.AgentSession
import ai.tos.mode.data.CellUser
import ai.tos.mode.data.Providers
import ai.tos.mode.ui.theme.Motion
import ai.tos.mode.ui.theme.Shapes
import ai.tos.mode.ui.theme.Silicon
import ai.tos.mode.ui.theme.SiliconColors
import ai.tos.mode.ui.theme.SiliconType
import ai.tos.mode.ui.theme.SmoothShape
import ai.tos.mode.ui.theme.pressable
import ai.tos.mode.ui.theme.reduceMotion
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import kotlin.math.cos
import kotlin.math.sin

// ---------------- agent state ----------------

enum class AgentUiState(val label: String) {
    NeedsYou("Needs you"), Working("Working"), Finished("Finished"), Idle("Idle"), Failed("Error");

    companion object {
        fun of(session: AgentSession): AgentUiState = when (session.state) {
            "waiting" -> NeedsYou
            "working", "starting" -> Working
            "finished" -> Finished
            "failed" -> Failed
            else -> Idle
        }
    }
}

fun SiliconColors.stateColor(state: AgentUiState): Color = when (state) {
    AgentUiState.NeedsYou -> warning
    AgentUiState.Working -> accent
    AgentUiState.Finished -> success
    AgentUiState.Idle -> textMuted
    AgentUiState.Failed -> danger
}

// ---------------- surfaces ----------------

/** A flat paper card: surface fill, hairline border, faint warm shadow, continuous corners. */
@Composable
fun SiCard(
    modifier: Modifier = Modifier,
    shape: Shape = Shapes.card,
    color: Color = Silicon.colors.surface,
    borderColor: Color = Silicon.colors.border,
    elevation: Dp = 10.dp,
    padding: PaddingValues = PaddingValues(18.dp),
    content: @Composable BoxScope.() -> Unit,
) {
    val c = Silicon.colors
    Box(
        modifier
            .shadow(
                elevation,
                shape,
                clip = false,
                ambientColor = c.shadow.copy(alpha = if (c.dark) 0.5f else 0.05f),
                spotColor = c.shadow.copy(alpha = if (c.dark) 0.6f else 0.08f),
            )
            .clip(shape)
            .background(color)
            .border(BorderStroke(1.dp, borderColor), shape)
            .padding(padding),
        content = content,
    )
}

@Composable
fun SectionHeader(title: String, modifier: Modifier = Modifier, trailing: @Composable (() -> Unit)? = null) {
    Row(
        modifier.fillMaxWidth().padding(start = 4.dp, end = 4.dp, top = 8.dp, bottom = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, style = SiliconType.h2, color = Silicon.colors.foreground, modifier = Modifier.weight(1f))
        trailing?.invoke()
    }
}

@Composable
fun Eyebrow(text: String, color: Color = Silicon.colors.textMuted, modifier: Modifier = Modifier) {
    Text(text.uppercase(), style = SiliconType.eyebrow, color = color, modifier = modifier)
}

// ---------------- marks ----------------

/** A provider's monogram disc in its brand colour (mirrors the Mac's ProviderMark). */
@Composable
fun ProviderMark(provider: String, size: Dp = 28.dp, modifier: Modifier = Modifier) {
    val info = Providers.info(provider)
    Box(
        modifier.size(size).clip(SmoothShape(size * 0.32f)).background(Color(info.color)),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            info.monogram,
            color = Color.White,
            style = SiliconType.label.copy(fontSize = (size.value * 0.4f).sp, lineHeight = (size.value * 0.45f).sp),
            maxLines = 1,
        )
    }
}

/** A status dot; [pulsing] adds a soft expanding ring (idle screens request no frames). */
@Composable
fun PulseDot(color: Color, pulsing: Boolean, modifier: Modifier = Modifier, size: Dp = 8.dp) {
    val still = reduceMotion()
    Box(modifier.size(size * 2.2f), contentAlignment = Alignment.Center) {
        if (pulsing && !still) {
            val t by rememberInfiniteTransition(label = "pulse").animateFloat(
                0f, 1f, infiniteRepeatable(tween(1600, easing = LinearEasing), RepeatMode.Restart), label = "p",
            )
            Canvas(Modifier.size(size * 2.2f)) {
                val base = size.toPx() / 2
                drawCircle(color.copy(alpha = 0.35f * (1f - t)), radius = base + (this.size.minDimension / 2 - base) * t)
            }
        }
        Box(Modifier.size(size).clip(CircleShape).background(color))
    }
}

@Composable
fun StatePill(state: AgentUiState, modifier: Modifier = Modifier) {
    val c = Silicon.colors
    val color = c.stateColor(state)
    Row(
        modifier.clip(CircleShape).background(color.copy(alpha = if (c.dark) 0.16f else 0.1f)).padding(start = 4.dp, end = 10.dp, top = 3.dp, bottom = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        PulseDot(color, pulsing = state == AgentUiState.Working || state == AgentUiState.NeedsYou, size = 6.dp)
        Text(state.label, style = SiliconType.caption, color = color)
    }
}

// ---------------- numbers ----------------

/** A number that rolls up or down when it changes. */
@Composable
fun RollingNumber(value: Long, style: TextStyle, color: Color, modifier: Modifier = Modifier, format: (Long) -> String = { it.toString() }) {
    val still = reduceMotion()
    AnimatedContent(
        targetState = value,
        transitionSpec = {
            if (still) fadeIn(tween(120)) togetherWith fadeOut(tween(80))
            else {
                val up = targetState > initialState
                (slideInVertically(Motion.offsetSpring) { if (up) it / 2 else -it / 2 } + fadeIn(tween(160))) togetherWith
                    (slideOutVertically(Motion.offsetSpring) { if (up) -it / 2 else it / 2 } + fadeOut(tween(100)))
            }
        },
        label = "number",
        modifier = modifier,
    ) { v -> Text(format(v), style = style, color = color, maxLines = 1) }
}

// ---------------- buttons ----------------

enum class ButtonKind { Primary, Accent, Secondary, Danger, Ghost }

@Composable
fun SiButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    kind: ButtonKind = ButtonKind.Primary,
    icon: ImageVector? = null,
    loading: Boolean = false,
    enabled: Boolean = true,
    compact: Boolean = false,
) {
    val c = Silicon.colors
    val (bg, fg, border) = when (kind) {
        ButtonKind.Primary -> Triple(c.primary, c.primaryForeground, Color.Transparent)
        ButtonKind.Accent -> Triple(c.accent, c.accentForeground, Color.Transparent)
        ButtonKind.Secondary -> Triple(c.surface, c.foreground, c.borderStrong.copy(alpha = 0.6f))
        ButtonKind.Danger -> Triple(c.danger.copy(alpha = if (c.dark) 0.14f else 0.07f), c.danger, c.danger.copy(alpha = 0.25f))
        ButtonKind.Ghost -> Triple(Color.Transparent, c.textSecondary, Color.Transparent)
    }
    val alpha by animateFloatAsState(if (enabled) 1f else 0.45f, Motion.fast(), label = "enabled")
    val shape = SmoothShape(if (compact) 12.dp else 14.dp)
    Row(
        modifier
            .graphicsLayer { this.alpha = alpha }
            .heightIn(min = if (compact) 38.dp else 50.dp)
            .clip(shape)
            .background(bg)
            .border(1.dp, border, shape)
            .pressable(enabled = enabled && !loading, onClick = onClick)
            .padding(horizontal = if (compact) 14.dp else 20.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (loading) {
            CircularProgressIndicator(color = fg, strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(10.dp))
        } else if (icon != null) {
            Icon(icon, null, tint = fg, modifier = Modifier.size(if (compact) 16.dp else 18.dp))
            Spacer(Modifier.width(8.dp))
        }
        Text(text, style = if (compact) SiliconType.label else SiliconType.h3.copy(fontWeight = androidx.compose.ui.text.font.FontWeight(500)), color = fg, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** Segmented control with a thumb that springs between options. */
@Composable
fun <T> Segmented(options: List<Pair<T, String>>, selected: T, onSelect: (T) -> Unit, modifier: Modifier = Modifier) {
    val c = Silicon.colors
    val index = options.indexOfFirst { it.first == selected }.coerceAtLeast(0)
    val pos by animateFloatAsState(index.toFloat(), Motion.moderate(), label = "segment")
    androidx.compose.foundation.layout.BoxWithConstraints(
        modifier.clip(SmoothShape(14.dp)).background(c.surfaceMuted).padding(3.dp),
    ) {
        val w = maxWidth / options.size
        Box(
            Modifier
                .offset(x = w * pos)
                .width(w)
                .height(36.dp)
                .shadow(3.dp, SmoothShape(11.dp), ambientColor = c.shadow.copy(alpha = 0.06f), spotColor = c.shadow.copy(alpha = 0.1f))
                .clip(SmoothShape(11.dp))
                .background(if (c.dark) c.surfacePressed else c.surface),
        )
        Row(Modifier.fillMaxWidth()) {
            options.forEach { (value, label) ->
                val active = value == selected
                val color by animateColorAsState(if (active) c.foreground else c.textMuted, Motion.fast(), label = "segColor")
                Box(
                    Modifier.weight(1f).height(36.dp).pressable(pressedScale = 0.96f) { onSelect(value) },
                    contentAlignment = Alignment.Center,
                ) { Text(label, style = SiliconType.label, color = color, maxLines = 1) }
            }
        }
    }
}

// ---------------- account ----------------

@Composable
fun Avatar(user: CellUser?, size: Dp, modifier: Modifier = Modifier) {
    val c = Silicon.colors
    Box(modifier.size(size).clip(CircleShape).background(c.siliconGradient), contentAlignment = Alignment.Center) {
        val initials = (user?.displayName ?: user?.id?.substringAfter(':') ?: "?")
            .split(' ', '-', '_').filter { it.isNotBlank() }.take(2).joinToString("") { it.take(1).uppercase() }
        Text(initials, style = SiliconType.label.copy(fontSize = (size.value * 0.38f).sp), color = c.gradientForeground)
        user?.pfpUrl?.takeIf { it.startsWith("https://") }?.let { url ->
            AsyncImage(model = url, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.size(size).clip(CircleShape))
        }
    }
}

// ---------------- the lid ----------------

/**
 * A laptop seen from the side: the base, and the lid hinged at the back at [angle] degrees,
 * with the angle's arc in [accent]. [siliconAngle] draws a faint ghost lid where Silicon Mode
 * started (panic fires below 90% of it).
 */
@Composable
fun LidGlyph(
    angle: Float?,
    siliconAngle: Float?,
    ink: Color,
    accent: Color,
    modifier: Modifier = Modifier,
    stroke: Dp = 4.dp,
) {
    val target = (angle ?: 110f).coerceIn(0f, 180f)
    val animated by animateFloatAsState(target, Motion.expressive(), label = "lid")
    Canvas(modifier) {
        val sw = stroke.toPx()
        val baseLen = size.width * 0.86f
        val lidLen = baseLen * 0.82f
        val hinge = Offset(size.width * 0.08f, size.height * 0.86f)
        fun lidEnd(deg: Float): Offset {
            val r = Math.toRadians(deg.toDouble())
            return Offset(hinge.x + (lidLen * cos(r)).toFloat(), hinge.y - (lidLen * sin(r)).toFloat())
        }
        siliconAngle?.let { sa ->
            drawLine(ink.copy(alpha = 0.14f), hinge, lidEnd(sa.coerceIn(0f, 180f)), sw * 0.8f, StrokeCap.Round)
        }
        val arcR = baseLen * 0.3f
        drawArc(
            color = accent,
            startAngle = -animated,
            sweepAngle = animated,
            useCenter = false,
            topLeft = Offset(hinge.x - arcR, hinge.y - arcR),
            size = androidx.compose.ui.geometry.Size(arcR * 2, arcR * 2),
            style = Stroke(sw * 0.75f, cap = StrokeCap.Round),
        )
        drawLine(ink, hinge, Offset(hinge.x + baseLen, hinge.y), sw, StrokeCap.Round)
        drawLine(ink, hinge, lidEnd(animated), sw, StrokeCap.Round)
    }
}

@Composable
fun Hairline(modifier: Modifier = Modifier, color: Color = Silicon.colors.border) {
    Box(modifier.fillMaxWidth().height(1.dp).background(color))
}

@Composable
fun IconBubble(icon: ImageVector, tint: Color, background: Color, size: Dp = 32.dp, modifier: Modifier = Modifier) {
    Box(modifier.size(size).clip(SmoothShape(size * 0.34f)).background(background), contentAlignment = Alignment.Center) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(size * 0.55f))
    }
}

@Composable
fun EmptyNote(icon: ImageVector, title: String, body: String, modifier: Modifier = Modifier) {
    val c = Silicon.colors
    Column(modifier.fillMaxWidth().padding(vertical = 22.dp, horizontal = 12.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        IconBubble(icon, c.textMuted, c.surfaceMuted, 40.dp)
        Spacer(Modifier.height(12.dp))
        Text(title, style = SiliconType.h3, color = c.foreground)
        Spacer(Modifier.height(4.dp))
        Text(body, style = SiliconType.small, color = c.textMuted, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
    }
}
