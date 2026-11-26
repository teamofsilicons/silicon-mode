package ai.tos.mode.data

import java.time.LocalDate
import java.time.temporal.ChronoUnit

/** One day of the 24h × days heatmap. [hours] has 24 entries (null = no agents that hour). */
data class HeatDay(val date: LocalDate, val hours: List<HeatCell?>) {
    val agentSeconds: Long get() = hours.sumOf { it?.agentSeconds ?: 0 }
    val active: Boolean get() = agentSeconds > 0
}

data class ProviderShare(val provider: String, val seconds: Long, val fraction: Float)

/** Everything the Stats screen shows, derived from `usage_heatmap` + `usage_hourly`. */
data class StatsSummary(
    val days: List<HeatDay>,
    val today: LocalDate,
    val windowDays: Int,
    val agentSecondsWindow: Long,
    val agentSeconds7d: Long,
    val activeDaysWindow: Int,
    val currentStreak: Int,
    val longestStreak: Int,
    val skippedDays: Int,
    val busiestHour: Int?,
    val peakConcurrent: Int,
    val sessionsStarted: Long,
    val siliconModeSeconds: Long,
    val providers: List<ProviderShare>,
    /** Total agent seconds per hour of day over all [days] (index = hour). */
    val byHourOfDay: List<Long>,
    val maxCellSeconds: Long,
) {
    val isEmpty: Boolean get() = days.none { it.active }

    companion object {
        val Empty = StatsSummary(
            days = emptyList(), today = LocalDate.now(), windowDays = 30, agentSecondsWindow = 0, agentSeconds7d = 0,
            activeDaysWindow = 0, currentStreak = 0, longestStreak = 0, skippedDays = 0, busiestHour = null,
            peakConcurrent = 0, sessionsStarted = 0, siliconModeSeconds = 0, providers = emptyList(),
            byHourOfDay = List(24) { 0L }, maxCellSeconds = 0,
        )
    }
}

/** Pure functions over the usage rows (unit tested). */
object StatsMath {
    /** The heatmap never shows fewer than four weeks, so a new account still sees a grid. */
    const val MIN_COLUMNS = 28

    fun summarize(
        cells: List<HeatCell>,
        usage: List<UsageRow>,
        today: LocalDate,
        windowDays: Int = 30,
        maxColumns: Int = 182,
    ): StatsSummary {
        val byDate = HashMap<LocalDate, Array<HeatCell?>>()
        for (cell in cells) {
            val date = Times.date(cell.localDate) ?: continue
            if (cell.localHour !in 0..23) continue
            val row = byDate.getOrPut(date) { arrayOfNulls(24) }
            val prev = row[cell.localHour]
            row[cell.localHour] = if (prev == null) cell else prev.copy(
                agentSeconds = prev.agentSeconds + cell.agentSeconds,
                maxConcurrent = maxOf(prev.maxConcurrent, cell.maxConcurrent),
                sessionsStarted = prev.sessionsStarted + cell.sessionsStarted,
            )
        }
        val firstActive = byDate.filterValues { row -> row.any { (it?.agentSeconds ?: 0) > 0 } }.keys.minOrNull()
        val earliestShown = today.minusDays((MIN_COLUMNS - 1).toLong())
        val start = listOfNotNull(firstActive, earliestShown).min()
            .coerceAtLeast(today.minusDays((maxColumns - 1).toLong()))
        val count = ChronoUnit.DAYS.between(start, today).toInt() + 1
        val days = (0 until count).map { i ->
            val date = start.plusDays(i.toLong())
            HeatDay(date, byDate[date]?.toList() ?: List(24) { null })
        }

        val windowStart = today.minusDays((windowDays - 1).toLong())
        val weekStart = today.minusDays(6)
        val inWindow = days.filter { !it.date.isBefore(windowStart) }
        val activeSet = days.filter { it.active }.map { it.date }.toSet()

        // Current streak: consecutive active days ending today (or yesterday, if today has not started yet).
        var current = 0
        var cursor = if (today in activeSet) today else today.minusDays(1)
        while (cursor in activeSet) { current++; cursor = cursor.minusDays(1) }

        var longest = 0
        var run = 0
        for (day in days) {
            run = if (day.active) run + 1 else 0
            longest = maxOf(longest, run)
        }

        // Skipped: idle days since the first day agents ever ran (today does not count yet).
        val skipped = firstActive?.let { first ->
            days.count { !it.active && !it.date.isBefore(first) && it.date.isBefore(today) }
        } ?: 0

        val byHour = LongArray(24)
        var peak = 0
        var sessions = 0L
        var maxCell = 0L
        for (day in days) for ((h, cell) in day.hours.withIndex()) {
            if (cell == null) continue
            byHour[h] += cell.agentSeconds
            peak = maxOf(peak, cell.maxConcurrent)
            if (!day.date.isBefore(windowStart)) sessions += cell.sessionsStarted
            maxCell = maxOf(maxCell, cell.agentSeconds)
        }
        val busiest = byHour.indices.maxByOrNull { byHour[it] }?.takeIf { byHour[it] > 0 }

        val providerTotals = HashMap<String, Long>()
        var silicon = 0L
        for (row in usage) {
            val date = Times.date(row.localDate) ?: continue
            if (date.isBefore(windowStart) || date.isAfter(today)) continue
            silicon += row.siliconModeSeconds
            for ((provider, seconds) in row.providerSeconds()) {
                val key = Providers.normalize(provider)
                providerTotals[key] = (providerTotals[key] ?: 0) + seconds
            }
        }
        val providerSum = providerTotals.values.sum().coerceAtLeast(1)
        val providers = providerTotals.entries
            .filter { it.value > 0 }
            .sortedByDescending { it.value }
            .map { ProviderShare(it.key, it.value, it.value.toFloat() / providerSum) }

        return StatsSummary(
            days = days,
            today = today,
            windowDays = windowDays,
            agentSecondsWindow = inWindow.sumOf { it.agentSeconds },
            agentSeconds7d = days.filter { !it.date.isBefore(weekStart) }.sumOf { it.agentSeconds },
            activeDaysWindow = inWindow.count { it.active },
            currentStreak = current,
            longestStreak = longest,
            skippedDays = skipped,
            busiestHour = busiest,
            peakConcurrent = peak,
            sessionsStarted = sessions,
            siliconModeSeconds = silicon,
            providers = providers,
            byHourOfDay = byHour.toList(),
            maxCellSeconds = maxCell,
        )
    }

    /** Heat level 0..5 for a cell's agent seconds (fixed thresholds, so weeks compare fairly). */
    fun level(seconds: Long): Int = when {
        seconds <= 0 -> 0
        seconds <= 15 * 60 -> 1
        seconds <= 45 * 60 -> 2
        seconds <= 90 * 60 -> 3
        seconds <= 3 * 3600 -> 4
        else -> 5
    }
}
