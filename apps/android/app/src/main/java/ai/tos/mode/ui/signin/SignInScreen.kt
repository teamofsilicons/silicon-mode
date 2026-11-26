package ai.tos.mode.ui.signin

import ai.tos.mode.ui.components.ButtonKind
import ai.tos.mode.ui.components.LidGlyph
import ai.tos.mode.ui.components.SiButton
import ai.tos.mode.ui.theme.Motion
import ai.tos.mode.ui.theme.SiIcons
import ai.tos.mode.ui.theme.Silicon
import ai.tos.mode.ui.theme.SiliconType
import ai.tos.mode.ui.theme.SmoothShape
import ai.tos.mode.ui.theme.reduceMotion
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/**
 * Sign-in: the silicon gradient breathing behind a laptop whose lid slowly lowers into Silicon
 * Mode and opens again. One button opens Silicon Accounts in a Custom Tab.
 */
@Composable
fun SignInScreen(busy: Boolean, message: String?, onSignIn: () -> Unit) {
    val c = Silicon.colors
    val still = reduceMotion()
    val drift = if (still) null else rememberInfiniteTransition(label = "bg").animateFloat(
        0f, 1f, infiniteRepeatable(tween(18_000, easing = LinearEasing)), label = "drift",
    )
    val lid = if (still) null else rememberInfiniteTransition(label = "lid").animateFloat(
        112f, 58f, infiniteRepeatable(tween(3_200, easing = Motion.inOut), RepeatMode.Reverse), label = "lidAngle",
    )
    // Staggered entrance.
    val intro = remember { List(5) { Animatable(if (still) 1f else 0f) } }
    LaunchedEffect(Unit) {
        intro.forEachIndexed { i, a ->
            launch {
                delay(i * 70L)
                a.animateTo(1f, Motion.slow())
            }
        }
    }
    fun Modifier.enter(i: Int) = graphicsLayer {
        val v = intro[i].value
        alpha = v.coerceIn(0f, 1f)
        translationY = (1f - v) * 24.dp.toPx()
    }

    val pool1 = if (c.dark) Color(0xFF6B5A8F) else Color(0xFFEFE6FF)
    val pool2 = if (c.dark) Color(0xFF7A5A3E) else Color(0xFFFFE6CF)
    Box(
        Modifier
            .fillMaxSize()
            .drawBehind {
                drawRect(Brush.linearGradient(listOf(c.gradientFrom, c.gradientTo), Offset.Zero, Offset(size.width, size.height)))
                val t = (drift?.value ?: 0.15f) * 2 * PI.toFloat()
                val r = size.maxDimension * 0.5f
                val p1 = Offset(size.width * (0.2f + 0.15f * cos(t)), size.height * (0.22f + 0.1f * sin(t)))
                val p2 = Offset(size.width * (0.85f + 0.1f * sin(t * 1.4f)), size.height * (0.7f + 0.12f * cos(t)))
                drawCircle(Brush.radialGradient(listOf(pool1.copy(alpha = 0.85f), Color.Transparent), p1, r), r, p1)
                drawCircle(Brush.radialGradient(listOf(pool2.copy(alpha = 0.8f), Color.Transparent), p2, r), r, p2)
            }
            .windowInsetsPadding(WindowInsets.safeDrawing)
            .padding(horizontal = 24.dp),
    ) {
        Column(
            Modifier.fillMaxWidth().align(Alignment.Center),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Box(
                Modifier
                    .enter(0)
                    .size(112.dp)
                    .shadow(30.dp, SmoothShape(30.dp), ambientColor = c.shadow.copy(alpha = 0.12f), spotColor = c.shadow.copy(alpha = 0.2f))
                    .clip(SmoothShape(30.dp))
                    .background(if (c.dark) Color(0xFF1B1A1F) else Color.White)
                    .border(1.dp, Color.White.copy(alpha = if (c.dark) 0.08f else 0.6f), SmoothShape(30.dp)),
                contentAlignment = Alignment.Center,
            ) {
                LidGlyph(
                    angle = lid?.value ?: 64f,
                    siliconAngle = null,
                    ink = c.foreground,
                    accent = c.accent,
                    modifier = Modifier.size(width = 70.dp, height = 56.dp),
                    stroke = 5.dp,
                )
            }
            Spacer(Modifier.height(28.dp))
            Text("Silicon Mode", style = SiliconType.hero, color = c.gradientForeground, modifier = Modifier.enter(1))
            Spacer(Modifier.height(10.dp))
            Text(
                "Your agents keep working while the lid is half-closed. Keep an eye on them from here.",
                style = SiliconType.body,
                color = c.gradientForeground.copy(alpha = 0.7f),
                textAlign = TextAlign.Center,
                modifier = Modifier.enter(2).padding(horizontal = 12.dp),
            )
            Spacer(Modifier.height(28.dp))
            Column(
                Modifier
                    .enter(3)
                    .fillMaxWidth()
                    .clip(SmoothShape(22.dp))
                    .background(Color.White.copy(alpha = if (c.dark) 0.06f else 0.5f))
                    .border(1.dp, Color.White.copy(alpha = if (c.dark) 0.08f else 0.7f), SmoothShape(22.dp))
                    .padding(horizontal = 18.dp, vertical = 16.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Feature(SiIcons.Activity, "What every agent is doing, live — on each of your Macs")
                Feature(SiIcons.Bell, "Answer questions and permissions from your phone")
                Feature(SiIcons.Stats, "Your patterns: a 24-hour column for every day")
            }
            Spacer(Modifier.height(28.dp))
            Column(Modifier.enter(4).fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
                SiButton(
                    "Continue with Silicon Accounts",
                    onClick = onSignIn,
                    kind = ButtonKind.Primary,
                    loading = busy,
                    modifier = Modifier.fillMaxWidth(),
                )
                AnimatedVisibility(message != null, enter = fadeIn() + expandVertically(), exit = fadeOut()) {
                    Text(
                        message.orEmpty(),
                        style = SiliconType.small,
                        color = c.danger,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.padding(top = 12.dp),
                    )
                }
                Spacer(Modifier.height(14.dp))
                Text(
                    "Signs in through your Silicon account. No password here.",
                    style = SiliconType.hint,
                    color = c.gradientForeground.copy(alpha = 0.55f),
                    textAlign = TextAlign.Center,
                )
            }
        }
        Text(
            "mode.teamofsilicons.com",
            style = SiliconType.caption,
            color = c.gradientForeground.copy(alpha = 0.45f),
            modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 12.dp),
        )
    }
}

@Composable
private fun Feature(icon: ImageVector, text: String) {
    val c = Silicon.colors
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(
            Modifier.size(30.dp).clip(SmoothShape(10.dp)).background(if (c.dark) Color.White.copy(alpha = 0.08f) else Color.White),
            contentAlignment = Alignment.Center,
        ) { Icon(icon, null, tint = c.inkFrom, modifier = Modifier.size(16.dp)) }
        Spacer(Modifier.width(12.dp))
        Text(text, style = SiliconType.small, color = c.gradientForeground.copy(alpha = 0.85f))
    }
}
