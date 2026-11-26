// Small, locale-stable formatters (fixed en-US so prerendered HTML and the client agree).

const SECOND = 1000;
const MINUTE = 60 * SECOND;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

export function ms(iso: string | null | undefined): number {
  if (!iso) return NaN;
  return Date.parse(iso);
}

/** "just now", "42s ago", "5m ago", "3h ago", "2d ago", then a short date. */
export function relativeTime(iso: string | null | undefined, now: number): string {
  const t = ms(iso);
  if (!Number.isFinite(t)) return "—";
  const d = Math.max(0, now - t);
  if (d < 5 * SECOND) return "just now";
  if (d < MINUTE) return `${Math.floor(d / SECOND)}s ago`;
  if (d < HOUR) return `${Math.floor(d / MINUTE)}m ago`;
  if (d < DAY) return `${Math.floor(d / HOUR)}h ago`;
  if (d < 7 * DAY) return `${Math.floor(d / DAY)}d ago`;
  return shortDate(new Date(t));
}

/** Compact duration: "45s", "12m", "2h 14m", "3d 4h". */
export function duration(seconds: number): string {
  const s = Math.max(0, Math.round(seconds));
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  const rm = m % 60;
  if (h < 24) return rm ? `${h}h ${rm}m` : `${h}h`;
  const d = Math.floor(h / 24);
  const rh = h % 24;
  return rh ? `${d}d ${rh}h` : `${d}d`;
}

/** A ticking clock for "in Silicon Mode for 1:02:33". */
export function clock(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const r = s % 60;
  const mm = String(m).padStart(h ? 2 : 1, "0");
  const ss = String(r).padStart(2, "0");
  return h ? `${h}:${mm}:${ss}` : `${mm}:${ss}`;
}

const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

export function shortDate(d: Date): string {
  return `${d.getDate()} ${MONTHS[d.getMonth()]}`;
}

/** "Mon 24 Nov" for a YYYY-MM-DD calendar day (no timezone shifts). */
export function dayLabel(date: string): string {
  const d = fromISODate(date);
  return `${WEEKDAYS[d.getUTCDay()]} ${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]}`;
}

export function monthDay(date: string): { day: number; month: string; weekday: string } {
  const d = fromISODate(date);
  return { day: d.getUTCDate(), month: MONTHS[d.getUTCMonth()], weekday: WEEKDAYS[d.getUTCDay()] };
}

/** "12a", "6a", "12p", "6p" */
export function hourLabel(h: number): string {
  const suffix = h < 12 ? "a" : "p";
  const v = h % 12 === 0 ? 12 : h % 12;
  return `${v}${suffix}`;
}

/** "9–10 pm" */
export function hourRange(h: number): string {
  const f = (x: number) => (x % 12 === 0 ? 12 : x % 12);
  const end = (h + 1) % 24;
  const ap = (x: number) => (x < 12 ? "am" : "pm");
  return ap(h) === ap(end) || end === 0 ? `${f(h)}–${f(end)} ${ap(h)}` : `${f(h)} ${ap(h)}–${f(end)} ${ap(end)}`;
}

/** Calendar day (YYYY-MM-DD) helpers; dates are anchored at UTC noon so DST never shifts them. */
export function fromISODate(date: string): Date {
  const [y, m, d] = date.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d, 12));
}

export function toISODate(d: Date): string {
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}-${String(d.getUTCDate()).padStart(2, "0")}`;
}

export function addDays(date: string, n: number): string {
  const d = fromISODate(date);
  d.setUTCDate(d.getUTCDate() + n);
  return toISODate(d);
}

/** Today in the viewer's local timezone. */
export function localToday(now: Date = new Date()): string {
  return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-${String(now.getDate()).padStart(2, "0")}`;
}

export function plural(n: number, one: string, other = `${one}s`): string {
  return `${n} ${n === 1 ? one : other}`;
}

/** Last path component of a cwd, for when a session has no project name. */
export function basename(path: string | null | undefined): string {
  if (!path) return "";
  const parts = path.replace(/\/+$/, "").split("/");
  return parts[parts.length - 1] ?? "";
}
