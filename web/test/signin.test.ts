import { test } from "node:test";
import assert from "node:assert/strict";
import { markSignIn, PENDING_SIGN_IN_KEY, PENDING_SIGN_IN_TTL_MS, takeSignIn } from "../lib/signin.ts";

function memory(): Storage {
  const m = new Map<string, string>();
  return {
    get length() { return m.size; },
    clear: () => m.clear(),
    key: (i: number) => [...m.keys()][i] ?? null,
    getItem: (k: string) => m.get(k) ?? null,
    setItem: (k: string, v: string) => void m.set(k, String(v)),
    removeItem: (k: string) => void m.delete(k),
  };
}

const NOW = Date.parse("2026-11-26T12:00:00Z");

test("a sign-in started here is accepted once, with the mode it asked for", () => {
  const s = memory();
  markSignIn(s, "token", NOW);
  assert.equal(takeSignIn(s, NOW + 30_000), "token");
  assert.equal(takeSignIn(s, NOW + 31_000), null, "single use: a second callback (or a replayed link) gets nothing");
  markSignIn(s, "cookie", NOW);
  assert.equal(takeSignIn(s, NOW), "cookie");
});

test("a callback nobody here started is not recognised", () => {
  assert.equal(takeSignIn(memory(), NOW), null);
  assert.equal(takeSignIn(null, NOW), null);
});

test("stale, future-dated or malformed markers are refused and cleared", () => {
  const s = memory();
  markSignIn(s, "token", NOW);
  assert.equal(takeSignIn(s, NOW + PENDING_SIGN_IN_TTL_MS + 1), null);
  assert.equal(s.getItem(PENDING_SIGN_IN_KEY), null);

  markSignIn(s, "token", NOW + 60_000);
  assert.equal(takeSignIn(s, NOW), null);

  for (const raw of ["1764158400000", "{", JSON.stringify({ at: NOW, mode: "admin" }), JSON.stringify({ mode: "token" }), "null"]) {
    s.setItem(PENDING_SIGN_IN_KEY, raw);
    assert.equal(takeSignIn(s, NOW), null, raw);
    assert.equal(s.getItem(PENDING_SIGN_IN_KEY), null);
  }
});

test("storage that throws never lets a sign-in through", () => {
  const broken = {
    getItem: () => { throw new Error("denied"); },
    setItem: () => { throw new Error("denied"); },
    removeItem: () => { throw new Error("denied"); },
  };
  assert.doesNotThrow(() => markSignIn(broken, "token", NOW));
  assert.equal(takeSignIn(broken, NOW), null);
});
