import { test } from "node:test";
import assert from "node:assert/strict";
import { buildHeatmap, levelFor, monthMarks } from "../lib/heatmap.ts";
import { addDays, hourRange, clock, duration, relativeTime } from "../lib/format.ts";
import type { HeatmapRow } from "../lib/types.ts";

const row = (local_date: string, local_hour: number, agent_seconds: number, max_concurrent = 1): HeatmapRow =>
  ({ local_date, local_hour, agent_seconds, max_concurrent, sessions_started: 1, devices: 1 });

test("grid is 24 rows × N day columns ending today", () => {
  const h = buildHeatmap([], 35, "2026-11-26");
  assert.equal(h.dates.length, 35);
  assert.equal(h.dates[0], "2026-10-23");
  assert.equal(h.dates.at(-1), "2026-11-26");
  assert.ok(h.columns.every((c) => c.length === 24));
  assert.equal(h.summary.activeDays, 0);
  assert.equal(h.summary.busiestHour, null);
});

test("cells carry agent seconds, concurrency and a level; out-of-range rows are ignored", () => {
  const h = buildHeatmap([
    row("2026-11-26", 21, 3600, 3),
    row("2026-11-26", 22, 900, 1),
    row("2026-11-25", 9, 100, 1),
    row("2026-01-01", 9, 9999, 9), // outside the window
    row("2026-11-26", 24 as number, 50), // bad hour
  ], 7, "2026-11-26");
  const today = h.columns.at(-1)!;
  assert.equal(today[21].agentSeconds, 3600);
  assert.equal(today[21].maxConcurrent, 3);
  assert.equal(today[21].level, 4);
  assert.equal(today[22].level, 2); // sqrt(900/3600) = 0.5, not above the 0.5 bound
  assert.equal(h.maxAgentSeconds, 3600);
  assert.equal(h.summary.peakConcurrent, 3);
  assert.equal(h.summary.busiestHour, 21);
  assert.equal(h.summary.totalAgentSeconds, 4600);
});

test("level buckets on a square-root scale", () => {
  assert.equal(levelFor(0, 100), 0);
  assert.equal(levelFor(1, 100), 1);
  assert.equal(levelFor(10, 100), 2);
  assert.equal(levelFor(30, 100), 3);
  assert.equal(levelFor(60, 100), 4);
  assert.equal(levelFor(5, 0), 0);
});

test("merged rows (several Macs) for the same hour add up", () => {
  const h = buildHeatmap([row("2026-11-26", 3, 600, 2), row("2026-11-26", 3, 300, 4)], 3, "2026-11-26");
  assert.equal(h.columns[2][3].agentSeconds, 900);
  assert.equal(h.columns[2][3].maxConcurrent, 4);
});

test("streaks and skipped days", () => {
  const today = "2026-11-26";
  const active = [-9, -8, -7, -5, -4, -3, -2, -1]; // today itself has nothing yet
  const rows = active.map((d) => row(addDays(today, d), 20, 1200));
  const h = buildHeatmap(rows, 14, today);
  assert.equal(h.summary.activeDays, 8);
  assert.equal(h.summary.currentStreak, 5, "streak counts back from yesterday when today is empty");
  assert.equal(h.summary.longestStreak, 5);
  // From the first active day (-9) to today: -6 and today (0) are empty.
  assert.equal(h.summary.skippedDays, 2);
});

test("a gap yesterday breaks the current streak", () => {
  const today = "2026-11-26";
  const h = buildHeatmap([row(today, 1, 60), row(addDays(today, -2), 1, 60), row(addDays(today, -3), 1, 60)], 7, today);
  assert.equal(h.summary.currentStreak, 1);
  assert.equal(h.summary.longestStreak, 2);
});

test("month marks", () => {
  const h = buildHeatmap([], 10, "2026-12-03");
  assert.deepEqual(monthMarks(h.dates).map((m) => m.label), ["Nov", "Dec"]);
});

test("formatters", () => {
  assert.equal(duration(59), "59s");
  assert.equal(duration(60 * 134), "2h 14m");
  assert.equal(duration(3600 * 27), "1d 3h");
  assert.equal(clock(3753), "1:02:33");
  assert.equal(clock(65), "1:05");
  assert.equal(hourRange(21), "9–10 pm");
  assert.equal(hourRange(11), "11 am–12 pm");
  assert.equal(hourRange(23), "11–12 pm");
  const now = Date.parse("2026-11-26T12:00:00Z");
  assert.equal(relativeTime("2026-11-26T11:59:58Z", now), "just now");
  assert.equal(relativeTime("2026-11-26T11:55:00Z", now), "5m ago");
  assert.equal(relativeTime(null, now), "—");
});
