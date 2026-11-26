"use client";
import { useCallback, useEffect, useReducer, useRef, useState } from "react";
import { answerQuestion, loadDeviceSnapshot, loadDevices, loadHeatmap } from "@/lib/api";
import { getCell, isUnauthorized } from "@/lib/cell";
import { demoDevices, demoHeatmap, demoSnapshot, demoTick, DEMO_MAC } from "@/lib/demo";
import { LiveFeed, type LiveStatus } from "@/lib/realtime";
import { initialState, reducer, type DashboardState } from "@/lib/store";
import type { HeatmapRow } from "@/lib/types";

export type Source = "live" | "demo";

export interface Dashboard {
  state: DashboardState;
  live: LiveStatus | "demo";
  loading: boolean;
  error: string | null;
  select: (deviceId: string) => void;
  answer: (questionId: string, answer: { optionId?: string | null; text?: string | null }) => Promise<void>;
  dismiss: (questionId: string) => void;
  settle: (ids: string[]) => void;
  retry: () => void;
}

const DEVICE_KEY = "sm.device";

export function useDashboard(source: Source, onSignedOut: () => void): Dashboard {
  const [state, dispatch] = useReducer(reducer, initialState);
  const [live, setLive] = useState<LiveStatus | "demo">(source === "demo" ? "demo" : "connecting");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [attempt, setAttempt] = useState(0);
  /** This attempt's realtime socket. State, not a ref: the per-Mac effect has to re-run for each new one. */
  const [feed, setFeed] = useState<LiveFeed | null>(null);
  const [resync, setResync] = useState(0);
  const signedOutRef = useRef(onSignedOut);
  signedOutRef.current = onSignedOut;

  const fail = useCallback((e: unknown) => {
    if (isUnauthorized(e)) {
      signedOutRef.current();
      return;
    }
    setError(e instanceof Error ? e.message : "Something went wrong talking to Silicon Mode's servers.");
  }, []);

  // Devices + the realtime socket.
  useEffect(() => {
    if (source === "demo") {
      dispatch({ type: "devices", devices: demoDevices(Date.now()) });
      setLoading(false);
      return;
    }
    let cancelled = false;
    const cell = getCell();
    const liveFeed = new LiveFeed(cell, {
      onChange: (table, operation, row, old) => dispatch({ type: "change", table, operation, row, old }),
      onStatus: (s) => !cancelled && setLive(s),
      onResync: () => setResync((n) => n + 1),
    });
    setFeed(liveFeed);
    setError(null);
    (async () => {
      try {
        const devices = await loadDevices(cell);
        if (cancelled) return;
        let preferred: string | null = null;
        try {
          preferred = localStorage.getItem(DEVICE_KEY);
        } catch {
          // ignore
        }
        dispatch({ type: "devices", devices });
        if (preferred && devices.some((d) => d.id === preferred)) dispatch({ type: "select", deviceId: preferred });
        setLoading(false);
        void liveFeed.start();
      } catch (e) {
        if (!cancelled) {
          setLoading(false);
          fail(e);
        }
      }
    })();
    return () => {
      cancelled = true;
      liveFeed.stop();
    };
  }, [source, attempt, fail]);

  // Per-Mac subscriptions + snapshot whenever the selection changes, a new socket replaces the old
  // one (Retry: it starts without them, and nothing was listening in between), or history was trimmed.
  useEffect(() => {
    const id = state.selected;
    if (!id) return;
    if (source === "demo") {
      dispatch({ type: "snapshot", deviceId: id, ...demoSnapshot(id, Date.now()) });
      return;
    }
    if (!feed) return;
    feed.setDevice(id);
    const ctrl = new AbortController();
    dispatch({ type: "snapshotRequested", deviceId: id });
    loadDeviceSnapshot(getCell(), id, ctrl.signal)
      .then((snap) => {
        if (!ctrl.signal.aborted) dispatch({ type: "snapshot", deviceId: id, ...snap });
      })
      .catch((e) => {
        if (!ctrl.signal.aborted) fail(e);
      });
    return () => ctrl.abort();
  }, [state.selected, source, feed, resync, fail]);

  // A device list resync after cursor_expired.
  useEffect(() => {
    if (source !== "live" || resync === 0) return;
    loadDevices(getCell()).then((devices) => dispatch({ type: "devices", devices })).catch(fail);
  }, [resync, source, fail]);

  // Demo liveness: events trickle in, the lid breathes, and the Mac answers one question itself.
  useEffect(() => {
    if (source !== "demo") return;
    let step = 0;
    const id = window.setInterval(() => {
      if (document.hidden) return;
      const now = Date.now();
      const { event, lid } = demoTick(step++, now);
      dispatch({ type: "change", table: "events", operation: "INSERT", row: event as unknown as Record<string, unknown>, old: null });
      dispatch({ type: "change", table: "device_status", operation: "UPDATE", row: { device_id: DEMO_MAC, lid_angle: lid, updated_at: new Date(now).toISOString() }, old: null });
      if (step === 4) {
        dispatch({
          type: "change", table: "answers", operation: "INSERT", old: null,
          row: { id: "demo-mac-answer", question_id: "c0000000-0000-4000-8000-000000000002", device_id: DEMO_MAC, option_id: "keep", text: null, answered_from: "mac", answered_by: null, created_at: new Date(now).toISOString(), consumed_at: null, outcome: null },
        });
      }
    }, 3400);
    return () => window.clearInterval(id);
  }, [source]);

  const select = useCallback((deviceId: string) => {
    try {
      localStorage.setItem(DEVICE_KEY, deviceId);
    } catch {
      // ignore
    }
    dispatch({ type: "select", deviceId });
  }, []);

  const answer = useCallback(async (questionId: string, a: { optionId?: string | null; text?: string | null }) => {
    const optionId = a.optionId ?? null;
    const text = a.text?.trim() ? a.text.trim() : null;
    dispatch({ type: "local", questionId, local: { phase: "sending", optionId, text } });
    if (source === "demo") {
      await new Promise((r) => setTimeout(r, 650));
      const answerId = `demo-${questionId}`;
      dispatch({ type: "local", questionId, local: { phase: "sent", answerId, optionId, text } });
      setTimeout(() => {
        dispatch({
          type: "change", table: "answers", operation: "INSERT", old: null,
          row: { id: answerId, question_id: questionId, device_id: DEMO_MAC, option_id: optionId, text, answered_from: "web", answered_by: null, created_at: new Date().toISOString(), consumed_at: new Date().toISOString(), outcome: "applied" },
        });
      }, 1600);
      return;
    }
    try {
      const result = await answerQuestion(getCell(), questionId, { optionId, text });
      if (result.ok) dispatch({ type: "local", questionId, local: { phase: "sent", answerId: result.answer_id, optionId, text } });
      else dispatch({ type: "local", questionId, local: { phase: "lost", reason: result.reason } });
    } catch (e) {
      if (isUnauthorized(e)) {
        signedOutRef.current();
        return;
      }
      dispatch({ type: "local", questionId, local: { phase: "failed", message: e instanceof Error ? e.message : "Couldn't send that answer." } });
    }
  }, [source]);

  const dismiss = useCallback((questionId: string) => {
    dispatch({ type: "change", table: "questions", operation: "DELETE", row: null, old: { id: questionId, device_id: state.selected } });
    dispatch({ type: "local", questionId, local: null });
  }, [state.selected]);

  const settle = useCallback((ids: string[]) => dispatch({ type: "settle", ids }), []);
  const retry = useCallback(() => {
    setLoading(true);
    setAttempt((n) => n + 1);
  }, []);

  return { state, live, loading, error, select, answer, dismiss, settle, retry };
}

export function useHeatmap(source: Source, days: number, deviceId: string | null, enabled = true): { rows: HeatmapRow[]; loading: boolean } {
  const [rows, setRows] = useState<HeatmapRow[]>([]);
  const [loading, setLoading] = useState(true);
  useEffect(() => {
    if (!enabled) return;
    if (source === "demo") {
      setRows(demoHeatmap(days));
      setLoading(false);
      return;
    }
    let cancelled = false;
    const load = () => {
      loadHeatmap(getCell(), days, deviceId)
        .then((r) => {
          if (!cancelled) {
            setRows(r);
            setLoading(false);
          }
        })
        .catch(() => !cancelled && setLoading(false));
    };
    setLoading(true);
    load();
    // Usage buckets move once a minute at most; refresh every 5 minutes while visible.
    const id = window.setInterval(() => !document.hidden && load(), 5 * 60_000);
    return () => {
      cancelled = true;
      window.clearInterval(id);
    };
  }, [source, days, deviceId, enabled]);
  return { rows, loading };
}
