"use client";
// Light by default (like Silicon Accounts); dark when chosen, or "system" to follow the OS.
import { useCallback, useEffect, useState } from "react";
import { THEME_KEY as KEY } from "./theme-script.ts";

export type ThemePreference = "light" | "dark" | "system";

function readPreference(): ThemePreference {
  try {
    const v = localStorage.getItem(KEY);
    return v === "dark" || v === "system" ? v : "light";
  } catch {
    return "light";
  }
}

function apply(pref: ThemePreference) {
  const dark = pref === "dark" || (pref === "system" && matchMedia("(prefers-color-scheme: dark)").matches);
  document.documentElement.dataset.theme = dark ? "dark" : "light";
}

export function useTheme(): { preference: ThemePreference; resolved: "light" | "dark"; setPreference: (p: ThemePreference) => void } {
  const [preference, setPref] = useState<ThemePreference>("light");
  const [resolved, setResolved] = useState<"light" | "dark">("light");

  useEffect(() => {
    const p = readPreference();
    setPref(p);
    setResolved(document.documentElement.dataset.theme === "dark" ? "dark" : "light");
    const mq = matchMedia("(prefers-color-scheme: dark)");
    const onChange = () => {
      if (readPreference() === "system") {
        apply("system");
        setResolved(document.documentElement.dataset.theme === "dark" ? "dark" : "light");
      }
    };
    mq.addEventListener("change", onChange);
    return () => mq.removeEventListener("change", onChange);
  }, []);

  const setPreference = useCallback((p: ThemePreference) => {
    try {
      localStorage.setItem(KEY, p);
    } catch {
      // Private mode: still switch for this page.
    }
    apply(p);
    setPref(p);
    setResolved(document.documentElement.dataset.theme === "dark" ? "dark" : "light");
  }, []);

  return { preference, resolved, setPreference };
}
