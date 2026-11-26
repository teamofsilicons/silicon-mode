import type { Metadata } from "next";
import Link from "next/link";
import { ArrowRight, Check } from "lucide-react";
import { ButtonLink } from "@teamofsilicons/silicon-ui/button-link";
import { SiteHeader } from "@/components/SiteHeader";
import { SiteFooter } from "@/components/SiteFooter";
import { LogoMark } from "@/components/Logo";
import styles from "./download.module.css";

export const metadata: Metadata = {
  title: "Download for Mac",
  description: "Silicon Mode for macOS — the notarized build is on its way.",
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
        <span className={styles.badge}>Coming soon</span>
        <h1>The notarized Mac build is on its way.</h1>
        <p className={styles.lede}>
          We&apos;re signing and notarizing Silicon Mode with Apple so it opens without warnings. It will be a small,
          free download that lives in your menu bar.
        </p>
        <ul className={styles.reqs}>
          <li><Check size={15} strokeWidth={2.4} aria-hidden="true" /> macOS 26 or later</li>
          <li><Check size={15} strokeWidth={2.4} aria-hidden="true" /> A MacBook with a lid-angle sensor (Apple silicon)</li>
          <li><Check size={15} strokeWidth={2.4} aria-hidden="true" /> Works without an account — sign in only for phone, web and community faces</li>
        </ul>
        <div className={styles.ctas}>
          <ButtonLink href="/app?demo" variant="primary" as={Link}>
            Try the dashboard with sample data <ArrowRight size={15} strokeWidth={2} aria-hidden="true" />
          </ButtonLink>
          <ButtonLink href="/" variant="ghost" as={Link}>
            Back to Silicon Mode
          </ButtonLink>
        </div>
      </main>
      <SiteFooter />
    </>
  );
}
