"use client";
import { Sparkles } from "lucide-react";
import { FaceCanvas } from "@/components/faces/FaceCanvas";
import { FACES, type FaceAgent } from "@/components/faces/draw";
import styles from "./FacesGallery.module.css";

const AGENTS: FaceAgent[] = [
  { color: "#D97757", mono: "C", state: "working" },
  { color: "#10A37F", mono: "Cx", state: "waiting" },
  { color: "#8B5CF6", mono: "π", state: "working" },
  { color: "#E4572E", mono: "OC", state: "working" },
  { color: "#6E6E6E", mono: "oc", state: "finished" },
];

export function FacesGallery() {
  return (
    <ul className={styles.grid}>
      {FACES.map((f, i) => (
        <li key={f.id} className={styles.tile}>
          <div className={styles.screen}>
            <FaceCanvas
              face={f.id}
              agents={AGENTS.slice(0, f.id === "desk" ? 3 : 5)}
              status={f.id === "chomp" || f.id === "orbit" ? undefined : "3 working · 1 needs you"}
              fps={30}
              offset={i * 3.7}
              className={styles.canvas}
              label={`${f.name}: ${f.summary}`}
            />
          </div>
          <div className={styles.meta}>
            <h3>{f.name}</h3>
            <p>{f.summary}</p>
          </div>
        </li>
      ))}
      <li className={`${styles.tile} ${styles.more}`}>
        <div className={`${styles.screen} ${styles.moreScreen}`}>
          <Sparkles size={22} strokeWidth={1.6} aria-hidden="true" />
          <span>Community faces</span>
        </div>
        <div className={styles.meta}>
          <h3>Marketplace</h3>
          <p>Faces made by other people, and your own — sign in with Silicon Accounts to use them. Coming soon.</p>
        </div>
      </li>
    </ul>
  );
}
