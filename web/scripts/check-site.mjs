// Post-build checks on out/: every page is there, every Next page carries a CSP that matches its
// inline scripts, the sign-in bounce pages stay inert (no inline or third-party code) and forward
// to the app scheme, and vercel.json keeps /auth/* out of caches and referrers.
import { readFile, stat } from "node:fs/promises";
import { join, relative } from "node:path";
import { BOUNCE, META_CSP, OUT, htmlFiles, policyFor } from "./csp.mjs";

const problems = [];
const must = ["index.html", "app.html", "download.html", "404.html", "auth/callback.html", ...BOUNCE, "auth/bounce.js", "auth/bounce.css", "icon.svg", "fonts/AlloVariable.woff2"];
for (const f of must) if (!(await stat(join(OUT, f)).catch(() => null))) problems.push(`missing out/${f}`);

for (const file of await htmlFiles(OUT)) {
  const rel = relative(OUT, file);
  const html = await readFile(file, "utf8");
  if (/<script[^>]+src=["']https?:/i.test(html) || /<link[^>]+href=["']https?:\/\/(?!mode\.teamofsilicons\.com)[^"']*["'][^>]*rel=["']?stylesheet/i.test(html)) {
    problems.push(`${rel}: loads third-party code`);
  }
  if (BOUNCE.has(rel)) {
    if (/<script(?![^>]*\bsrc=)[^>]*>/i.test(html)) problems.push(`${rel}: has an inline script`);
    if (!html.includes('src="/auth/bounce.js"')) problems.push(`${rel}: doesn't load /auth/bounce.js`);
    if (!html.includes('id="open"')) problems.push(`${rel}: has no "Open Silicon Mode" fallback`);
    continue;
  }
  const meta = META_CSP.exec(html);
  if (!meta) problems.push(`${rel}: no CSP meta`);
  else if (meta[1] !== policyFor(html.replace(META_CSP, ""))) problems.push(`${rel}: CSP hashes are stale`);
}

const bounce = await readFile(join(OUT, "auth/bounce.js"), "utf8");
if (!bounce.includes('"ai.tos.mode://auth/callback"')) problems.push("bounce.js: wrong app scheme");
if (!bounce.includes("history.replaceState")) problems.push("bounce.js: tokens stay in history");

const vercel = JSON.parse(await readFile(new URL("../vercel.json", import.meta.url), "utf8"));
const auth = vercel.headers.filter((h) => h.source.startsWith("/auth/"));
for (const src of ["/auth/callback", "/auth/:page(mac|ios|android|app)"]) {
  const rule = auth.find((h) => h.source === src);
  const get = (k) => rule?.headers.find((h) => h.key === k)?.value;
  if (get("Cache-Control") !== "no-store") problems.push(`vercel.json: ${src} must be no-store`);
  if (get("Referrer-Policy") !== "no-referrer") problems.push(`vercel.json: ${src} must be no-referrer`);
  if (!get("Content-Security-Policy")?.includes("frame-ancestors 'none'")) problems.push(`vercel.json: ${src} needs a strict CSP`);
}

if (problems.length) {
  console.error(`check-site: ${problems.length} problem(s)\n  ${problems.join("\n  ")}`);
  process.exit(1);
}
console.log(`check-site: ok (${must.length} required files, bounce pages inert, CSP pinned)`);
