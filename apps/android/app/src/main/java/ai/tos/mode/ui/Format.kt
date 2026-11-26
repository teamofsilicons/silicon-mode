package ai.tos.mode.ui

import ai.tos.mode.data.Times
import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle
import java.util.Locale

object Format {
    /** 42m · 1h 05m · 3h · 2d 4h */
    fun duration(seconds: Long): String {
        val s = seconds.coerceAtLeast(0)
        val d = s / 86_400
        val h = (s % 86_400) / 3600
        val m = (s % 3600) / 60
        return when {
            d > 0 -> if (h > 0) "${d}d ${h}h" else "${d}d"
            h > 0 -> if (m > 0) "${h}h ${"%02d".format(m)}m" else "${h}h"
            m > 0 -> "${m}m"
            else -> "${s}s"
        }
    }

    /** Hours with one decimal under 10 (7.5h), whole above (86h). */
    fun hours(seconds: Long): String {
        val h = seconds / 3600.0
        return when {
            seconds <= 0 -> "0h"
            h < 1 -> "${(seconds / 60).coerceAtLeast(1)}m"
            h < 10 -> "%.1fh".format(h)
            else -> "${h.toLong()}h"
        }
    }

    fun since(iso: String?, now: Instant): Long? =
        Times.parse(iso)?.let { Duration.between(it, now).seconds.coerceAtLeast(0) }

    /** now · 12s · 5m · 2h · yesterday · 3d */
    fun ago(iso: String?, now: Instant): String {
        val s = since(iso, now) ?: return ""
        return when {
            s < 5 -> "now"
            s < 60 -> "${s}s"
            s < 3600 -> "${s / 60}m"
            s < 86_400 -> "${s / 3600}h"
            s < 2 * 86_400 -> "yesterday"
            else -> "${s / 86_400}d"
        }
    }

    private val clock = DateTimeFormatter.ofPattern("HH:mm:ss")
    private val hm = DateTimeFormatter.ofPattern("HH:mm")

    fun clock(iso: String?): String = Times.parse(iso)?.atZone(ZoneId.systemDefault())?.format(clock) ?: "--:--:--"

    fun hourRange(hour: Int): String = "%02d:00–%02d:00".format(hour, (hour + 1) % 24)

    fun hour(hour: Int): String = "%02d:00".format(hour)

    fun day(date: LocalDate, today: LocalDate): String = when (date) {
        today -> "Today"
        today.minusDays(1) -> "Yesterday"
        else -> "${date.dayOfWeek.getDisplayName(TextStyle.SHORT, Locale.getDefault())} ${date.dayOfMonth} " +
            date.month.getDisplayName(TextStyle.SHORT, Locale.getDefault())
    }

    fun month(date: LocalDate): String = date.month.getDisplayName(TextStyle.SHORT, Locale.getDefault())

    fun time(iso: String?): String = Times.parse(iso)?.atZone(ZoneId.systemDefault())?.format(hm) ?: ""

    /** "MacBookPro18,1" → "MacBook Pro". */
    fun macModel(model: String?): String? {
        val m = model?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        val families = listOf(
            "MacBookPro" to "MacBook Pro", "MacBookAir" to "MacBook Air", "MacBook" to "MacBook",
            "Macmini" to "Mac mini", "MacStudio" to "Mac Studio", "MacPro" to "Mac Pro", "iMac" to "iMac",
            "Mac" to "Mac",
        )
        return families.firstOrNull { m.startsWith(it.first) }?.second ?: m
    }

    fun agentCount(n: Int, noun: String = "agent"): String = if (n == 1) "1 $noun" else "$n ${noun}s"
}
