"use client";
import { useEffect, useRef, useState, type CSSProperties, type ReactNode } from "react";

/** Marks itself data-inview once it scrolls into view, so CSS can start one-shot or looping motion only then. */
export function InView({ children, className, style, as: Tag = "div", once = false }: {
  children: ReactNode;
  className?: string;
  style?: CSSProperties;
  as?: "div" | "section" | "article" | "li" | "figure";
  once?: boolean;
}) {
  const ref = useRef<HTMLElement>(null);
  const [inView, setInView] = useState(false);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const io = new IntersectionObserver(([e]) => {
      if (e.isIntersecting) {
        setInView(true);
        if (once) io.disconnect();
      } else if (!once) {
        setInView(false);
      }
    }, { threshold: 0.2 });
    io.observe(el);
    return () => io.disconnect();
  }, [once]);
  const Any = Tag as "div";
  return (
    <Any ref={ref as React.RefObject<HTMLDivElement>} className={className} style={style} data-inview={inView ? "" : undefined}>
      {children}
    </Any>
  );
}
