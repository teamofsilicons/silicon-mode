"use client";
import { useEffect, useState } from "react";
import { Plus } from "lucide-react";
import SlotText from "@teamofsilicons/silicon-ui/slot-text";
import { ProviderMark } from "@/components/ProviderMark";
import { SUPPORTED } from "@/lib/providers";
import styles from "./AgentsSection.module.css";

const MOMENTS = [
  { need: 1, finished: 1, working: 3 },
  { need: 3, finished: 4, working: 2 },
  { need: 0, finished: 6, working: 1 },
  { need: 2, finished: 2, working: 4 },
];

export function AgentsSection() {
  const [i, setI] = useState(1);
  useEffect(() => {
    if (matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const id = window.setInterval(() => {
      if (!document.hidden) setI((x) => (x + 1) % MOMENTS.length);
    }, 2600);
    return () => window.clearInterval(id);
  }, []);
  const m = MOMENTS[i];

  return (
    <div className={styles.wrap}>
      <div className={styles.copy}>
        <p className={styles.ticker} aria-live="off">
          <span className={styles.stat} data-tone="need">
            <SlotText value={m.need} className="tabular" /> need you
          </span>
          <span className={styles.stat} data-tone="done">
            <SlotText value={m.finished} className="tabular" /> finished
          </span>
          <span className={styles.stat} data-tone="work">
            <SlotText value={m.working} className="tabular" /> working
          </span>
        </p>
        <p className={styles.body}>
          Silicon Mode finds agent sessions on your Mac by itself — through hooks where an agent has them, and its
          logs and processes where it doesn&apos;t. Questions and permission prompts come with answer buttons, right on the face.
        </p>
      </div>
      <ul className={styles.grid}>
        {SUPPORTED.map((p) => (
          <li key={p.id} className={styles.agent}>
            <ProviderMark id={p.id} size={30} />
            <span>{p.name}</span>
          </li>
        ))}
        <li className={`${styles.agent} ${styles.own}`}>
          <span className={styles.plus}>
            <Plus size={14} strokeWidth={2} aria-hidden="true" />
          </span>
          <span>Your own harness</span>
        </li>
      </ul>
    </div>
  );
}
