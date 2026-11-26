"use client";
import { useCallback, useEffect, useRef, useState } from "react";
import { Lock, RotateCcw } from "lucide-react";
import { FaceCanvas } from "@/components/faces/FaceCanvas";
import type { FaceAgent } from "@/components/faces/draw";
import styles from "./LaptopHero.module.css";

type Phase = "open" | "tilt" | "stable" | "countdown" | "bloom" | "face" | "locked";

const OPEN = 108;
const MODE = 62;
const THRESHOLD = 75;
// Timeline (seconds). The countdown shows the default 5 s at 0.6 s per tick so the story fits a glance.
const T = { tiltStart: 0.9, tiltEnd: 2.6, stableEnd: 3.1, countEnd: 6.1, bloomEnd: 7.2, lock: 12.5 };

const AGENTS: FaceAgent[] = [
  { color: "#D97757", mono: "C", state: "working" },
  { color: "#10A37F", mono: "Cx", state: "waiting" },
  { color: "#8B5CF6", mono: "π", state: "working" },
  { color: "#6E6E6E", mono: "oc", state: "finished" },
];

const STEPS: { id: Phase[]; label: string }[] = [
  { id: ["open", "tilt", "stable"], label: "Tilt below 75°" },
  { id: ["countdown"], label: "5 s countdown" },
  { id: ["bloom", "face"], label: "Silicon Mode" },
  { id: ["locked"], label: "Locked to your PIN" },
];

function easeInOut(x: number) {
  return x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2;
}

/** Lid angle over time: open, then a smooth close with a tiny settle, like a hand letting go. */
function lidAt(t: number): number {
  if (t <= T.tiltStart) return OPEN;
  if (t >= T.tiltEnd + 0.4) return MODE;
  if (t <= T.tiltEnd) {
    const p = easeInOut((t - T.tiltStart) / (T.tiltEnd - T.tiltStart));
    return OPEN + (MODE - 1.6 - OPEN) * p;
  }
  const p = (t - T.tiltEnd) / 0.4;
  return MODE - 1.6 * (1 - p) * Math.cos(p * Math.PI * 0.5);
}

function phaseAt(t: number): Phase {
  if (t < T.tiltStart) return "open";
  if (t < T.tiltEnd) return "tilt";
  if (t < T.stableEnd) return "stable";
  if (t < T.countEnd) return "countdown";
  if (t < T.bloomEnd) return "bloom";
  if (t < T.lock) return "face";
  return "locked";
}

export function LaptopHero() {
  const lidRef = useRef<HTMLDivElement>(null);
  const angleRef = useRef<HTMLSpanElement>(null);
  const needleRef = useRef<SVGLineElement>(null);
  const [phase, setPhase] = useState<Phase>("open");
  const [count, setCount] = useState(5);
  const [run, setRun] = useState(0);
  const [visible, setVisible] = useState(true);
  const [started, setStarted] = useState(false);
  const stageRef = useRef<HTMLDivElement>(null);

  const apply = useCallback((angle: number) => {
    if (lidRef.current) lidRef.current.style.transform = `rotateX(${(angle - 90).toFixed(2)}deg)`;
    if (angleRef.current) angleRef.current.textContent = `${Math.round(angle)}°`;
    if (needleRef.current) {
      const a = (180 - angle) * (Math.PI / 180);
      needleRef.current.setAttribute("x2", (32 + Math.cos(a) * 22).toFixed(2));
      needleRef.current.setAttribute("y2", (32 - Math.sin(a) * 22).toFixed(2));
    }
    stageRef.current?.toggleAttribute("data-below", angle < THRESHOLD);
  }, []);

  useEffect(() => {
    const el = stageRef.current;
    if (!el) return;
    const io = new IntersectionObserver(([e]) => {
      setVisible(e.isIntersecting);
      // Play the story once the laptop is properly on screen, not while it's below the fold.
      if (e.intersectionRatio >= 0.45) setStarted(true);
    }, { threshold: [0, 0.05, 0.45] });
    io.observe(el);
    return () => io.disconnect();
  }, []);

  useEffect(() => {
    if (!started) return;
    const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (reduce) {
      apply(MODE);
      setPhase("face");
      return;
    }
    let raf = 0;
    let start = 0;
    let lastPhase: Phase | null = null;
    let lastCount = -1;
    const tick = (now: number) => {
      if (!start) start = now;
      const t = (now - start) / 1000;
      apply(lidAt(t));
      const p = phaseAt(t);
      if (p !== lastPhase) {
        lastPhase = p;
        setPhase(p);
      }
      if (p === "countdown") {
        const c = Math.max(1, 5 - Math.floor((t - T.stableEnd) / 0.6));
        if (c !== lastCount) {
          lastCount = c;
          setCount(c);
        }
      }
      if (t < T.lock + 0.1) raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [run, apply, started]);

  const faceOn = phase === "bloom" || phase === "face" || phase === "locked";
  const step = STEPS.findIndex((s) => s.id.includes(phase));

  return (
    <div className={styles.stage} ref={stageRef} data-phase={phase}>
      <div className={styles.scene}>
        <div className={styles.laptop}>
          <div className={styles.lid} ref={lidRef} style={{ transform: `rotateX(${OPEN - 90}deg)` }}>
            <div className={styles.bezel}>
              <div className={styles.screen}>
                <Desktop />
                <div className={styles.blurred} aria-hidden="true">
                  <Desktop />
                </div>
                <div className={styles.countdown} aria-live="polite">
                  <span key={count} className={styles.count}>{count}</span>
                  <span className={styles.countLabel}>Entering Silicon Mode</span>
                </div>
                <span className={styles.dont}>Do not enter Silicon Mode</span>
                <div className={styles.face}>
                  <FaceCanvas
                    face="orbit"
                    agents={AGENTS}
                    status="2 working · 1 needs you · 1 finished"
                    paused={!faceOn || !visible}
                    className={styles.faceCanvas}
                    label="The Orbit face: four agents circling a glowing core"
                  />
                </div>
                <div className={styles.wave} aria-hidden="true" />
                <span className={styles.locked}>
                  <Lock size={10} strokeWidth={2.4} aria-hidden="true" /> Locked
                </span>
              </div>
              <span className={styles.camera} aria-hidden="true" />
            </div>
          </div>
          <div className={styles.base}>
            <Keyboard />
            <div className={styles.spill} aria-hidden="true" />
            <div className={styles.lip} />
          </div>
        </div>
        <div className={styles.shadow} aria-hidden="true" />
      </div>

      <div className={styles.footer}>
      <div className={styles.readout} aria-hidden="true">
        <svg viewBox="0 0 64 36" width="48" height="27">
          <path d="M10 32 A22 22 0 0 1 54 32" fill="none" stroke="var(--border)" strokeWidth="3" strokeLinecap="round" />
          <path d={arcPath(75)} fill="none" stroke="var(--accent)" strokeWidth="3" strokeLinecap="round" opacity=".9" />
          <line x1="32" y1="32" x2="32" y2="10" ref={needleRef} stroke="var(--foreground)" strokeWidth="2" strokeLinecap="round" />
          <circle cx="32" cy="32" r="2.6" fill="var(--foreground)" />
        </svg>
        <div>
          <span className={styles.readoutLabel}>Lid</span>
          <span className={`${styles.readoutValue} tabular`} ref={angleRef}>{OPEN}°</span>
        </div>
      </div>

      <ol className={styles.steps} aria-label="What just happened">
        {STEPS.map((s, i) => (
          <li key={s.label} data-state={i < step ? "done" : i === step ? "now" : "next"}>
            <span className={styles.stepDot} />
            {s.label}
          </li>
        ))}
      </ol>

      <button type="button" className={styles.replay} onClick={() => { setCount(5); setRun((r) => r + 1); }} aria-label="Replay the animation">
        <RotateCcw size={14} strokeWidth={2} />
      </button>
      </div>
    </div>
  );
}

/** The part of the gauge below the 75° threshold (the Silicon Mode zone), angle measured from the lid's closed side. */
function arcPath(threshold: number) {
  const a = (180 - threshold) * (Math.PI / 180);
  const x = 32 + Math.cos(a) * 22;
  const y = 32 - Math.sin(a) * 22;
  return `M${x.toFixed(2)} ${y.toFixed(2)} A22 22 0 0 0 10 32`;
}

function Desktop() {
  return (
    <div className={styles.desktop}>
      <div className={styles.menubar}>
        <span className={styles.menuDot} />
        <span className={styles.menuItem} />
        <span className={styles.menuItem} style={{ width: "9%" }} />
        <span className={styles.menuSpacer} />
        <span className={styles.menuIcon} />
        <span className={styles.menuItem} style={{ width: "7%" }} />
      </div>
      <div className={styles.window}>
        <div className={styles.windowBar}>
          <i /> <i /> <i />
        </div>
        <div className={styles.term}>
          <p><b style={{ color: "#D97757" }}>claude</b> editing src/middleware/auth.ts</p>
          <p><b style={{ color: "#10A37F" }}>codex</b> npm test -- checkout.spec.ts</p>
          <p><b style={{ color: "#8B5CF6" }}>pi</b> summarizing 14 review comments</p>
          <p><b style={{ color: "#9a9a9a" }}>opencode</b> ✓ migration written</p>
          <p className={styles.cursorLine}>
            <span className={styles.cursor} />
          </p>
        </div>
      </div>
      <div className={styles.note}>
        <span className={styles.noteIcon} />
        <span>
          <b>4 agents running</b>
          <br />
          Close the lid halfway to step away.
        </span>
      </div>
    </div>
  );
}

const ROWS = [14, 14, 13, 12, 11];

function Keyboard() {
  return (
    <div className={styles.deck} aria-hidden="true">
      <div className={styles.keys}>
        {ROWS.map((n, r) => (
          <div key={r} className={styles.keyRow}>
            {Array.from({ length: n }, (_, k) => (
              <span key={k} className={styles.key} />
            ))}
          </div>
        ))}
        <div className={styles.keyRow}>
          <span className={styles.key} />
          <span className={styles.key} />
          <span className={styles.key} />
          <span className={styles.key} style={{ flex: 6 }} />
          <span className={styles.key} />
          <span className={styles.key} />
          <span className={styles.key} />
        </div>
      </div>
      <div className={styles.trackpad} />
    </div>
  );
}
