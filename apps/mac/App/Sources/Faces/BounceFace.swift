import SwiftUI
import simd
import SiliconModeKit

/// Bounce: DVD-screensaver energy, upgraded. Every agent is a glowing puck (provider mark, state
/// ring, title) ricocheting off the screen edges with elastic collisions between pucks. Land a
/// perfect corner and the screen celebrates with a burst of silicon-gradient sparks.
enum BounceFace {
    static let descriptor = FaceDescriptor(
        id: "bounce",
        name: "Bounce",
        summary: "Agents ricochet around your screen. Hit a perfect corner for a tiny celebration.",
        options: [
            FaceOptionSpec(key: "speed", label: "Speed", kind: .slider(min: 0.25, max: 3, step: 0.05, default: 1)),
            FaceOptionSpec(key: "trails", label: "Trails", kind: .toggle(default: true)),
            FaceOptionSpec(key: "titles", label: "Show titles", kind: .toggle(default: true)),
            FaceOptionSpec(key: "size", label: "Puck size", kind: .choice(options: [
                (id: "small", label: "Small"), (id: "medium", label: "Medium"), (id: "large", label: "Large"),
            ], default: "medium")),
        ],
        make: { ctx in AnyView(BounceFaceView(ctx: ctx)) }
    )
}

struct BounceFaceView: View {
    let ctx: FaceContext
    /// Snapshot items pin the animation clock here.
    var fixedTime: Double?

    @State private var world = BounceWorld()
    @State private var start = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let specs = BounceSpec.make(from: ctx)
        let titles = ctx.bool("titles", true) && !ctx.isPreview
        let sizeChoice = ctx.string("size", "medium")
        GeometryReader { geo in
            let size = geo.size
            let u = FaceA.unit(for: size)
            let radius = BounceWorld.radius(sizeChoice, unit: u, preview: ctx.isPreview, alone: specs.first?.isMark == true)
            ZStack {
                if ctx.showClock && !ctx.isPreview {
                    BounceClockWatermark(start: start, fixedTime: fixedTime, unit: u)
                }
                TimelineView(.animation(minimumInterval: ctx.isPreview ? 1 / 30 : ctx.frameInterval)) { tl in
                    let t = FaceA.elapsed(since: start, now: tl.date, fixed: fixedTime)
                    let symbolSpecs = world.sync(specs, t: t)
                    let config = BounceWorld.Config(
                        unit: u, radius: radius, speed: ctx.number("speed", 1),
                        trails: ctx.bool("trails", true) && !reduceMotion, titles: titles,
                        reduceMotion: reduceMotion, panicking: ctx.isPanicking, preview: ctx.isPreview)
                    Canvas { g, canvasSize in
                        world.advance(to: t, size: canvasSize, config: config, g: g)
                        world.draw(in: &g, size: canvasSize, t: t, config: config)
                    } symbols: {
                        ForEach(symbolSpecs) { s in
                            BouncePuckDisc(spec: s, radius: radius, unit: u).tag(s.id)
                            if titles { BouncePuckLabel(spec: s, unit: u).tag(BounceWorld.labelTag(s.id)) }
                        }
                    }
                }
            }
        }
        .background(Theme.Night.background)
        .overlay(FaceAPanicWash(active: ctx.isPanicking))
        .accessibilityElement()
        .accessibilityLabel("Bounce face: \(ctx.counts.running) agents running")
    }
}

/// One thing that bounces: an agent session, or the Silicon mark when nothing is running.
struct BounceSpec: Identifiable, Equatable {
    let id: String
    let provider: String
    let title: String
    let state: AgentState
    let isMark: Bool

    static let markID = "silicon-mark"

    static func make(from ctx: FaceContext) -> [BounceSpec] {
        let sessions = FaceA.visibleSessions(ctx.sessions, max: ctx.isPreview ? 6 : 12)
        if sessions.isEmpty {
            return [BounceSpec(id: markID, provider: "silicon", title: "No agents running", state: .idle, isMark: true)]
        }
        return sessions.map {
            BounceSpec(id: $0.id, provider: $0.provider, title: FaceA.title($0, max: 30), state: $0.state, isMark: false)
        }
    }
}

// MARK: - Simulation

/// Fixed-step (120 Hz) physics: pucks with elastic wall and pairwise collisions, plus a pooled
/// particle system for corner bursts. Deterministic for a given (specs, size, time), so
/// snapshots replay exactly.
final class BounceWorld {
    struct Config {
        var unit: CGFloat
        var radius: CGFloat
        var speed: Double
        var trails: Bool
        var titles: Bool
        var reduceMotion: Bool
        var panicking: Bool
        var preview: Bool
    }

    typealias V = SIMD2<Double>

    struct Puck {
        var spec: BounceSpec
        var p = V(0, 0)
        var v = V(0, 0)
        var placed = false
        var born: Double
        var dying: Double?
        var stateSince: Double
        // Box around the disc (+ label) in points: left/right/top/bottom extents from center.
        var ext = (l: 0.0, r: 0.0, t: 0.0, b: 0.0)
        // Squash on impact.
        var hitT = -10.0
        var hitN = V(1, 0)
        // Trail ring buffer.
        var trail = [V](repeating: V(0, 0), count: BounceWorld.trailCount)
        var trailHead = 0
        var trailLen = 0
        var trailT = -1.0
        var lastCorner = -10.0
    }

    struct Particle {
        var p = V(0, 0)
        var v = V(0, 0)
        var born = -100.0
        var life = 1.0
        var size = 2.0
        var hue = 0.0
        var sparkle = false
        var spin = 0.0
    }

    struct Ring { var p: V; var born: Double; var rgb: FaceA.RGB; var maxR: Double }
    struct Flourish { var p: V; var corner: V; var dir: V; var born: Double; var count: Int; var halfW: Double }

    static let trailCount = 30
    static let dt = 1.0 / 120

    private(set) var pucks: [Puck] = []
    private var particles = [Particle](repeating: Particle(), count: 360)
    private var particleHead = 0
    /// Sim time after which no particle is alive (skip the pool entirely when idle).
    private var particlesUntil = -1.0
    private var rings: [Ring] = []
    private var flourishes: [Flourish] = []
    private var corners = 0
    private var simT = 0.0
    private var started = false
    private var rng = FaceA.RNG(seed: 0x5111_C0DE)
    private var lastSize = CGSize.zero
    private var aimedFirst = false

    static func labelTag(_ id: String) -> String { "label:" + id }

    static func radius(_ choice: String, unit: CGFloat, preview: Bool, alone: Bool) -> CGFloat {
        let base: CGFloat = switch choice {
        case "small": 30
        case "large": 62
        default: 44
        }
        return base * unit * (preview ? 1.35 : 1) * (alone ? 1.35 : 1)
    }

    // MARK: Sync with sessions

    /// Registers new specs, updates states, starts exit animations. Returns every spec that still
    /// needs a symbol (alive + leaving).
    func sync(_ specs: [BounceSpec], t: Double) -> [BounceSpec] {
        if t + 1e-6 < simT { reset() }
        let ids = Set(specs.map(\.id))
        for i in pucks.indices where pucks[i].dying == nil && !ids.contains(pucks[i].spec.id) {
            pucks[i].dying = t
        }
        pucks.removeAll { p in p.dying.map { t - $0 > 0.6 } ?? false }
        for (k, s) in specs.enumerated() {
            if let i = pucks.firstIndex(where: { $0.spec.id == s.id && $0.dying == nil }) {
                if pucks[i].spec.state != s.state {
                    pucks[i].stateSince = t
                    if pucks[i].placed {
                        rings.append(Ring(p: pucks[i].p, born: t, rgb: FaceA.stateRGB(s.state), maxR: 3.2))
                        if s.state == .finished { emitSoftBurst(at: pucks[i].p, t: t) }
                    }
                }
                pucks[i].spec = s
            } else {
                // Staggered entrance for the first batch; immediate for later arrivals.
                let delay = started ? 0 : Double(k) * 0.09
                pucks.append(Puck(spec: s, born: (started ? t : simT) + delay, stateSince: -100))
            }
        }
        started = true
        if rings.count > 24 { rings.removeFirst(rings.count - 24) }
        return pucks.map(\.spec)
    }

    private func reset() {
        pucks = []; rings = []; flourishes = []; corners = 0; simT = 0; started = false; aimedFirst = false
        particles = [Particle](repeating: Particle(), count: particles.count); particleHead = 0; particlesUntil = -1
        rng = FaceA.RNG(seed: 0x5111_C0DE)
    }

    // MARK: Step

    func advance(to t: Double, size: CGSize, config c: Config, g: GraphicsContext) {
        // Box extents (label size is only known once its symbol is resolved).
        let r = Double(c.radius)
        for i in pucks.indices {
            var halfW = r, bottom = r
            if c.titles, let lab = g.resolveSymbol(id: Self.labelTag(pucks[i].spec.id)) {
                halfW = max(r, Double(lab.size.width) / 2)
                bottom = r + Double(c.unit) * 10 + Double(lab.size.height)
            }
            pucks[i].ext = (halfW, halfW, r * 1.18, bottom)
        }
        if size != lastSize { lastSize = size; for i in pucks.indices where pucks[i].placed { clamp(&pucks[i], size) } }
        for i in pucks.indices where !pucks[i].placed { place(i, size: size, config: c) }

        var steps = Int((t - simT) / Self.dt)
        if steps > 7200 { simT = t - 7200 * Self.dt; steps = 7200 }
        for _ in 0..<max(0, steps) {
            simT += Self.dt
            step(size: size, config: c)
        }
    }

    private func targetSpeed(_ s: BounceSpec, _ c: Config, t: Double) -> Double {
        var f: Double = switch s.state {
        case .working: 1.0
        case .needsYou: 0.42 * (0.8 + 0.2 * sin(t * 2 * .pi / 1.6))
        case .finished: 0.3
        case .idle: s.isMark ? 0.75 : 0.32
        case .error: 0.38
        }
        if c.panicking { f *= 2.4 }
        if c.reduceMotion { f *= 0.35 }
        return 118 * Double(c.unit) * (c.preview ? 1.25 : 1) * c.speed * f
    }

    private func bounds(_ q: Puck, _ size: CGSize) -> (minX: Double, maxX: Double, minY: Double, maxY: Double) {
        let m = 4.0
        let minX = m + q.ext.l, maxX = max(minX, Double(size.width) - m - q.ext.r)
        let minY = m + q.ext.t, maxY = max(minY, Double(size.height) - m - q.ext.b)
        return (minX, maxX, minY, maxY)
    }

    private func clamp(_ q: inout Puck, _ size: CGSize) {
        let b = bounds(q, size)
        q.p.x = min(max(q.p.x, b.minX), b.maxX)
        q.p.y = min(max(q.p.y, b.minY), b.maxY)
    }

    private func place(_ i: Int, size: CGSize, config c: Config) {
        var q = pucks[i]
        let b = bounds(q, size)
        let seed = FaceA.hash(q.spec.id)
        let speed = targetSpeed(q.spec, c, t: 0)
        let angle = Double.pi / 4 + (FaceA.unit(seed, 3) - 0.5) * 0.55
        let sx: Double = FaceA.unit(seed, 4) < 0.5 ? -1 : 1, sy: Double = FaceA.unit(seed, 5) < 0.5 ? -1 : 1
        q.v = V(cos(angle) * sx, sin(angle) * sy) * max(speed, 1)

        if !aimedFirst {
            // The first puck is aimed so it lands a perfect corner a few seconds in: a little
            // moment of delight right after Silicon Mode starts.
            aimedFirst = true
            let corner = V(sx > 0 ? b.maxX : b.minX, sy > 0 ? b.maxY : b.minY)
            var tau = 5.2
            let vx = abs(q.v.x), vy = abs(q.v.y)
            if vx > 0 { tau = min(tau, 0.92 * (b.maxX - b.minX) / vx) }
            if vy > 0 { tau = min(tau, 0.92 * (b.maxY - b.minY) / vy) }
            q.p = corner - q.v * tau
            q.p.x = min(max(q.p.x, b.minX), b.maxX); q.p.y = min(max(q.p.y, b.minY), b.maxY)
        } else {
            var best = V((b.minX + b.maxX) / 2, (b.minY + b.maxY) / 2), bestD = -1.0
            for k in 0..<10 {
                let cand = V(FaceA.lerp(b.minX, b.maxX, FaceA.unit(seed, 10 + UInt64(k))),
                             FaceA.lerp(b.minY, b.maxY, FaceA.unit(seed, 30 + UInt64(k))))
                var d = Double.greatestFiniteMagnitude
                for o in pucks where o.placed && o.dying == nil { d = min(d, simd_length(o.p - cand)) }
                if d > bestD { bestD = d; best = cand }
                if d > Double(c.radius) * 4 { break }
            }
            q.p = best
        }
        q.placed = true
        q.trailT = -1
        pucks[i] = q
    }

    private func step(size: CGSize, config c: Config) {
        let t = simT, dt = Self.dt
        let r = Double(c.radius)
        for i in pucks.indices where pucks[i].placed && pucks[i].dying == nil {
            var q = pucks[i]
            guard t >= q.born else { continue }
            // Ease speed toward the state's target, keep heading; avoid boring axis-locked paths.
            let target = targetSpeed(q.spec, c, t: t)
            var s = simd_length(q.v)
            if s < 1e-6 { q.v = V(0.7, 0.7); s = simd_length(q.v) }
            let ns = s + (target - s) * min(1, dt * 1.1)
            q.v = q.v / s * ns
            let minComp = 0.28 * ns
            if abs(q.v.x) < minComp { q.v.x = (q.v.x < 0 ? -1 : 1) * min(minComp, abs(q.v.x) + ns * dt * 0.6) }
            if abs(q.v.y) < minComp { q.v.y = (q.v.y < 0 ? -1 : 1) * min(minComp, abs(q.v.y) + ns * dt * 0.6) }

            q.p += q.v * dt
            let b = bounds(q, size)
            var hitX = 0.0, hitY = 0.0
            if q.p.x < b.minX { q.p.x = b.minX; q.v.x = abs(q.v.x); hitX = -1 }
            if q.p.x > b.maxX { q.p.x = b.maxX; q.v.x = -abs(q.v.x); hitX = 1 }
            if q.p.y < b.minY { q.p.y = b.minY; q.v.y = abs(q.v.y); hitY = -1 }
            if q.p.y > b.maxY { q.p.y = b.maxY; q.v.y = -abs(q.v.y); hitY = 1 }

            if hitX != 0 || hitY != 0 {
                q.hitT = t
                q.hitN = V(hitX != 0 ? 1 : 0, hitY != 0 && hitX == 0 ? 1 : 0)
                // Perfect corner: both walls at once, or the other wall within a hair.
                let tol = r * 0.42
                if hitX != 0 && hitY == 0 {
                    if q.p.y - b.minY < tol { hitY = -1 } else if b.maxY - q.p.y < tol { hitY = 1 }
                } else if hitY != 0 && hitX == 0 {
                    if q.p.x - b.minX < tol { hitX = -1 } else if b.maxX - q.p.x < tol { hitX = 1 }
                }
                if hitX != 0 && hitY != 0 && t - q.lastCorner > 1.0 {
                    q.lastCorner = t
                    q.p.x = hitX < 0 ? b.minX : b.maxX
                    q.p.y = hitY < 0 ? b.minY : b.maxY
                    q.v.x = -hitX * abs(q.v.x); q.v.y = -hitY * abs(q.v.y)
                    corners += 1
                    let cornerPt = V(hitX < 0 ? 0 : Double(size.width), hitY < 0 ? 0 : Double(size.height))
                    cornerHit(at: cornerPt, puck: q.p, halfW: max(q.ext.l, r), inward: V(-hitX, -hitY), t: t, config: c)
                }
            }
            // Trail samples at 30 Hz.
            if t - q.trailT >= 1.0 / 30 {
                q.trailT = t
                q.trailHead = (q.trailHead + 1) % Self.trailCount
                q.trail[q.trailHead] = q.p
                q.trailLen = min(q.trailLen + 1, Self.trailCount)
            }
            pucks[i] = q
        }

        // Pairwise elastic collisions (equal mass circles).
        let n = pucks.count
        if n > 1 {
            for i in 0..<(n - 1) {
                guard pucks[i].placed, pucks[i].dying == nil, t >= pucks[i].born else { continue }
                for j in (i + 1)..<n {
                    guard pucks[j].placed, pucks[j].dying == nil, t >= pucks[j].born else { continue }
                    if c.titles { collideBoxes(i, j, t: t); continue }
                    let d = pucks[j].p - pucks[i].p
                    let dist = simd_length(d)
                    let minD = r * 2.3
                    guard dist < minD, dist > 1e-6 else { continue }
                    let nrm = d / dist
                    let rel = simd_dot(pucks[i].v - pucks[j].v, nrm)
                    if rel > 0 {
                        pucks[i].v -= rel * nrm
                        pucks[j].v += rel * nrm
                        pucks[i].hitT = t; pucks[i].hitN = simd_abs(nrm)
                        pucks[j].hitT = t; pucks[j].hitN = simd_abs(nrm)
                    }
                    let push = (minD - dist) / 2
                    pucks[i].p -= nrm * push
                    pucks[j].p += nrm * push
                }
            }
        }

        // Particles: drag, no gravity (floating sparks).
        if t <= particlesUntil {
            let drag = exp(-2.1 * dt)
            for k in particles.indices where t - particles[k].born < particles[k].life {
                particles[k].p += particles[k].v * dt
                particles[k].v *= drag
            }
        }
        rings.removeAll { t - $0.born > 1.6 }
        flourishes.removeAll { t - $0.born > 2.4 }
    }

    /// Cards (disc + title pill) collide as boxes along the axis of least overlap, so titles
    /// never slide over other pucks. Equal masses: the normal velocity components swap.
    private func collideBoxes(_ i: Int, _ j: Int, t: Double) {
        let a = pucks[i], b = pucks[j]
        let ox = min(a.p.x + a.ext.r, b.p.x + b.ext.r) - max(a.p.x - a.ext.l, b.p.x - b.ext.l)
        let oy = min(a.p.y + a.ext.b, b.p.y + b.ext.b) - max(a.p.y - a.ext.t, b.p.y - b.ext.t)
        guard ox > 0, oy > 0 else { return }
        let gap = 1.0
        var impact = false
        if ox < oy {
            let n: Double = b.p.x >= a.p.x ? 1 : -1
            if (a.v.x - b.v.x) * n > 0 { pucks[i].v.x = b.v.x; pucks[j].v.x = a.v.x; impact = true }
            pucks[i].p.x -= n * (ox / 2 + gap); pucks[j].p.x += n * (ox / 2 + gap)
            if impact { pucks[i].hitN = V(1, 0); pucks[j].hitN = V(1, 0) }
        } else {
            let n: Double = b.p.y >= a.p.y ? 1 : -1
            if (a.v.y - b.v.y) * n > 0 { pucks[i].v.y = b.v.y; pucks[j].v.y = a.v.y; impact = true }
            pucks[i].p.y -= n * (oy / 2 + gap); pucks[j].p.y += n * (oy / 2 + gap)
            if impact { pucks[i].hitN = V(0, 1); pucks[j].hitN = V(0, 1) }
        }
        // Only a real impact squashes (not resting contact).
        if impact { pucks[i].hitT = t; pucks[j].hitT = t }
    }

    private func cornerHit(at corner: V, puck: V, halfW: Double, inward: V, t: Double, config c: Config) {
        let u = Double(c.unit)
        rings.append(Ring(p: corner, born: t, rgb: FaceA.lavender, maxR: 7))
        flourishes.append(Flourish(p: puck, corner: corner, dir: inward, born: t, count: corners, halfW: halfW))
        guard !c.reduceMotion else { return }
        let count = c.preview ? 40 : 110
        let base = atan2(inward.y, inward.x)
        for _ in 0..<count {
            let a = base + rng.range(-0.95, 0.95)
            let sp = rng.range(140, 720) * u * (c.preview ? 1.4 : 1)
            var p = Particle()
            p.p = corner + V(inward.x * rng.range(4, 26) * u, inward.y * rng.range(4, 26) * u)
            p.v = V(cos(a), sin(a)) * sp
            p.born = t
            p.life = rng.range(1.0, 2.4)
            p.size = rng.range(1.6, 5.0) * u * (c.preview ? 1.8 : 1)
            p.hue = rng.next()
            p.sparkle = rng.next() < 0.18
            p.spin = rng.range(-3, 3)
            particles[particleHead] = p
            particleHead = (particleHead + 1) % particles.count
            particlesUntil = max(particlesUntil, t + p.life)
        }
    }

    private func emitSoftBurst(at center: V, t: Double) {
        for k in 0..<16 {
            let a = Double(k) / 16 * 2 * .pi + rng.range(-0.2, 0.2)
            var p = Particle()
            p.p = center
            p.v = V(cos(a), sin(a)) * rng.range(60, 140)
            p.born = t; p.life = rng.range(0.8, 1.4); p.size = rng.range(1.2, 2.6)
            p.hue = -1   // marks "state green"
            particlesUntil = max(particlesUntil, t + p.life)
            particles[particleHead] = p
            particleHead = (particleHead + 1) % particles.count
        }
    }

    // MARK: Draw

    func draw(in g: inout GraphicsContext, size: CGSize, t: Double, config c: Config) {
        let u = Double(c.unit)
        let r = Double(c.radius)
        drawHaze(&g, size: size, t: t)

        // Trails (a soft tapered comet per puck, alpha by distance from the head).
        if c.trails {
            for q in pucks where q.placed && q.dying == nil && q.trailLen > 3 && t >= q.born {
                drawTrail(&g, q, r: r, t: t)
            }
        }

        // Glows + state rings (additive), under the discs.
        do {
            var layer = g
            layer.blendMode = .plusLighter
            for q in pucks where q.placed {
                let a = alpha(q, t)
                guard a > 0.01 else { continue }
                drawGlow(&layer, q, r: r, u: u, t: t, a: a, panic: c.panicking)
            }
        }

        // Discs and labels.
        for q in pucks where q.placed {
            let a = alpha(q, t)
            guard a > 0.01 else { continue }
            let pop = scale(q, t)
            let center = CGPoint(x: q.p.x, y: q.p.y)
            // Squash on impact along the hit normal.
            let age = t - q.hitT
            let sq = c.reduceMotion ? 0 : 0.085 * exp(-age * 14) * cos(age * 30)
            let sx = 1 - sq * q.hitN.x + sq * 0.5 * q.hitN.y
            let sy = 1 - sq * q.hitN.y + sq * 0.5 * q.hitN.x
            if c.titles, let lab = g.resolveSymbol(id: Self.labelTag(q.spec.id)) {
                var lc = g
                lc.opacity = a * FaceA.smoothstep(0.25, 0.7, pop)
                let y = q.p.y + r + u * 10 + Double(lab.size.height) / 2
                lc.draw(lab, at: CGPoint(x: q.p.x, y: y), anchor: .center)
            }
            if let sym = g.resolveSymbol(id: q.spec.id) {
                var dc = g
                dc.opacity = a
                dc.translateBy(x: center.x, y: center.y)
                dc.scaleBy(x: pop * sx, y: pop * sy)
                dc.draw(sym, at: .zero, anchor: .center)
            }
        }

        // Rings (corner shockwave, state changes), particles, flourishes.
        do {
            var layer = g
            layer.blendMode = .plusLighter
            for ring in rings {
                let p = FaceA.clamp((t - ring.born) / 1.4)
                let rr = r * (1 + ring.maxR * FaceA.easeOutCubic(p))
                let path = Path(ellipseIn: CGRect(x: ring.p.x - rr, y: ring.p.y - rr, width: rr * 2, height: rr * 2))
                layer.stroke(path, with: .color(ring.rgb.color(0.55 * pow(1 - p, 1.6))), lineWidth: max(1, 2.2 * u * (1 - p * 0.6)))
            }
            for k in particles.indices where t <= particlesUntil {
                let pt = particles[k]
                let age = t - pt.born
                guard age >= 0, age < pt.life else { continue }
                let f = age / pt.life
                let a = pow(1 - f, 1.4)
                let col: Color = pt.hue < 0 ? FaceA.green.color(a * 0.9) : FaceA.silicon(pt.hue, a)
                let s = pt.size * (1 - f * 0.55)
                if pt.sparkle {
                    let len = s * 3.2
                    let ang = pt.spin * age
                    var path = Path()
                    for k2 in 0..<2 {
                        let aa = ang + Double(k2) * .pi / 2
                        let dx = cos(aa) * len, dy = sin(aa) * len
                        path.move(to: CGPoint(x: pt.p.x - dx, y: pt.p.y - dy))
                        path.addLine(to: CGPoint(x: pt.p.x + dx, y: pt.p.y + dy))
                    }
                    layer.stroke(path, with: .color(col), style: StrokeStyle(lineWidth: max(0.8, s * 0.45), lineCap: .round))
                } else {
                    layer.fill(Path(ellipseIn: CGRect(x: pt.p.x - s, y: pt.p.y - s, width: s * 2, height: s * 2)), with: .color(col))
                }
            }
        }
        for fl in flourishes { drawFlourish(&g, fl, t: t, u: u, r: r, preview: c.preview) }
    }

    private func alpha(_ q: Puck, _ t: Double) -> Double {
        if let d = q.dying { return 1 - FaceA.smoothstep(0, 0.5, t - d) }
        return t < q.born ? 0 : 1
    }

    private func scale(_ q: Puck, _ t: Double) -> Double {
        if let d = q.dying { return 1 - 0.6 * FaceA.easeInCubic((t - d) / 0.5) }
        return max(0, FaceA.spring(t - q.born, response: 0.55, damping: 0.62))
    }

    private func drawHaze(_ g: inout GraphicsContext, size: CGSize, t: Double) {
        let w = size.width, h = size.height
        let c1 = CGPoint(x: w * (0.28 + 0.06 * sin(t / 23)), y: h * (0.3 + 0.08 * cos(t / 29)))
        let c2 = CGPoint(x: w * (0.74 + 0.05 * cos(t / 31)), y: h * (0.72 + 0.07 * sin(t / 27)))
        let rad = max(w, h) * 0.55
        g.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
            Gradient(colors: [FaceA.lavender.color(0.075), .clear]), center: c1, startRadius: 0, endRadius: rad))
        g.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
            Gradient(colors: [FaceA.peach.color(0.06), .clear]), center: c2, startRadius: 0, endRadius: rad))
    }

    private func drawTrail(_ g: inout GraphicsContext, _ q: Puck, r: Double, t: Double) {
        let n = q.trailLen
        var path = Path()
        var length = 0.0
        var prev = q.p
        path.move(to: CGPoint(x: q.p.x, y: q.p.y))
        // Three nested strokes (long+thin → short+wide) give a tapered comet with round joins,
        // so a fold at a bounce stays soft instead of turning into a shard.
        let cut1 = n / 3, cut2 = (n * 2) / 3
        var p1 = Path(), p2 = Path()
        for k in 0..<n {
            let pt = q.trail[(q.trailHead - k + Self.trailCount) % Self.trailCount]
            length += simd_length(pt - prev)
            prev = pt
            let cg = CGPoint(x: pt.x, y: pt.y)
            path.addLine(to: cg)
            if k == cut1 { p1 = path }
            if k == cut2 { p2 = path }
        }
        guard length > r * 0.3 else { return }
        let rgb = q.spec.isMark ? FaceA.lavender : FaceA.stateRGB(q.spec.state)
        let head = CGPoint(x: q.p.x, y: q.p.y)
        let strength = q.spec.state == .working || q.spec.isMark ? 0.11 : 0.06
        let shading = GraphicsContext.Shading.radialGradient(
            Gradient(colors: [rgb.color(strength), rgb.color(strength * 0.4), .clear]),
            center: head, startRadius: r * 0.5, endRadius: max(r, length * 0.95))
        g.stroke(path, with: shading, style: StrokeStyle(lineWidth: r * 0.55, lineCap: .round, lineJoin: .round))
        if !p2.isEmpty { g.stroke(p2, with: shading, style: StrokeStyle(lineWidth: r * 1.05, lineCap: .round, lineJoin: .round)) }
        if !p1.isEmpty { g.stroke(p1, with: shading, style: StrokeStyle(lineWidth: r * 1.6, lineCap: .round, lineJoin: .round)) }
    }

    private func drawGlow(_ g: inout GraphicsContext, _ q: Puck, r: Double, u: Double, t: Double, a: Double, panic: Bool) {
        let c = CGPoint(x: q.p.x, y: q.p.y)
        func circle(_ rad: Double) -> Path { Path(ellipseIn: CGRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2)) }
        let ringR = r * 1.17
        let lw = max(1, 2.3 * u)
        var rgb = q.spec.isMark ? FaceA.lavender : FaceA.stateRGB(q.spec.state)
        if panic { rgb = FaceA.red }
        let pulse = 0.5 + 0.5 * sin(t * 2 * .pi / 1.6)

        // Soft halo.
        let glowA: Double = switch q.spec.state {
        case .needsYou: 0.22 + 0.3 * pulse
        case .working: 0.24
        case .finished: 0.16
        case .error: 0.2
        case .idle: q.spec.isMark ? 0.26 : 0.06
        }
        if q.spec.isMark {
            g.fill(circle(r * 2.9), with: .radialGradient(Gradient(colors: [FaceA.lavender.color(glowA * a), FaceA.peach.color(glowA * 0.4 * a), .clear]),
                                                         center: c, startRadius: r * 0.5, endRadius: r * 2.9))
        } else {
            g.fill(circle(r * 2.6), with: .radialGradient(Gradient(colors: [rgb.color(glowA * a), .clear]),
                                                         center: c, startRadius: r * 0.6, endRadius: r * 2.6))
        }

        switch q.spec.state {
        case .working where !q.spec.isMark:
            g.stroke(circle(ringR), with: .color(rgb.color(0.12 * a)), lineWidth: lw)
            // Rotating comet arc.
            let head = t * 2 * .pi * 0.7 + Double(FaceA.hash(q.spec.id) % 628) / 100
            let segs = 12
            for k in 0..<segs {
                let a0 = head - Double(k) * 0.16
                var arc = Path()
                arc.addArc(center: c, radius: ringR, startAngle: .radians(a0 - 0.17), endAngle: .radians(a0), clockwise: false)
                let f = 1 - Double(k) / Double(segs)
                g.stroke(arc, with: .color(rgb.color(0.95 * f * f * a)), style: StrokeStyle(lineWidth: lw, lineCap: .round))
            }
        case .needsYou:
            g.stroke(circle(ringR), with: .color(rgb.color((0.35 + 0.4 * pulse) * a)), lineWidth: lw * 1.1)
            // Sonar ping.
            for k in 0..<2 {
                let p = (t / 1.6 + Double(k) * 0.5).truncatingRemainder(dividingBy: 1)
                let rr = ringR + p * r * 1.1
                g.stroke(circle(rr), with: .color(rgb.color(0.55 * pow(1 - p, 1.8) * a)), lineWidth: lw * (1 - p * 0.5))
            }
        case .finished:
            g.stroke(circle(ringR), with: .color(rgb.color(0.7 * a)), lineWidth: lw)
        case .error:
            let flicker = 0.6 + 0.4 * (sin(t * 9) > 0.6 ? 0.3 : 1)
            g.stroke(circle(ringR), with: .color(rgb.color(0.75 * flicker * a)), lineWidth: lw)
        default:
            if q.spec.isMark {
                // A slowly rotating lavender→peach ring.
                let rot = t * 0.35
                g.stroke(circle(ringR), with: .conicGradient(
                    Gradient(colors: [FaceA.lavender.color(0.9 * a), FaceA.peach.color(0.9 * a), FaceA.lavender.color(0.15 * a), FaceA.lavender.color(0.9 * a)]),
                    center: c, angle: .radians(rot)), lineWidth: lw)
            } else {
                g.stroke(circle(ringR), with: .color(rgb.color(0.28 * a)), lineWidth: lw * 0.8)
            }
        }
    }

    private func drawFlourish(_ g: inout GraphicsContext, _ fl: Flourish, t: Double, u: Double, r: Double, preview: Bool) {
        let age = t - fl.born
        guard age >= 0 else { return }
        // A quick flash of silicon light in the corner itself.
        let flash = exp(-age * 4.5)
        if flash > 0.02 {
            let fr = (preview ? 120 : 300) * u * (0.6 + 0.4 * FaceA.easeOutCubic(age * 2))
            let c = CGPoint(x: fl.corner.x, y: fl.corner.y)
            var l = g
            l.blendMode = .plusLighter
            l.fill(Path(ellipseIn: CGRect(x: c.x - fr, y: c.y - fr, width: fr * 2, height: fr * 2)), with: .radialGradient(
                Gradient(colors: [FaceA.lavender.color(0.55 * flash), FaceA.peach.color(0.22 * flash), .clear]),
                center: c, startRadius: 0, endRadius: fr))
        }
        let s = FaceA.spring(age, response: 0.5, damping: 0.55)
        let fade = 1 - FaceA.smoothstep(1.5, 2.35, age)
        // Beside the puck along the wall it hit: the puck leaves diagonally, so they never meet.
        let dist = fl.halfW + (preview ? 46 : 96) * u + (preview ? 8 : 26) * u * FaceA.easeOutCubic(age / 2.2)
        let pos = CGPoint(x: fl.p.x + fl.dir.x * dist, y: fl.p.y)
        let label = fl.count > 1 ? "corner! ×\(fl.count)" : "corner!"
        var text = g.resolve(Text(label).font(Theme.allo((preview ? 20 : 30) * u, .semibold)))
        text.shading = .linearGradient(FaceA.siliconGradient, startPoint: CGPoint(x: pos.x - 70 * u, y: pos.y),
                                       endPoint: CGPoint(x: pos.x + 70 * u, y: pos.y))
        var c = g
        c.opacity = fade
        c.translateBy(x: pos.x, y: pos.y)
        c.rotate(by: .degrees(-6))
        c.scaleBy(x: s, y: s)
        c.draw(text, at: .zero, anchor: .center)
    }
}

// MARK: - Symbols

/// The puck body: provider mark (or the Silicon mark) with a state badge.
struct BouncePuckDisc: View {
    let spec: BounceSpec
    let radius: CGFloat
    let unit: CGFloat

    var body: some View {
        let d = radius * 2
        ZStack(alignment: .topTrailing) {
            if spec.isMark {
                FaceASiliconMark(size: d)
            } else {
                ProviderMark(provider: spec.provider, size: d)
            }
            if let badge {
                ZStack {
                    Circle().fill(Theme.stateColor(spec.state))
                    Image(systemName: badge)
                        .font(.system(size: d * 0.17, weight: .heavy))
                        .foregroundStyle(Theme.Night.background)
                }
                .frame(width: d * 0.34, height: d * 0.34)
                .overlay(Circle().strokeBorder(Theme.Night.background, lineWidth: max(1.5, d * 0.035)))
                .offset(x: d * 0.04, y: -d * 0.04)
            }
        }
        .frame(width: d, height: d)
    }

    private var badge: String? {
        switch spec.state {
        case .finished: "checkmark"
        case .needsYou: "exclamationmark"
        case .error: "xmark"
        default: nil
        }
    }
}

/// The title pill under a puck.
struct BouncePuckLabel: View {
    let spec: BounceSpec
    let unit: CGFloat

    var body: some View {
        let fs = max(9, 13 * unit)
        HStack(spacing: 6 * unit) {
            if !spec.isMark {
                Circle().fill(Theme.stateColor(spec.state)).frame(width: 6 * unit, height: 6 * unit)
            }
            Text(spec.title)
                .font(Theme.allo(fs, .medium))
                .foregroundStyle(spec.isMark ? Theme.Night.secondary : Theme.Night.foreground.opacity(0.94))
            if let s = stateWord {
                Text(s)
                    .font(Theme.allo(fs, .medium))
                    .foregroundStyle(Theme.stateColor(spec.state))
            }
        }
        .tracking(Theme.tracking(fs))
        .lineLimit(1)
        .padding(.horizontal, 11 * unit)
        .padding(.vertical, 5.5 * unit)
        .background(Capsule(style: .continuous).fill(Color(hex: "141414").opacity(0.86)))
        .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .fixedSize()
    }

    private var stateWord: String? {
        guard !spec.isMark else { return nil }
        switch spec.state {
        case .needsYou: return "· Needs you"
        case .finished: return "· Done"
        case .error: return "· Error"
        case .idle: return "· Idle"
        case .working: return nil
        }
    }
}

/// A huge, barely-there clock behind the pucks (drifts slowly; updates once a second).
struct BounceClockWatermark: View {
    let start: Date
    let fixedTime: Double?
    let unit: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { tl in
            let t = FaceA.elapsed(since: start, now: tl.date, fixed: fixedTime)
            let date = FaceA.wallDate(now: tl.date, fixed: fixedTime)
            let d = FaceA.drift(t, amplitude: 26 * unit)
            Text(date, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute(.twoDigits))
                .font(Theme.allo(230 * unit, .thin))
                .monospacedDigit()
                .tracking(-6 * unit)
                .foregroundStyle(.white.opacity(0.05))
                .offset(d)
        }
        .allowsHitTesting(false)
    }
}
