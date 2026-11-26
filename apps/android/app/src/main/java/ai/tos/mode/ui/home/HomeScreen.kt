package ai.tos.mode.ui.home

import ai.tos.mode.data.AgentEvent
import ai.tos.mode.data.AgentSession
import ai.tos.mode.data.AnswerState
import ai.tos.mode.data.CellUser
import ai.tos.mode.data.DeviceFeed
import ai.tos.mode.data.MacItem
import ai.tos.mode.data.Question
import ai.tos.mode.data.Realtime
import ai.tos.mode.data.Times
import ai.tos.mode.ui.Format
import ai.tos.mode.ui.components.AgentUiState
import ai.tos.mode.ui.components.EmptyNote
import ai.tos.mode.ui.components.Eyebrow
import ai.tos.mode.ui.components.IconBubble
import ai.tos.mode.ui.components.ProviderMark
import ai.tos.mode.ui.components.PulseDot
import ai.tos.mode.ui.components.RollingNumber
import ai.tos.mode.ui.components.SectionHeader
import ai.tos.mode.ui.components.SiCard
import ai.tos.mode.ui.components.StatePill
import ai.tos.mode.ui.components.stateColor
import ai.tos.mode.ui.rememberNow
import ai.tos.mode.ui.theme.Motion
import ai.tos.mode.ui.theme.SiIcons
import ai.tos.mode.ui.theme.Silicon
import ai.tos.mode.ui.theme.SiliconType
import ai.tos.mode.ui.theme.SmoothShape
import ai.tos.mode.ui.theme.pressable
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

data class HomeData(
    val user: CellUser?,
    val macs: List<MacItem>,
    val selected: MacItem?,
    val feed: DeviceFeed,
    val answers: Map<String, AnswerState>,
    val live: Realtime.Status,
    val loaded: Boolean,
    val refreshing: Boolean,
    val error: String?,
)

private val stateOrder = listOf(AgentUiState.NeedsYou, AgentUiState.Working, AgentUiState.Idle, AgentUiState.Failed, AgentUiState.Finished)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(
    data: HomeData,
    contentPadding: PaddingValues,
    onSelect: (String) -> Unit,
    onRefresh: () -> Unit,
    onAnswer: (Question, String?, String?) -> Unit,
    onDismissFailure: (String) -> Unit,
) {
    val c = Silicon.colors
    val now by rememberNow(15_000)
    var showAllAgents by rememberSaveable { mutableStateOf(false) }
    var tailFilter by rememberSaveable { mutableStateOf<String?>(null) }

    val sessionsById = remember(data.feed.sessions) { data.feed.sessions.associateBy { it.id } }
    val lastEventBySession = remember(data.feed.events) {
        data.feed.events.groupBy { it.sessionId }.mapValues { (_, list) -> list.maxByOrNull { it.id } }
    }
    val agents = remember(data.feed.sessions) {
        data.feed.sessions.sortedWith(
            compareBy<AgentSession> { stateOrder.indexOf(AgentUiState.of(it)) }
                .thenByDescending { Times.parse(it.lastEventAt) },
        )
    }
    val shownAgents = if (showAllAgents) agents else agents.take(8)

    PullToRefreshBox(isRefreshing = data.refreshing, onRefresh = onRefresh, modifier = Modifier.fillMaxSize()) {
        LazyColumn(
            contentPadding = contentPadding,
            verticalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.fillMaxSize(),
        ) {
            item(key = "header") { HomeHeader(data.user, data.live) }

            if (data.macs.size > 1) {
                item(key = "picker") { MacPicker(data.macs, data.selected?.device?.id, onSelect) }
            }

            if (data.error != null) {
                item(key = "error") { ErrorBanner(data.error) }
            }

            val mac = data.selected
            if (mac == null) {
                item(key = "nomac") {
                    when {
                        !data.loaded -> HeroPlaceholder()
                        data.error == null -> NoMacCard()
                        else -> Unit
                    }
                }
                return@LazyColumn
            }

            item(key = "hero:${mac.device.id}") { HeroCard(mac, now, Modifier.animateItem()) }
            item(key = "counts") { CountsRow(mac, data.feed) }

            val questions = data.feed.questions
            if (questions.isNotEmpty()) {
                item(key = "q-header") {
                    SectionHeader("Needs you", Modifier.animateItem()) {
                        val open = questions.count { data.answers[it.id] == null || data.answers[it.id] is AnswerState.Failed }
                        Text(
                            if (open == 0) "all answered" else Format.agentCount(open, "question"),
                            style = SiliconType.caption, color = if (open == 0) c.success else c.warning,
                        )
                    }
                }
                items(questions, key = { "q:${it.id}" }) { q ->
                    QuestionCard(
                        question = q,
                        session = q.sessionId?.let { sessionsById[it] },
                        state = data.answers[q.id],
                        now = now,
                        macName = mac.device.name,
                        onAnswer = onAnswer,
                        onDismissFailure = onDismissFailure,
                        modifier = Modifier.animateItem(fadeInSpec = Motion.enterTween(), fadeOutSpec = Motion.exitTween(), placementSpec = Motion.offsetSpring),
                    )
                }
            }

            item(key = "a-header") {
                SectionHeader("Agents", Modifier.animateItem()) {
                    if (agents.size > 8) {
                        Text(
                            if (showAllAgents) "Show less" else "Show all ${agents.size}",
                            style = SiliconType.label, color = c.accent,
                            modifier = Modifier.clip(CircleShape).pressable { showAllAgents = !showAllAgents }.padding(horizontal = 8.dp, vertical = 4.dp),
                        )
                    }
                }
            }
            if (agents.isEmpty()) {
                item(key = "a-empty") {
                    SiCard(Modifier.fillMaxWidth().animateItem()) {
                        EmptyNote(SiIcons.Terminal, "No agents yet", "Agents running on ${mac.device.name} show up here as they start.")
                    }
                }
            } else {
                items(shownAgents, key = { "s:${it.id}" }) { session ->
                    AgentRow(
                        session = session,
                        lastEvent = lastEventBySession[session.id],
                        now = now,
                        filtered = tailFilter == session.id,
                        onClick = { tailFilter = if (tailFilter == session.id) null else session.id },
                        modifier = Modifier.animateItem(placementSpec = Motion.offsetSpring),
                    )
                }
            }

            item(key = "tail") {
                Column(Modifier.animateItem()) {
                    SectionHeader("Live tail") {
                        LiveBadge(data.live)
                    }
                    TailCard(
                        events = data.feed.events,
                        sessions = sessionsById,
                        filter = tailFilter?.let { sessionsById[it] },
                        onClearFilter = { tailFilter = null },
                    )
                }
            }
        }
    }
}

@Composable
private fun HomeHeader(user: CellUser?, live: Realtime.Status) {
    val c = Silicon.colors
    Row(Modifier.fillMaxWidth().padding(start = 4.dp, end = 4.dp, top = 6.dp, bottom = 2.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Eyebrow("Silicon Mode")
            Spacer(Modifier.height(2.dp))
            Text(
                greeting(user),
                style = SiliconType.display,
                color = c.foreground,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        ai.tos.mode.ui.components.Avatar(user, 38.dp)
    }
}

private fun greeting(user: CellUser?): String {
    val hour = java.time.LocalTime.now().hour
    val part = when (hour) { in 5..11 -> "Good morning"; in 12..16 -> "Good afternoon"; in 17..21 -> "Good evening"; else -> "Up late" }
    val name = user?.displayName?.split(' ')?.firstOrNull()?.takeIf { it.isNotBlank() }
    return if (name != null) "$part, $name" else part
}

@Composable
fun LiveBadge(live: Realtime.Status) {
    val c = Silicon.colors
    val (color, label) = when (live) {
        Realtime.Status.Live -> c.success to "Live"
        Realtime.Status.Connecting -> c.warning to "Connecting"
        Realtime.Status.Offline -> c.textFaint to "Offline"
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        PulseDot(color, pulsing = live == Realtime.Status.Live, size = 7.dp)
        Text(label, style = SiliconType.caption, color = c.textMuted)
    }
}

@Composable
private fun MacPicker(macs: List<MacItem>, selectedId: String?, onSelect: (String) -> Unit) {
    val c = Silicon.colors
    val listState = androidx.compose.foundation.lazy.rememberLazyListState()
    val index = macs.indexOfFirst { it.device.id == selectedId }
    // Keep the selected Mac in view (it may sit past the edge of the row).
    androidx.compose.runtime.LaunchedEffect(index) {
        if (index >= 0) {
            val visible = listState.layoutInfo.visibleItemsInfo
            val shown = visible.firstOrNull { it.index == index }
            val fully = shown != null && shown.offset >= 0 && shown.offset + shown.size <= listState.layoutInfo.viewportEndOffset
            if (!fully) listState.animateScrollToItem(index)
        }
    }
    LazyRow(state = listState, horizontalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(horizontal = 2.dp)) {
        items(macs, key = { it.device.id }) { mac ->
            val active = mac.device.id == selectedId
            val bg by animateColorAsState(if (active) c.primary else c.surfaceMuted, Motion.moderate(), label = "macBg")
            val fg by animateColorAsState(if (active) c.primaryForeground else c.textSecondary, Motion.moderate(), label = "macFg")
            val mode = mac.status?.mode ?: "off"
            val dot = when {
                mode == "panic" -> c.danger
                mode in setOf("active", "locked", "arming") -> if (active) c.inkFrom else c.accent
                isOnline(mac) -> c.success
                else -> c.textFaint
            }
            Row(
                Modifier.clip(SmoothShape(14.dp)).background(bg).pressable { onSelect(mac.device.id) }.padding(start = 8.dp, end = 14.dp, top = 8.dp, bottom = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                PulseDot(dot, pulsing = mode in setOf("active", "panic", "arming"), size = 7.dp)
                Icon(SiIcons.Laptop, null, tint = fg, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
                Text(mac.device.name, style = SiliconType.label, color = fg, maxLines = 1)
            }
        }
    }
}

internal fun isOnline(mac: MacItem, now: java.time.Instant = java.time.Instant.now()): Boolean {
    val status = mac.status ?: return false
    if (!status.online) return false
    val updated = Times.parse(status.updatedAt) ?: return status.online
    return java.time.Duration.between(updated, now).toMinutes() < 6
}

@Composable
private fun CountsRow(mac: MacItem, feed: DeviceFeed) {
    val c = Silicon.colors
    val status = mac.status
    // The Mac's own counts when it reports them; otherwise derive them from the sessions we have.
    val derived = feed.sessions.groupingBy { AgentUiState.of(it) }.eachCount()
    val needs = status?.agentsWaiting ?: derived[AgentUiState.NeedsYou] ?: 0
    val working = status?.agentsWorking ?: derived[AgentUiState.Working] ?: 0
    val finished = status?.agentsFinished ?: derived[AgentUiState.Finished] ?: 0
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        CountTile("Needs you", needs, c.stateColor(AgentUiState.NeedsYou), SiIcons.Bell, Modifier.weight(1f))
        CountTile("Working", working, c.stateColor(AgentUiState.Working), SiIcons.Activity, Modifier.weight(1f))
        CountTile("Finished", finished, c.stateColor(AgentUiState.Finished), SiIcons.Done, Modifier.weight(1f))
    }
}

@Composable
private fun CountTile(label: String, count: Int, color: Color, icon: androidx.compose.ui.graphics.vector.ImageVector, modifier: Modifier) {
    val c = Silicon.colors
    val lit = count > 0
    // Opaque tints: a translucent fill would let the card's shadow show through.
    val bg by animateColorAsState(if (lit) lerp(c.surface, color, if (c.dark) 0.12f else 0.06f) else c.surface, Motion.moderate(), label = "tileBg")
    val border by animateColorAsState(if (lit) color.copy(alpha = 0.22f) else c.border, Motion.moderate(), label = "tileBorder")
    SiCard(modifier, color = bg, borderColor = border, elevation = if (lit) 6.dp else 3.dp, padding = PaddingValues(14.dp)) {
        Column {
            Icon(icon, null, tint = if (lit) color else c.textFaint, modifier = Modifier.size(18.dp))
            Spacer(Modifier.height(12.dp))
            RollingNumber(count.toLong(), SiliconType.number(30.sp()), if (lit) c.foreground else c.textFaint)
            Spacer(Modifier.height(2.dp))
            Text(label, style = SiliconType.caption, color = if (lit) color else c.textMuted, maxLines = 1)
        }
    }
}

private fun Int.sp() = androidx.compose.ui.unit.TextUnit(this.toFloat(), androidx.compose.ui.unit.TextUnitType.Sp)

@Composable
private fun ErrorBanner(message: String) {
    val c = Silicon.colors
    Row(
        Modifier.fillMaxWidth().clip(SmoothShape(14.dp)).background(c.danger.copy(alpha = if (c.dark) 0.14f else 0.07f)).padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(SiIcons.Alert, null, tint = c.danger, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(10.dp))
        Column {
            Text(message, style = SiliconType.small, color = c.danger)
            Text("Pull down to try again.", style = SiliconType.hint, color = c.danger.copy(alpha = 0.7f))
        }
    }
}

@Composable
private fun NoMacCard() {
    val c = Silicon.colors
    SiCard(Modifier.fillMaxWidth(), padding = PaddingValues(22.dp)) {
        Column {
            IconBubble(SiIcons.Laptop, c.inkFrom, c.accentSubtle, 44.dp)
            Spacer(Modifier.height(16.dp))
            Text("Connect your Mac", style = SiliconType.h1, color = c.foreground)
            Spacer(Modifier.height(6.dp))
            Text(
                "Open Silicon Mode on your Mac and sign in with the same Silicon account. Its agents, questions and " +
                    "Silicon Mode status appear here live. Each Mac stays separate.",
                style = SiliconType.small, color = c.textMuted,
            )
            Spacer(Modifier.height(14.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Menu bar", style = SiliconType.label, color = c.textSecondary)
                Icon(SiIcons.ChevronRight, null, tint = c.textFaint, modifier = Modifier.size(16.dp))
                Text("Settings", style = SiliconType.label, color = c.textSecondary)
                Icon(SiIcons.ChevronRight, null, tint = c.textFaint, modifier = Modifier.size(16.dp))
                Text("Account", style = SiliconType.label, color = c.textSecondary)
            }
        }
    }
}

@Composable
private fun HeroPlaceholder() {
    val c = Silicon.colors
    Box(Modifier.fillMaxWidth().height(220.dp).clip(SmoothShape(30.dp)).background(c.surfaceMuted))
}

@Composable
private fun AgentRow(
    session: AgentSession,
    lastEvent: AgentEvent?,
    now: java.time.Instant,
    filtered: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val c = Silicon.colors
    val state = AgentUiState.of(session)
    val border by animateColorAsState(if (filtered) c.accent.copy(alpha = 0.6f) else c.border, Motion.fast(), label = "rowBorder")
    SiCard(
        modifier.fillMaxWidth().pressable(pressedScale = 0.985f, onClick = onClick),
        shape = SmoothShape(18.dp),
        borderColor = border,
        elevation = 3.dp,
        padding = PaddingValues(start = 14.dp, end = 14.dp, top = 13.dp, bottom = 13.dp),
    ) {
        Row(verticalAlignment = Alignment.Top) {
            ProviderMark(session.provider, 36.dp)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        session.title?.takeIf { it.isNotBlank() } ?: session.project ?: ai.tos.mode.data.Providers.info(session.provider).name,
                        style = SiliconType.label.copy(fontSize = androidx.compose.ui.unit.TextUnit(15f, androidx.compose.ui.unit.TextUnitType.Sp)),
                        color = c.foreground,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                }
                val meta = listOfNotNull(
                    ai.tos.mode.data.Providers.info(session.provider).name,
                    session.project?.takeIf { it.isNotBlank() && it != session.title },
                    session.model?.takeIf { it.isNotBlank() },
                ).joinToString(" · ")
                Text(meta, style = SiliconType.hint, color = c.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                val last = lastEvent?.summary?.takeIf { it.isNotBlank() }
                    ?: session.waitingReason?.let { "Waiting for ${it}" }
                if (last != null) {
                    Spacer(Modifier.height(6.dp))
                    Text(
                        last,
                        style = SiliconType.monoSmall,
                        color = c.textSecondary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.clip(SmoothShape(6.dp)).background(c.surfaceMuted).padding(horizontal = 6.dp, vertical = 3.dp),
                    )
                }
            }
            Spacer(Modifier.width(10.dp))
            Column(horizontalAlignment = Alignment.End) {
                StatePill(state)
                Spacer(Modifier.height(6.dp))
                Text(Format.ago(session.lastEventAt, now), style = SiliconType.hint.copy(fontFeatureSettings = "tnum"), color = c.textFaint)
            }
        }
    }
}

@Composable
internal fun FadeIn(visible: Boolean, content: @Composable () -> Unit) {
    AnimatedVisibility(visible, enter = fadeIn(Motion.enterTween()), exit = fadeOut(Motion.exitTween())) { content() }
}
