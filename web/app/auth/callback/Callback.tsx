"use client";
// Web sign-in completion. Token mode: the cell put the session in the fragment; consume it before
// anything else runs, strip it from history, store it, go to /app. Cookie mode: the cell already set
// its HttpOnly cookies; confirm they stick (some browsers refuse them) and otherwise fall back to
// token mode once, automatically.
//
// Only a sign-in this browser started can finish here (lib/signin.ts): without that check, a link to
// /auth/callback#access_token=… would sign the browser into whoever made the link.
import { useEffect, useRef, useState } from "react";
import Link from "next/link";
import { Button } from "@teamofsilicons/silicon-ui/button";
import { LogoMark } from "@/components/Logo";
import { chooseMode, forceMode, getCell, restoreUser, startSignIn, takePendingSignIn } from "@/lib/cell";
import styles from "./callback.module.css";

const RETRY_KEY = "sm.cb.retry";

export function Callback() {
  const [message, setMessage] = useState("Signing you in…");
  const [failed, setFailed] = useState(false);
  // React runs effects twice in development (StrictMode); the marker is single-use, so act once.
  const ran = useRef(false);

  useEffect(() => {
    if (ran.current) return;
    ran.current = true;
    const url = new URL(location.href);
    const fragment = new URLSearchParams(url.hash.slice(1));
    const pending = takePendingSignIn();
    const error = url.searchParams.get("error") ?? fragment.get("error");
    if (error) {
      history.replaceState(null, "", url.pathname);
      setFailed(true);
      setMessage(error === "access_denied" ? "Sign-in was cancelled." : "Sign-in didn't complete.");
      return;
    }

    if (!pending) {
      // Not a sign-in this browser started. Drop whatever came with the link, change nothing.
      history.replaceState(null, "", url.pathname);
      if (fragment.has("access_token")) {
        setFailed(true);
        setMessage("That sign-in link wasn't started here.");
      } else {
        // Nothing to finish (a reload, a bookmark): /app knows whether this browser is signed in.
        location.replace("/app");
      }
      return;
    }

    (async () => {
      try {
        if (fragment.has("access_token")) {
          // Tokens in the fragment only come back for a sign-in that asked for token mode.
          if (pending !== "token") throw new Error("unexpected-tokens");
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
              startSignIn({ replace: true });
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
          <Button onClick={() => { sessionStorage.removeItem(RETRY_KEY); startSignIn(); }}>Try again</Button>
          <Link href="/" className={styles.link}>Back to Silicon Mode</Link>
        </div>
      ) : (
        <span className={styles.spinner} aria-hidden="true" />
      )}
    </main>
  );
}
