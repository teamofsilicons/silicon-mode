package ai.tos.mode.ui.theme

import android.provider.Settings
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize

/** Silicon UI motion tokens (shared/design/tokens.json `motion`), mapped to Compose springs. */
object Motion {
    val enter = CubicBezierEasing(0.16f, 1f, 0.3f, 1f)
    val standard = CubicBezierEasing(0.22f, 1f, 0.36f, 1f)
    val exit = CubicBezierEasing(0.7f, 0f, 0.84f, 0f)
    val inOut = CubicBezierEasing(0.65f, 0f, 0.35f, 1f)

    /** hover, press, toggles, small indicators */
    fun <T> fast(): FiniteAnimationSpec<T> = spring(dampingRatio = 1f, stiffness = 1400f)

    /** menus, tabs, height changes */
    fun <T> moderate(): FiniteAnimationSpec<T> = spring(dampingRatio = 1f, stiffness = 700f)

    /** sheets, shape morphs, large moves (a touch of bounce) */
    fun <T> slow(): FiniteAnimationSpec<T> = spring(dampingRatio = 0.82f, stiffness = 380f)

    /** charts, counters, values settling */
    fun <T> expressive(): FiniteAnimationSpec<T> = spring(dampingRatio = 0.72f, stiffness = Spring.StiffnessLow)

    fun <T> exitTween(ms: Int = 120): FiniteAnimationSpec<T> = tween(ms, easing = exit)
    fun <T> enterTween(ms: Int = 240): FiniteAnimationSpec<T> = tween(ms, easing = enter)

    val offsetSpring = spring(dampingRatio = 0.86f, stiffness = 500f, visibilityThreshold = IntOffset(1, 1))
    val sizeSpring = spring(dampingRatio = 1f, stiffness = 600f, visibilityThreshold = IntSize(1, 1))

    const val STAGGER_MS = 35
    const val STAGGER_MAX_MS = 400
}

/** True when the system asks for reduced motion (animator duration scale 0). */
@Composable
fun reduceMotion(): Boolean {
    val context = LocalContext.current
    return remember {
        Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    }
}

/** Click with a springy press (scale to [pressedScale]) and a light haptic tick. */
fun Modifier.pressable(
    enabled: Boolean = true,
    pressedScale: Float = 0.97f,
    haptic: Boolean = true,
    role: Role = Role.Button,
    onClick: () -> Unit,
): Modifier = composed {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val haptics = LocalHapticFeedback.current
    val scale by animateFloatAsState(if (pressed && enabled) pressedScale else 1f, Motion.fast(), label = "press")
    this
        .graphicsLayer { scaleX = scale; scaleY = scale }
        .clickable(interactionSource = interaction, indication = null, enabled = enabled, role = role) {
            if (haptic) haptics.performHapticFeedback(HapticFeedbackType.ContextClick)
            onClick()
        }
}
