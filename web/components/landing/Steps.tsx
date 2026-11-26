import { Coffee, Fingerprint, Lock, Siren } from "lucide-react";
import { FaceCanvas } from "@/components/faces/FaceCanvas";
import { InView } from "./InView";
import styles from "./Steps.module.css";

const MINI_AGENTS = [
  { color: "#D97757", mono: "C", state: "working" as const },
  { color: "#10A37F", mono: "Cx", state: "waiting" as const },
  { color: "#8B5CF6", mono: "π", state: "working" as const },
];

export function Steps() {
  return (
    <div className={styles.grid}>
      <InView as="article" className={styles.card}>
        <div className={styles.art}>
          <TiltArt />
        </div>
        <span className={styles.num}>1</span>
        <h3>Tilt the lid below 75°</h3>
        <p>Silicon Mode reads your MacBook&apos;s lid-angle sensor. When agents are running and the lid settles below 75°, it starts counting.</p>
      </InView>

      <InView as="article" className={styles.card}>
        <div className={styles.art}>
          <CountdownArt />
        </div>
        <span className={styles.num}>2</span>
        <h3>Five seconds to change your mind</h3>
        <p>A countdown blurs in from the top with a <em>Do not enter Silicon Mode</em> button. Lying down with the laptop? Tap it and it leaves you alone.</p>
      </InView>

      <InView as="article" className={styles.card}>
        <div className={`${styles.art} ${styles.night}`}>
          <FaceCanvas face="orbit" agents={MINI_AGENTS} fps={30} offset={4} className={styles.mini} label="A Silicon Mode face" />
          <span className={styles.awake}>
            <Coffee size={12} strokeWidth={2} aria-hidden="true" /> Mac stays awake
          </span>
        </div>
        <span className={styles.num}>3</span>
        <h3>Your agents, as a face</h3>
        <p>The screen blooms into a living face that shows who&apos;s working, who finished and who needs you — with the last few events and questions you can answer.</p>
      </InView>

      <InView as="article" className={styles.card}>
        <div className={styles.art}>
          <PinArt />
        </div>
        <span className={styles.num}>4</span>
        <h3>Locked to your PIN</h3>
        <p>For the first minute you can simply open the lid. After that it never turns off by itself — only your 6-digit PIN (or Touch ID) ends it.</p>
      </InView>

      <InView as="article" className={`${styles.card} ${styles.panic}`}>
        <div className={`${styles.art} ${styles.panicArt}`}>
          <Siren size={26} strokeWidth={1.8} aria-hidden="true" />
        </div>
        <div>
          <h3>Close it further and it panics</h3>
          <p>If someone shuts the lid on running agents, the screen flashes and a sound plays — only on the way down, never when you open it again.</p>
        </div>
      </InView>
    </div>
  );
}

function TiltArt() {
  return (
    <svg viewBox="0 0 200 120" className={styles.tilt} aria-hidden="true">
      <path d="M60 96 L104 96 A44 44 0 0 0 71.4 53.5 Z" className={styles.zone} />
      <line x1="60" y1="96" x2="71.4" y2="53.5" className={styles.threshold} />
      <text x="76" y="50" className={styles.thresholdLabel}>75°</text>
      <line x1="40" y1="96" x2="168" y2="96" className={styles.baseLine} />
      <g className={styles.lidGroup}>
        <line x1="60" y1="96" x2="60" y2="22" className={styles.lidLine} />
        <circle cx="60" cy="22" r="4" className={styles.lidTip} />
      </g>
      <circle cx="60" cy="96" r="4.5" className={styles.hinge} />
    </svg>
  );
}

function CountdownArt() {
  return (
    <div className={styles.count}>
      <svg viewBox="0 0 100 100" aria-hidden="true">
        <circle cx="50" cy="50" r="40" className={styles.ringTrack} />
        <circle cx="50" cy="50" r="40" className={styles.ring} pathLength={100} />
      </svg>
      <span className={styles.countNums} aria-hidden="true">
        <span>5</span><span>4</span><span>3</span><span>2</span><span>1</span>
      </span>
      <span className={styles.dont}>Do not enter Silicon Mode</span>
    </div>
  );
}

function PinArt() {
  return (
    <div className={styles.pin}>
      <span className={styles.lock}>
        <Lock size={16} strokeWidth={2} aria-hidden="true" />
      </span>
      <span className={styles.dots} aria-hidden="true">
        {Array.from({ length: 6 }, (_, i) => <i key={i} style={{ animationDelay: `${0.25 + i * 0.22}s` }} />)}
      </span>
      <span className={styles.touch}>
        <Fingerprint size={14} strokeWidth={1.8} aria-hidden="true" /> or Touch ID
      </span>
    </div>
  );
}
