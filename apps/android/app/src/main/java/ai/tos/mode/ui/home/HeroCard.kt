package ai.tos.mode.ui.home

import ai.tos.mode.data.MacItem
import ai.tos.mode.ui.Format
import ai.tos.mode.ui.components.LidGlyph
import ai.tos.mode.ui.components.PulseDot
import ai.tos.mode.ui.theme.Motion
import ai.tos.mode.ui.theme.SiIcons
import ai.tos.mode.ui.theme.Silicon
import ai.tos.mode.ui.theme.SiliconColors
import ai.tos.mode.ui.theme.SiliconType
import ai.tos.mode.ui.theme.SmoothShape
import ai.tos.mode.ui.theme.reduceMotion
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import java.time.Instant
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

private enum class HeroMode { Active, Locked, Arming, Panic, Off, Offline }

private fun heroMode(mac: MacItem, now: Instant): HeroMode {
    val mode = mac.status?.mode ?: "off"
    return when {
        mode == "panic" -> HeroMode.Panic
        !isOnline(mac, now) -> HeroMode.Offline
        mode == "active" -> HeroMode.Active
        mode == "locked" -> HeroMode.Locked
        mode == "arming" -> HeroMode.Arming
        else -> HeroMode.Off
    }
}

/**
 * The status hero: "Silicon Mode active for 42m on Shubham's MacBook Pro", the live lid angle,
 * online state and the facts the Mac reports. Active cards breathe with the silicon gradient;
 * panic flashes to get attention.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun HeroCard(mac: MacItem, now: Instant, modifier: Modifier = Modifier) {
    val c = Silicon.colors
    val status = mac.status
    val mode = heroMode(mac, now)
    // Panic on the Mac buzzes the phone too: three sharp pulses, once per panic.
    val haptics = androidx.compose.ui.platform.LocalHapticFeedback.current
    androidx.compose.runtime.LaunchedEffect(mode == HeroMode.Panic, mac.device.id) {
        if (mode == HeroMode.Panic) repeat(3) {
            haptics.performHapticFeedback(androidx.compose.ui.hapticfeedback.HapticFeedbackType.Reject)
            kotlinx.coroutines.delay(180)
        }
    }
    val lit = mode == HeroMode.Active || mode == HeroMode.Locked || mode == HeroMode.Arming
    val panic = mode == HeroMode.Panic
    val fg = when {
        panic -> Color.White
        lit -> c.gradientForeground
        else -> c.foreground
    }
    val fgSoft = fg.copy(alpha = if (lit || panic) 0.68f else 1f).let { if (!lit && !panic) c.textMuted else it }
    val shape = SmoothShape(30.dp)
    val borderColor by animateColorAsState(
        when { panic -> Color.Transparent; lit -> Color.White.copy(alpha = if (c.dark) 0.06f else 0.5f); else -> c.border },
        Motion.moderate(), label = "heroBorder",
    )

    Box(
        modifier
            .fillMaxWidth()
            .shadow(
                if (lit || panic) 22.dp else 8.dp, shape,
                ambientColor = (if (panic) c.danger else c.shadow).copy(alpha = if (c.dark) 0.5f else 0.08f),
                spotColor = (if (panic) c.danger else c.shadow).copy(alpha = if (c.dark) 0.6f else 0.12f),
            )
            .clip(shape)
            .heroBackground(mode, c)
            .border(1.dp, borderColor, shape)
            .padding(20.dp),
    ) {
        Column {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(SiIcons.Laptop, null, tint = fg, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                // The name is in the sentence below; up here, what kind of Mac it is.
                Text(
                    listOfNotNull(Format.macModel(mac.device.model) ?: "Mac", mac.device.osVersion).joinToString(" · "),
                    style = SiliconType.label,
                    color = fg.copy(alpha = 0.8f),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                OnlinePill(mode, mac, now, fg)
            }
            Spacer(Modifier.height(18.dp))
            Row(verticalAlignment = Alignment.Bottom) {
                Column(Modifier.weight(1f)) {
                    AnimatedContent(
                        targetState = mode,
                        transitionSpec = {
                            (fadeIn(Motion.enterTween()) + slideInVertically(Motion.offsetSpring) { it / 4 }) togetherWith fadeOut(Motion.exitTween())
                        },
                        label = "heroText",
                    ) { m ->
                        HeroText(m, mac, now, fg, fgSoft)
                    }
                }
                Spacer(Modifier.width(12.dp))
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    LidGlyph(
                        angle = status?.lidAngle?.toFloat(),
                        siliconAngle = if (lit || panic) status?.siliconAngle?.toFloat() else null,
                        ink = fg,
                        accent = when { panic -> Color.White.copy(alpha = 0.8f); lit -> c.inkFrom; else -> c.accent },
                        modifier = Modifier.size(width = 92.dp, height = 74.dp),
                    )
                    Spacer(Modifier.height(4.dp))
                    Text(
                        status?.lidAngle?.let { "${it.toInt()}°" } ?: "–°",
                        style = SiliconType.number(androidx.compose.ui.unit.TextUnit(20f, androidx.compose.ui.unit.TextUnitType.Sp)),
                        color = fg,
                    )
                    Text("lid", style = SiliconType.hint, color = fgSoft)
                }
            }
            val facts = buildList {
                status?.siliconAngle?.takeIf { lit || panic }?.let { add(SiIcons.Lock to "Silicon angle ${it.toInt()}°") }
                if (status?.caffeinated == true) add(SiIcons.Coffee to "Caffeinated")
                status?.face?.takeIf { it.isNotBlank() }?.let { add(SiIcons.Bolt to "Face · ${prettyFace(it)}") }
                status?.updatedAt?.let { add(SiIcons.Clock to "Updated ${Format.ago(it, now).let { a -> if (a == "now") "just now" else "$a ago" }}") }
            }
            if (facts.isNotEmpty()) {
                Spacer(Modifier.height(16.dp))
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    facts.forEach { (icon, label) -> Fact(icon, label, fg, lit || panic) }
                }
            }
        }
    }
}

@Composable
private fun HeroText(mode: HeroMode, mac: MacItem, now: Instant, fg: Color, fgSoft: Color) {
    val c = Silicon.colors
    val status = mac.status
    val forText = Format.since(status?.modeSince, now)?.let { Format.duration(it) }
    val working = status?.agentsWorking ?: 0
    val (eyebrow, headline, sub) = when (mode) {
        HeroMode.Active -> Triple("Active", "Silicon Mode active" + (forText?.let { " for $it" } ?: ""), "on ${mac.device.name}")
        HeroMode.Locked -> Triple("Locked", "Silicon Mode active" + (forText?.let { " for $it" } ?: ""), "Locked with your PIN on ${mac.device.name}")
        HeroMode.Arming -> Triple("Counting down", "Entering Silicon Mode…", "The lid went down on ${mac.device.name}")
        HeroMode.Panic -> Triple("Panic", "The lid is closing!", "Agents are still running on ${mac.device.name}. Open it back up.")
        HeroMode.Off -> Triple(
            "Off",
            "Silicon Mode is off",
            if (working > 0) "${Format.agentCount(working)} running on ${mac.device.name}" else "Lower the lid while agents run to start it",
        )
        HeroMode.Offline -> Triple(
            "Offline",
            mac.status?.updatedAt?.let { "Last seen ${Format.ago(it, now)} ago" } ?: "Not reporting yet",
            "${mac.device.name} is asleep or not signed in",
        )
    }
    Column {
        Row(verticalAlignment = Alignment.CenterVertically) {
            val dot = when (mode) {
                HeroMode.Active, HeroMode.Locked, HeroMode.Arming -> c.inkFrom
                HeroMode.Panic -> Color.White
                HeroMode.Off -> c.success
                HeroMode.Offline -> c.textFaint
            }
            PulseDot(dot, pulsing = mode == HeroMode.Active || mode == HeroMode.Panic || mode == HeroMode.Arming, size = 7.dp)
            Text(eyebrow.uppercase(), style = SiliconType.eyebrow, color = fgSoft)
        }
        Spacer(Modifier.height(6.dp))
        Text(headline, style = SiliconType.display, color = fg)
        Spacer(Modifier.height(6.dp))
        Text(sub, style = SiliconType.small, color = fgSoft, maxLines = 3, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun OnlinePill(mode: HeroMode, mac: MacItem, now: Instant, fg: Color) {
    val c = Silicon.colors
    val online = mode != HeroMode.Offline
    val bg = when (mode) {
        HeroMode.Panic -> Color.White.copy(alpha = 0.18f)
        HeroMode.Active, HeroMode.Locked, HeroMode.Arming -> Color.White.copy(alpha = if (c.dark) 0.08f else 0.45f)
        else -> c.surfaceMuted
    }
    Row(
        Modifier.clip(SmoothShape(10.dp)).background(bg).padding(start = 2.dp, end = 9.dp, top = 2.dp, bottom = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        PulseDot(if (online) (if (mode == HeroMode.Panic) Color.White else c.success) else c.textFaint, pulsing = false, size = 6.dp)
        Text(if (online) "Online" else "Offline", style = SiliconType.caption, color = fg.copy(alpha = 0.8f))
    }
}

@Composable
private fun Fact(icon: ImageVector, label: String, fg: Color, onColor: Boolean) {
    val c = Silicon.colors
    Row(
        Modifier
            .clip(SmoothShape(10.dp))
            .background(if (onColor) Color.White.copy(alpha = if (c.dark) 0.07f else 0.4f) else c.surfaceMuted)
            .padding(horizontal = 9.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, tint = fg.copy(alpha = 0.75f), modifier = Modifier.size(13.dp))
        Spacer(Modifier.width(5.dp))
        Text(label, style = SiliconType.caption, color = fg.copy(alpha = 0.85f), maxLines = 1)
    }
}

private fun prettyFace(id: String): String =
    id.replace('_', ' ').replace('-', ' ').split(' ').joinToString(" ") { w -> w.replaceFirstChar { it.uppercase() } }

/**
 * Lit cards: the silicon gradient with two soft light pools drifting slowly and a sheen that
 * sweeps across every few seconds. Panic: a rapid red flash. All drawn in the draw phase, so
 * the animation costs no recomposition.
 */
@Composable
private fun Modifier.heroBackground(mode: HeroMode, c: SiliconColors): Modifier {
    val still = reduceMotion()
    return when (mode) {
        HeroMode.Panic -> {
            val flash = if (still) null else rememberInfiniteTransition(label = "panic").animateFloat(
                0f, 1f, infiniteRepeatable(tween(380, easing = LinearEasing), RepeatMode.Reverse), label = "flash",
            )
            val base = c.danger.let { if (c.dark) lerp(it, Color.Black, 0.35f) else it }
            val hot = if (c.dark) Color(0xFFE5484D) else Color(0xFFE5484D)
            this.drawBehind { drawRect(lerp(base, hot, flash?.value ?: 0.5f)) }
        }
        HeroMode.Active, HeroMode.Locked, HeroMode.Arming -> {
            val drift = if (still) null else rememberInfiniteTransition(label = "drift").animateFloat(
                0f, 1f, infiniteRepeatable(tween(16_000, easing = LinearEasing)), label = "t",
            )
            val sheen = if (still) null else rememberInfiniteTransition(label = "sheen").animateFloat(
                -0.4f, 1.6f, infiniteRepeatable(tween(7_000, easing = Motion.inOut)), label = "s",
            )
            val pool1 = remember(c) { if (c.dark) Color(0xFF6B5A8F) else Color(0xFFF1EAFD) }
            val pool2 = remember(c) { if (c.dark) Color(0xFF7A5A3E) else Color(0xFFFFEBD8) }
            this
                .drawBehind {
                    drawRect(Brush.linearGradient(listOf(c.gradientFrom, c.gradientTo), Offset.Zero, Offset(size.width, size.height)))
                    val t = (drift?.value ?: 0.2f) * 2 * PI.toFloat()
                    val r = size.maxDimension * 0.55f
                    val p1 = Offset(size.width * (0.25f + 0.12f * cos(t)), size.height * (0.3f + 0.18f * sin(t)))
                    val p2 = Offset(size.width * (0.78f + 0.1f * sin(t * 1.3f)), size.height * (0.72f + 0.15f * cos(t * 0.8f)))
                    drawCircle(Brush.radialGradient(listOf(pool1.copy(alpha = 0.75f), Color.Transparent), p1, r), r, p1)
                    drawCircle(Brush.radialGradient(listOf(pool2.copy(alpha = 0.7f), Color.Transparent), p2, r * 0.9f), r * 0.9f, p2)
                }
                .drawWithContent {
                    drawContent()
                    val s = sheen?.value ?: return@drawWithContent
                    if (s !in -0.3f..1.3f) return@drawWithContent
                    val x = size.width * s
                    val band = size.width * 0.35f
                    drawRect(
                        Brush.linearGradient(
                            listOf(Color.Transparent, Color.White.copy(alpha = if (c.dark) 0.05f else 0.22f), Color.Transparent),
                            start = Offset(x - band, 0f), end = Offset(x + band, size.height * 0.6f),
                        ),
                        blendMode = BlendMode.SrcOver,
                    )
                }
        }
        else -> this.background(c.surface)
    }
}
