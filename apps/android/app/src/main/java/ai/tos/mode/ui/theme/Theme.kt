package ai.tos.mode.ui.theme

import ai.tos.mode.R
import ai.tos.mode.data.Appearance
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.ExperimentalTextApi
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp

/** Silicon tokens (shared/design/tokens.json — Silicon Accounts + Silicon UI). */
@Immutable
data class SiliconColors(
    val background: Color,
    val canvas: Color,
    val surface: Color,
    val surfaceRaised: Color,
    val surfaceMuted: Color,
    val surfacePressed: Color,
    val foreground: Color,
    val textSoft: Color,
    val textSecondary: Color,
    val textMuted: Color,
    val textFaint: Color,
    val border: Color,
    val borderSubtle: Color,
    val borderStrong: Color,
    val accent: Color,
    val accentStrong: Color,
    val accentSubtle: Color,
    val accentForeground: Color,
    val primary: Color,
    val primaryForeground: Color,
    val success: Color,
    val warning: Color,
    val danger: Color,
    val gradientFrom: Color,
    val gradientTo: Color,
    val gradientForeground: Color,
    val inkFrom: Color,
    val inkTo: Color,
    /** Faint warm shadow (rgb 30 30 28) in light; plain black in dark. */
    val shadow: Color,
    val dark: Boolean,
) {
    val siliconGradient: Brush get() = Brush.linearGradient(listOf(gradientFrom, gradientTo))
    val siliconInk: Brush get() = Brush.horizontalGradient(listOf(inkFrom, inkTo))
}

val LightSilicon = SiliconColors(
    background = Color(0xFFFCFCFC),
    canvas = Color(0xFFF8F8F8),
    surface = Color(0xFFFFFFFF),
    surfaceRaised = Color(0xFFFFFFFF),
    surfaceMuted = Color(0xFFF1F1F1),
    surfacePressed = Color(0xFFE3E3E3),
    foreground = Color(0xFF1B1B1B),
    textSoft = Color(0xFF353535),
    textSecondary = Color(0xFF505050),
    textMuted = Color(0xFF6B6B6B),
    textFaint = Color(0xFFA4A4A4),
    border = Color(0xFFE9E9E9),
    borderSubtle = Color(0xFFF3F3F3),
    borderStrong = Color(0xFFC4C4C4),
    accent = Color(0xFF3460F0),
    accentStrong = Color(0xFF2449C9),
    accentSubtle = Color(0xFFEEF2FE),
    accentForeground = Color(0xFFFFFFFF),
    primary = Color(0xFF181818),
    primaryForeground = Color(0xFFFFFFFF),
    success = Color(0xFF2B7148),
    warning = Color(0xFF8F560D),
    danger = Color(0xFFB42318),
    gradientFrom = Color(0xFFE2D8F8),
    gradientTo = Color(0xFFFADFC6),
    gradientForeground = Color(0xFF1B1A1F),
    inkFrom = Color(0xFF644C8A),
    inkTo = Color(0xFF8A542D),
    shadow = Color(0xFF1E1E1C),
    dark = false,
)

val DarkSilicon = SiliconColors(
    background = Color(0xFF141414),
    canvas = Color(0xFF0F0F0F),
    surface = Color(0xFF191919),
    surfaceRaised = Color(0xFF1F1F1F),
    surfaceMuted = Color(0xFF242424),
    surfacePressed = Color(0xFF2E2E2E),
    foreground = Color(0xFFF2F2F2),
    textSoft = Color(0xFFD1D1D1),
    textSecondary = Color(0xFFB4B4B4),
    textMuted = Color(0xFF8C8C8C),
    textFaint = Color(0xFF4D4D4D),
    border = Color(0xFF2B2B2B),
    borderSubtle = Color(0xFF222222),
    borderStrong = Color(0xFF484848),
    accent = Color(0xFF7D9BFF),
    accentStrong = Color(0xFFA9BDFF),
    accentSubtle = Color(0xFF1D2440),
    accentForeground = Color(0xFF141414),
    primary = Color(0xFFF2F2F2),
    primaryForeground = Color(0xFF141414),
    success = Color(0xFF7FC79A),
    warning = Color(0xFFE3B55A),
    danger = Color(0xFFF4968C),
    gradientFrom = Color(0xFF463C59),
    gradientTo = Color(0xFF5A422F),
    gradientForeground = Color(0xFFF2F1F5),
    inkFrom = Color(0xFFCBBAEB),
    inkTo = Color(0xFFEDCAA3),
    shadow = Color(0xFF000000),
    dark = true,
)

/** The always-dark palette of the Silicon Mode overlay (used by the live tail "terminal"). */
object Night {
    val background = Color(0xFF0B0B0B)
    val surface = Color(0xFF151515)
    val foreground = Color(0xFFF2F2F2)
    val secondary = Color(0xFFB4B4B4)
    val muted = Color(0xFF8C8C8C)
    val faint = Color(0xFF4D4D4D)
    val border = Color(0x14FFFFFF)
    val accent = Color(0xFF7D9BFF)
    val lavender = Color(0xFFCBBAEB)
    val peach = Color(0xFFEDCAA3)
    val success = Color(0xFF7FC79A)
    val warning = Color(0xFFE3B55A)
    val danger = Color(0xFFF4968C)
}

// ---------- Allo (variable, ROND 20 like Silicon Accounts) ----------

@OptIn(ExperimentalTextApi::class)
private fun allo(weight: Int, opsz: Float) = Font(
    R.font.allo_variable,
    FontWeight(weight),
    variationSettings = FontVariation.Settings(
        FontVariation.weight(weight),
        FontVariation.Setting("ROND", 20f),
        FontVariation.Setting("opsz", opsz),
    ),
)

/** Text sizes get Allo's text shapes (opsz 14). */
val Allo = FontFamily(allo(400, 14f), allo(500, 14f), allo(600, 14f), allo(700, 14f))

/** Titles get the display shapes (opsz 28), as `font-optical-sizing: auto` does on the web. */
val AlloDisplay = FontFamily(allo(500, 28f), allo(600, 28f), allo(700, 28f))

private val trim = LineHeightStyle(LineHeightStyle.Alignment.Center, LineHeightStyle.Trim.None)

private fun role(size: Int, weight: Int, leading: Float, tracking: Float, display: Boolean = false) = TextStyle(
    fontFamily = if (display) AlloDisplay else Allo,
    fontWeight = FontWeight(weight),
    fontSize = size.sp,
    lineHeight = (size * leading).sp,
    letterSpacing = tracking.em,
    lineHeightStyle = trim,
)

/** Silicon UI type roles (compact set, Accounts' default). */
object SiliconType {
    val hero = role(36, 600, 1.08f, -0.035f, display = true)
    val display = role(28, 600, 1.1f, -0.03f, display = true)
    val h1 = role(22, 600, 1.15f, -0.03f, display = true)
    val h2 = role(18, 600, 1.3f, -0.02f, display = true)
    val h3 = role(16, 500, 1.4f, -0.01f)
    val body = role(16, 400, 1.4f, -0.01f)
    val label = role(14, 500, 1.4f, -0.01f)
    val small = role(14, 400, 1.4f, -0.01f)
    val caption = role(12, 500, 1.4f, -0.01f)
    val hint = role(12, 400, 1.4f, -0.01f)
    val eyebrow = role(11, 600, 1.3f, 0.06f)
    val mono = TextStyle(fontFamily = FontFamily.Monospace, fontSize = 12.sp, lineHeight = 17.sp, letterSpacing = 0.sp)
    val monoSmall = TextStyle(fontFamily = FontFamily.Monospace, fontSize = 11.sp, lineHeight = 15.sp, letterSpacing = 0.sp)

    /** Big tabular numbers (tnum) for values that change. */
    fun number(size: TextUnit, weight: Int = 600) = TextStyle(
        fontFamily = AlloDisplay,
        fontWeight = FontWeight(weight),
        fontSize = size,
        lineHeight = size * 1.05f,
        letterSpacing = (-0.03).em,
        fontFeatureSettings = "tnum",
        lineHeightStyle = trim,
    )
}

val LocalSilicon = staticCompositionLocalOf { LightSilicon }

object Silicon {
    val colors: SiliconColors
        @Composable get() = LocalSilicon.current
}

@Composable
fun isDark(appearance: Appearance): Boolean = when (appearance) {
    Appearance.System -> isSystemInDarkTheme()
    Appearance.Light -> false
    Appearance.Dark -> true
}

@Composable
fun SiliconTheme(dark: Boolean, content: @Composable () -> Unit) {
    val c = if (dark) DarkSilicon else LightSilicon
    val scheme = (if (dark) darkColorScheme() else lightColorScheme()).copy(
        primary = c.primary, onPrimary = c.primaryForeground,
        secondary = c.accent, onSecondary = c.accentForeground,
        tertiary = c.accent, onTertiary = c.accentForeground,
        background = c.background, onBackground = c.foreground,
        surface = c.surface, onSurface = c.foreground,
        surfaceVariant = c.surfaceMuted, onSurfaceVariant = c.textSecondary,
        surfaceContainerLowest = c.surface, surfaceContainerLow = c.surface,
        surfaceContainer = c.surface, surfaceContainerHigh = c.surfaceRaised, surfaceContainerHighest = c.surfaceRaised,
        outline = c.borderStrong, outlineVariant = c.border,
        error = c.danger, onError = c.primaryForeground,
        primaryContainer = c.accentSubtle, onPrimaryContainer = c.accent,
    )
    val typography = Typography(
        displayLarge = SiliconType.hero, displayMedium = SiliconType.display, displaySmall = SiliconType.h1,
        headlineLarge = SiliconType.display, headlineMedium = SiliconType.h1, headlineSmall = SiliconType.h2,
        titleLarge = SiliconType.h1, titleMedium = SiliconType.h3, titleSmall = SiliconType.label,
        bodyLarge = SiliconType.body, bodyMedium = SiliconType.small, bodySmall = SiliconType.hint,
        labelLarge = SiliconType.label, labelMedium = SiliconType.caption, labelSmall = SiliconType.hint,
    )
    CompositionLocalProvider(LocalSilicon provides c) {
        MaterialTheme(colorScheme = scheme, typography = typography, content = content)
    }
}
