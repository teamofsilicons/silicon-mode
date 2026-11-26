// Canvas renderings of the five built-in Silicon Mode faces (the Mac's FaceRegistry:
// bounce, orbit, chomp, clock, desk). Every frame is a pure function of time `t` (seconds), so
// a face can be paused, scrubbed, or drawn once for reduced motion.

export type FaceId = "bounce" | "orbit" | "chomp" | "clock" | "desk";

export interface FaceAgent {
  color: string;
  mono: string;
  state: "working" | "waiting" | "finished" | "idle";
}

export interface FaceScene {
  agents: FaceAgent[];
  /** Shown under the face: "2 working · 1 needs you". */
  status?: string;
  /** Wall-clock time to show (ms since epoch). */
  now: number;
  font: string;
  /** 0–1, for the entry bloom. */
  intro?: number;
}

export const FACES: { id: FaceId; name: string; summary: string }[] = [
  { id: "bounce", name: "Bounce", summary: "Agents drift and ricochet off the edges of your screen." },
  { id: "orbit", name: "Orbit", summary: "Your agents orbit a glowing core; the busier, the faster." },
  { id: "chomp", name: "Chomp", summary: "A hungry little chip eats through every event your agents emit." },
  { id: "clock", name: "Clock", summary: "A big, calm clock with your agents' pulse underneath." },
  { id: "desk", name: "Desk", summary: "Silly the silicon mascot works away at a desk full of screens." },
];

const NIGHT = "#0b0b0d";
const LAV = "#cbbaeb";
const PEACH = "#edcaa3";
const TEXT = "#f2f2f2";
const MUTED = "rgba(242,242,242,0.46)";
const AMBER = "#e3b55a";

function glow(ctx: CanvasRenderingContext2D, x: number, y: number, r: number, a: number) {
  const g = ctx.createRadialGradient(x, y, 0, x, y, r);
  g.addColorStop(0, `rgba(203,186,235,${0.34 * a})`);
  g.addColorStop(0.45, `rgba(237,202,163,${0.12 * a})`);
  g.addColorStop(1, "rgba(237,202,163,0)");
  ctx.fillStyle = g;
  ctx.fillRect(x - r, y - r, r * 2, r * 2);
}

function background(ctx: CanvasRenderingContext2D, w: number, h: number) {
  ctx.fillStyle = NIGHT;
  ctx.fillRect(0, 0, w, h);
}

function timeText(now: number): string {
  const d = new Date(now);
  return `${d.getHours()}:${String(d.getMinutes()).padStart(2, "0")}`;
}

function mark(ctx: CanvasRenderingContext2D, a: FaceAgent, x: number, y: number, size: number, font: string, t: number, round = 0.32) {
  const r = size * round;
  ctx.save();
  if (a.state === "waiting") {
    const p = (Math.sin(t * 4) + 1) / 2;
    ctx.strokeStyle = AMBER;
    ctx.globalAlpha = 0.35 + p * 0.5;
    ctx.lineWidth = Math.max(1, size * 0.06);
    roundRect(ctx, x - size / 2 - size * 0.14, y - size / 2 - size * 0.14, size * 1.28, size * 1.28, r * 1.3);
    ctx.stroke();
    ctx.globalAlpha = 1;
  }
  ctx.fillStyle = a.state === "finished" ? "rgba(255,255,255,0.14)" : a.color;
  roundRect(ctx, x - size / 2, y - size / 2, size, size, r);
  ctx.fill();
  ctx.fillStyle = a.state === "finished" ? "rgba(242,242,242,0.7)" : "#fff";
  ctx.font = `600 ${Math.round(size * (a.mono.length > 1 ? 0.36 : 0.46))}px ${font}`;
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.fillText(a.mono, x, y + size * 0.02);
  ctx.restore();
}

function roundRect(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, r: number) {
  const rr = Math.min(r, w / 2, h / 2);
  ctx.beginPath();
  ctx.moveTo(x + rr, y);
  ctx.arcTo(x + w, y, x + w, y + h, rr);
  ctx.arcTo(x + w, y + h, x, y + h, rr);
  ctx.arcTo(x, y + h, x, y, rr);
  ctx.arcTo(x, y, x + w, y, rr);
  ctx.closePath();
}

function statusLine(ctx: CanvasRenderingContext2D, w: number, h: number, s: FaceScene, scale: number) {
  if (!s.status) return;
  ctx.fillStyle = MUTED;
  ctx.font = `500 ${Math.round(11 * scale)}px ${s.font}`;
  ctx.textAlign = "center";
  ctx.textBaseline = "alphabetic";
  ctx.fillText(s.status, w / 2, h - 14 * scale);
}

function smallClock(ctx: CanvasRenderingContext2D, w: number, s: FaceScene, scale: number) {
  ctx.fillStyle = "rgba(242,242,242,0.82)";
  ctx.font = `500 ${Math.round(13 * scale)}px ${s.font}`;
  ctx.textAlign = "center";
  ctx.textBaseline = "alphabetic";
  ctx.fillText(timeText(s.now), w / 2, 24 * scale);
}

// ---- Orbit ----------------------------------------------------------------------------------
function orbit(ctx: CanvasRenderingContext2D, w: number, h: number, t: number, s: FaceScene) {
  background(ctx, w, h);
  const scale = Math.min(w, h * 1.6) / 420;
  const cx = w / 2;
  const cy = h * 0.5;
  const busy = s.agents.filter((a) => a.state === "working").length;
  glow(ctx, cx, cy, Math.min(w, h) * 0.75, 1);
  const pulse = 1 + Math.sin(t * 1.6) * 0.05;
  const core = 18 * scale * pulse;
  const g = ctx.createRadialGradient(cx - core * 0.3, cy - core * 0.4, core * 0.1, cx, cy, core);
  g.addColorStop(0, "#fff7ef");
  g.addColorStop(0.5, PEACH);
  g.addColorStop(1, LAV);
  ctx.fillStyle = g;
  ctx.beginPath();
  ctx.arc(cx, cy, core, 0, Math.PI * 2);
  ctx.fill();

  const rings = [0.24, 0.36, 0.48];
  ctx.lineWidth = 1;
  for (const r of rings) {
    ctx.strokeStyle = "rgba(255,255,255,0.07)";
    ctx.beginPath();
    ctx.ellipse(cx, cy, w * r, h * r * 0.62, 0, 0, Math.PI * 2);
    ctx.stroke();
  }
  const speed = 0.22 + busy * 0.07;
  s.agents.forEach((a, i) => {
    const ring = rings[i % rings.length];
    const dir = i % 2 === 0 ? 1 : -1;
    const ang = t * speed * dir * (1 + (i % 3) * 0.18) + (i * Math.PI * 2) / Math.max(1, s.agents.length) + i;
    const x = cx + Math.cos(ang) * w * ring;
    const y = cy + Math.sin(ang) * h * ring * 0.62;
    // A short comet tail.
    ctx.strokeStyle = a.state === "finished" ? "rgba(255,255,255,0.06)" : hexA(a.color, 0.28);
    ctx.lineWidth = 2 * scale;
    ctx.beginPath();
    for (let k = 0; k <= 10; k++) {
      const aa = ang - dir * k * 0.035;
      const px = cx + Math.cos(aa) * w * ring;
      const py = cy + Math.sin(aa) * h * ring * 0.62;
      if (k === 0) ctx.moveTo(px, py);
      else ctx.lineTo(px, py);
    }
    ctx.stroke();
    mark(ctx, a, x, y, 22 * scale, s.font, t);
  });
  smallClock(ctx, w, s, scale);
  statusLine(ctx, w, h, s, scale);
}

// ---- Bounce (DVD) ---------------------------------------------------------------------------
function tri(v: number, span: number) {
  const m = ((v % (2 * span)) + 2 * span) % (2 * span);
  return m < span ? m : 2 * span - m;
}

function bounce(ctx: CanvasRenderingContext2D, w: number, h: number, t: number, s: FaceScene) {
  background(ctx, w, h);
  const scale = Math.min(w, h * 1.6) / 420;
  glow(ctx, w * 0.5, h * 0.55, Math.max(w, h) * 0.7, 0.5);
  const size = 34 * scale;
  s.agents.forEach((a, i) => {
    const vx = (46 + i * 13) * scale;
    const vy = (37 + i * 9) * scale;
    const x = tri(t * vx + i * 97 * scale, w - size) + size / 2;
    const y = tri(t * vy + i * 61 * scale, h - size) + size / 2;
    for (let k = 4; k >= 1; k--) {
      const xt = tri((t - k * 0.06) * vx + i * 97 * scale, w - size) + size / 2;
      const yt = tri((t - k * 0.06) * vy + i * 61 * scale, h - size) + size / 2;
      ctx.globalAlpha = 0.05 * (5 - k);
      ctx.fillStyle = a.color;
      roundRect(ctx, xt - size / 2, yt - size / 2, size, size, size * 0.3);
      ctx.fill();
    }
    ctx.globalAlpha = 1;
    mark(ctx, a, x, y, size, s.font, t, 0.3);
  });
  ctx.fillStyle = "rgba(242,242,242,0.9)";
  ctx.font = `300 ${Math.round(40 * scale)}px ${s.font}`;
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.fillText(timeText(s.now), w / 2, h / 2);
  statusLine(ctx, w, h, s, scale);
}

// ---- Chomp ----------------------------------------------------------------------------------
function chomp(ctx: CanvasRenderingContext2D, w: number, h: number, t: number, s: FaceScene) {
  background(ctx, w, h);
  const scale = Math.min(w, h * 1.6) / 420;
  const y = h * 0.54;
  const gap = 26 * scale;
  const speed = 70 * scale;
  const span = w + gap * 4;
  const px = ((t * speed) % span) - gap * 2;
  glow(ctx, px, y, 120 * scale, 0.7);
  const colors = s.agents.length ? s.agents.map((a) => a.color) : [LAV, PEACH];
  // Dots ahead of the chip; behind it they have been eaten (and slowly grow back).
  for (let x = gap / 2, i = 0; x < w; x += gap, i++) {
    const behind = x < px;
    const since = behind ? (px - x) / speed : 99;
    const regrow = Math.min(1, Math.max(0, (since - 2.2) / 1.2));
    const a = behind ? regrow : 1;
    if (a <= 0) continue;
    const big = i % 7 === 3;
    ctx.globalAlpha = a;
    ctx.fillStyle = big ? AMBER : colors[i % colors.length];
    ctx.beginPath();
    ctx.arc(x, y, (big ? 5.5 : 3.2) * scale * (0.6 + 0.4 * a), 0, Math.PI * 2);
    ctx.fill();
  }
  ctx.globalAlpha = 1;
  const r = 26 * scale;
  const mouth = (Math.abs(Math.sin(t * 9)) * 0.32 + 0.04) * Math.PI;
  const g = ctx.createLinearGradient(px - r, y - r, px + r, y + r);
  g.addColorStop(0, LAV);
  g.addColorStop(1, PEACH);
  ctx.fillStyle = g;
  ctx.beginPath();
  ctx.moveTo(px, y);
  ctx.arc(px, y, r, mouth, Math.PI * 2 - mouth);
  ctx.closePath();
  ctx.fill();
  ctx.fillStyle = NIGHT;
  ctx.beginPath();
  ctx.arc(px + r * 0.1, y - r * 0.5, r * 0.12, 0, Math.PI * 2);
  ctx.fill();
  const eaten = Math.floor(t * speed / gap) + 1200;
  ctx.fillStyle = MUTED;
  ctx.font = `500 ${Math.round(11 * scale)}px ${s.font}`;
  ctx.textAlign = "left";
  ctx.fillText(`${eaten.toLocaleString("en-US")} events`, 16 * scale, 24 * scale);
  ctx.textAlign = "right";
  ctx.fillText(timeText(s.now), w - 16 * scale, 24 * scale);
  statusLine(ctx, w, h, s, scale);
}

// ---- Clock ----------------------------------------------------------------------------------
function clockFace(ctx: CanvasRenderingContext2D, w: number, h: number, t: number, s: FaceScene) {
  background(ctx, w, h);
  const scale = Math.min(w, h * 1.6) / 420;
  glow(ctx, w / 2, h * 0.42, Math.max(w, h) * 0.6, 0.55);
  const d = new Date(s.now);
  ctx.fillStyle = TEXT;
  ctx.font = `200 ${Math.round(84 * scale)}px ${s.font}`;
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.fillText(timeText(s.now), w / 2, h * 0.4);
  ctx.fillStyle = MUTED;
  ctx.font = `500 ${Math.round(12 * scale)}px ${s.font}`;
  ctx.fillText(d.toLocaleDateString("en-US", { weekday: "long", month: "long", day: "numeric" }), w / 2, h * 0.4 + 52 * scale);
  // The pulse: one line per agent, scrolling left.
  const base = h * 0.76;
  const agents = s.agents.length ? s.agents : [{ color: LAV, mono: "", state: "working" as const }];
  agents.forEach((a, i) => {
    const amp = (a.state === "working" ? 10 : a.state === "waiting" ? 6 : 2) * scale;
    ctx.strokeStyle = a.state === "finished" ? "rgba(255,255,255,0.12)" : hexA(a.color, 0.75);
    ctx.lineWidth = 1.6 * scale;
    ctx.beginPath();
    for (let x = w * 0.12; x <= w * 0.88; x += 3) {
      const u = x / (w * 0.1) + t * 2.2 + i * 1.3;
      const beat = Math.exp(-Math.pow(((u % 6) + 6) % 6 - 3, 2) * 3) * 1.6;
      const yy = base + i * 3 * scale - (Math.sin(u * 1.7) * 0.25 + beat) * amp;
      if (x === w * 0.12) ctx.moveTo(x, yy);
      else ctx.lineTo(x, yy);
    }
    ctx.stroke();
  });
  statusLine(ctx, w, h, s, scale);
}

// ---- Desk -----------------------------------------------------------------------------------
function desk(ctx: CanvasRenderingContext2D, w: number, h: number, t: number, s: FaceScene) {
  background(ctx, w, h);
  const scale = Math.min(w, h * 1.6) / 420;
  const floor = h * 0.72;
  glow(ctx, w / 2, floor - 60 * scale, 200 * scale, 0.8);
  // Desk
  ctx.fillStyle = "#1c1b20";
  roundRect(ctx, w * 0.14, floor, w * 0.72, 8 * scale, 3 * scale);
  ctx.fill();
  // Screens
  const screens = Math.max(2, Math.min(4, s.agents.length || 3));
  const sw = 74 * scale;
  const sh = 48 * scale;
  for (let i = 0; i < screens; i++) {
    const x = w / 2 + (i - (screens - 1) / 2) * (sw + 12 * scale) - sw / 2;
    const y = floor - sh - 46 * scale - (i % 2) * 6 * scale;
    const a = s.agents[i];
    ctx.fillStyle = "#16161a";
    roundRect(ctx, x, y, sw, sh, 5 * scale);
    ctx.fill();
    ctx.strokeStyle = a ? hexA(a.color, 0.55) : "rgba(255,255,255,0.12)";
    ctx.lineWidth = 1.2 * scale;
    ctx.stroke();
    // Code lines that type themselves.
    for (let l = 0; l < 4; l++) {
      const len = ((t * 0.9 + i * 0.37 + l * 0.21) % 1.3) / 1.3;
      const lw = (sw - 16 * scale) * (0.35 + ((l * 37 + i * 11) % 50) / 100) * Math.min(1, len * 1.6);
      ctx.fillStyle = a ? hexA(a.color, 0.7) : "rgba(255,255,255,0.3)";
      ctx.fillRect(x + 8 * scale + (l % 2) * 6 * scale, y + 9 * scale + l * 9 * scale, lw, 3 * scale);
    }
    ctx.fillStyle = "#1c1b20";
    ctx.fillRect(x + sw / 2 - 2 * scale, y + sh, 4 * scale, floor - y - sh);
  }
  // Silly: a soft silicon blob with blinking eyes and busy arms.
  const bx = w / 2;
  const by = floor + 30 * scale + Math.sin(t * 3) * 1.5 * scale;
  const br = 26 * scale;
  const g = ctx.createLinearGradient(bx - br, by - br, bx + br, by + br);
  g.addColorStop(0, LAV);
  g.addColorStop(1, PEACH);
  ctx.fillStyle = g;
  ctx.beginPath();
  ctx.ellipse(bx, by, br * 1.1, br, 0, Math.PI, 0);
  ctx.lineTo(bx + br * 1.1, by + br * 0.4);
  ctx.lineTo(bx - br * 1.1, by + br * 0.4);
  ctx.closePath();
  ctx.fill();
  // arms
  ctx.strokeStyle = PEACH;
  ctx.lineCap = "round";
  ctx.lineWidth = 5 * scale;
  for (const side of [-1, 1]) {
    const tap = Math.sin(t * 14 + (side > 0 ? 0 : Math.PI)) * 3 * scale;
    ctx.beginPath();
    ctx.moveTo(bx + side * br * 0.9, by - br * 0.1);
    ctx.lineTo(bx + side * br * 1.25, floor + 2 * scale + tap);
    ctx.stroke();
  }
  // eyes (looking up at the screens), blink every ~4 s
  const blink = (t % 4.2) < 0.12 ? 0.15 : 1;
  ctx.fillStyle = NIGHT;
  for (const side of [-1, 1]) {
    ctx.beginPath();
    ctx.ellipse(bx + side * 9 * scale, by - 12 * scale, 3.2 * scale, 4.2 * scale * blink, 0, 0, Math.PI * 2);
    ctx.fill();
  }
  smallClock(ctx, w, s, scale);
  statusLine(ctx, w, h, s, scale);
}

function hexA(hex: string, a: number): string {
  const v = hex.replace("#", "");
  const n = parseInt(v.length === 3 ? v.split("").map((c) => c + c).join("") : v, 16);
  return `rgba(${(n >> 16) & 255},${(n >> 8) & 255},${n & 255},${a})`;
}

const DRAW: Record<FaceId, (ctx: CanvasRenderingContext2D, w: number, h: number, t: number, s: FaceScene) => void> = {
  orbit, bounce, chomp, clock: clockFace, desk,
};

export function drawFace(id: FaceId, ctx: CanvasRenderingContext2D, w: number, h: number, t: number, scene: FaceScene) {
  (DRAW[id] ?? orbit)(ctx, w, h, t, scene);
}

export function isFaceId(id: string | null | undefined): id is FaceId {
  return id === "bounce" || id === "orbit" || id === "chomp" || id === "clock" || id === "desk";
}
