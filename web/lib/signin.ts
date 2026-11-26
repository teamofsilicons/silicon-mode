// Login-CSRF guard for /auth/callback. The cell's last redirect carries no client state (redirect_to
// must equal an allow-listed URL exactly), so on its own the callback can't tell a sign-in this
// browser asked for from a link like /auth/callback#access_token=<someone else's>…, which would sign
// the browser into that account and switch it to token mode. So every sign-in this site starts leaves
// a short-lived, single-use marker, and the callback accepts a session only when it finds one.
//
// The marker lives in localStorage rather than sessionStorage so that a sign-in finishing in another
// tab (an emailed sign-in link, say) still works. It still only opens a narrow window: the sign-in
// must have started in this browser less than 10 minutes ago and not finished yet.

export type SignInMode = "cookie" | "token";

type Store = Pick<Storage, "getItem" | "setItem" | "removeItem">;

export const PENDING_SIGN_IN_KEY = "sm.cb.pending";
/** As long as the cell's own sign-in flow cookie (`__Host-cells-flow`) lives. */
export const PENDING_SIGN_IN_TTL_MS = 10 * 60_000;

/** Notes that this browser is starting a sign-in that asked the cell for `mode`. */
export function markSignIn(store: Store | null, mode: SignInMode, now = Date.now()): void {
  try {
    store?.setItem(PENDING_SIGN_IN_KEY, JSON.stringify({ at: now, mode }));
  } catch {
    // Storage refused: the callback will treat the sign-in as unrecognised and offer to try again.
  }
}

/**
 * Reads and clears the marker. Returns the session mode a sign-in started here within the last
 * 10 minutes asked for, or null when there is none (or it is stale or malformed).
 */
export function takeSignIn(store: Store | null, now = Date.now()): SignInMode | null {
  let raw: string | null;
  try {
    raw = store?.getItem(PENDING_SIGN_IN_KEY) ?? null;
    store?.removeItem(PENDING_SIGN_IN_KEY);
  } catch {
    return null;
  }
  if (!raw) return null;
  try {
    const p = JSON.parse(raw) as { at?: unknown; mode?: unknown };
    if (typeof p?.at !== "number" || (p.mode !== "cookie" && p.mode !== "token")) return null;
    const age = now - p.at;
    return age >= 0 && age <= PENDING_SIGN_IN_TTL_MS ? p.mode : null;
  } catch {
    return null;
  }
}
