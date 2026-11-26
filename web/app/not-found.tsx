import Link from "next/link";
import { ButtonLink } from "@teamofsilicons/silicon-ui/button-link";
import { SiteHeader } from "@/components/SiteHeader";

export default function NotFound() {
  return (
    <>
      <SiteHeader links={false} />
      <main className="page enter" style={{ display: "grid", justifyItems: "center", gap: 16, paddingTop: 120, textAlign: "center" }}>
        <p style={{ font: "var(--caption)", color: "var(--text-muted)", textTransform: "uppercase" }}>404</p>
        <h1 style={{ font: "var(--display)", letterSpacing: "var(--display-tracking)" }}>This page is in Silicon Mode.</h1>
        <p style={{ color: "var(--text-secondary)" }}>It&apos;s locked, and we don&apos;t know the PIN either.</p>
        <ButtonLink href="/" variant="primary" as={Link}>Back home</ButtonLink>
      </main>
    </>
  );
}
