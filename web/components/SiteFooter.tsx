import Link from "next/link";
import { LogoMark } from "./Logo";
import styles from "./SiteFooter.module.css";

export function SiteFooter() {
  return (
    <footer className={styles.footer}>
      <div className={`page ${styles.inner}`}>
        <div className={styles.brand}>
          <LogoMark size={22} />
          <span>Silicon Mode</span>
          <span className={styles.by}>by Team of Silicons</span>
        </div>
        <nav className={styles.links} aria-label="Footer">
          <Link href="/download">Download</Link>
          <Link href="/app">Dashboard</Link>
          <Link href="/app?demo">Live demo</Link>
          <a href="https://accounts.teamofsilicons.com" rel="noopener">Silicon Accounts</a>
        </nav>
      </div>
    </footer>
  );
}
