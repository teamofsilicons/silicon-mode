package ai.tos.mode.ui.stats

import ai.tos.mode.data.MacItem
import ai.tos.mode.data.Providers
import ai.tos.mode.data.StatsState
import ai.tos.mode.data.StatsSummary
import ai.tos.mode.ui.Format
import ai.tos.mode.ui.components.EmptyNote
import ai.tos.mode.ui.components.Eyebrow
import ai.tos.mode.ui.components.IconBubble
import ai.tos.mode.ui.components.ProviderMark
import ai.tos.mode.ui.components.SiCard
import ai.tos.mode.ui.theme.Motion
import ai.tos.mode.ui.theme.SiIcons
import ai.tos.mode.ui.theme.Silicon
import ai.tos.mode.ui.theme.SiliconType
import ai.tos.mode.ui.theme.SmoothShape
import ai.tos.mode.ui.theme.pressable
import ai.tos.mode.ui.theme.reduceMotion
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.TextUnitType
import androidx.compose.ui.unit.dp

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StatsScreen(
    state: StatsState,
    macs: List<MacItem>,
    contentPadding: PaddingValues,
    onScope: (String?) -> Unit,
    onRefresh: () -> Unit,
) {
    val c = Silicon.colors
    val s = state.summary
    var pick by remember(state.deviceId, s.days.size) { mutableStateOf<HeatPick?>(null) }

    PullToRefreshBox(isRefreshing = state.loading && state.loaded, onRefresh = onRefresh, modifier = Modifier.fillMaxSize()) {
        LazyColumn(contentPadding = contentPadding, verticalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxSize()) {
            item(key = "title") {
                Column(Modifier.padding(start = 4.dp, end = 4.dp, top = 6.dp, bottom = 2.dp)) {
                    Eyebrow("Stats")
                    Spacer(Modifier.height(2.dp))
                    Text("Your patterns", style = SiliconType.display, color = c.foreground)
                    Spacer(Modifier.height(4.dp))
                    Text("When your agents run, hour by hour, day after day.", style = SiliconType.small, color = c.textMuted)
                }
            }
            if (macs.size > 1) {
                item(key = "scope") { ScopePicker(macs, state.deviceId, onScope) }
            }
            state.error?.let { msg ->
                item(key = "err") { Text(msg, style = SiliconType.small, color = c.danger, modifier = Modifier.padding(horizontal = 4.dp)) }
            }
            if (!state.loaded) {
                item(key = "loading") {
                    Box(Modifier.fillMaxWidth().height(420.dp).clip(SmoothShape(22.dp)).background(c.surfaceMuted))
                }
                return@LazyColumn
            }
            item(key = "tiles") { Tiles(s) }
            item(key = "heat") {
                SiCard(Modifier.fillMaxWidth(), padding = PaddingValues(start = 12.dp, end = 0.dp, top = 16.dp, bottom = 14.dp)) {
                    Column {
                        Row(Modifier.padding(start = 4.dp, end = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text("24h × days", style = SiliconType.h3, color = c.foreground)
                                Text("${s.days.size} days · a new column every day", style = SiliconType.hint, color = c.textMuted)
                            }
                            HeatLegend()
                        }
                        Spacer(Modifier.height(12.dp))
                        Heatmap(s.days, s.today, pick) { pick = it }
                        Spacer(Modifier.height(10.dp))
                        Box(Modifier.padding(start = 4.dp, end = 16.dp)) { PickDetail(pick, s) }
                    }
                }
            }
            item(key = "hours") { HourOfDay(s) }
            item(key = "providers") { ProviderBreakdown(s) }
        }
    }
}

@Composable
private fun ScopePicker(macs: List<MacItem>, selected: String?, onScope: (String?) -> Unit) {
    val c = Silicon.colors
    val options = listOf<Pair<String?, String>>(null to "All Macs") + macs.map { it.device.id to it.device.name }
    LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(horizontal = 2.dp)) {
        items(options, key = { it.first ?: "all" }) { (id, label) ->
            val active = id == selected
            val bg by animateColorAsState(if (active) c.primary else c.surfaceMuted, Motion.moderate(), label = "scopeBg")
            val fg by animateColorAsState(if (active) c.primaryForeground else c.textSecondary, Motion.moderate(), label = "scopeFg")
            Text(
                label, style = SiliconType.label, color = fg, maxLines = 1,
                modifier = Modifier.clip(SmoothShape(14.dp)).background(bg).pressable { onScope(id) }.padding(horizontal = 14.dp, vertical = 9.dp),
            )
        }
    }
}

@Composable
private fun Tiles(s: StatsSummary) {
    val c = Silicon.colors
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Tile(
                SiIcons.Clock, c.accent, "Agent time", Format.hours(s.agentSecondsWindow), null,
                "last ${s.windowDays} days · ${Format.hours(s.agentSeconds7d)} this week", Modifier.weight(1f),
            )
            Tile(
                SiIcons.Calendar, c.success, "Active days", s.activeDaysWindow.toString(), "/${s.windowDays}",
                "skipped ${s.skippedDays} ${if (s.skippedDays == 1) "day" else "days"} in all", Modifier.weight(1f),
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Tile(
                SiIcons.Flame, c.warning, "Streak", s.currentStreak.toString(), if (s.currentStreak == 1) " day" else " days",
                "longest ${s.longestStreak}", Modifier.weight(1f),
            )
            Tile(
                SiIcons.Activity, c.inkFrom, "Busiest hour", s.busiestHour?.let { Format.hour(it) } ?: "–", null,
                if (s.peakConcurrent > 0) "up to ${s.peakConcurrent} agents at once" else "no agents yet", Modifier.weight(1f),
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Tile(
                SiIcons.Laptop, c.inkTo, "Silicon Mode", Format.hours(s.siliconModeSeconds), null,
                "lid half-closed, last ${s.windowDays} days", Modifier.weight(1f),
            )
            Tile(
                SiIcons.Terminal, c.textSecondary, "Sessions", s.sessionsStarted.toString(), null,
                "started, last ${s.windowDays} days", Modifier.weight(1f),
            )
        }
    }
}

@Composable
private fun Tile(icon: ImageVector, tint: Color, label: String, value: String, unit: String?, caption: String, modifier: Modifier) {
    val c = Silicon.colors
    SiCard(modifier, elevation = 3.dp, padding = PaddingValues(14.dp)) {
        Column {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconBubble(icon, tint, tint.copy(alpha = if (c.dark) 0.16f else 0.1f), 26.dp)
                Spacer(Modifier.width(8.dp))
                Text(label, style = SiliconType.caption, color = c.textMuted)
            }
            Spacer(Modifier.height(12.dp))
            AnimatedContent(
                targetState = value to unit,
                transitionSpec = { (fadeIn(Motion.enterTween()) + slideInVertically(Motion.offsetSpring) { it / 3 }) togetherWith fadeOut(Motion.exitTween()) },
                label = "tile",
            ) { (v, u) ->
                Text(
                    buildAnnotatedString {
                        append(v)
                        if (u != null) withStyle(SpanStyle(color = c.textFaint, fontSize = TextUnit(16f, TextUnitType.Sp))) { append(u) }
                    },
                    style = SiliconType.number(TextUnit(28f, TextUnitType.Sp)),
                    color = c.foreground,
                    maxLines = 1,
                )
            }
            Spacer(Modifier.height(4.dp))
            Text(caption, style = SiliconType.hint, color = c.textMuted, maxLines = 2)
        }
    }
}

@Composable
private fun PickDetail(pick: HeatPick?, s: StatsSummary) {
    val c = Silicon.colors
    AnimatedContent(
        targetState = pick,
        transitionSpec = { (fadeIn(Motion.enterTween()) + slideInVertically(Motion.offsetSpring) { it / 3 }) togetherWith fadeOut(Motion.exitTween()) },
        label = "pick",
    ) { p ->
        if (p == null) {
            Text("Tap a square to see that hour.", style = SiliconType.hint, color = c.textFaint, modifier = Modifier.padding(vertical = 6.dp))
        } else {
            Row(
                Modifier.fillMaxWidth().clip(SmoothShape(14.dp)).background(c.surfaceMuted).padding(12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text("${Format.day(p.date, s.today)} · ${Format.hourRange(p.hour)}", style = SiliconType.label, color = c.foreground)
                    val cell = p.cell
                    Text(
                        if (cell == null || cell.agentSeconds <= 0) "No agents ran this hour."
                        else buildString {
                            append("${Format.duration(cell.agentSeconds)} of agent time")
                            if (cell.maxConcurrent > 1) append(" · up to ${cell.maxConcurrent} at once")
                            if (cell.sessionsStarted > 0) append(" · ${cell.sessionsStarted} started")
                            if (cell.devices > 1) append(" · ${cell.devices} Macs")
                        },
                        style = SiliconType.hint, color = c.textMuted,
                    )
                }
                Box(Modifier.size(22.dp).clip(SmoothShape(6.dp)).background(c.heat(ai.tos.mode.data.StatsMath.level(p.cell?.agentSeconds ?: 0))))
            }
        }
    }
}

@Composable
private fun HourOfDay(s: StatsSummary) {
    val c = Silicon.colors
    val still = reduceMotion()
    val grow = remember { Animatable(if (still) 1f else 0f) }
    LaunchedEffect(s.byHourOfDay) { grow.animateTo(1f, Motion.expressive()) }
    val max = s.byHourOfDay.maxOrNull()?.coerceAtLeast(1) ?: 1
    SiCard(Modifier.fillMaxWidth()) {
        Column {
            Text("By hour of day", style = SiliconType.h3, color = c.foreground)
            Text(
                s.busiestHour?.let { "Your agents run most around ${Format.hour(it)}." } ?: "Nothing yet.",
                style = SiliconType.hint, color = c.textMuted,
            )
            Spacer(Modifier.height(14.dp))
            Canvas(Modifier.fillMaxWidth().height(84.dp)) {
                val n = 24
                val gap = 3.dp.toPx()
                val w = (size.width - gap * (n - 1)) / n
                s.byHourOfDay.forEachIndexed { h, v ->
                    val frac = (v.toFloat() / max) * grow.value
                    val bh = (size.height * frac).coerceAtLeast(if (v > 0) 3.dp.toPx() else 2.dp.toPx())
                    val color = when {
                        v <= 0 -> c.surfaceMuted
                        h == s.busiestHour -> c.accent
                        else -> c.accent.copy(alpha = 0.35f)
                    }
                    drawRoundRect(color, Offset(h * (w + gap), size.height - bh), Size(w, bh), CornerRadius(w * 0.35f))
                }
            }
            Spacer(Modifier.height(6.dp))
            Row(Modifier.fillMaxWidth()) {
                listOf("00", "06", "12", "18", "23").forEachIndexed { i, label ->
                    Text(label, style = SiliconType.monoSmall, color = c.textFaint)
                    if (i < 4) Spacer(Modifier.weight(1f))
                }
            }
        }
    }
}

@Composable
private fun ProviderBreakdown(s: StatsSummary) {
    val c = Silicon.colors
    val still = reduceMotion()
    val grow = remember { Animatable(if (still) 1f else 0f) }
    LaunchedEffect(s.providers) { grow.animateTo(1f, Motion.expressive()) }
    SiCard(Modifier.fillMaxWidth()) {
        Column {
            Text("By agent", style = SiliconType.h3, color = c.foreground)
            Text("Agent time per provider, last ${s.windowDays} days.", style = SiliconType.hint, color = c.textMuted)
            Spacer(Modifier.height(14.dp))
            if (s.providers.isEmpty()) {
                EmptyNote(SiIcons.Stats, "No usage yet", "Run an agent on your Mac and it shows up here within the hour.")
                return@Column
            }
            Canvas(Modifier.fillMaxWidth().height(12.dp).clip(SmoothShape(6.dp))) {
                drawRect(c.surfaceMuted)
                var x = 0f
                val gap = 2.dp.toPx()
                s.providers.forEach { share ->
                    val w = size.width * share.fraction * grow.value
                    if (w > 0.5f) drawRect(Color(Providers.info(share.provider).color), Offset(x, 0f), Size((w - gap).coerceAtLeast(1f), size.height))
                    x += w
                }
            }
            Spacer(Modifier.height(14.dp))
            s.providers.take(8).forEach { share ->
                val info = Providers.info(share.provider)
                Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                    ProviderMark(share.provider, 26.dp)
                    Spacer(Modifier.width(10.dp))
                    Text(info.name, style = SiliconType.label, color = c.foreground, modifier = Modifier.weight(1f))
                    Text(Format.hours(share.seconds), style = SiliconType.label.copy(fontFeatureSettings = "tnum"), color = c.textSecondary)
                    Spacer(Modifier.width(10.dp))
                    Text(
                        "${(share.fraction * 100).toInt()}%",
                        style = SiliconType.hint.copy(fontFeatureSettings = "tnum"),
                        color = c.textFaint,
                        modifier = Modifier.width(34.dp),
                        textAlign = androidx.compose.ui.text.style.TextAlign.End,
                    )
                }
            }
        }
    }
}
