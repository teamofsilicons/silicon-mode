package ai.tos.mode.ui

import ai.tos.mode.AppGraph
import ai.tos.mode.data.DeviceFeed
import ai.tos.mode.ui.home.HomeData
import ai.tos.mode.ui.home.HomeScreen
import ai.tos.mode.ui.settings.SettingsData
import ai.tos.mode.ui.settings.SettingsScreen
import ai.tos.mode.ui.signin.SignInScreen
import ai.tos.mode.ui.stats.StatsScreen
import ai.tos.mode.ui.theme.Motion
import ai.tos.mode.ui.theme.SiIcons
import ai.tos.mode.ui.theme.Silicon
import ai.tos.mode.ui.theme.SiliconType
import ai.tos.mode.ui.theme.SmoothShape
import ai.tos.mode.ui.theme.pressable
import ai.tos.mode.ui.theme.reduceMotion
import android.content.Intent
import android.net.Uri
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.time.Instant

enum class Tab(val label: String) { Home("Home"), Stats("Stats"), Settings("Settings") }

/** The current instant, ticking every [periodMs] (only the composables that read it recompose). */
@Composable
fun rememberNow(periodMs: Long = 15_000): State<Instant> = produceState(Instant.now(), periodMs) {
    while (true) {
        delay(periodMs)
        value = Instant.now()
    }
}

@Composable
fun AppRoot(graph: AppGraph, onSignIn: () -> Unit) {
    val session by graph.sessions.session.collectAsStateWithLifecycle()
    val c = Silicon.colors
    Box(Modifier.fillMaxSize().background(c.background)) {
        AnimatedContent(
            targetState = session != null,
            transitionSpec = { (fadeIn(tween(320)) + scaleIn(initialScale = 0.98f)) togetherWith fadeOut(tween(160)) },
            label = "auth",
        ) { signedIn ->
            if (signedIn) MainTabs(graph) else {
                val busy by graph.signIn.busy.collectAsStateWithLifecycle()
                val message by graph.signIn.message.collectAsStateWithLifecycle()
                SignInScreen(busy = busy, message = message, onSignIn = onSignIn)
            }
        }
    }
}

@Composable
private fun MainTabs(graph: AppGraph) {
    var tab by rememberSaveable { mutableStateOf(Tab.Home) }
    val still = reduceMotion()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    val session by graph.sessions.session.collectAsStateWithLifecycle()
    val macs by graph.repo.macs.collectAsStateWithLifecycle()
    val selectedId by graph.repo.selectedId.collectAsStateWithLifecycle()
    val feeds by graph.repo.feeds.collectAsStateWithLifecycle()
    val answers by graph.repo.answers.collectAsStateWithLifecycle()
    val loaded by graph.repo.loaded.collectAsStateWithLifecycle()
    val refreshing by graph.repo.refreshing.collectAsStateWithLifecycle()
    val error by graph.repo.error.collectAsStateWithLifecycle()
    val live by graph.realtime.status.collectAsStateWithLifecycle()
    val stats by graph.repo.stats.collectAsStateWithLifecycle()
    val appearance by graph.prefs.appearance.collectAsStateWithLifecycle()

    val selected = macs.firstOrNull { it.device.id == selectedId }
    val feed = selectedId?.let { feeds[it] } ?: DeviceFeed()
    val pendingQuestions = feed.questions.count { answers[it.id] == null }

    LaunchedEffect(tab) {
        if (tab == Tab.Stats && !stats.loaded && !stats.loading) graph.repo.loadStats()
    }

    val insets = WindowInsets.statusBars.asPaddingValues()
    val nav = WindowInsets.navigationBars.asPaddingValues()
    val padding = PaddingValues(
        start = 16.dp, end = 16.dp,
        top = insets.calculateTopPadding() + 8.dp,
        bottom = nav.calculateBottomPadding() + 96.dp,
    )
    val c = Silicon.colors
    val openUrl: (String) -> Unit = { url ->
        runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
    }

    Box(Modifier.fillMaxSize()) {
        AnimatedContent(
            targetState = tab,
            transitionSpec = {
                if (still) fadeIn(tween(120)) togetherWith fadeOut(tween(80))
                else {
                    val forward = targetState.ordinal > initialState.ordinal
                    (fadeIn(tween(240, easing = Motion.enter)) + slideInHorizontally(tween(240, easing = Motion.enter)) { if (forward) 48 else -48 }) togetherWith
                        (fadeOut(tween(90, easing = Motion.exit)) + slideOutHorizontally(tween(90, easing = Motion.exit)) { if (forward) -30 else 30 })
                }
            },
            label = "tabs",
        ) { current ->
            when (current) {
                Tab.Home -> HomeScreen(
                    data = HomeData(
                        user = session?.user,
                        macs = macs,
                        selected = selected,
                        feed = feed,
                        answers = answers,
                        live = live,
                        loaded = loaded,
                        refreshing = refreshing,
                        error = error,
                    ),
                    contentPadding = padding,
                    onSelect = graph.repo::select,
                    onRefresh = { graph.repo.refreshAll(userInitiated = true) },
                    onAnswer = { q, option, text -> graph.repo.answer(q, option, text, graph.prefs.phoneDeviceId) },
                    onDismissFailure = graph.repo::dismissFailure,
                )
                Tab.Stats -> StatsScreen(
                    state = stats,
                    macs = macs,
                    contentPadding = padding,
                    onScope = { graph.repo.loadStats(it) },
                    onRefresh = { graph.repo.loadStats() },
                )
                Tab.Settings -> SettingsScreen(
                    data = SettingsData(
                        user = session?.user,
                        macs = macs,
                        appearance = appearance,
                        live = live,
                        phoneName = graph.deviceName,
                    ),
                    contentPadding = padding,
                    onAppearance = graph.prefs::setAppearance,
                    onSignOut = { scope.launch { graph.signOut() } },
                    onOpenUrl = openUrl,
                )
            }
        }
        // Content slides under the status bar behind a soft fade, and out under the tab bar.
        Box(
            Modifier
                .align(Alignment.TopCenter)
                .fillMaxWidth()
                .height(insets.calculateTopPadding() + 22.dp)
                .drawBehind {
                    val solid = (insets.calculateTopPadding().toPx() / size.height).coerceIn(0f, 0.95f)
                    drawRect(
                        Brush.verticalGradient(
                            0f to c.background, solid to c.background.copy(alpha = 0.96f), 1f to c.background.copy(alpha = 0f),
                        ),
                    )
                },
        )
        // Content fades out under the floating tab bar instead of colliding with it.
        Box(
            Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .height(nav.calculateBottomPadding() + 110.dp)
                .background(Brush.verticalGradient(listOf(c.background.copy(alpha = 0f), c.background.copy(alpha = 0.92f), c.background))),
        )
        FloatingTabBar(
            selected = tab,
            badge = if (pendingQuestions > 0 && tab != Tab.Home) Tab.Home else null,
            onSelect = { tab = it },
            modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = nav.calculateBottomPadding() + 14.dp),
        )
    }
}

/** A floating, translucent pill with a spring-loaded selection lozenge (Liquid Glass's cousin). */
@Composable
fun FloatingTabBar(selected: Tab, badge: Tab?, onSelect: (Tab) -> Unit, modifier: Modifier = Modifier) {
    val c = Silicon.colors
    val itemWidth = 92.dp
    val shape = SmoothShape(28.dp)
    val x by animateDpAsState(itemWidth * selected.ordinal, Motion.slow(), label = "tabX")
    Box(
        modifier
            .shadow(24.dp, shape, ambientColor = c.shadow.copy(alpha = if (c.dark) 0.6f else 0.1f), spotColor = c.shadow.copy(alpha = if (c.dark) 0.7f else 0.16f))
            .clip(shape)
            .background(if (c.dark) c.surfaceRaised.copy(alpha = 0.94f) else c.surface.copy(alpha = 0.94f))
            .border(1.dp, c.border.copy(alpha = 0.8f), shape)
            .padding(6.dp),
    ) {
        Box(
            Modifier
                .offset(x = x)
                .width(itemWidth)
                .height(52.dp)
                .clip(SmoothShape(22.dp))
                .background(c.foreground.copy(alpha = if (c.dark) 0.1f else 0.065f)),
        )
        Row {
            Tab.entries.forEach { tab ->
                val active = tab == selected
                val tint by animateColorAsState(if (active) c.foreground else c.textMuted, Motion.fast(), label = "tabTint")
                Column(
                    Modifier.width(itemWidth).height(52.dp).pressable(pressedScale = 0.92f) { onSelect(tab) },
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = androidx.compose.foundation.layout.Arrangement.Center,
                ) {
                    Box {
                        Icon(
                            when (tab) { Tab.Home -> SiIcons.Home; Tab.Stats -> SiIcons.Stats; Tab.Settings -> SiIcons.Settings },
                            contentDescription = tab.label,
                            tint = tint,
                            modifier = Modifier.size(22.dp),
                        )
                        if (badge == tab) {
                            Box(Modifier.align(Alignment.TopEnd).offset(x = 4.dp, y = (-2).dp).size(9.dp).clip(CircleShape).background(c.surface).padding(1.5.dp).clip(CircleShape).background(c.warning))
                        }
                    }
                    Text(tab.label, style = SiliconType.caption, color = tint)
                }
            }
        }
    }
}
