// Copies the shared design assets into the web app. The font lives once, in shared/design/fonts:
// accounts-1.0.1/AlloVariable.woff2 is byte-for-byte what accounts.teamofsilicons.com serves, so the
// web app reads exactly like Silicon Accounts (Allo, ROND 20 via Silicon UI's styles.css).
//   app/fonts/AlloVariable.woff2     → next/font/local (preloaded, --font-allo)
//   public/fonts/AlloVariable.woff2  → the static sign-in bounce pages (no Next runtime there)
import { copyFile, mkdir, readFile, stat } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const web = join(dirname(fileURLToPath(import.meta.url)), "..");
const fonts = join(web, "..", "shared", "design", "fonts", "accounts-1.0.1");
const source = join(fonts, "AlloVariable.woff2");

const targets = [join(web, "app", "fonts", "AlloVariable.woff2"), join(web, "public", "fonts", "AlloVariable.woff2")];

const bytes = await readFile(source);
for (const target of targets) {
  await mkdir(dirname(target), { recursive: true });
  const current = await stat(target).catch(() => null);
  if (current && current.size === bytes.length) continue;
  await copyFile(source, target);
}
await copyFile(join(fonts, "OFL.txt"), join(web, "public", "fonts", "OFL.txt"));
console.log(`assets: Allo ${(bytes.length / 1024).toFixed(0)} KiB → app/fonts, public/fonts`);
