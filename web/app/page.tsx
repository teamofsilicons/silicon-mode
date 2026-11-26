import Link from "next/link";
import { ArrowRight, Download } from "lucide-react";
import { ButtonLink } from "@teamofsilicons/silicon-ui/button-link";
import { SiteHeader } from "@/components/SiteHeader";
import { SiteFooter } from "@/components/SiteFooter";
import { LaptopHero } from "@/components/landing/LaptopHero";
import { Steps } from "@/components/landing/Steps";
import { FacesGallery } from "@/components/landing/FacesGallery";
import { AgentsSection } from "@/components/landing/AgentsSection";
import { Anywhere } from "@/components/landing/Anywhere";
import { InView } from "@/components/landing/InView";
import styles from "./landing.module.css";

export default function Home() {
  return (
    <>
      <SiteHeader />
      <main>
        <section className={`page ${styles.hero}`}>
          <div className={`${styles.heroCopy} enter`}>
            <span className={styles.eyebrow}>
              <span className={styles.eyebrowDot} /> For Macs with agents running
            </span>
            <h1 className={styles.title}>
              Close the lid halfway.
              <br />
              <span className={styles.titleSoft}>Your agents keep working.</span>
            </h1>
            <p className={styles.lede}>
              Silicon Mode turns a half-closed MacBook into a calm, locked screen for your coding agents. It keeps the
              Mac awake, shows every agent as a living face, and lets you answer them from your phone or the web.
            </p>
            <div className={styles.ctas}>
              <ButtonLink href="/download" variant="primary" size="lg" as={Link}>
                <Download size={17} strokeWidth={2} aria-hidden="true" /> Download for Mac
              </ButtonLink>
              <ButtonLink href="/app" variant="secondary" size="lg" as={Link}>
                Sign in to the dashboard
              </ButtonLink>
            </div>
            <p className={styles.fine}>Free · macOS 26 · Apple silicon MacBooks</p>
          </div>
          <LaptopHero />
        </section>

        <section id="how" className={`page ${styles.section}`}>
          <header className={styles.sectionHead}>
            <span className={styles.kicker}>How it works</span>
            <h2>Tilt, count, bloom, lock.</h2>
            <p>No buttons to remember. The lid is the switch — and once you&apos;re away, only you can turn it off.</p>
          </header>
          <Steps />
        </section>

        <section id="faces" className={`page ${styles.section}`}>
          <header className={styles.sectionHead}>
            <span className={styles.kicker}>Faces</span>
            <h2>A screensaver that knows what your agents are doing.</h2>
            <p>Five faces to start, each one infinite and easy on the battery. Pick one per Mac, tune it, or bring your own.</p>
          </header>
          <FacesGallery />
        </section>

        <section id="agents" className={`page ${styles.section}`}>
          <header className={styles.sectionHead}>
            <span className={styles.kicker}>Agents</span>
            <h2>Every agent you run, at a glance.</h2>
          </header>
          <AgentsSection />
        </section>

        <section id="anywhere" className={`page ${styles.section}`}>
          <div className={styles.split}>
            <header className={`${styles.sectionHead} ${styles.left}`}>
              <span className={styles.kicker}>Phone &amp; web</span>
              <h2>Answer from anywhere.</h2>
              <p>
                When an agent asks for permission, the question reaches your phone and this website within a second or
                two. The first answer wins — answer on the Mac and everywhere else shows it as answered.
              </p>
              <ul className={styles.list}>
                <li>Live status for each Mac, kept separate</li>
                <li>The last events from every agent</li>
                <li>Questions with one-tap answers</li>
                <li>A 24-hour × day map of when your agents run</li>
              </ul>
              <div className={styles.ctas}>
                <ButtonLink href="/app" variant="primary" as={Link}>
                  Open the dashboard
                </ButtonLink>
                <ButtonLink href="/app?demo" variant="ghost" as={Link}>
                  Try it with sample data <ArrowRight size={15} strokeWidth={2} aria-hidden="true" />
                </ButtonLink>
              </div>
              <p className={styles.fine}>iPhone and Android apps are on the way. The web dashboard works today.</p>
            </header>
            <InView once>
              <Anywhere />
            </InView>
          </div>
        </section>

        <section className={`page ${styles.section}`}>
          <div className={styles.band}>
            <h2>Put your Mac in Silicon Mode.</h2>
            <p>Sign in with Silicon Accounts to use it on your phone and the web. Everything else works without an account.</p>
            <div className={styles.ctas}>
              <ButtonLink href="/download" variant="primary" size="lg" as={Link}>
                <Download size={17} strokeWidth={2} aria-hidden="true" /> Download for Mac
              </ButtonLink>
              <ButtonLink href="/app" variant="secondary" size="lg" as={Link}>
                Sign in
              </ButtonLink>
            </div>
          </div>
        </section>
      </main>
      <SiteFooter />
    </>
  );
}
