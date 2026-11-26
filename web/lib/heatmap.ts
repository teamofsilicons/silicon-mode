// The 24 × N usage grid: one column per local day, one row per local hour, from rpc/usage_heatmap.
import { addDays, fromISODate } from "./format.ts";
import type { HeatmapRow } from "./types.ts";

export interface HeatCell {
  date: string;
  hour: number;
  agentSeconds: number;
  maxConcurrent: number;
  sessionsStarted: number;
  /** 0 = nothing, 1–4 = intensity relative to the busiest hour in range. */
  level: 0 | 1 | 2 | 3 | 4;
}

export interface HeatmapSummary {
  totalAgentSeconds: number;
  activeDays: number;
  /** Days with no agent time between the first active day in range and today. */
  skippedDays: number;
  currentStreak: number;
  longestStreak: number;
  /** The local hour with the most agent time across the range, or null when empty. */
  busiestHour: number | null;
  peakConcurrent: number;
  sessionsStarted: number;
  /** Agent time per day, oldest first (for the totals row). */
  perDay: number[];
}

export interface Heatmap {
  dates: string[];
  /** columns[dayIndex][hour] */
  columns: HeatCell[][];
  maxAgentSeconds: number;
  summary: HeatmapSummary;
}

/** Intensity buckets on a square-root scale, so a few huge hours don't wash out the rest. */
export function levelFor(seconds: number, max: number): 0 | 1 | 2 | 3 | 4 {
  if (seconds <= 0 || max <= 0) return 0;
  const r = Math.sqrt(seconds / max);
  if (r > 0.75) return 4;
  if (r > 0.5) return 3;
  if (r > 0.25) return 2;
  return 1;
}

/**
 * Builds `days` columns ending at `today` (inclusive). Rows outside the window are ignored; rows the
 * server merged across Macs (p_device = null) arrive already summed per (date, hour).
 */
export function buildHeatmap(rows: HeatmapRow[], days: number, today: string): Heatmap {
  const n = Math.max(1, Math.min(366, Math.floor(days)));
  const start = addDays(today, -(n - 1));
  const dates = Array.from({ length: n }, (_, i) => addDays(start, i));
  const index = new Map(dates.map((d, i) => [d, i]));

  const seconds = dates.map(() => new Array<number>(24).fill(0));
  const concurrent = dates.map(() => new Array<number>(24).fill(0));
  const started = dates.map(() => new Array<number>(24).fill(0));

  for (const row of rows) {
    const day = index.get(String(row.local_date).slice(0, 10));
    const hour = Number(row.local_hour);
    if (day === undefined || !(hour >= 0 && hour < 24)) continue;
    seconds[day][hour] += Math.max(0, Number(row.agent_seconds) || 0);
    concurrent[day][hour] = Math.max(concurrent[day][hour], Number(row.max_concurrent) || 0);
    started[day][hour] += Math.max(0, Number(row.sessions_started) || 0);
  }

  let max = 0;
  for (const col of seconds) for (const v of col) if (v > max) max = v;

  const columns = dates.map((date, d) =>
    seconds[d].map((v, hour) => ({
      date,
      hour,
      agentSeconds: v,
      maxConcurrent: concurrent[d][hour],
      sessionsStarted: started[d][hour],
      level: levelFor(v, max),
    })),
  );

  return { dates, columns, maxAgentSeconds: max, summary: summarize(dates, seconds, concurrent, started) };
}

function summarize(dates: string[], seconds: number[][], concurrent: number[][], started: number[][]): HeatmapSummary {
  const perDay = seconds.map((col) => col.reduce((a, b) => a + b, 0));
  const active = perDay.map((v) => v > 0);
  const total = perDay.reduce((a, b) => a + b, 0);
  const activeDays = active.filter(Boolean).length;

  const first = active.indexOf(true);
  const skippedDays = first < 0 ? 0 : active.slice(first).filter((a) => !a).length;

  let longest = 0;
  let run = 0;
  for (const a of active) {
    run = a ? run + 1 : 0;
    if (run > longest) longest = run;
  }

  // A streak is still alive if today has no agent time yet: count back from yesterday then.
  let current = 0;
  let i = active.length - 1;
  if (i >= 0 && !active[i]) i -= 1;
  for (; i >= 0 && active[i]; i--) current += 1;

  const byHour = new Array<number>(24).fill(0);
  for (const col of seconds) col.forEach((v, h) => (byHour[h] += v));
  const busiest = byHour.reduce((best, v, h) => (v > (best < 0 ? 0 : byHour[best]) ? h : best), -1);

  let peak = 0;
  for (const col of concurrent) for (const v of col) if (v > peak) peak = v;
  const sessions = started.reduce((a, col) => a + col.reduce((x, y) => x + y, 0), 0);

  return {
    totalAgentSeconds: total,
    activeDays,
    skippedDays,
    currentStreak: current,
    longestStreak: longest,
    busiestHour: busiest < 0 ? null : busiest,
    peakConcurrent: peak,
    sessionsStarted: sessions,
    perDay,
  };
}

/** Month boundaries for the column header: index of the first column of each month shown. */
export function monthMarks(dates: string[]): { index: number; label: string }[] {
  const out: { index: number; label: string }[] = [];
  let last = -1;
  dates.forEach((date, i) => {
    const m = fromISODate(date).getUTCMonth();
    if (m !== last) {
      out.push({ index: i, label: fromISODate(date).toLocaleString("en-US", { month: "short", timeZone: "UTC" }) });
      last = m;
    }
  });
  return out;
}
