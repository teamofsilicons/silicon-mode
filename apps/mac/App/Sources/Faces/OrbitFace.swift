import SwiftUI
import SiliconModeKit

/// Orbit: a 3D-ish orbital system around an eclipsed, luminous core. Agents are planets on tilted
/// elliptical orbits (older agents farther out) with perspective depth; working ones shed comet
/// tails, needs-you planets flare amber, finished ones wear a green ring.
enum OrbitFace {
    static let descriptor = FaceDescriptor(
        id: "orbit",
        name: "Orbit",
        summary: "Your agents orbit a glowing core. Working ones leave comet tails.",
        options: [
            FaceOptionSpec(key: "speed", label: "Speed", kind: .slider(min: 0.25, max: 3, step: 0.05, default: 1)),
            FaceOptionSpec(key: "tilt", label: "Tilt", kind: .slider(min: 0, max: 80, step: 1, default: 66)),
            FaceOptionSpec(key: "trails", label: "Comet tails", kind: .toggle(default: true)),
            FaceOptionSpec(key: "starfield", label: "Starfield", kind: .toggle(default: true)),
        ],
        make: { ctx in AnyView(OrbitFaceView(ctx: ctx)) }
    )
}

struct OrbitFaceView: View {
    let ctx: FaceContext
    var fixedTime: Double?

    @State private var start = Date()
    @State private var phases = OrbitPhases()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let tiltDeg = ctx.number("tilt", 66)
        let planets = OrbitPlanet.make(ctx.sessions, preview: ctx.isPreview)
        GeometryReader { geo in
            let size = geo.size
            let u = FaceA.unit(for: size) * (ctx.isPreview ? 1.45 : 1)
            let planetR = 19 * u
            let maxScale: CGFloat = 1.4
            TimelineView(.animation(minimumInterval: ctx.isPreview ? 1 / 30 : ctx.frameInterval)) { tl in
                let t = FaceA.elapsed(since: start, now: tl.date, fixed: fixedTime)
                let wall = FaceA.wallDate(now: tl.date, fixed: fixedTime)
                let config = OrbitRenderer.Config(
                    unit: u, planetR: planetR, symbolScale: maxScale, tilt: tiltDeg * .pi / 180,
                    speed: ctx.number("speed", 1), trails: ctx.bool("trails", true) && !reduceMotion,
                    starfield: ctx.bool("starfield", true), reduceMotion: reduceMotion,
                    panicking: ctx.isPanicking, preview: ctx.isPreview, labels: !ctx.isPreview)
                Canvas { g, sz in
                    OrbitRenderer(config: config, planets: planets, phases: phases).draw(&g, size: sz, t: t)
                } symbols: {
                    OrbitCoreLabel(date: wall, counts: ctx.counts, showClock: ctx.showClock, unit: u, preview: ctx.isPreview)
                        .tag("core")
                    ForEach(planets) { p in
                        ProviderMark(provider: p.provider, size: planetR * 2 * maxScale).tag(p.id)
                        ProviderMark(provider: p.provider, size: planetR * 2 * maxScale)
                            .padding(planetR * 0.6)
                            .blur(radius: planetR * 0.22)
                            .tag("blur:" + p.id)
                        if !ctx.isPreview {
                            OrbitPlanetLabel(planet: p, unit: u, trailing: false).tag("label:" + p.id)
                            OrbitPlanetLabel(planet: p, unit: u, trailing: true).tag("labelR:" + p.id)
                        }
                    }
                }
            }
        }
        .background(Theme.Night.background)
        .overlay(FaceAPanicWash(active: ctx.isPanicking))
        .accessibilityElement()
        .accessibilityLabel("Orbit face: \(ctx.counts.running) agents running")
    }
}

/// One orbiting agent and its orbital elements.
struct OrbitPlanet: Identifiable, Equatable {
    let id: String
    let provider: String
    let title: String
    let state: AgentState
    /// 0 = innermost (newest) … 1 = outermost (oldest).
    let ring: Double
    let seed: UInt64

    static func make(_ sessions: [AgentSession], preview: Bool) -> [OrbitPlanet] {
        let visible = FaceA.visibleSessions(sessions, max: preview ? 6 : 10)
        // Older agents orbit farther out.
        let byAge = visible.sorted { ($0.startedAt ?? $0.updatedAt) > ($1.startedAt ?? $1.updatedAt) }
        let n = byAge.count
        return byAge.enumerated().map { i, s in
            OrbitPlanet(id: s.id, provider: s.provider, title: FaceA.title(s, max: 26), state: s.state,
                        ring: n == 1 ? 0.45 : Double(i) / Double(n - 1), seed: FaceA.hash(s.id))
        }
    }
}

/// Integrated orbital phase per planet, so speed changes (state, options) never make a planet jump.
final class OrbitPhases {
    private struct Entry { var theta: Double; var omega: Double; var t: Double }
    private var entries: [String: Entry] = [:]
    private var lastT = -1.0

    func theta(_ id: String, initial: Double, omega target: Double, t: Double) -> (theta: Double, omega: Double) {
        if t + 1e-6 < lastT { entries.removeAll(); labelAlphas.removeAll() }
        lastT = max(lastT, t)
        // Sessions come and go over hours: forget the ones not drawn for a while.
        if entries.count > 40 { entries = entries.filter { t - $0.value.t < 20 } }
        if labelAlphas.count > 40 { labelAlphas = labelAlphas.filter { t - $0.value.t < 20 } }
        guard var e = entries[id] else {
            let e = Entry(theta: initial + target * t, omega: target, t: t)
            entries[id] = e
            return (e.theta, e.omega)
        }
        let dt = min(max(0, t - e.t), 1)
        e.omega += (target - e.omega) * min(1, dt * 0.9)
        e.theta += e.omega * dt
        e.t = t
        entries[id] = e
        return (e.theta, e.omega)
    }

    private var labelAlphas: [String: (a: Double, t: Double)] = [:]

    /// Eased label visibility (labels fade instead of popping when they start/stop colliding).
    func labelAlpha(_ id: String, target: Double, t: Double) -> Double {
        guard let e = labelAlphas[id], t >= e.t else { labelAlphas[id] = (target, t); return target }
        let k = min(1, (t - e.t) * 5)
        let a = e.a + (target - e.a) * k
        labelAlphas[id] = (a, t)
        return a
    }
}

/// Canvas renderer for the Orbit face. Pure function of (config, planets, phases, time).
struct OrbitRenderer {
    struct Config {
        var unit: CGFloat
        var planetR: CGFloat
        var symbolScale: CGFloat
        var tilt: Double
        var speed: Double
        var trails: Bool
        var starfield: Bool
        var reduceMotion: Bool
        var panicking: Bool
        var preview: Bool
        var labels: Bool
    }

    let config: Config
    let planets: [OrbitPlanet]
    let phases: OrbitPhases

    private struct Orbit {
        var a: Double, incl: Double, node: Double
    }

    private struct LabelSpot { var point: CGPoint; var left: Bool; var alpha: Double }

    private struct Body {
        var planet: OrbitPlanet
        var orbit: Orbit
        var theta: Double
        var omega: Double
        var pos: CGPoint
        var z: Double
        var s: Double
    }

    // MARK: Geometry

    private func project(_ o: Orbit, _ theta: Double, center: CGPoint, depth D: Double) -> (CGPoint, Double, Double) {
        let x = o.a * cos(theta), y = o.a * sin(theta)
        let y1 = y * cos(o.incl), z = -y * sin(o.incl)
        let x2 = x * cos(o.node) - y1 * sin(o.node)
        let y2 = x * sin(o.node) + y1 * cos(o.node)
        let s = D / (D - z)
        return (CGPoint(x: center.x + x2 * s, y: center.y - y2 * s), z, s)
    }

    func draw(_ g: inout GraphicsContext, size: CGSize, t: Double) {
        let u = Double(config.unit)
        let center = CGPoint(x: size.width / 2, y: size.height * 0.5)
        let coreR = 64 * u
        let tilt = config.tilt
        let aMin = coreR * 2.25
        let aMax = max(aMin * 1.25, min(Double(size.width) * 0.42, Double(size.height) * 0.43 / max(cos(tilt), 0.12)))
        let D = aMax * 3.4

        drawNebula(&g, size: size, t: t)
        if config.starfield { drawStars(&g, size: size, t: t) }

        // Bodies.
        var bodies: [Body] = []
        bodies.reserveCapacity(planets.count)
        for p in planets {
            let a = aMin + (aMax - aMin) * (0.08 + 0.92 * p.ring)
            let incl = min(max(tilt + (FaceA.unit(p.seed, 1) - 0.5) * 0.16, 0), 1.48)
            let node = (FaceA.unit(p.seed, 2) - 0.5) * 0.32
            let o = Orbit(a: a, incl: incl, node: node)
            let period = 30 * pow(a / aMin, 1.5)
            var f: Double = switch p.state {
            case .working: 1
            case .needsYou: 0.32
            case .finished: 0.55
            case .idle: 0.4
            case .error: 0.3
            }
            if config.panicking { f *= 3 }
            if config.reduceMotion { f *= 0.35 }
            let omega = 2 * .pi / period * f * config.speed
            let ph = phases.theta(p.id, initial: FaceA.unit(p.seed, 3) * 2 * .pi, omega: omega, t: t)
            let (pos, z, s) = project(o, ph.theta, center: center, depth: D)
            bodies.append(Body(planet: p, orbit: o, theta: ph.theta, omega: ph.omega, pos: pos, z: z, s: s))
        }

        // Orbits: back halves first.
        var front = Path(), back = Path()
        for b in bodies { orbitPaths(b.orbit, center: center, depth: D, front: &front, back: &back) }
        if planets.isEmpty { dustOrbits(&front, &back, coreR: coreR, center: center, depth: D) }
        g.stroke(back, with: .color(.white.opacity(0.055)), lineWidth: max(0.6, 1 * u))

        let labels = config.labels ? layoutLabels(g, bodies, size: size, center: center, coreR: coreR, t: t) : [:]

        // Core glow (additive), then planets behind the core.
        drawCoreGlow(&g, center: center, coreR: coreR, t: t)
        let sorted = bodies.sorted { $0.z < $1.z }
        for b in sorted where b.z < 0 { drawBody(&g, b, center: center, depth: D, t: t, label: labels[b.planet.id]) }
        if planets.isEmpty { drawDust(&g, center: center, coreR: coreR, depth: D, t: t, front: false) }

        drawCore(&g, center: center, coreR: coreR, t: t)

        g.stroke(front, with: .color(.white.opacity(0.10)), lineWidth: max(0.6, 1 * u))
        for b in sorted where b.z >= 0 { drawBody(&g, b, center: center, depth: D, t: t, label: labels[b.planet.id]) }
        if planets.isEmpty { drawDust(&g, center: center, coreR: coreR, depth: D, t: t, front: true) }
    }

    private func depthN(_ b: Body) -> Double {
        FaceA.clamp(b.z / (b.orbit.a * max(sin(b.orbit.incl), 0.2)) * 0.5 + 0.5)   // 0 back … 1 front
    }

    private func planetRadius(_ b: Body) -> Double {
        Double(config.planetR) * b.s * (b.planet.state == .needsYou ? 1.12 : 1)
    }

    /// Places labels by priority (needs-you, then nearest), on the side away from the core, and
    /// hides those that would collide with the core, a planet, another label or the screen edge.
    private func layoutLabels(_ g: GraphicsContext, _ bodies: [Body], size: CGSize, center: CGPoint, coreR: Double, t: Double) -> [String: LabelSpot] {
        let u = Double(config.unit)
        var taken: [CGRect] = [CGRect(x: center.x - coreR * 1.2, y: center.y - coreR * 1.2, width: coreR * 2.4, height: coreR * 2.4)]
        for b in bodies {
            let r = planetRadius(b)
            taken.append(CGRect(x: b.pos.x - r, y: b.pos.y - r, width: r * 2, height: r * 2))
        }
        let ordered = bodies.sorted { a, b in
            let pa = (a.planet.state == .needsYou ? 2.0 : 0) + depthN(a), pb = (b.planet.state == .needsYou ? 2.0 : 0) + depthN(b)
            return pa > pb
        }
        var out: [String: LabelSpot] = [:]
        for b in ordered {
            guard let sym = g.resolveSymbol(id: "label:" + b.planet.id) else { continue }
            let sz = sym.size
            let gap = planetRadius(b) * (b.planet.state == .finished ? 1.9 : 1) + 10 * u
            let preferLeft = b.pos.x < center.x
            var chosen: (CGRect, Bool)?
            for left in [preferLeft, !preferLeft] {
                let x = left ? b.pos.x - gap - sz.width : b.pos.x + gap
                let rect = CGRect(x: x, y: b.pos.y - sz.height / 2, width: sz.width, height: sz.height)
                guard rect.minX >= 10, rect.maxX <= size.width - 10, rect.minY >= 6, rect.maxY <= size.height - 6 else { continue }
                if taken.contains(where: { $0.intersects(rect.insetBy(dx: -4 * u, dy: -2 * u)) }) { continue }
                chosen = (rect, left)
                break
            }
            if let (rect, _) = chosen { taken.append(rect) }
            let target = chosen == nil ? 0.0 : 1.0
            let a = phases.labelAlpha(b.planet.id, target: target, t: t)
            let left = chosen?.1 ?? preferLeft
            let x = left ? b.pos.x - gap : b.pos.x + gap
            out[b.planet.id] = LabelSpot(point: CGPoint(x: x, y: b.pos.y), left: left, alpha: a)
        }
        return out
    }

    private func orbitPaths(_ o: Orbit, center: CGPoint, depth: Double, front: inout Path, back: inout Path) {
        let n = 96
        var prevFront: Bool?
        for k in 0...n {
            let th = Double(k) / Double(n) * 2 * .pi
            let (p, z, _) = project(o, th, center: center, depth: depth)
            let isFront = z >= 0
            if isFront != prevFront {
                // Close the old side up to this point, start the new side here (no gaps).
                if let was = prevFront { if was { front.addLine(to: p) } else { back.addLine(to: p) } }
                if isFront { front.move(to: p) } else { back.move(to: p) }
                prevFront = isFront
            } else {
                if isFront { front.addLine(to: p) } else { back.addLine(to: p) }
            }
        }
    }

    // MARK: Background

    private func drawNebula(_ g: inout GraphicsContext, size: CGSize, t: Double) {
        let w = size.width, h = size.height
        let rect = Path(CGRect(origin: .zero, size: size))
        let c1 = CGPoint(x: w * (0.2 + 0.04 * sin(t / 41)), y: h * (0.22 + 0.05 * cos(t / 37)))
        let c2 = CGPoint(x: w * (0.82 + 0.04 * cos(t / 43)), y: h * (0.8 + 0.04 * sin(t / 39)))
        g.fill(rect, with: .radialGradient(Gradient(colors: [FaceA.lavender.color(0.07), .clear]),
                                           center: c1, startRadius: 0, endRadius: max(w, h) * 0.5))
        g.fill(rect, with: .radialGradient(Gradient(colors: [FaceA.peach.color(0.05), .clear]),
                                           center: c2, startRadius: 0, endRadius: max(w, h) * 0.45))
    }

    private struct Star { var x: Double; var y: Double; var layer: Int; var bucket: Int; var size: Double }

    private static let stars: [Star] = {
        var rng = FaceA.RNG(seed: 0x57A2_F1E1)
        var out: [Star] = []
        let counts = [190, 80, 26]
        for (layer, n) in counts.enumerated() {
            for _ in 0..<n {
                let size: Double = switch layer {
                case 0: rng.range(0.45, 0.9)
                case 1: rng.range(0.8, 1.35)
                default: rng.range(1.3, 2.0)
                }
                out.append(Star(x: rng.next(), y: rng.next(), layer: layer, bucket: Int(rng.next() * 4), size: size))
            }
        }
        return out
    }()

    private func drawStars(_ g: inout GraphicsContext, size: CGSize, t: Double) {
        let w = Double(size.width), h = Double(size.height)
        let u = max(Double(config.unit), 0.5)
        let drift = config.reduceMotion ? [0.4, 1.0, 2.0] : [1.6, 4.2, 9.5]
        let baseA = [0.32, 0.5, 0.75]
        var paths = [Path](repeating: Path(), count: 12)
        for s in Self.stars {
            let off = (t * drift[s.layer] * u).truncatingRemainder(dividingBy: w)
            var x = s.x * w - off
            if x < 0 { x += w }
            let y = s.y * h
            let r = s.size * u
            paths[s.layer * 4 + s.bucket].addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
        for layer in 0..<3 {
            for b in 0..<4 {
                let tw = 0.72 + 0.28 * sin(t * (0.6 + Double(b) * 0.37) + Double(b * 7 + layer * 3))
                g.fill(paths[layer * 4 + b], with: .color(.white.opacity(baseA[layer] * tw)))
            }
        }
        // An occasional shooting star.
        guard !config.reduceMotion else { return }
        let period = 29.0
        let k = floor(t / period)
        let seed = UInt64(max(0, k)) &+ 0x5EED
        let startAt = 4 + FaceA.unit(seed, 1) * (period - 8)
        let local = t - k * period - startAt
        let dur = 0.95
        guard local >= 0, local <= dur else { return }
        let p = local / dur
        let x0 = w * (0.15 + 0.7 * FaceA.unit(seed, 2)), y0 = h * (0.05 + 0.3 * FaceA.unit(seed, 3))
        let ang = (FaceA.unit(seed, 4) < 0.5 ? 1 : -1) * (0.35 + 0.25 * FaceA.unit(seed, 5))
        let dir = CGPoint(x: cos(ang) * (ang > 0 ? 1 : -1), y: abs(sin(ang)))
        let travel = 420 * u
        let head = CGPoint(x: x0 + dir.x * travel * p, y: y0 + dir.y * travel * p)
        let len = 140 * u * sin(p * .pi)
        let tail = CGPoint(x: head.x - dir.x * len, y: head.y - dir.y * len)
        var path = Path(); path.move(to: tail); path.addLine(to: head)
        g.stroke(path, with: .linearGradient(Gradient(colors: [.clear, .white.opacity(0.85 * sin(p * .pi))]), startPoint: tail, endPoint: head),
                 style: StrokeStyle(lineWidth: 1.4 * u, lineCap: .round))
    }

    // MARK: Core

    private func circle(_ c: CGPoint, _ r: Double) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }

    private func coreColors() -> (FaceA.RGB, FaceA.RGB) {
        config.panicking ? (FaceA.red, FaceA.RGB(0xFF6A5C)) : (FaceA.lavender, FaceA.peach)
    }

    private func breathe(_ t: Double) -> Double {
        1 + (config.reduceMotion ? 0.006 : 0.02) * sin(t * 2 * .pi / (config.panicking ? 0.5 : 6.5))
    }

    private func drawCoreGlow(_ g: inout GraphicsContext, center: CGPoint, coreR: Double, t: Double) {
        let (c1, c2) = coreColors()
        let R = coreR * breathe(t)
        do {
            var l = g
            l.blendMode = .plusLighter
            l.fill(circle(center, R * 4.4), with: .radialGradient(
                Gradient(stops: [.init(color: c1.color(0.26), location: 0), .init(color: c2.color(0.09), location: 0.4),
                                 .init(color: .clear, location: 1)]),
                center: center, startRadius: R * 0.9, endRadius: R * 4.4))
        }
    }

    private func drawCore(_ g: inout GraphicsContext, center: CGPoint, coreR: Double, t: Double) {
        let u = Double(config.unit)
        let (c1, c2) = coreColors()
        let R = coreR * breathe(t)
        let rot = t * 0.16
        // Corona: layered strokes approximate a soft, rotating, gradient blur (cheap).
        do {
            var l = g
            l.blendMode = .plusLighter
            for k in 0..<6 {
                let f = Double(k) / 5
                let rr = R * (1.02 + f * 0.16)
                l.stroke(circle(center, rr), with: .conicGradient(
                    Gradient(colors: [c1.color(0.5 * (1 - f)), c2.color(0.55 * (1 - f)), .white.opacity(0.35 * (1 - f)), c1.color(0.5 * (1 - f))]),
                    center: center, angle: .radians(rot)), lineWidth: R * (0.05 + f * 0.09))
            }
        }
        // The eclipsed disc.
        g.fill(circle(center, R), with: .radialGradient(
            Gradient(colors: [Color(hex: "1A1622"), Color(hex: "0D0C10")]),
            center: CGPoint(x: center.x - R * 0.3, y: center.y - R * 0.35), startRadius: 0, endRadius: R * 1.3))
        // Rim light.
        g.stroke(circle(center, R), with: .conicGradient(
            Gradient(colors: [c1.color(), c2.color(), .white.opacity(0.95), c1.color(0.6), c1.color()]),
            center: center, angle: .radians(-rot * 1.3)), lineWidth: max(1, 1.7 * u))
        if let label = g.resolveSymbol(id: "core") {
            g.draw(label, at: center, anchor: .center)
        }
    }

    // MARK: Planets

    private func drawBody(_ g: inout GraphicsContext, _ b: Body, center: CGPoint, depth D: Double, t: Double, label: LabelSpot?) {
        let u = Double(config.unit)
        let pr = planetRadius(b)
        let rgb = config.panicking ? FaceA.red : FaceA.stateRGB(b.planet.state)
        let depthN = depthN(b)
        // Needs-you planets stay loud even on the far side.
        let fade = b.planet.state == .needsYou ? 0.85 + 0.15 * depthN : 0.5 + 0.5 * depthN

        // Comet tail + shed particles (working).
        if config.trails && b.planet.state == .working {
            do {
                var l = g
                l.blendMode = .plusLighter
                // Tail: short butt-capped segments along the orbit behind the planet, tapering in
                // width and alpha (smooth, no beads).
                let n = 44
                let delta = (Double(config.planetR) * 0.3) / b.orbit.a
                let dirSign: Double = b.omega >= 0 ? 1 : -1
                let w = Double(config.planetR) * b.s
                var prev = b.pos
                for k in 1...n {
                    let (p, _, _) = project(b.orbit, b.theta - dirSign * Double(k) * delta, center: center, depth: D)
                    let f = Double(k - 1) / Double(n)
                    var seg = Path(); seg.move(to: prev); seg.addLine(to: p)
                    let col = FaceA.accent.mix(FaceA.lavender, f)
                    l.stroke(seg, with: .color(col.color(0.5 * pow(1 - f, 1.4) * fade)),
                             style: StrokeStyle(lineWidth: w * (1.05 - 0.9 * f), lineCap: .butt))
                    prev = p
                }
                for j in 0..<14 {
                    let P = 1.7
                    let x = t / P + Double(j) / 14
                    let cycle = floor(x)
                    let ph = x - cycle
                    let seed = b.planet.seed &+ UInt64(Int64(cycle) & 0xFFFFF) &* 977 &+ UInt64(j)
                    let back = ph * P * max(abs(b.omega), 0.05) * 0.9 + 0.08
                    let (o, _, s) = project(b.orbit, b.theta - dirSign * back, center: center, depth: D)
                    let ang = FaceA.unit(seed, 1) * 2 * .pi
                    let dist = (8 + 26 * FaceA.unit(seed, 2)) * u * ph * s
                    let p = CGPoint(x: o.x + cos(ang) * dist, y: o.y + sin(ang) * dist)
                    let r = (0.7 + 1.3 * FaceA.unit(seed, 3)) * u * s * (1 - ph * 0.4)
                    l.fill(circle(p, r), with: .color(FaceA.silicon(FaceA.unit(seed, 4), 0.85 * pow(1 - ph, 2) * fade)))
                }
            }
        }

        // Halo + state effects.
        do {
            var l = g
            l.blendMode = .plusLighter
            let glow: Double = switch b.planet.state {
            case .needsYou: 0.3 + 0.3 * (0.5 + 0.5 * sin(t * 2 * .pi / 1.4))
            case .working: 0.22
            case .finished: 0.16
            case .error: 0.24
            case .idle: 0.07
            }
            l.fill(circle(b.pos, pr * 2.8), with: .radialGradient(Gradient(colors: [rgb.color(glow * fade), .clear]),
                                                                center: b.pos, startRadius: pr * 0.5, endRadius: pr * 2.8))
            if b.planet.state == .needsYou {
                // Expanding rings.
                for k in 0..<2 {
                    let p = (t / 1.8 + Double(k) * 0.5).truncatingRemainder(dividingBy: 1)
                    let rr = pr * (1.15 + 2.3 * FaceA.easeOutCubic(p))
                    l.stroke(circle(b.pos, rr), with: .color(rgb.color(0.7 * pow(1 - p, 1.6) * fade)),
                             lineWidth: max(0.8, 2 * u * b.s * (1 - p * 0.5)))
                }
            }
        }

        // Finished: a Saturn-like ring in the orbit's tilt (back half, planet, front half).
        let ringW = pr * 1.85, ringH = ringW * max(0.18, cos(b.orbit.incl))
        func ringArc(front: Bool) -> Path {
            var p = Path()
            p.addArc(center: .zero, radius: 1, startAngle: .radians(front ? 0 : .pi), endAngle: .radians(front ? .pi : 2 * .pi), clockwise: false)
            return p.applying(CGAffineTransform(scaleX: ringW, y: ringH).concatenating(CGAffineTransform(rotationAngle: -b.orbit.node))
                .concatenating(CGAffineTransform(translationX: b.pos.x, y: b.pos.y)))
        }
        let isFinished = b.planet.state == .finished
        if isFinished {
            g.stroke(ringArc(front: false), with: .color(FaceA.green.color(0.55 * fade)), lineWidth: max(1, 2.2 * u * b.s))
        }

        // The planet (sharp ↔ pre-blurred crossfade by depth: depth of field).
        let symScale = pr / (Double(config.planetR) * Double(config.symbolScale))
        let blurMix = FaceA.smoothstep(0.45, 0.0, depthN)
        var pc = g
        pc.translateBy(x: b.pos.x, y: b.pos.y)
        pc.scaleBy(x: symScale, y: symScale)
        if blurMix < 0.99, let sym = g.resolveSymbol(id: b.planet.id) {
            var c = pc; c.opacity = (1 - blurMix) * (0.55 + 0.45 * fade)
            c.draw(sym, at: .zero, anchor: .center)
        }
        if blurMix > 0.01, let sym = g.resolveSymbol(id: "blur:" + b.planet.id) {
            var c = pc; c.opacity = blurMix * (0.55 + 0.45 * fade)
            c.draw(sym, at: .zero, anchor: .center)
        }
        // Depth shading: a faint dark veil on far planets.
        if depthN < 0.5 {
            g.fill(circle(b.pos, pr), with: .color(.black.opacity((0.5 - depthN) * 0.6)))
        }
        if isFinished {
            g.stroke(ringArc(front: true), with: .color(FaceA.green.color(0.9 * fade)), lineWidth: max(1, 2.2 * u * b.s))
        }

        // Label (placed by layoutLabels).
        if let label, label.alpha > 0.01,
           let lab = g.resolveSymbol(id: (label.left ? "labelR:" : "label:") + b.planet.id) {
            var c = g
            c.opacity = label.alpha * (b.planet.state == .needsYou ? 0.95 : 0.3 + 0.65 * depthN)
            c.draw(lab, at: label.point, anchor: label.left ? .trailing : .leading)
        }
    }

    // MARK: Empty state: a little dust that keeps the core company.

    private func dustOrbit(_ k: Int, coreR: Double) -> Orbit {
        Orbit(a: coreR * (1.9 + Double(k) * 0.75), incl: config.tilt + Double(k) * 0.06 - 0.06, node: Double(k) * 0.11 - 0.1)
    }

    private func dustOrbits(_ front: inout Path, _ back: inout Path, coreR: Double, center: CGPoint, depth: Double) {
        for k in 0..<3 { orbitPaths(dustOrbit(k, coreR: coreR), center: center, depth: depth, front: &front, back: &back) }
    }

    private func drawDust(_ g: inout GraphicsContext, center: CGPoint, coreR: Double, depth: Double, t: Double, front: Bool) {
        let u = Double(config.unit)
        do {
            var l = g
            l.blendMode = .plusLighter
            for k in 0..<3 {
                let o = dustOrbit(k, coreR: coreR)
                let omega = 2 * .pi / (24 * pow(o.a / coreR / 1.9, 1.5)) * config.speed * (config.reduceMotion ? 0.35 : 1)
                let th = Double(k) * 2.1 + t * omega
                let (p, z, s) = project(o, th, center: center, depth: depth)
                guard (z >= 0) == front else { continue }
                let r = (3 + Double(k)) * u * s
                let col = FaceA.silicon(Double(k) / 2)
                l.fill(circle(p, r * 4), with: .radialGradient(Gradient(colors: [col.opacity(0.35), .clear]), center: p, startRadius: 0, endRadius: r * 4))
                l.fill(circle(p, r), with: .color(col))
                for j in 1...10 {
                    let (q, _, s2) = project(o, th - Double(j) * 0.045, center: center, depth: depth)
                    let f = Double(j) / 10
                    l.fill(circle(q, r * 0.7 * (1 - f) * s2 / s), with: .color(col.opacity(0.35 * (1 - f))))
                }
            }
        }
    }
}

// MARK: - Symbols

/// Text inside the core: the time (or the running count) and a quiet summary line.
struct OrbitCoreLabel: View {
    let date: Date
    let counts: AgentCounts
    let showClock: Bool
    let unit: CGFloat
    let preview: Bool

    var body: some View {
        VStack(spacing: 3 * unit) {
            if showClock {
                Text(date, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute(.twoDigits))
                    .font(Theme.allo(34 * unit, .light))
                    .monospacedDigit()
                    .tracking(-0.8 * unit)
                    .foregroundStyle(Theme.Night.foreground)
            } else {
                Text("\(counts.running)")
                    .font(Theme.allo(42 * unit, .light))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Night.foreground)
            }
            if !preview {
                Text(caption)
                    .font(Theme.allo(10.5 * unit, .medium))
                    .tracking(0.6 * unit)
                    .textCase(.uppercase)
                    .foregroundStyle(counts.needsYou > 0 ? Theme.Night.warning : Theme.Night.muted)
            }
        }
        .fixedSize()
    }

    private var caption: String {
        if counts.needsYou > 0 { return counts.needsYou == 1 ? "1 needs you" : "\(counts.needsYou) need you" }
        if !showClock { return counts.running == 1 ? "agent running" : "agents running" }
        if counts.running > 0 { return "\(counts.running) running" }
        if counts.total > 0 { return "all done" }
        return "all quiet"
    }
}

struct OrbitPlanetLabel: View {
    let planet: OrbitPlanet
    let unit: CGFloat
    let trailing: Bool

    var body: some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 1 * unit) {
            Text(planet.title)
                .font(Theme.allo(12 * unit, .medium))
                .foregroundStyle(Theme.Night.foreground.opacity(0.9))
            Text(planet.state.label)
                .font(Theme.allo(10.5 * unit, .medium))
                .foregroundStyle(Theme.stateColor(planet.state))
        }
        .tracking(Theme.tracking(12 * unit))
        .lineLimit(1)
        .fixedSize()
    }
}
