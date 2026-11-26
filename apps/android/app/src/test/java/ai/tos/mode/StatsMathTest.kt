package ai.tos.mode

import ai.tos.mode.data.HeatCell
import ai.tos.mode.data.ModeJson
import ai.tos.mode.data.Providers
import ai.tos.mode.data.StatsMath
import ai.tos.mode.data.Times
import ai.tos.mode.data.UsageRow
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.LocalDate

class StatsMathTest {
    private val today = LocalDate.of(2026, 11, 26)

    private fun cell(daysAgo: Long, hour: Int, seconds: Long, concurrent: Int = 1, started: Long = 0) =
        HeatCell(today.minusDays(daysAgo).toString(), hour, seconds, concurrent, started, 1)

    @Test
    fun streaksSkipsAndBusiestHour() {
        // active: today, 1, 2 days ago (streak 3); gap at 3; active 4..8 (run of 5); first active 8 days ago.
        val cells = listOf(0L, 1, 2, 4, 5, 6, 7, 8).map { cell(it, 14, 1800) } + cell(1, 23, 20_000, concurrent = 4, started = 3)
        val s = StatsMath.summarize(cells, emptyList(), today)
        assertEquals(3, s.currentStreak)
        assertEquals(5, s.longestStreak)
        assertEquals(1, s.skippedDays)
        assertEquals(23, s.busiestHour)
        assertEquals(4, s.peakConcurrent)
        assertEquals(3L, s.sessionsStarted)
        assertEquals(8, s.activeDaysWindow)
        assertEquals(StatsMath.MIN_COLUMNS, s.days.size)
        assertEquals(today, s.days.last().date)
    }

    @Test
    fun streakCountsFromYesterdayWhenTodayIsQuiet() {
        val s = StatsMath.summarize(listOf(cell(1, 10, 600), cell(2, 10, 600)), emptyList(), today)
        assertEquals(2, s.currentStreak)
        assertEquals(0, s.skippedDays)
    }

    @Test
    fun columnsGrowWithHistoryButAreCapped() {
        val s = StatsMath.summarize(listOf(cell(60, 9, 600)), emptyList(), today)
        assertEquals(61, s.days.size)
        val capped = StatsMath.summarize(listOf(cell(400, 9, 600)), emptyList(), today, maxColumns = 182)
        assertEquals(182, capped.days.size)
    }

    @Test
    fun providerSharesNormalizeIds() {
        fun row(daysAgo: Long, by: Map<String, Long>, silicon: Long = 0) = UsageRow(
            "d", today.minusDays(daysAgo).toString(), 10, by.values.sum(), silicon,
            JsonObject(by.mapValues { JsonPrimitive(it.value) }),
        )
        val usage = listOf(
            row(0, mapOf("claude-code" to 3000, "codex" to 1000), silicon = 1200),
            row(3, mapOf("claude_code" to 1000)),
            row(45, mapOf("pi" to 9999)), // outside the 30-day window
        )
        val s = StatsMath.summarize(emptyList(), usage, today)
        assertEquals(listOf("claude_code", "codex"), s.providers.map { it.provider })
        assertEquals(4000L, s.providers[0].seconds)
        assertEquals(0.8f, s.providers[0].fraction, 0.001f)
        assertEquals(1200L, s.siliconModeSeconds)
    }

    @Test
    fun heatLevels() {
        assertEquals(0, StatsMath.level(0))
        assertEquals(1, StatsMath.level(600))
        assertEquals(3, StatsMath.level(3600))
        assertEquals(5, StatsMath.level(4 * 3600))
    }

    @Test
    fun parsesPostgresTimestamps() {
        val expected = Instant.parse("2026-11-26T15:30:00.123456Z")
        assertEquals(expected, Times.parse("2026-11-26T15:30:00.123456+00:00"))
        assertEquals(expected, Times.parse("2026-11-26 21:00:00.123456+05:30"))
        assertEquals(expected, Times.parse("2026-11-26T15:30:00.123456Z"))
        assertNotNull(Times.parse("2026-11-26T15:30:00+0000"))
        assertEquals(null, Times.parse(null))
    }

    @Test
    fun providerCatalog() {
        assertEquals("claude_code", Providers.normalize("Claude-Code"))
        assertEquals("Claude Code", Providers.info("claude-code").name)
        assertEquals("Codex", Providers.info("codex").name)
        assertTrue(Providers.info("custom:my_harness").name.startsWith("My harness"))
    }

    @Test
    fun decodesHeatmapRows() {
        val rows = ModeJson.decodeFromString(
            kotlinx.serialization.builtins.ListSerializer(HeatCell.serializer()),
            """[{"local_date":"2026-11-26","local_hour":9,"agent_seconds":5400,"max_concurrent":3,"sessions_started":2,"devices":1}]""",
        )
        assertEquals(5400L, rows.single().agentSeconds)
    }
}
