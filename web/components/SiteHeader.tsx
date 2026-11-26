import Link from "next/link";
import { ButtonLink } from "@teamofsilicons/silicon-ui/button-link";
import { Download } from "lucide-react";
import { Wordmark } from "./Logo";
import { ThemeToggle } from "./ThemeToggle";
import styles from "./SiteHeader.module.css";

export function SiteHeader({ links = true }: { links?: boolean }) {
  return (
    <header className={styles.header}>
      <div className={`page ${styles.bar}`}>
        <Link href="/" className={styles.brand} aria-label="Silicon Mode home">
          <Wordmark />
        </Link>
        {links && (
          <nav className={styles.nav} aria-label="Sections">
            <a href="/#how">How it works</a>
            <a href="/#faces">Faces</a>
            <a href="/#agents">Agents</a>
            <a href="/#anywhere">Phone &amp; web</a>
          </nav>
        )}
        <div className={styles.actions}>
          <ThemeToggle />
          <ButtonLink href="/app" variant="ghost" size="sm" as={Link}>
            Sign in
          </ButtonLink>
          <ButtonLink href="/download" variant="primary" size="sm" as={Link} className={styles.download}>
            <Download size={15} strokeWidth={2} aria-hidden="true" />
            <span className={styles.downloadLong}>Download for Mac</span>
            <span className={styles.downloadShort}>Download</span>
          </ButtonLink>
        </div>
      </div>
    </header>
  );
}
