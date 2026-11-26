"use client";
import { useEffect, useRef } from "react";
import { drawFace, type FaceAgent, type FaceId } from "./draw";

export interface FaceCanvasProps {
  face: FaceId;
  agents: FaceAgent[];
  status?: string;
  className?: string;
  /** Frames per second while visible (gallery tiles use 30 to stay light). */
  fps?: number;
  /** Seconds offset so neighbouring tiles don't move in lockstep. */
  offset?: number;
  /** Stop animating (still draw the current frame). */
  paused?: boolean;
  label?: string;
}

/**
 * A face, drawn on a canvas only while it is on screen and the tab is visible. Reduced motion
 * draws a single, settled frame. The clock still updates once a minute.
 */
export function FaceCanvas({ face, agents, status, className, fps = 60, offset = 0, paused = false, label }: FaceCanvasProps) {
  const ref = useRef<HTMLCanvasElement>(null);
  const sceneRef = useRef({ agents, status, face, paused });
  sceneRef.current = { agents, status, face, paused };
  const wakeRef = useRef<() => void>(() => {});

  useEffect(() => {
    const canvas = ref.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    const reduce = matchMedia("(prefers-reduced-motion: reduce)");
    let w = 0;
    let h = 0;
    let visible = false;
    let raf = 0;
    let last = 0;
    let still = 0;
    const start = performance.now();
    const font = getComputedStyle(canvas).fontFamily || "system-ui, sans-serif";

    const resize = () => {
      const rect = canvas.getBoundingClientRect();
      const dpr = Math.min(2, window.devicePixelRatio || 1);
      w = Math.max(1, rect.width);
      h = Math.max(1, rect.height);
      canvas.width = Math.round(w * dpr);
      canvas.height = Math.round(h * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      paint(currentTime());
    };

    const currentTime = () => (reduce.matches ? 12 + offset : (performance.now() - start) / 1000 + offset);

    const paint = (t: number) => {
      const s = sceneRef.current;
      drawFace(s.face, ctx, w, h, t, { agents: s.agents, status: s.status, now: Date.now(), font });
    };

    const loop = (now: number) => {
      raf = 0;
      if (!visible || document.hidden) return;
      const s = sceneRef.current;
      if (reduce.matches || s.paused) {
        // One frame, then a slow refresh for the clock.
        paint(currentTime());
        still = window.setTimeout(() => { raf = requestAnimationFrame(loop); }, 30_000);
        return;
      }
      if (now - last >= 1000 / fps - 2) {
        last = now;
        paint(currentTime());
      }
      raf = requestAnimationFrame(loop);
    };

    const wake = () => {
      if (visible && !document.hidden) {
        window.clearTimeout(still);
        if (!raf) raf = requestAnimationFrame(loop);
      }
    };
    wakeRef.current = wake;

    const ro = new ResizeObserver(resize);
    ro.observe(canvas);
    const io = new IntersectionObserver(([entry]) => {
      visible = entry.isIntersecting;
      if (visible) wake();
    }, { rootMargin: "80px" });
    io.observe(canvas);
    const onVis = () => wake();
    document.addEventListener("visibilitychange", onVis);
    reduce.addEventListener("change", wake);
    resize();

    return () => {
      cancelAnimationFrame(raf);
      window.clearTimeout(still);
      ro.disconnect();
      io.disconnect();
      document.removeEventListener("visibilitychange", onVis);
      reduce.removeEventListener("change", wake);
    };
  }, [fps, offset]);

  // Resume (or settle) right away when paused flips or the face changes.
  useEffect(() => { wakeRef.current(); }, [paused, face]);

  return <canvas ref={ref} className={className} role="img" aria-label={label ?? `${face} face`} />;
}
