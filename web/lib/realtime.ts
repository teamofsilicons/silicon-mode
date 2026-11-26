// Live row changes for the dashboard (cells.md §5). One socket per tab:
//   devices, device_status       — every Mac of this user (RLS scopes them)
//   agent_sessions, events,      — only the selected Mac (device_id filter), so several Macs never mix
//   questions, answers
// The client resumes from saved cursors after a reconnect; we dedupe on event_id.
import type { Cells, Realtime, RealtimeMessage, Subscription } from "@teamofsilicons/cells";

export type LiveStatus = "connecting" | "live" | "reconnecting" | "offline";

export interface LiveHandlers {
  onChange: (table: string, operation: "INSERT" | "UPDATE" | "DELETE", row: Record<string, unknown> | null, old: Record<string, unknown> | null) => void;
  onStatus: (status: LiveStatus) => void;
  /** History was trimmed (cursor_expired): re-read through REST. */
  onResync: () => void;
}

const DEVICE_TABLES: { key: string; table: string; events?: Subscription["events"] }[] = [
  { key: "se", table: "agent_sessions" },
  { key: "ev", table: "events", events: ["INSERT"] },
  { key: "qu", table: "questions" },
  { key: "an", table: "answers" },
];

export class LiveFeed {
  #rt: Realtime;
  #device: string | null = null;
  #seen = new Set<string>();
  #order: string[] = [];
  #handlers: LiveHandlers;
  #stopped = false;

  constructor(cell: Cells, handlers: LiveHandlers) {
    this.#handlers = handlers;
    this.#rt = cell.realtime({
      reconnect: true,
      onMessage: (m) => this.#message(m),
      onError: () => handlers.onStatus("reconnecting"),
      onStatus: (s) => {
        if (this.#stopped) return;
        handlers.onStatus(s === "connected" ? "live" : s === "connecting" ? "connecting" : s === "disconnected" ? "reconnecting" : "offline");
      },
    });
    this.#rt.subscribe({ id: "devices", table: "devices" });
    this.#rt.subscribe({ id: "status", table: "device_status" });
  }

  async start(): Promise<void> {
    try {
      await this.#rt.connect();
    } catch {
      if (!this.#stopped) this.#handlers.onStatus("offline");
    }
  }

  /** Points the per-device subscriptions at another Mac. */
  setDevice(deviceId: string | null): void {
    const id = deviceId?.toLowerCase() ?? null;
    if (id === this.#device) return;
    if (this.#device) {
      for (const t of DEVICE_TABLES) this.#safe(() => this.#rt.unsubscribe(`${t.key}:${this.#device}`));
    }
    this.#device = id;
    if (!id) return;
    for (const t of DEVICE_TABLES) {
      this.#safe(() => this.#rt.subscribe({
        id: `${t.key}:${id}`,
        table: t.table,
        events: t.events,
        filters: [{ column: "device_id", op: "eq", value: id }],
      }));
    }
  }

  stop(): void {
    this.#stopped = true;
    this.#rt.close();
  }

  #safe(fn: () => void) {
    try {
      fn();
    } catch {
      // Not connected yet: the subscription map is replayed on "ready".
    }
  }

  #message(m: RealtimeMessage) {
    if (this.#stopped) return;
    if (m.type === "change") {
      if (this.#seen.has(m.event_id)) return;
      this.#seen.add(m.event_id);
      this.#order.push(m.event_id);
      if (this.#order.length > 4000) this.#seen.delete(this.#order.shift()!);
      this.#handlers.onChange(m.table, m.operation, (m.new as Record<string, unknown>) ?? null, (m.old as Record<string, unknown>) ?? null);
    } else if (m.type === "error" && m.code === "cursor_expired") {
      // The client dropped that subscription; put it back from "now" and re-read the snapshot.
      const id = m.id ?? "";
      const t = DEVICE_TABLES.find((x) => id.startsWith(`${x.key}:`));
      if (t && this.#device) {
        this.#safe(() => this.#rt.subscribe({ id, table: t.table, events: t.events, filters: [{ column: "device_id", op: "eq", value: this.#device }] }));
      } else if (id === "devices" || id === "status") {
        this.#safe(() => this.#rt.subscribe({ id, table: id === "devices" ? "devices" : "device_status" }));
      }
      this.#handlers.onResync();
    }
  }
}
