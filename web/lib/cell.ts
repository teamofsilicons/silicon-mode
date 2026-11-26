// The browser's Silicon Cell client.
//
// Session mode: on mode.teamofsilicons.com the cell (silicon-mode.cells.teamofsilicons.com) is
// same-site, so the cell's HttpOnly `__Host-cells-*` cookies work and no token ever touches JS
// ("cookie" mode, cells.md §2.3). Anywhere else — localhost, a preview host, or a browser that
// refuses the cookie — we use "token" mode, keeping the rotating session in localStorage.
// The callback page flips to token mode automatically if a cookie sign-in doesn't stick.
import { createClient, CellsError, type Cells, type Session } from "@teamofsilicons/cells";
import { APP_ID, CELL_URL, PUBLISHABLE_KEY } from "./config.ts";
import type { CellUser } from "./types.ts";

export type SessionMode = "cookie" | "token";

const SESSION_KEY = "sm.cell.session";
const MODE_KEY = "sm.cell.mode";

function storage(): Storage | null {
  try {
    return typeof window === "undefined" ? null : window.localStorage;
  } catch {
    return null;
  }
}

function readStoredSession(): Session | null {
  try {
    const raw = storage()?.getItem(SESSION_KEY);
    if (!raw) return null;
    const s = JSON.parse(raw) as Session;
    return s && typeof s.access_token === "string" && typeof s.refresh_token === "string" ? s : null;
  } catch {
    return null;
  }
}

export function chooseMode(): SessionMode {
  const forced = storage()?.getItem(MODE_KEY);
  if (forced === "cookie" || forced === "token") return forced;
  if (readStoredSession()) return "token";
  const host = typeof location === "undefined" ? "" : location.hostname;
  return host === "teamofsilicons.com" || host.endsWith(".teamofsilicons.com") ? "cookie" : "token";
}

let client: Cells | null = null;
let clientMode: SessionMode | null = null;

export function getCell(): Cells {
  const mode = chooseMode();
  if (client && clientMode === mode) return client;
  clientMode = mode;
  client = createClient(CELL_URL, {
    publishableKey: PUBLISHABLE_KEY,
    sessionMode: mode,
    session: mode === "token" ? readStoredSession() : null,
    onSessionChange: (session) => {
      if (mode !== "token") return;
      const s = storage();
      if (!s) return;
      if (session) s.setItem(SESSION_KEY, JSON.stringify(session));
      else s.removeItem(SESSION_KEY);
    },
  });
  return client;
}

export function sessionMode(): SessionMode {
  return clientMode ?? chooseMode();
}

/** Switches modes for this browser (used when cookies are refused). Drops the current client. */
export function forceMode(mode: SessionMode | null): void {
  const s = storage();
  if (mode) s?.setItem(MODE_KEY, mode);
  else s?.removeItem(MODE_KEY);
  client = null;
  clientMode = null;
}

export function callbackUrl(): string {
  return `${location.origin}/auth/callback`;
}

export function signInUrl(method?: "google" | "apple" | "email" | "phone" | "signup"): string {
  return getCell().signInUrl({ redirectTo: callbackUrl(), app: APP_ID, method });
}

export function isUnauthorized(error: unknown): boolean {
  return error instanceof CellsError && (error.status === 401 || error.status === 403);
}

/**
 * Restores the signed-in user, or null when signed out.
 * Cookie mode refreshes once up front: the client only learns the HttpOnly session's expiry from a
 * refresh, and without it every request would first re-check /auth/user.
 */
export async function restoreUser(): Promise<CellUser | null> {
  const cell = getCell();
  try {
    if (sessionMode() === "cookie") {
      const session = await cell.refresh();
      return session.user as CellUser;
    }
    if (!cell.getSession()) return null;
    return (await cell.user()) as CellUser;
  } catch (error) {
    if (isUnauthorized(error)) {
      if (sessionMode() === "token") await cell.setSession(null).catch(() => undefined);
      return null;
    }
    throw error;
  }
}

export async function signOut(): Promise<void> {
  const cell = getCell();
  try {
    await cell.signOut();
  } catch {
    // Already signed out server-side; clear locally either way.
  }
  if (sessionMode() === "token") await cell.setSession(null).catch(() => undefined);
  storage()?.removeItem(SESSION_KEY);
}

export { CellsError };
