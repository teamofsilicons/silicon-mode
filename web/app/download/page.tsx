import type { Metadata } from "next";
import Link from "next/link";
import { ArrowRight, Check, Download } from "lucide-react";
import { ButtonLink } from "@teamofsilicons/silicon-ui/button-link";
import { SiteHeader } from "@/components/SiteHeader";
import { SiteFooter } from "@/components/SiteFooter";
import { LogoMark } from "@/components/Logo";
import styles from "./download.module.css";

// Filled in by the release (scripts/release-mac.sh → web/public/downloads/).
const VERSION = "0.1.2";
const FILE = `/downloads/SiliconMode-${VERSION}.dmg`;
const SHA256 = "e0f474892009b978f9ff1c38e0d64fe2c0bc5b0d6c8c5069c0dd66238905a996";
const SIZE = "13 MB";

export const metadata: Metadata = {
  title: "Download for Mac",
  description: "Download Silicon Mode for macOS — signed and notarized by Apple.",
};

export default function DownloadPage() {
  return (
    <>
      <SiteHeader links={false} />
      <main className={`page ${styles.main} enter`}>
        <div className={styles.icon}>
          <LogoMark size={88} />
          <span className={styles.ring} aria-hidden="true" />
        </div>
        <span className={styles.badge}>Version {VERSION}</span>
        <h1>Silicon Mode for Mac</h1>
        <p className={styles.lede}>
          Signed with Developer ID and notarized by Apple, so it opens without warnings. Drag it to Applications,
          open it, set your 6-digit PIN, and tilt your lid below 75° the next time your agents are working.
        </p>
        <ul className={styles.reqs}>
          <li><Check size={15} strokeWidth={2.4} aria-hidden="true" /> macOS 26 or later</li>
          <li><Check size={15} strokeWidth={2.4} aria-hidden="true" /> A MacBook with a lid-angle sensor (Apple silicon)</li>
          <li><Check size={15} strokeWidth={2.4} aria-hidden="true" /> Works without an account — sign in only for phone, web and community faces</li>
        </ul>
        <div className={styles.ctas}>
          <ButtonLink href={FILE} variant="primary" download>
            <Download size={15} strokeWidth={2} aria-hidden="true" /> Download Silicon Mode {VERSION} ({SIZE})
          </ButtonLink>
          <ButtonLink href="/app?demo" variant="ghost" as={Link}>
            Try the dashboard with sample data <ArrowRight size={15} strokeWidth={2} aria-hidden="true" />
          </ButtonLink>
          <ButtonLink href="/" variant="ghost" as={Link}>
            Back to Silicon Mode
          </ButtonLink>
        </div>
        <p className={styles.lede} style={{ fontSize: 12, marginTop: 24, wordBreak: "break-all" }}>
          SHA-256 <code>{SHA256}</code>
        </p>
      </main>
      <SiteFooter />
    </>
  );
}
