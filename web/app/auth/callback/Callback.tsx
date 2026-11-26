"use client";
// Web sign-in completion. Token mode: the cell put the session in the fragment; consume it before
// anything else runs, strip it from history, store it, go to /app. Cookie mode: the cell already set
// its HttpOnly cookies; confirm they stick (some browsers refuse them) and otherwise fall back to
// token mode once, automatically.
import { useEffect, useState } from "react";
import Link from "next/link";
import { Button } from "@teamofsilicons/silicon-ui/button";
import { LogoMark } from "@/components/Logo";
import { chooseMode, forceMode, getCell, restoreUser, signInUrl } from "@/lib/cell";
import styles from "./callback.module.css";

const RETRY_KEY = "sm.cb.retry";

export function Callback() {
  const [message, setMessage] = useState("Signing you in…");
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    const url = new URL(location.href);
    const fragment = new URLSearchParams(url.hash.slice(1));
    const error = url.searchParams.get("error") ?? fragment.get("error");
    if (error) {
      history.replaceState(null, "", url.pathname);
      setFailed(true);
      setMessage(error === "access_denied" ? "Sign-in was cancelled." : "Sign-in didn't complete.");
      return;
    }

    (async () => {
      try {
        if (fragment.has("access_token")) {
          // Tokens in the fragment mean the cell used token mode for this sign-in.
          if (chooseMode() !== "token") forceMode("token");
          const user = await getCell().consumeCallback();
          if (!user) throw new Error("incomplete");
        } else {
          const user = await restoreUser();
          if (!user) {
            // Cookie mode didn't stick here (third-party cookie rules, privacy settings): retry once with tokens.
            if (sessionStorage.getItem(RETRY_KEY) !== "1") {
              sessionStorage.setItem(RETRY_KEY, "1");
              forceMode("token");
              location.replace(signInUrl());
              return;
            }
            throw new Error("no-session");
          }
        }
        sessionStorage.removeItem(RETRY_KEY);
        location.replace("/app");
      } catch {
        history.replaceState(null, "", url.pathname);
        setFailed(true);
        setMessage("We couldn't finish signing you in.");
      }
    })();
  }, []);

  return (
    <main className={styles.main}>
      <LogoMark size={52} />
      <h1>{message}</h1>
      {failed ? (
        <div className={styles.actions}>
          <Button onClick={() => { sessionStorage.removeItem(RETRY_KEY); location.href = signInUrl(); }}>Try again</Button>
          <Link href="/" className={styles.link}>Back to Silicon Mode</Link>
        </div>
      ) : (
        <span className={styles.spinner} aria-hidden="true" />
      )}
    </main>
  );
}
