import "@teamofsilicons/silicon-ui/styles.css";
import "./globals.css";
import type { Metadata, Viewport } from "next";
import localFont from "next/font/local";
import type { ReactNode } from "react";
import { SITE_URL } from "@/lib/config";
import { THEME_SCRIPT } from "@/lib/theme-script";

// Allo, exactly as Silicon Accounts ships it (accounts-1.0.1); Silicon UI's styles.css reads
// --font-allo and sets ROND 20 on every element.
const allo = localFont({
  src: [{ path: "./fonts/AlloVariable.woff2", weight: "100 900", style: "normal" }],
  variable: "--font-allo",
  display: "swap",
  preload: true,
});

const description =
  "Close your MacBook halfway and Silicon Mode keeps it awake, shows your running agents as a living face, and lets you answer them from anywhere.";

export const metadata: Metadata = {
  metadataBase: new URL(SITE_URL),
  title: { default: "Silicon Mode — for when your agents are working", template: "%s · Silicon Mode" },
  description,
  applicationName: "Silicon Mode",
  icons: { icon: [{ url: "/icon.svg", type: "image/svg+xml" }] },
  openGraph: { title: "Silicon Mode", description, url: SITE_URL, siteName: "Silicon Mode", type: "website" },
  twitter: { card: "summary", title: "Silicon Mode", description },
  robots: { index: true, follow: true },
};

export const viewport: Viewport = {
  themeColor: [
    { media: "(prefers-color-scheme: light)", color: "#fcfcfc" },
    { media: "(prefers-color-scheme: dark)", color: "#141414" },
  ],
  colorScheme: "light dark",
  width: "device-width",
  initialScale: 1,
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en" data-theme="light" data-corners="squircle" className={allo.variable} suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: THEME_SCRIPT }} />
      </head>
      <body>{children}</body>
    </html>
  );
}
