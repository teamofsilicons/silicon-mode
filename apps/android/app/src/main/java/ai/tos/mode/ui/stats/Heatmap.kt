package ai.tos.mode.ui.stats

import ai.tos.mode.data.HeatCell
import ai.tos.mode.data.HeatDay
import ai.tos.mode.data.StatsMath
import ai.tos.mode.ui.Format
import ai.tos.mode.ui.theme.Motion
import ai.tos.mode.ui.theme.Silicon
import ai.tos.mode.ui.theme.SiliconColors
import ai.tos.mode.ui.theme.SiliconType
import ai.tos.mode.ui.theme.reduceMotion
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.LocalTime

/** The selected heatmap cell: a day column and an hour row. */
data class HeatPick(val date: LocalDate, val hour: Int, val cell: HeatCell?)

private val CELL = 13.dp
private val GAP = 3.dp
private val HEADER = 20.dp

fun SiliconColors.heat(level: Int): Color {
    if (level <= 0) return if (dark) Color(0xFF1E1E1E) else Color(0xFFF0F0F0)
    val alphas = floatArrayOf(0f, 0.2f, 0.38f, 0.58f, 0.8f, 1f)
    return lerp(surface, accent, alphas[level.coerceIn(0, 5)])
}

/**
 * The 24h × days heatmap: one row per hour (00 at the top), one column per day (today at the
 * right, a new column every day), horizontally scrollable. Columns sweep in from today on first
 * show. Tap a cell for its details.
 */
@Composable
fun Heatmap(days: List<HeatDay>, today: LocalDate, selected: HeatPick?, onPick: (HeatPick?) -> Unit) {
    val c = Silicon.colors
    val still = reduceMotion()
    val density = LocalDensity.current
    val haptics = LocalHapticFeedback.current
    val scroll = rememberScrollState()
    val reveal = remember(days.size) { Animatable(if (still) 1f else 0f) }
    LaunchedEffect(days.size) {
        launch { reveal.animateTo(1f, tween(if (still) 0 else 900, easing = Motion.enter)) }
        // Open on today (the right edge) once the grid knows how far it scrolls.
        snapshotFlow { scroll.maxValue }.first { it in 1 until Int.MAX_VALUE }
        scroll.scrollTo(scroll.maxValue)
    }
    val pitch = CELL + GAP
    val nowHour = LocalTime.now().hour
    val gridHeight = HEADER + pitch * 24
    Row {
        // Hour labels stay put while the days scroll.
        Box(Modifier.width(26.dp).height(gridHeight)) {
            listOf(0, 6, 12, 18, 23).forEach { h ->
                Text(
                    "%02d".format(h),
                    style = SiliconType.monoSmall.copy(fontFeatureSettings = "tnum"),
                    color = c.textFaint,
                    modifier = Modifier.offset(y = HEADER + pitch * h - 1.dp),
                )
            }
        }
        Box(
            Modifier
                // Days fade out at the left edge as they scroll under the hour labels.
                .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
                .drawWithContent {
                    drawContent()
                    val fade = 18.dp.toPx()
                    drawRect(
                        Brush.horizontalGradient(0f to Color.Transparent, 1f to Color.Black, startX = 0f, endX = fade),
                        size = Size(fade, size.height),
                        blendMode = BlendMode.DstIn,
                    )
                }
                .horizontalScroll(scroll),
        ) {
            val width = pitch * days.size
            Column {
                // Month and Monday labels.
                Box(Modifier.width(width).height(HEADER)) {
                    days.forEachIndexed { i, day ->
                        val label = when {
                            day.date == today -> "today"
                            day.date.dayOfMonth == 1 || i == 0 -> Format.month(day.date)
                            day.date.dayOfWeek == DayOfWeek.MONDAY && days.size - i > 3 -> day.date.dayOfMonth.toString()
                            else -> null
                        }
                        if (label != null) {
                            Text(
                                label,
                                style = SiliconType.monoSmall,
                                color = if (day.date == today) c.accent else c.textFaint,
                                maxLines = 1,
                                softWrap = false,
                                modifier = Modifier.offset(x = pitch * i - (if (day.date == today) 22.dp else 0.dp)),
                            )
                        }
                    }
                }
                Canvas(
                    Modifier
                        .size(width, pitch * 24)
                        .pointerInput(days) {
                            detectTapGestures { pos ->
                                val p = with(density) { pitch.toPx() }
                                val col = (pos.x / p).toInt()
                                val row = (pos.y / p).toInt()
                                val day = days.getOrNull(col)
                                if (day == null || row !in 0..23) {
                                    onPick(null)
                                } else {
                                    haptics.performHapticFeedback(HapticFeedbackType.SegmentTick)
                                    val pick = HeatPick(day.date, row, day.hours[row])
                                    onPick(if (selected?.date == pick.date && selected.hour == row) null else pick)
                                }
                            }
                        },
                ) {
                    val cell = CELL.toPx()
                    val p = pitch.toPx()
                    val r = CornerRadius(cell * 0.28f)
                    val n = days.size
                    days.forEachIndexed { i, day ->
                        // Columns appear from today backwards.
                        val order = (n - 1 - i).toFloat() / n.coerceAtLeast(1)
                        val t = ((reveal.value - order * 0.6f) / 0.4f).coerceIn(0f, 1f)
                        if (t <= 0f) return@forEachIndexed
                        val inset = cell * (1f - t) / 2f
                        for (h in 0 until 24) {
                            val seconds = day.hours[h]?.agentSeconds ?: 0
                            val color = c.heat(StatsMath.level(seconds))
                            drawRoundRect(
                                color = color.copy(alpha = color.alpha * t),
                                topLeft = Offset(i * p + inset, h * p + inset),
                                size = Size(cell - inset * 2, cell - inset * 2),
                                cornerRadius = r,
                            )
                        }
                    }
                    if (days.lastOrNull()?.date == today) {
                        val i = n - 1
                        drawRoundRect(
                            color = c.accent,
                            topLeft = Offset(i * p - 1.5f, nowHour * p - 1.5f),
                            size = Size(cell + 3f, cell + 3f),
                            cornerRadius = CornerRadius(cell * 0.34f),
                            style = Stroke(1.5.dp.toPx()),
                        )
                    }
                    selected?.let { pick ->
                        val i = days.indexOfFirst { it.date == pick.date }
                        if (i >= 0) {
                            drawRoundRect(
                                color = c.foreground,
                                topLeft = Offset(i * p - 2.5f, pick.hour * p - 2.5f),
                                size = Size(cell + 5f, cell + 5f),
                                cornerRadius = CornerRadius(cell * 0.4f),
                                style = Stroke(2.dp.toPx()),
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun HeatLegend() {
    val c = Silicon.colors
    Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
        Text("less", style = SiliconType.hint, color = c.textFaint)
        Spacer(Modifier.width(6.dp))
        (0..5).forEach { level ->
            Canvas(Modifier.padding(horizontal = 1.5.dp).size(10.dp)) {
                drawRoundRect(c.heat(level), cornerRadius = CornerRadius(size.minDimension * 0.28f))
            }
        }
        Spacer(Modifier.width(6.dp))
        Text("more", style = SiliconType.hint, color = c.textFaint)
    }
}
