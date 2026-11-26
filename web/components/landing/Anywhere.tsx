import { buildHeatmap } from "@/lib/heatmap";
import { demoHeatmap } from "@/lib/demo";
import { ProviderMark } from "@/components/ProviderMark";
import styles from "./Anywhere.module.css";

const TODAY = "2026-11-26";

export function Anywhere() {
  const heat = buildHeatmap(demoHeatmap(30, TODAY), 30, TODAY);
  const cell = 7;
  const gap = 2;
  return (
    <div className={styles.devices}>
      <div className={styles.browser} aria-hidden="true">
        <div className={styles.chrome}>
          <i /> <i /> <i />
          <span className={styles.url}>mode.teamofsilicons.com/app</span>
        </div>
        <div className={styles.browserBody}>
          <div className={styles.browserHead}>
            <b>When your agents run</b>
            <span>{Math.round(heat.summary.totalAgentSeconds / 3600)} agent-hours · {heat.summary.currentStreak}-day streak</span>
          </div>
          <svg viewBox={`0 0 ${30 * (cell + gap)} ${24 * (cell + gap)}`} className={styles.heat}>
            {heat.columns.map((col, d) =>
              col.map((c) => (
                <rect
                  key={`${d}-${c.hour}`}
                  x={d * (cell + gap)}
                  y={c.hour * (cell + gap)}
                  width={cell}
                  height={cell}
                  rx={1.8}
                  className={styles[`l${c.level}`]}
                  style={{ animationDelay: `${d * 22 + c.hour * 6}ms` }}
                />
              )),
            )}
          </svg>
        </div>
      </div>

      <div className={styles.phone} aria-hidden="true">
        <div className={styles.phoneScreen}>
          <div className={styles.island} />
          <div className={styles.macRow}>
            <span className={styles.liveDot} />
            <span>
              <b>Studio MacBook Pro</b>
              <br />
              Silicon Mode · 52m
            </span>
          </div>
          <div className={styles.counts}>
            <span><b>2</b> working</span>
            <span data-tone="need"><b>1</b> needs you</span>
            <span><b>1</b> done</span>
          </div>
          <div className={styles.question}>
            <div className={styles.qHead}>
              <ProviderMark id="codex" size={18} />
              <span>Codex · shop</span>
            </div>
            <p>Allow Bash: <code>git push origin fix/checkout</code>?</p>
            <div className={styles.qActions}>
              <span className={styles.allow}>Allow once</span>
              <span className={styles.deny}>Deny</span>
            </div>
            <div className={styles.answered}>Answered · Allow once</div>
          </div>
          <ul className={styles.tail}>
            <li><ProviderMark id="claude_code" size={14} /> Edit: src/middleware/auth.ts</li>
            <li><ProviderMark id="opencode" size={14} /> Migration applied · 3 tables</li>
            <li><ProviderMark id="claude_code" size={14} /> npm test · 214 passed</li>
          </ul>
        </div>
      </div>
    </div>
  );
}
