package ai.tos.mode.ui.theme

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.unit.dp

/** A small line-icon set (Lucide geometry, ISC licence) drawn at a 1.75 stroke. */
object SiIcons {
    private fun line(name: String, vararg paths: String, stroke: Float = 1.75f): ImageVector =
        ImageVector.Builder(name, 24.dp, 24.dp, 24f, 24f).apply {
            paths.forEach {
                addPath(
                    pathData = addPathNodes(it),
                    fill = null,
                    stroke = SolidColor(Color.Black),
                    strokeLineWidth = stroke,
                    strokeLineCap = StrokeCap.Round,
                    strokeLineJoin = StrokeJoin.Round,
                )
            }
        }.build()

    val Home = line(
        "home",
        "M15 21v-8a1 1 0 0 0-1-1h-4a1 1 0 0 0-1 1v8",
        "M3 10a2 2 0 0 1 .709-1.528l7-5.999a2 2 0 0 1 2.582 0l7 5.999A2 2 0 0 1 21 10v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z",
    )
    val Stats = line("stats", "M3 3v16a2 2 0 0 0 2 2h16", "M18 17V9", "M13 17V5", "M8 17v-3")
    val Settings = line(
        "settings",
        "M20 7h-9", "M14 17H5",
        "M17 14a3 3 0 1 0 0 6a3 3 0 1 0 0-6",
        "M7 4a3 3 0 1 0 0 6a3 3 0 1 0 0-6",
    )
    val Laptop = line("laptop", "M6 5h12a2 2 0 0 1 2 2v8H4V7a2 2 0 0 1 2-2z", "M2 19h20")
    val Check = line("check", "M20 6 9 17l-5-5", stroke = 2.2f)
    val Close = line("close", "M18 6 6 18", "M6 6l12 12")
    val ChevronDown = line("chevron-down", "M6 9l6 6 6-6")
    val ChevronRight = line("chevron-right", "M9 18l6-6-6-6")
    val Send = line("send", "M5 12l7-7 7 7", "M12 19V5", stroke = 2.2f)
    val SignOut = line("sign-out", "M16 17l5-5-5-5", "M21 12H9", "M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4")
    val External = line("external", "M7 7h10v10", "M7 17 17 7")
    val Bolt = line(
        "bolt",
        "M4 14a1 1 0 0 1-.78-1.63l9.9-10.2a.5.5 0 0 1 .86.46l-1.92 6.02A1 1 0 0 0 13 10h7a1 1 0 0 1 .78 1.63l-9.9 10.2a.5.5 0 0 1-.86-.46l1.92-6.02A1 1 0 0 0 11 14z",
    )
    val Coffee = line(
        "coffee",
        "M10 2v2", "M14 2v2", "M6 2v2",
        "M16 8a1 1 0 0 1 1 1v8a4 4 0 0 1-4 4H7a4 4 0 0 1-4-4V9a1 1 0 0 1 1-1h14a4 4 0 1 1 0 8h-1",
    )
    val Alert = line(
        "alert",
        "M21.73 18l-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3",
        "M12 9v4", "M12 17h.01",
    )
    val Clock = line("clock", "M12 2a10 10 0 1 0 0 20a10 10 0 1 0 0-20", "M12 6v6l4 2")
    val Flame = line(
        "flame",
        "M8.5 14.5A2.5 2.5 0 0 0 11 12c0-1.38-.5-2-1-3-1.072-2.143-.224-4.054 2-6 .5 2.5 2 4.9 4 6.5 2 1.6 3 3.5 3 5.5a7 7 0 1 1-14 0c0-1.153.433-2.294 1-3a2.5 2.5 0 0 0 2.5 2.5z",
    )
    val Bell = line(
        "bell",
        "M10.268 21a2 2 0 0 0 3.464 0",
        "M3.262 15.326A1 1 0 0 0 4 17h16a1 1 0 0 0 .74-1.673C19.41 13.956 18 12.499 18 8A6 6 0 0 0 6 8c0 4.499-1.411 5.956-2.738 7.326",
    )
    val Activity = line(
        "activity",
        "M22 12h-2.48a2 2 0 0 0-1.93 1.46l-2.35 8.36a.25.25 0 0 1-.48 0L9.24 2.18a.25.25 0 0 0-.48 0l-2.35 8.36A2 2 0 0 1 4.49 12H2",
    )
    val Done = line("done", "M12 2a10 10 0 1 0 0 20a10 10 0 1 0 0-20", "M9 12l2 2 4-4")
    val Terminal = line("terminal", "M4 17l6-6-6-6", "M12 19h8")
    val Calendar = line(
        "calendar",
        "M8 2v4", "M16 2v4",
        "M5 4h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z",
        "M3 10h18",
    )
    val Moon = line("moon", "M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z")
    val Sun = line(
        "sun",
        "M12 8a4 4 0 1 0 0 8a4 4 0 1 0 0-8",
        "M12 2v2", "M12 20v2", "M4.93 4.93l1.41 1.41", "M17.66 17.66l1.41 1.41",
        "M2 12h2", "M20 12h2", "M6.34 17.66l-1.41 1.41", "M19.07 4.93l-1.41 1.41",
    )
    val Phone = line("phone", "M7 2h10a2 2 0 0 1 2 2v16a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2z", "M12 18h.01")
    val Lock = line("lock", "M5 11h14a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-7a2 2 0 0 1 2-2z", "M7 11V7a5 5 0 0 1 10 0v4")
}
