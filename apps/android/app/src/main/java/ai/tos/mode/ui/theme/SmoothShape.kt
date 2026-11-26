package ai.tos.mode.ui.theme

import androidx.compose.runtime.Immutable
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import kotlin.math.PI
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.math.tan

/**
 * A continuous-corner ("squircle") rounded rectangle: Figma-style corner smoothing, which is what
 * Silicon UI's `corner-shape: squircle` (smoothing 60%) and SwiftUI's `.continuous` corners look
 * like. Each corner eases out of the straight edge with cubic curves around a shorter circular arc,
 * so there is no visible kink where the edge meets the curve.
 */
@Immutable
class SmoothShape(private val radius: Dp, private val smoothing: Float = 0.6f) : Shape {
    override fun createOutline(size: Size, layoutDirection: LayoutDirection, density: Density): Outline {
        val r = with(density) { radius.toPx() }
        return Outline.Generic(smoothRectPath(size, r, smoothing))
    }

    override fun equals(other: Any?) = other is SmoothShape && other.radius == radius && other.smoothing == smoothing
    override fun hashCode() = radius.hashCode() * 31 + smoothing.hashCode()
}

/** Common radii (tokens.json `radius.squircle`, tuned for touch). */
object Shapes {
    val detail = SmoothShape(4.dp)
    val control = SmoothShape(11.dp)
    val chip = SmoothShape(12.dp)
    val container = SmoothShape(16.dp)
    val card = SmoothShape(22.dp)
    val hero = SmoothShape(30.dp)
}

private fun deg(d: Double) = d * PI / 180.0

fun smoothRectPath(size: Size, cornerRadius: Float, cornerSmoothing: Float): Path {
    val w = size.width
    val h = size.height
    val path = Path()
    if (w <= 0f || h <= 0f) return path
    val maxR = min(w, h) / 2f
    var r = min(cornerRadius, maxR).toDouble()
    var s = cornerSmoothing.toDouble().coerceIn(0.0, 1.0)
    // Not enough room for the smoothing: give it up first, as Figma does.
    if ((1 + s) * r > maxR) s = ((maxR / r) - 1).coerceIn(0.0, s)
    if (r <= 0.0) {
        path.addRect(androidx.compose.ui.geometry.Rect(0f, 0f, w, h))
        return path
    }
    val p = min((1 + s) * r, maxR.toDouble())
    val arcMeasure = 90 * (1 - s)
    val arcSection = sin(deg(arcMeasure / 2)) * r * sqrt(2.0)
    val angleAlpha = (90 - arcMeasure) / 2
    val p3ToP4 = r * tan(deg(angleAlpha / 2))
    val angleBeta = 45 * s
    val c = p3ToP4 * cos(deg(angleBeta))
    val d = c * tan(deg(angleBeta))
    val b = (p - arcSection - c - d) / 3
    val a = 2 * b

    // Corners clockwise from the top edge. u runs along the incoming edge, v along the outgoing one.
    data class Corner(val apex: Offset, val u: Offset, val v: Offset)
    val corners = listOf(
        Corner(Offset(w, 0f), Offset(1f, 0f), Offset(0f, 1f)),
        Corner(Offset(w, h), Offset(0f, 1f), Offset(-1f, 0f)),
        Corner(Offset(0f, h), Offset(-1f, 0f), Offset(0f, -1f)),
        Corner(Offset(0f, 0f), Offset(0f, -1f), Offset(1f, 0f)),
    )
    corners.forEachIndexed { index, corner ->
        val start = corner.apex - corner.u * p.toFloat()
        fun g(x: Double, y: Double): Offset = start + corner.u * x.toFloat() + corner.v * y.toFloat()
        val s0 = g(0.0, 0.0)
        if (index == 0) path.moveTo(s0.x, s0.y) else path.lineTo(s0.x, s0.y)
        // ease in
        val e1 = g(a + b + c, d)
        g(a, 0.0).let { c1 -> g(a + b, 0.0).let { c2 -> path.cubicTo(c1.x, c1.y, c2.x, c2.y, e1.x, e1.y) } }
        // circular arc around the corner's centre (p - r, r), drawn as one cubic (≤ 90°)
        val cx = p - r
        val cy = r
        val t1 = atan2(d - cy, a + b + c - cx)
        val t2 = atan2(d + arcSection - cy, a + b + c + arcSection - cx)
        val k = 4.0 / 3.0 * tan((t2 - t1) / 4) * r
        val a1 = g(cx + r * cos(t1) - k * sin(t1), cy + r * sin(t1) + k * cos(t1))
        val a2 = g(cx + r * cos(t2) + k * sin(t2), cy + r * sin(t2) - k * cos(t2))
        val e2 = g(cx + r * cos(t2), cy + r * sin(t2))
        path.cubicTo(a1.x, a1.y, a2.x, a2.y, e2.x, e2.y)
        // ease out onto the next edge
        val x0 = a + b + c + arcSection
        val y0 = d + arcSection
        val c3 = g(x0 + d, y0 + c)
        val c4 = g(x0 + d, y0 + b + c)
        val e3 = g(x0 + d, y0 + a + b + c)
        path.cubicTo(c3.x, c3.y, c4.x, c4.y, e3.x, e3.y)
    }
    path.close()
    return path
}
