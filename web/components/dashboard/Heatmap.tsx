"use client";
import { useEffect, useMemo, useRef, useState } from "react";
import SegmentedControl from "@teamofsilicons/silicon-ui/segmented-control";
import SlotText from "@teamofsilicons/silicon-ui/slot-text";
import { buildHeatmap, monthMarks, type HeatCell } from "@/lib/heatmap";
import { dayLabel, duration, hourLabel, hourRange, localToday, monthDay, plural } from "@/lib/format";
import type { HeatmapRow } from "@/lib/types";
import styles from "./dashboard.module.css";

const ROW = 14;
const GAP = 2;
const LABEL_W = 30;
const HEAD_H = 30;

export function Heatmap({ rows, days, onDays, scope, onScope, canScope, loading }: {
  rows: HeatmapRow[];
  days: number;
  onDays: (d: number) => void;
  scope: "all" | "this";
  onScope: (s: "all" | "this") => void;
  canScope: boolean;
  loading: boolean;
}) {
  const today = localToday();
  const heat = useMemo(() => buildHeatmap(rows, days, today), [rows, days, today]);
  const wrapRef = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(720);
  const [focus, setFocus] = useState<{ d: number; h: number } | null>(null);
  const nowHour = new Date().getHours();

  useEffect(() => {
    const el = wrapRef.current;
    if (!el) return;
    const ro = new ResizeObserver(([e]) => setWidth(e.contentRect.width));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  const n = heat.dates.length;
  const cw = Math.max(5, Math.min(34, (width - LABEL_W) / n));
  const gridW = cw * n;
  const gridH = 24 * ROW;
  const marks = monthMarks(heat.dates);
  const s = heat.summary;
  const cell: HeatCell | null = focus ? heat.columns[focus.d]?.[focus.h] ?? null : null;
  const dayEvery = cw >= 22 ? 1 : cw >= 12 ? 2 : 7;

  const pick = (clientX: number, clientY: number, svg: SVGSVGElement) => {
    const r = svg.getBoundingClientRect();
    const d = Math.floor((clientX - r.left) / cw);
    const h = Math.floor((clientY - r.top - HEAD_H) / ROW);
    if (d >= 0 && d < n && h >= 0 && h < 24) setFocus({ d, h });
    else setFocus(null);
  };

  const onKey = (e: React.KeyboardEvent) => {
    const f = focus ?? { d: n - 1, h: nowHour };
    const moves: Record<string, [number, number]> = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] };
    if (e.key === "Escape") return setFocus(null);
    const m = moves[e.key];
    if (!m) return;
    e.preventDefault();
    setFocus({ d: Math.max(0, Math.min(n - 1, f.d + m[0])), h: Math.max(0, Math.min(23, f.h + m[1])) });
  };

  const tipLeft = focus ? LABEL_W + focus.d * cw + cw / 2 : 0;
  const tipTop = focus ? HEAD_H + focus.h * ROW : 0;
  const flip = focus ? tipLeft > width - 140 : false;
  const flipLeft = focus ? tipLeft < 140 : false;

  return (
    <section className={`${styles.panel} ${styles.heatPanel}`} aria-labelledby="heat-title">
      <header className={styles.heatHead}>
        <div>
          <h2 id="heat-title">When your agents run</h2>
          <p className={styles.panelMeta}>Each column is a day, each row an hour of your local time. Darker means more agent time.</p>
        </div>
        <div className={styles.heatControls}>
          {canScope && (
            <SegmentedControl
              size="xs"
              label="Which Macs"
              value={scope}
              onValueChange={(v) => onScope(v as "all" | "this")}
              options={[{ value: "all", label: "All Macs" }, { value: "this", label: "This Mac" }]}
            />
          )}
          <SegmentedControl
            size="xs"
            label="Range"
            value={String(days)}
            onValueChange={(v) => onDays(Number(v))}
            options={[{ value: "14", label: "2 weeks" }, { value: "35", label: "5 weeks" }, { value: "90", label: "90 days" }]}
          />
        </div>
      </header>

      <dl className={styles.heatStats}>
        <Stat label="Agent time" value={duration(s.totalAgentSeconds)} />
        <Stat label="Active days" value={`${s.activeDays}`} suffix={`/ ${n}`} />
        <Stat label="Current streak" value={plural(s.currentStreak, "day")} />
        <Stat label="Longest streak" value={plural(s.longestStreak, "day")} />
        <Stat label="Skipped days" value={`${s.skippedDays}`} />
        <Stat label="Busiest hour" value={s.busiestHour === null ? "—" : hourRange(s.busiestHour)} />
        <Stat label="Most at once" value={`${s.peakConcurrent}`} />
      </dl>

      <div className={styles.heatWrap} ref={wrapRef} data-loading={loading ? "" : undefined}>
        <svg
          className={styles.heatSvg}
          width={LABEL_W + gridW}
          height={HEAD_H + gridH}
          viewBox={`0 0 ${LABEL_W + gridW} ${HEAD_H + gridH}`}
          role="img"
          aria-label={`Agent activity over ${n} days: ${duration(s.totalAgentSeconds)} of agent time on ${s.activeDays} days, current streak ${s.currentStreak} days. Use the arrow keys to read individual hours.`}
          tabIndex={0}
          onKeyDown={onKey}
          onBlur={() => setFocus(null)}
          onPointerLeave={() => setFocus(null)}
          onPointerMove={(e) => pick(e.clientX - LABEL_W, e.clientY, e.currentTarget)}
        >
          {[0, 6, 12, 18].map((h) => (
            <text key={h} x={LABEL_W - 8} y={HEAD_H + h * ROW + ROW / 2} className={styles.heatLabel} textAnchor="end" dominantBaseline="central">
              {hourLabel(h)}
            </text>
          ))}
          {marks.map((m) => (
            <text key={`m${m.index}`} x={LABEL_W + m.index * cw} y={10} className={styles.heatMonth} dominantBaseline="central">
              {m.label}
            </text>
          ))}
          {heat.dates.map((d, i) =>
            (n - 1 - i) % dayEvery === 0 ? (
              <text key={`d${d}`} x={LABEL_W + i * cw + cw / 2} y={HEAD_H - 8} className={styles.heatDay} data-today={d === today ? "" : undefined} textAnchor="middle" dominantBaseline="central">
                {monthDay(d).day}
              </text>
            ) : null,
          )}
          <g key={`${days}-${scope}-${rows.length}`} transform={`translate(${LABEL_W} ${HEAD_H})`}>
            {heat.columns.map((col, d) =>
              col.map((c) => (
                <rect
                  key={`${d}-${c.hour}`}
                  x={d * cw + GAP / 2}
                  y={c.hour * ROW + GAP / 2}
                  width={Math.max(1, cw - GAP)}
                  height={ROW - GAP}
                  rx={Math.min(3, (cw - GAP) / 3)}
                  className={styles.heatCell}
                  data-level={c.level}
                  data-now={heat.dates[d] === today && c.hour === nowHour ? "" : undefined}
                  style={{ animationDelay: `${Math.round((d / n) * 520 + c.hour * 6)}ms` }}
                />
              )),
            )}
            {focus && (
              <rect
                x={focus.d * cw + 0.5}
                y={focus.h * ROW + 0.5}
                width={cw - 1}
                height={ROW - 1}
                rx={3}
                className={styles.heatFocus}
              />
            )}
          </g>
        </svg>
        {cell && focus && (
          <div
            className={styles.heatTip}
            style={{ left: tipLeft, top: tipTop, transform: `translate(${flip ? "-100%" : flipLeft ? "0" : "-50%"}, calc(-100% - 8px))` }}
            role="status"
          >
            <b>{dayLabel(cell.date)} · {hourRange(cell.hour)}</b>
            {cell.agentSeconds > 0 ? (
              <>
                <span>{duration(cell.agentSeconds)} of agent time</span>
                <span>
                  {cell.maxConcurrent > 1 ? `Up to ${cell.maxConcurrent} at once` : "1 at a time"}
                  {cell.sessionsStarted ? ` · ${plural(cell.sessionsStarted, "session")} started` : ""}
                </span>
              </>
            ) : (
              <span>No agents running</span>
            )}
          </div>
        )}
      </div>
      <div className={styles.legend} aria-hidden="true">
        <span>Less</span>
        {[0, 1, 2, 3, 4].map((l) => <i key={l} data-level={l} />)}
        <span>More</span>
      </div>
    </section>
  );
}

function Stat({ label, value, suffix }: { label: string; value: string; suffix?: string }) {
  return (
    <div className={styles.heatStat}>
      <dt>{label}</dt>
      <dd>
        <SlotText value={value} className="tabular" />
        {suffix && <span className={styles.heatSuffix}> {suffix}</span>}
      </dd>
    </div>
  );
}
