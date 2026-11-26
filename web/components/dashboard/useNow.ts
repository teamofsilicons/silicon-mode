"use client";
import { useEffect, useState } from "react";

/** The current time, refreshed every `interval` ms while the tab is visible. */
export function useNow(interval = 1000): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    let id = 0;
    const start = () => {
      window.clearInterval(id);
      setNow(Date.now());
      id = window.setInterval(() => setNow(Date.now()), interval);
    };
    const onVis = () => (document.hidden ? window.clearInterval(id) : start());
    start();
    document.addEventListener("visibilitychange", onVis);
    return () => {
      window.clearInterval(id);
      document.removeEventListener("visibilitychange", onVis);
    };
  }, [interval]);
  return now;
}
