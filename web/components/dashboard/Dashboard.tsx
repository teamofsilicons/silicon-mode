"use client";
import { useCallback, useEffect, useState } from "react";
import Link from "next/link";
import { Download, FlaskConical, LogIn, RefreshCw } from "lucide-react";
import { Button } from "@teamofsilicons/silicon-ui/button";
import { ButtonLink } from "@teamofsilicons/silicon-ui/button-link";
import EmptyState from "@teamofsilicons/silicon-ui/empty-state";
import SegmentedControl from "@teamofsilicons/silicon-ui/segmented-control";
import UserMenu from "@teamofsilicons/silicon-ui/user-menu";
import { LogoMark } from "@/components/Logo";
import { ThemeToggle } from "@/components/ThemeToggle";
import { restoreUser, signInUrl, signOut } from "@/lib/cell";
import { counts as countsOf, isOnline } from "@/lib/store";
import { useTheme } from "@/lib/theme";
import type { CellUser } from "@/lib/types";
import { AgentsList } from "./AgentsList";
import { Heatmap } from "./Heatmap";
import { Questions } from "./Questions";
import { StatusCard } from "./StatusCard";
import { TailLog } from "./TailLog";
import { useDashboard, useHeatmap, type Source } from "./useDashboard";
import { useNow } from "./useNow";
import styles from "./dashboard.module.css";

type Auth =
  | { state: "loading" }
  | { state: "out" }
  | { state: "in"; user: CellUser }
  | { state: "demo" }
  | { state: "error"; message: string };

export function Dashboard() {
  const [auth, setAuth] = useState<Auth>({ state: "loading" });
  const [attempt, setAttempt] = useState(0);

  useEffect(() => {
    const params = new URLSearchParams(location.search);
    if (params.has("demo")) {
      setAuth({ state: "demo" });
      return;
    }
    let cancelled = false;
    restoreUser()
      .then((user) => !cancelled && setAuth(user ? { state: "in", user } : { state: "out" }))
      .catch((e) => !cancelled && setAuth({ state: "error", message: e instanceof Error ? e.message : "Couldn't reach Silicon Mode." }));
    return () => {
      cancelled = true;
    };
  }, [attempt]);

  if (auth.state === "loading") return <Shell><div className={styles.loading} aria-busy="true"><span className={styles.spinner} />Loading your Macs…</div></Shell>;
  if (auth.state === "out") return <Shell><SignIn /></Shell>;
  if (auth.state === "error") {
    return (
      <Shell>
        <div className={styles.center}>
          <EmptyState
            title="Can't reach Silicon Mode right now"
            description={auth.message}
            action={<Button variant="secondary" onClick={() => { setAuth({ state: "loading" }); setAttempt((n) => n + 1); }}><RefreshCw size={14} /> Try again</Button>}
          />
        </div>
      </Shell>
    );
  }
  return (
    <Signed
      source={auth.state === "demo" ? "demo" : "live"}
      user={auth.state === "in" ? auth.user : null}
      onSignedOut={() => setAuth({ state: "out" })}
    />
  );
}

function Shell({ children, right }: { children: React.ReactNode; right?: React.ReactNode }) {
  return (
    <div className={styles.shell}>
      <header className={styles.top}>
        <div className={`page ${styles.topBar}`}>
          <Link href="/" className={styles.brand} aria-label="Silicon Mode home">
            <LogoMark size={26} />
            <span>Silicon Mode</span>
          </Link>
          <div className={styles.topRight}>{right ?? <ThemeToggle />}</div>
        </div>
      </header>
      <main className={`page ${styles.main} enter`}>{children}</main>
    </div>
  );
}

function SignIn() {
  return (
    <div className={styles.center}>
      <div className={styles.signIn}>
        <div className={styles.signInMark}>
          <LogoMark size={56} />
        </div>
        <h1>Sign in to Silicon Mode</h1>
        <p>See each Mac&apos;s status, follow your agents live and answer their questions — from any browser.</p>
        <Button size="lg" onClick={() => { location.href = signInUrl(); }} className={styles.signInButton}>
          <LogIn size={16} strokeWidth={2} aria-hidden="true" /> Continue with Silicon Accounts
        </Button>
        <div className={styles.signInLinks}>
          <Link href="/app?demo" onClick={(e) => { e.preventDefault(); location.href = "/app?demo"; }}>
            <FlaskConical size={14} strokeWidth={2} aria-hidden="true" /> Preview with sample data
          </Link>
          <Link href="/download">
            <Download size={14} strokeWidth={2} aria-hidden="true" /> Get the Mac app
          </Link>
        </div>
      </div>
    </div>
  );
}

function Signed({ source, user, onSignedOut }: { source: Source; user: CellUser | null; onSignedOut: () => void }) {
  const dash = useDashboard(source, onSignedOut);
  const { state } = dash;
  const theme = useTheme();
  const [days, setDays] = useState(35);
  const [scope, setScope] = useState<"all" | "this">("all");
  const devices = Object.values(state.devices).sort((a, b) => a.name.localeCompare(b.name));
  const device = state.selected ? state.devices[state.selected] : undefined;
  const heat = useHeatmap(source, days, scope === "this" ? state.selected : null, !dash.loading);
  const now = useNow(30_000);
  const sessions = Object.values(state.sessions);

  const doSignOut = useCallback(async () => {
    await signOut();
    onSignedOut();
  }, [onSignedOut]);

  const right = source === "demo" ? (
    <>
      <span className={styles.demoPill}><FlaskConical size={12} strokeWidth={2.2} aria-hidden="true" /> Sample data</span>
      <ThemeToggle />
      <ButtonLink href="/app" size="sm" variant="primary" onClick={(e) => { e.preventDefault(); location.href = "/app"; }}>Sign in</ButtonLink>
    </>
  ) : user ? (
    <UserMenu
      user={{ name: user.display_name || user.id, email: user.id, avatarSrc: user.pfp_url || undefined }}
      showTheme
      theme={theme.preference}
      onThemeChange={(t) => theme.setPreference(t)}
      onSignOut={doSignOut}
      align="end"
    />
  ) : null;

  return (
    <Shell right={right}>
      {dash.error && (
        <div className={styles.banner} role="alert">
          <span>{dash.error}</span>
          <Button size="xs" variant="secondary" onClick={dash.retry}>Retry</Button>
        </div>
      )}

      {dash.loading ? (
        <div className={styles.loading} aria-busy="true"><span className={styles.spinner} />Loading your Macs…</div>
      ) : devices.length === 0 ? (
        <div className={styles.center}>
          <EmptyState
            title="No Macs yet"
            description="Install Silicon Mode on your Mac and sign in from its menu bar. It shows up here within seconds — each Mac on its own."
            action={<ButtonLink href="/download" variant="primary"><Download size={15} /> Download for Mac</ButtonLink>}
          />
        </div>
      ) : (
        <>
          {devices.length > 1 && (
            <div className={styles.switcher}>
              <span className={styles.switcherLabel}>Your Macs</span>
              <SegmentedControl
                label="Choose a Mac"
                value={state.selected ?? ""}
                onValueChange={dash.select}
                options={devices.map((d) => ({
                  value: d.id,
                  label: d.name,
                  accessory: <i className={styles.switchDot} data-online={isOnline(state.statuses[d.id], d, now) ? "" : undefined} data-mode={state.statuses[d.id]?.mode ?? "off"} aria-hidden="true" />,
                }))}
              />
            </div>
          )}

          {device && (
            <div className={styles.grid}>
              <div className={styles.colMain}>
                <div className={styles.deviceHead}>
                  <h1>{device.name}</h1>
                  <span>
                    {[device.model, device.os_version && `macOS ${device.os_version}`, device.app_version && `Silicon Mode ${device.app_version}`].filter(Boolean).join(" · ")}
                  </span>
                </div>
                <StatusCard device={device} status={state.statuses[device.id]} counts={countsOf(state)} sessions={sessions} />
                <Questions state={state} onAnswer={dash.answer} onDismiss={dash.dismiss} />
                <AgentsList sessions={sessions} events={state.events} />
              </div>
              <div className={styles.colSide}>
                <TailLog events={state.events} sessions={state.sessions} fresh={state.fresh} live={dash.live} onSettle={dash.settle} />
              </div>
            </div>
          )}
        </>
      )}

      {!dash.loading && (
        <Heatmap
          rows={heat.rows}
          days={days}
          onDays={setDays}
          scope={scope}
          onScope={setScope}
          canScope={devices.length > 1}
          loading={heat.loading}
        />
      )}
    </Shell>
  );
}
