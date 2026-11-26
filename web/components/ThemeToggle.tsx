"use client";
import { Moon, Sun } from "lucide-react";
import { Button } from "@teamofsilicons/silicon-ui/button";
import { useTheme } from "@/lib/theme";

export function ThemeToggle() {
  const { resolved, setPreference } = useTheme();
  const next = resolved === "dark" ? "light" : "dark";
  return (
    <Button variant="ghost" size="sm" aria-label={`Switch to ${next} theme`} onClick={() => setPreference(next)} style={{ width: 36, paddingInline: 0 }}>
      {resolved === "dark" ? <Sun size={16} strokeWidth={1.8} /> : <Moon size={16} strokeWidth={1.8} />}
    </Button>
  );
}
