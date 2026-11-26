// Serves out/ the way Vercel will: cleanUrls (/app → app.html), the headers from vercel.json,
// and 404.html. Usage: node scripts/serve.mjs [port]   (default 5173, an allowed cell origin)
import { createServer } from "node:http";
import { readFile, stat } from "node:fs/promises";
import { dirname, extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";

const web = join(dirname(fileURLToPath(import.meta.url)), "..");
const root = join(web, "out");
const port = Number(process.argv[2] ?? process.env.PORT ?? 5173);
const config = JSON.parse(await readFile(join(web, "vercel.json"), "utf8"));

const TYPES = {
  ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8",
  ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".ico": "image/x-icon",
  ".woff2": "font/woff2", ".txt": "text/plain; charset=utf-8", ".webmanifest": "application/manifest+json",
};

/** path-to-regexp subset used in vercel.json: literal text, (regex groups) and :name(groups). */
export function sourceToRegExp(source) {
  let out = "";
  let depth = 0;
  for (let i = 0; i < source.length; i++) {
    const c = source[i];
    if (depth === 0 && c === ":") {
      const m = /^:[A-Za-z_]\w*/.exec(source.slice(i));
      if (m) {
        i += m[0].length - 1;
        if (source[i + 1] !== "(") out += "([^/]+)";
        continue;
      }
    }
    if (c === "(") depth++;
    if (c === ")") depth--;
    out += depth === 0 && c !== ")" && /[.*+?^${}|[\]\\]/.test(c) ? `\\${c}` : c;
  }
  return new RegExp(`^${out}$`);
}

const rules = (config.headers ?? []).map((r) => ({ re: sourceToRegExp(r.source), headers: r.headers }));

async function resolveFile(pathname) {
  const clean = normalize(decodeURIComponent(pathname)).replace(/^(\.\.[/\\])+/, "");
  const candidates = clean.endsWith("/")
    ? [join(root, clean, "index.html")]
    : [join(root, clean), join(root, `${clean}.html`), join(root, clean, "index.html")];
  for (const file of candidates) {
    if (!file.startsWith(root)) continue;
    const s = await stat(file).catch(() => null);
    if (s?.isFile()) return file;
  }
  return null;
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url ?? "/", "http://localhost");
  let pathname = url.pathname;
  if (config.cleanUrls && pathname.endsWith(".html")) {
    res.writeHead(308, { Location: pathname.replace(/(\/index)?\.html$/, "") || "/" });
    res.end();
    return;
  }
  if (pathname.length > 1 && pathname.endsWith("/")) pathname = pathname.slice(0, -1);
  const headers = {};
  for (const rule of rules) if (rule.re.test(pathname)) for (const h of rule.headers) headers[h.key] = h.value;
  // Local only: HSTS on http://localhost would be wrong.
  delete headers["Strict-Transport-Security"];
  let file = await resolveFile(pathname === "/" ? "/index.html" : pathname);
  let status = 200;
  if (!file) {
    file = join(root, "404.html");
    status = 404;
  }
  const body = await readFile(file);
  res.writeHead(status, { "Content-Type": TYPES[extname(file)] ?? "application/octet-stream", ...headers });
  res.end(body);
});

if (import.meta.url === `file://${process.argv[1]}`) {
  server.listen(port, "localhost", () => console.log(`serving out/ on http://localhost:${port}`));
}
