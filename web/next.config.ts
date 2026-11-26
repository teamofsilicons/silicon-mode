import { dirname } from "node:path";
import { fileURLToPath } from "node:url";
import type { NextConfig } from "next";

// A static export: every page is prerendered into out/, which Vercel serves with vercel.json
// (cleanUrls, security headers, no-store on /auth/*). scripts/csp.mjs then pins each page's inline
// scripts with a hash-based CSP. There is no server: the dashboard talks to the Silicon Cell directly.
const config: NextConfig = {
  output: "export",
  distDir: "out",
  trailingSlash: false,
  images: { unoptimized: true },
  devIndicators: false,
  poweredByHeader: false,
  reactStrictMode: true,
  turbopack: { root: dirname(fileURLToPath(import.meta.url)) },
};

export default config;
