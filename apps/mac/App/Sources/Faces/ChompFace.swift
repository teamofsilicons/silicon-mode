import SwiftUI
import SiliconModeKit

/// Chomp: every agent gets a lane; its events roll in from the right as glowing pellets and a
/// hungry little silicon chip (pins for teeth, hinged jaw, tiny feet) runs along eating them.
/// When an agent needs you a big amber "?" block drops into its lane and the chip turns to you,
/// tapping its foot. Finished lanes get a checkered flag and one burst of confetti.
enum ChompFace {
    static let descriptor = FaceDescriptor(
        id: "chomp",
        name: "Chomp",
        summary: "A hungry little chip eats through every event your agents emit.",
        options: [
            FaceOptionSpec(key: "speed", label: "Speed", kind: .slider(min: 0.5, max: 2, step: 0.25, default: 1)),
            FaceOptionSpec(key: "labels", label: "Show labels", kind: .toggle(default: true)),
            FaceOptionSpec(key: "character", label: "Character color",
                           kind: .choice(options: FBStyle.characterChoices, default: "silicon")),
        ],
        make: { ctx in AnyView(ChompFaceView(ctx: ctx)) }
    )

    static let maxLanes = 6
    static let ambientID = "__chomp_ambient__"
}

// MARK: - View

struct ChompFaceView: View {
    let ctx: FaceContext
    @State private var sim = ChompSim()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let plan = ChompPlan(ctx: ctx, size: geo.size, reduceMotion: reduceMotion)
            TimelineView(.animation(minimumInterval: ctx.isPreview ? 1.0 / 30 : ctx.frameInterval)) { tl in
                let t = FaceBClock.seconds(tl.date)
                let wall = FaceBClock.wallDate(tl.date)
                let _ = sim.advance(to: t, plan: plan)
                Canvas { g, size in
                    ChompPainter(sim: sim, plan: plan, t: t, wall: wall).draw(&g, size: size)
                } symbols: {
                    ForEach(sim.headerSessions, id: \.id) { s in
                        ChompLaneHeader(session: s, u: plan.u, width: plan.headerW, compact: plan.compactHeader)
                            .equatable()
                            .tag(s.id)
                    }
                }
            }
        }
        .background(Theme.Night.background)
    }
}

/// Provider mark + title + state, rendered once per lane as a Canvas symbol.
private struct ChompLaneHeader: View, Equatable {
    let session: AgentSession
    let u: CGFloat
    let width: CGFloat
    let compact: Bool

    var body: some View {
        HStack(spacing: 12 * u) {
            ProviderMark(provider: session.provider, size: 34 * u)
            if !compact {
                VStack(alignment: .leading, spacing: 5 * u) {
                    Text(session.title)
                        .font(Theme.allo(15.5 * u, .semibold))
                        .tracking(Theme.tracking(15.5 * u))
                        .foregroundStyle(Theme.Night.foreground)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6 * u) {
                        Circle().fill(Theme.stateColor(session.state)).frame(width: 6 * u, height: 6 * u)
                        Text(subtitle)
                            .font(Theme.allo(12 * u, .medium))
                            .foregroundStyle(Theme.Night.muted)
                            .lineLimit(1)
                    }
                }
            }
        }
        .frame(width: max(width, 1), alignment: .leading)
    }

    private var subtitle: String {
        let where_ = session.projectName ?? ProviderCatalog.info(for: session.provider).name
        return "\(session.state.label) · \(where_)"
    }
}

// MARK: - Layout plan

/// Everything derived from the context + size (no time): which lanes, where, how big.
struct ChompPlan {
    let size: CGSize
    let shown: [AgentSession]
    let hidden: Int
    let ambient: Bool
    let laneH: CGFloat
    /// Lane scale unit: 1 at a 120 pt lane.
    let u: CGFloat
    /// Screen scale unit: 1 on a 1512 × 982 display.
    let cu: CGFloat
    let marginX: CGFloat
    let headerW: CGFloat
    let compactHeader: Bool
    let labels: Bool
    let speed: Double
    let palette: FBCharacterPalette
    let showClock: Bool
    let isPreview: Bool
    let isPanicking: Bool
    let reduceMotion: Bool
    let targets: [String: CGRect]
    /// Conveyor length (mouth → right edge) in design units.
    let conveyorLength: Double

    init(ctx: FaceContext, size: CGSize, reduceMotion: Bool) {
        self.size = size
        isPreview = ctx.isPreview
        isPanicking = ctx.isPanicking
        showClock = ctx.showClock
        self.reduceMotion = reduceMotion
        labels = ctx.bool("labels", true) && !ctx.isPreview
        speed = ctx.number("speed", 1).clamped(0.25, 3)
        palette = FBStyle.character(ctx.string("character", "silicon"))

        let maxLanes = ctx.isPreview ? 3 : ChompFace.maxLanes
        let ranked = ctx.sessions.sorted {
            $0.state.rank != $1.state.rank ? $0.state.rank < $1.state.rank : $0.updatedAt > $1.updatedAt
        }
        let top = Array(ranked.prefix(maxLanes))
        // Stable order on screen (by start), so lanes don't shuffle when states change.
        shown = top.sorted {
            let a = $0.startedAt ?? $0.updatedAt, b = $1.startedAt ?? $1.updatedAt
            return a != b ? a < b : $0.id < $1.id
        }
        hidden = max(0, ctx.sessions.count - shown.count)
        ambient = shown.isEmpty

        let W = max(size.width, 1), H = max(size.height, 1)
        cu = min(W / 1512, H / 982)
        let n = CGFloat(ambient ? 1 : shown.count)
        marginX = W * (isPreview ? 0.045 : 0.055)
        let top_ = H * (isPreview ? 0.1 : 0.17)
        let bottom = H * (isPreview ? 0.1 : 0.15)
        let avail = H - top_ - bottom
        let gap = (isPreview ? 5 : 16) * cu
        var lh = (avail - gap * (n - 1)) / n
        lh = min(lh, (ambient ? 190 : 168) * cu)
        if isPreview { lh = min(lh, ambient ? H * 0.42 : H * 0.26) }
        laneH = max(lh, 8)
        u = laneH / 120
        let total = n * laneH + (n - 1) * gap
        let y0 = top_ + (avail - total) / 2
        compactHeader = isPreview
        headerW = ambient ? 0 : (compactHeader ? 34 * u : min(max(W * 0.19, 220 * cu), 300 * cu))

        var t: [String: CGRect] = [:]
        let ids = ambient ? [ChompFace.ambientID] : shown.map(\.id)
        let laneW = ambient ? min(W - 2 * marginX, max(W * 0.58, 640 * cu)) : W - 2 * marginX
        for (i, id) in ids.enumerated() {
            t[id] = CGRect(x: (W - laneW) / 2, y: y0 + CGFloat(i) * (laneH + gap), width: laneW, height: laneH)
        }
        targets = t
        let g = ChompLaneGeo(rect: CGRect(x: 0, y: 0, width: laneW, height: laneH), headerW: headerW)
        conveyorLength = Double((g.rightX - g.mouthX) / g.u)
    }
}

/// Lane geometry, from its (eased) rect.
struct ChompLaneGeo {
    let rect: CGRect
    let u: CGFloat
    let laneH: CGFloat
    /// Body height of the chomper.
    let B: CGFloat
    let headerX: CGFloat
    let convX: CGFloat
    let bodyX: CGFloat
    let mouthX: CGFloat
    let rightX: CGFloat
    let floorY: CGFloat
    let mouthY: CGFloat

    init(rect: CGRect, headerW: CGFloat) {
        self.rect = rect
        laneH = rect.height
        u = laneH / 120
        B = laneH * 0.36
        headerX = rect.minX + 22 * u
        convX = headerW > 0 ? headerX + headerW + 18 * u : rect.minX + 26 * u
        bodyX = convX + B * 0.85
        mouthX = bodyX + B * 1.16 * 0.5 - B * 0.12
        rightX = rect.maxX - 26 * u
        floorY = rect.minY + laneH * 0.78
        mouthY = floorY - B * 0.76
    }
}

// MARK: - Simulation

struct ChompPellet {
    let id: String
    let kind: FBEventKind
    let text: String
}

struct ChompBurst {
    let time: Double
    let slot: Int
    let color: Color?
    let big: Bool
}

enum ChompAmbient { case none, dot, big }

@MainActor
final class ChompLane {
    let id: String
    let seed: Int
    var session: AgentSession?
    var state: AgentState = .working
    var stateSince: Double
    var front = false
    var prevFront = false
    var turnAt = -1000.0
    var scroll: Double = 0
    var rate: Double = 1
    var assigned: [Int: ChompPellet] = [:]
    var queue: [ChompPellet] = []
    var seen: Set<String> = []
    var lastAssigned = Int.min / 4
    var lastEat = -1000.0
    var bursts: [ChompBurst] = []
    var confettiAt: Double?
    var rect: CGRect
    var target: CGRect
    var alpha: Double = 0
    var present = true

    init(id: String, rect: CGRect, now: Double) {
        self.id = id
        seed = FB.seed(id)
        self.rect = rect
        target = rect
        stateSince = now
    }
}

@MainActor
final class ChompSim {
    static let spacing: Double = 46
    static let baseSpeed: Double = 74

    private(set) var lanes: [String: ChompLane] = [:]
    private(set) var order: [String] = []
    private(set) var now: Double = 0
    private var time: Double?

    /// Sessions that need a header symbol (shown + fading out).
    var headerSessions: [AgentSession] { order.compactMap { lanes[$0]?.session } }

    static func ambient(_ k: Int, seed: Int) -> ChompAmbient {
        let h = FB.hash(k, seed)
        if h < 0.17 { return .none }
        if h > 0.955 { return .big }
        return .dot
    }

    func isFull(_ lane: ChompLane, _ k: Int) -> Bool {
        lane.assigned[k] != nil || ChompSim.ambient(k, seed: lane.seed) != .none
    }

    func advance(to t: Double, plan: ChompPlan) {
        if time == nil {
            let start = FaceBClock.replayStart(for: t, history: 14)
            time = start
            now = start
            sync(plan, first: true)
        }
        var cur = time ?? t
        if t < cur - 0.5 { cur = t }          // clock jumped backwards
        var remaining = max(0, t - cur)
        if !FaceBClock.isSnapshot { remaining = min(remaining, 0.1) }   // after a stall, don't fast-forward
        now = t - remaining
        sync(plan, first: false)
        let h = 1.0 / 60
        while remaining > 1e-9 {
            let dt = min(h, remaining)
            remaining -= dt
            now += dt
            step(dt, plan: plan)
        }
        now = t
        time = t
    }

    private func sync(_ plan: ChompPlan, first: Bool) {
        var ids: [String] = []
        if plan.ambient {
            ids = [ChompFace.ambientID]
            ensure(ChompFace.ambientID, session: nil, plan: plan, first: first)
        } else {
            for s in plan.shown {
                ids.append(s.id)
                ensure(s.id, session: s, plan: plan, first: first)
            }
        }
        let idSet = Set(ids)
        for (id, lane) in lanes where !idSet.contains(id) { lane.present = false }
        order = ids + lanes.keys.filter { !idSet.contains($0) }.sorted()
    }

    private func ensure(_ id: String, session: AgentSession?, plan: ChompPlan, first: Bool) {
        let target = plan.targets[id] ?? .zero
        let state = session?.state ?? .working
        let wantFront = plan.isPanicking || state != .working
        let lane: ChompLane
        var isNew = false
        if let l = lanes[id] {
            lane = l
        } else {
            lane = ChompLane(id: id, rect: target, now: now)
            lane.alpha = first ? 1 : 0
            lane.state = state
            lane.front = wantFront
            lane.prevFront = wantFront
            lane.rate = state == .working && !plan.isPanicking ? 1 : 0
            if state == .finished { lane.confettiAt = now }
            lanes[id] = lane
            isNew = true
        }
        lane.present = true
        lane.target = target
        lane.session = session

        if !isNew, state != lane.state {
            lane.state = state
            lane.stateSince = now
            if state == .finished { lane.confettiAt = now }
        }
        if wantFront != lane.front {
            lane.prevFront = lane.front
            lane.front = wantFront
            lane.turnAt = now
        }

        guard let session else { return }
        var fresh: [ChompPellet] = []
        for e in session.recentEvents where !lane.seen.contains(e.id) {
            lane.seen.insert(e.id)
            fresh.append(ChompPellet(id: e.id, kind: FBEventKind(e), text: FBEventKind.shortText(e, max: 46)))
        }
        if lane.seen.count > 4000 { lane.seen = Set(session.recentEvents.map(\.id)) }
        guard !fresh.isEmpty else { return }
        if isNew {
            // History: spread the latest few across the conveyor so the lane reads at a glance.
            let L = plan.conveyorLength
            let maxInitial = max(1, Int(L / (ChompSim.spacing * 2.4)))
            let evs = Array(fresh.suffix(maxInitial))
            for (i, p) in evs.enumerated() {
                let f = evs.count == 1 ? 0.55 : 0.26 + 0.66 * Double(i) / Double(evs.count - 1)
                let slot = max(Int((lane.scroll + f * L) / ChompSim.spacing), lane.lastAssigned + 2)
                lane.assigned[slot] = p
                lane.lastAssigned = slot
            }
        } else {
            lane.queue.append(contentsOf: fresh)
        }
    }

    private func step(_ dt: Double, plan: ChompPlan) {
        let v = ChompSim.baseSpeed * plan.speed * (plan.reduceMotion ? 0.6 : 1)
        let sp = ChompSim.spacing
        var dead: [String] = []
        for lane in lanes.values {
            let k = 1 - exp(-9 * dt)
            lane.rect = CGRect(x: lane.rect.minX + (lane.target.minX - lane.rect.minX) * k,
                               y: lane.rect.minY + (lane.target.minY - lane.rect.minY) * k,
                               width: lane.rect.width + (lane.target.width - lane.rect.width) * k,
                               height: lane.rect.height + (lane.target.height - lane.rect.height) * k)
            lane.alpha = FB.approach(lane.alpha, lane.present ? 1 : 0, rate: 5, dt: dt)
            if !lane.present && lane.alpha < 0.01 { dead.append(lane.id); continue }

            let running = lane.state == .working && !plan.isPanicking
            let target: Double = running ? 1 : 0
            lane.rate = FB.approach(lane.rate, target, rate: target > lane.rate ? 2.2 : 5.5, dt: dt)
            if lane.rate < 0.002 && target == 0 { lane.rate = 0 }

            let old = lane.scroll
            lane.scroll += lane.rate * v * (0.9 + 0.2 * FB.hash(lane.seed, 11)) * dt
            var slot = Int(floor(old / sp)) + 1
            while Double(slot) * sp <= lane.scroll {
                if let p = lane.assigned.removeValue(forKey: slot) {
                    lane.bursts.append(ChompBurst(time: now, slot: slot, color: p.kind.color, big: true))
                    lane.lastEat = now
                } else {
                    let a = ChompSim.ambient(slot, seed: lane.seed)
                    if a != .none {
                        lane.bursts.append(ChompBurst(time: now, slot: slot, color: nil, big: a == .big))
                        lane.lastEat = now
                    }
                }
                slot += 1
            }

            if !lane.queue.isEmpty {
                if lane.queue.count > 8 { lane.queue.removeFirst(lane.queue.count - 8) }
                let minSlot = Int(ceil((lane.scroll + plan.conveyorLength + 30) / sp))
                for p in lane.queue {
                    let s = max(minSlot, lane.lastAssigned + 2)
                    lane.assigned[s] = p
                    lane.lastAssigned = s
                }
                lane.queue.removeAll()
            }
            if !lane.bursts.isEmpty { lane.bursts.removeAll { now - $0.time > 1.0 } }
        }
        for id in dead { lanes[id] = nil }
        if !dead.isEmpty { order.removeAll { dead.contains($0) } }
    }
}

// MARK: - Painter

@MainActor
struct ChompPainter {
    let sim: ChompSim
    let plan: ChompPlan
    let t: Double
    let wall: Date

    func draw(_ g: inout GraphicsContext, size: CGSize) {
        let W = size.width, H = size.height
        drawBackground(&g, W: W, H: H)

        var w = g
        if !plan.reduceMotion {
            // Slow drift so nothing sits on the same pixels for hours.
            w.translateBy(x: sin(t / 97) * 6 * plan.cu, y: cos(t / 131) * 5 * plan.cu)
            if plan.isPanicking { w.translateBy(x: sin(t * 53) * 4 * plan.cu, y: cos(t * 47) * 3 * plan.cu) }
        }
        for id in sim.order {
            guard let lane = sim.lanes[id] else { continue }
            var lg = w
            lg.opacity = lane.alpha
            drawLane(&lg, lane)
        }
        if plan.ambient, let lane = sim.lanes[ChompFace.ambientID] { drawAmbientCaption(&w, lane) }
        if plan.hidden > 0, let last = plan.shown.last, let r = plan.targets[last.id] {
            w.draw(Text("+\(plan.hidden) more agent\(plan.hidden == 1 ? "" : "s")")
                    .font(Theme.allo(13 * plan.cu, .medium)).foregroundStyle(Theme.Night.muted),
                   at: CGPoint(x: r.maxX - 4 * plan.cu, y: r.maxY + 14 * plan.cu), anchor: .topTrailing)
        }
        if plan.showClock { drawClock(&w, W: W, H: H) }
    }

    // MARK: Background & chrome

    private func drawBackground(_ g: inout GraphicsContext, W: CGFloat, H: CGFloat) {
        let full = CGRect(x: 0, y: 0, width: W, height: H)
        g.fill(Path(full), with: .color(Theme.Night.background))
        let r1 = max(W, H) * 0.75
        let c1 = CGPoint(x: W * (0.16 + 0.05 * sin(t / 41)), y: H * (0.12 + 0.05 * cos(t / 57)))
        g.fill(Path(ellipseIn: CGRect(x: c1.x - r1, y: c1.y - r1, width: r1 * 2, height: r1 * 2)),
               with: .radialGradient(Gradient(colors: [Theme.Night.lavender.opacity(0.075), .clear]),
                                     center: c1, startRadius: 0, endRadius: r1))
        let r2 = max(W, H) * 0.7
        let c2 = CGPoint(x: W * (0.86 + 0.04 * cos(t / 47)), y: H * (0.92 + 0.04 * sin(t / 61)))
        g.fill(Path(ellipseIn: CGRect(x: c2.x - r2, y: c2.y - r2, width: r2 * 2, height: r2 * 2)),
               with: .radialGradient(Gradient(colors: [Theme.Night.peach.opacity(0.06), .clear]),
                                     center: c2, startRadius: 0, endRadius: r2))
        if plan.isPanicking {
            let a = 0.10 + 0.08 * (0.5 + 0.5 * sin(t * 14))
            g.fill(Path(full), with: .color(Theme.Night.danger.opacity(a)))
        }
    }

    private func drawClock(_ g: inout GraphicsContext, W: CGFloat, H: CGFloat) {
        let cu = plan.cu
        let x = W - plan.marginX, y = H * (plan.isPreview ? 0.04 : 0.06)
        let time = Text(wall, format: .dateTime.hour().minute())
            .font(Theme.allo((plan.isPreview ? 30 : 46) * cu, .light).monospacedDigit())
            .tracking(Theme.tracking(46 * cu, display: true))
            .foregroundStyle(Theme.Night.foreground.opacity(0.92))
        let resolved = g.resolve(time)
        let sz = resolved.measure(in: CGSize(width: W, height: H))
        g.draw(resolved, at: CGPoint(x: x, y: y), anchor: .topTrailing)
        if !plan.isPreview {
            let date = Text(wall, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                .font(Theme.allo(14 * cu, .medium)).foregroundStyle(Theme.Night.muted)
            g.draw(date, at: CGPoint(x: x, y: y + sz.height + 2 * cu), anchor: .topTrailing)
        }
    }

    private func drawAmbientCaption(_ g: inout GraphicsContext, _ lane: ChompLane) {
        let r = lane.rect
        let u = r.height / 120
        let title = Text("No agents running")
            .font(Theme.allo(17 * u, .semibold)).foregroundStyle(Theme.Night.secondary)
        let sub = Text("Chomp is snacking on spare cycles until they show up.")
            .font(Theme.allo(13 * u, .regular)).foregroundStyle(Theme.Night.muted)
        if plan.isPreview { return }
        g.draw(title, at: CGPoint(x: r.midX, y: r.maxY + 26 * u), anchor: .top)
        g.draw(sub, at: CGPoint(x: r.midX, y: r.maxY + 52 * u), anchor: .top)
    }

    // MARK: Lane

    private func drawLane(_ g: inout GraphicsContext, _ lane: ChompLane) {
        let geo = ChompLaneGeo(rect: lane.rect, headerW: plan.ambient ? 0 : plan.headerW)
        let u = geo.u
        let now = sim.now
        let state = lane.state
        let since = now - lane.stateSince

        // Card
        let card = Path.roundedRect(geo.rect, 24 * u)
        g.fill(card, with: .color(.white.opacity(0.028)))
        let tint: Color? = switch state {
        case .needsYou: Theme.Night.warning
        case .finished: Theme.Night.success
        case .error: Theme.Night.danger
        default: nil
        }
        if let tint, lane.session != nil {
            let pulse = state == .needsYou ? 0.05 + 0.03 * (0.5 + 0.5 * sin(t * 3)) : 0.035
            g.fill(card, with: .linearGradient(Gradient(colors: [tint.opacity(pulse * 0.4), tint.opacity(pulse)]),
                                               startPoint: CGPoint(x: geo.rect.minX, y: 0),
                                               endPoint: CGPoint(x: geo.rect.maxX, y: 0)))
        }
        g.stroke(card, with: .color(.white.opacity(0.05)), lineWidth: 1)

        // Header (symbol) + sonar ring
        if let s = lane.session, let sym = g.resolveSymbol(id: s.id) {
            let markC = CGPoint(x: geo.headerX + 17 * u, y: geo.rect.midY)
            if s.state == .working || s.state == .needsYou {
                let period = s.state == .needsYou ? 1.4 : 2.5
                let p = (t / period + Double(lane.seed % 100) / 100).truncatingRemainder(dividingBy: 1)
                let rr = 17 * u * (1 + 0.55 * p)
                let a = (p < 0.2 ? p / 0.2 : (1 - p) / 0.8) * 0.6
                g.stroke(Path(ellipseIn: CGRect(x: markC.x - rr, y: markC.y - rr, width: rr * 2, height: rr * 2)),
                         with: .color(Theme.stateColor(s.state).opacity(a)), lineWidth: 1.2 * u)
            }
            g.draw(sym, at: CGPoint(x: geo.headerX, y: geo.rect.midY), anchor: .leading)
        }

        // Floor dashes, scrolling with the conveyor.
        let period = 22 * u
        let phase = CGFloat((lane.scroll * Double(u)).truncatingRemainder(dividingBy: Double(period)))
        var dashes = Path()
        var x = geo.convX - phase
        while x < geo.rightX {
            let x0 = max(x, geo.convX), x1 = min(x + 10 * u, geo.rightX)
            if x1 > x0 { dashes.addRoundedRect(in: CGRect(x: x0, y: geo.floorY - 1 * u, width: x1 - x0, height: 2 * u),
                                                cornerSize: CGSize(width: u, height: u)) }
            x += period
        }
        g.fill(dashes, with: .linearGradient(Gradient(colors: [.white.opacity(0.10), .white.opacity(0.05)]),
                                             startPoint: CGPoint(x: geo.convX, y: 0), endPoint: CGPoint(x: geo.rightX, y: 0)))

        // Chomper pose
        let chomper = ChompCharacter(pal: plan.palette, B: geo.B, u: u)
        let base = CGPoint(x: geo.bodyX, y: geo.floorY)
        var turnScale: CGFloat = 1
        var showFront = lane.front
        var hop: CGFloat = 0
        let turnP = plan.reduceMotion ? 1 : (now - lane.turnAt) / 0.32
        if turnP < 1 {
            if turnP < 0.5 { showFront = lane.prevFront; turnScale = CGFloat(1 - 2 * turnP) } else { turnScale = CGFloat(2 * turnP - 1) }
            turnScale = max(turnScale, 0.06)
            hop = CGFloat(sin(turnP * .pi)) * geo.B * 0.18
        }

        // Mouth: opens as the next pellet approaches, snaps shut on a bite.
        let sp = ChompSim.spacing
        var nextD = 1e9
        let firstK = Int(floor(lane.scroll / sp)) + 1
        for k in firstK..<(firstK + 4) where sim.isFull(lane, k) {
            nextD = Double(k) * sp - lane.scroll
            break
        }
        let open = FB.smooth(1 - (nextD - 3) / (sp * 0.85))
        let snap = exp(-(now - lane.lastEat) * 16)
        let mouth = open * (1 - snap) * FB.clamp(lane.rate * 1.5)
        let squash = exp(-(now - lane.lastEat) * 11) * FB.clamp(lane.rate * 2)
        let stride = lane.scroll / 30 * 2 * .pi
        let blink = FB.blink(t, seed: lane.seed)

        // Stopped lanes clear their pellets from under the status text and dim the rest.
        let status = lane.session.flatMap { statusLayout(&g, $0, geo, since: since) }
        let stopped = lane.session != nil && (state != .working || plan.isPanicking) ? 1 - FB.clamp(lane.rate) : 0
        let clearEnd = status.map { $0.x + $0.width + 28 * u } ?? geo.mouthX + 0.5 * geo.laneH

        // Back half of the chomper, then pellets, then the front half (so bites land inside the mouth).
        if !showFront {
            chomper.drawSide(&g, at: base, part: .back, mouth: mouth, stride: stride, moving: lane.rate,
                             blink: blink, squash: squash, turnScale: turnScale, hop: hop, alarmed: plan.isPanicking)
        }
        drawPellets(&g, lane, geo, stopped: stopped * FB.smooth(since / 0.5), clearEnd: clearEnd)
        if !showFront {
            chomper.drawSide(&g, at: base, part: .front, mouth: mouth, stride: stride, moving: lane.rate,
                             blink: blink, squash: squash, turnScale: turnScale, hop: hop, alarmed: plan.isPanicking)
        }

        // State props
        if let s = lane.session {
            switch s.state {
            case .needsYou: drawQuestionBlock(&g, geo, since: since)
            case .finished: drawFlag(&g, geo, since: since)
            default: break
            }
        }

        if showFront {
            let expr: ChompCharacter.Expression = switch state {
            case _ where plan.isPanicking: .alarmed
            case .needsYou: .impatient
            case .finished: .happy
            case .idle: .sleepy
            case .error: .dizzy
            case .working: .content
            }
            chomper.drawFront(&g, at: base, expression: expr, t: t, since: since, blink: blink,
                              turnScale: turnScale, hop: hop, seed: lane.seed)
        }

        drawBursts(&g, lane, geo)
        if let status { drawStatus(&g, status, geo, since: since) }
        if let c = lane.confettiAt, lane.session?.state == .finished, !plan.isPanicking {
            let flagTop = CGPoint(x: geo.mouthX + 0.5 * geo.laneH, y: geo.floorY - 0.66 * geo.laneH)
            FBConfetti.draw(&g, origin: flagTop, age: now - c - 0.35, seed: lane.seed, scale: Double(u) * 0.85,
                            count: plan.reduceMotion ? 14 : 34, spread: 0.9)
        }
    }

    // MARK: Pellets

    private func drawPellets(_ g: inout GraphicsContext, _ lane: ChompLane, _ geo: ChompLaneGeo,
                             stopped: Double, clearEnd: CGFloat) {
        let u = geo.u
        let sp = ChompSim.spacing
        let firstK = Int(floor(lane.scroll / sp)) + 1
        let lastK = Int(ceil((lane.scroll + Double((geo.rightX - geo.mouthX) / u) + 20) / sp))
        guard lastK >= firstK else { return }
        var pg = g
        pg.clip(to: Path(CGRect(x: geo.bodyX, y: geo.rect.minY, width: geo.rightX + 12 * u - geo.bodyX, height: geo.rect.height)))

        var dots = Path()
        var newest: (k: Int, x: CGFloat, y: CGFloat, p: ChompPellet)?
        for k in firstK...lastK {
            let x = geo.mouthX + CGFloat(Double(k) * sp - lane.scroll) * u
            var fade = FB.smooth(Double((geo.rightX + 8 * u - x) / (90 * u)))
            if stopped > 0 {
                let cleared = 1 - FB.smooth(Double((x - clearEnd) / (40 * u)) + 0.5)
                fade *= (1 - 0.55 * stopped) * (1 - stopped * cleared)
            }
            guard fade > 0.001 else { continue }
            let y = geo.mouthY + CGFloat(sin(t * 2.1 + Double(k) * 0.7)) * 1.6 * u
            if let p = lane.assigned[k] {
                let r = 8.5 * u * CGFloat(1 + 0.07 * sin(t * 4 + Double(k)))
                let c = p.kind.color
                pg.fill(Path(ellipseIn: CGRect(x: x - r * 2.7, y: y - r * 2.7, width: r * 5.4, height: r * 5.4)),
                        with: .radialGradient(Gradient(colors: [c.opacity(0.28 * fade), c.opacity(0)]),
                                              center: CGPoint(x: x, y: y), startRadius: r * 0.6, endRadius: r * 2.7))
                pg.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(c.opacity(fade)))
                let hr = r * 0.36
                pg.fill(Path(ellipseIn: CGRect(x: x - r * 0.36 - hr, y: y - r * 0.36 - hr, width: hr * 2, height: hr * 2)),
                        with: .color(.white.opacity(0.55 * fade)))
                if newest == nil || k > newest!.k { newest = (k, x, y, p) }
            } else {
                switch ChompSim.ambient(k, seed: lane.seed) {
                case .none: break
                case .dot:
                    let s = 4.4 * u
                    if fade > 0.999 {
                        dots.addRoundedRect(in: CGRect(x: x - s / 2, y: y - s / 2, width: s, height: s),
                                            cornerSize: CGSize(width: s * 0.3, height: s * 0.3))
                    } else {
                        pg.fill(Path(roundedRect: CGRect(x: x - s / 2, y: y - s / 2, width: s, height: s), cornerRadius: s * 0.3),
                                with: .color(.white.opacity(0.32 * fade)))
                    }
                case .big:
                    let r = 5.5 * u * CGFloat(1 + 0.12 * sin(t * 5 + Double(k)))
                    let c = plan.palette.top
                    pg.fill(Path(ellipseIn: CGRect(x: x - r * 2.4, y: y - r * 2.4, width: r * 4.8, height: r * 4.8)),
                            with: .radialGradient(Gradient(colors: [c.opacity(0.25 * fade), c.opacity(0)]),
                                                  center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r * 2.4))
                    pg.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(c.opacity(fade)))
                }
            }
        }
        pg.fill(dots, with: .color(.white.opacity(0.32)))

        // The newest event gets its label.
        if plan.labels, stopped < 0.5, let n = newest, n.x > geo.mouthX + 30 * u {
            let fadeIn = FB.smooth(Double((geo.rightX + 8 * u - n.x) / (120 * u)))
            let fadeOut = FB.smooth(Double((n.x - geo.mouthX - 40 * u) / (140 * u)))
            let a = fadeIn * fadeOut
            if a > 0.01 {
                let text = Text("\(n.p.kind.glyph)  \(n.p.text)")
                    .font(Theme.allo(13 * u, .medium))
                    .foregroundStyle(n.p.kind.color.opacity(a))
                let res = g.resolve(text)
                let sz = res.measure(in: CGSize(width: 900 * u, height: 60 * u))
                let ly = n.y - 8.5 * u - 19 * u
                let lx = min(n.x - 9 * u, geo.rightX - sz.width)
                g.draw(res, at: CGPoint(x: lx, y: ly), anchor: .bottomLeading)
                var lead = Path()
                lead.move(to: CGPoint(x: n.x, y: ly + 3 * u))
                lead.addLine(to: CGPoint(x: n.x, y: n.y - 8.5 * u - 4 * u))
                g.stroke(lead, with: .color(n.p.kind.color.opacity(0.4 * a)), lineWidth: 1 * u)
            }
        }
    }

    private func drawBursts(_ g: inout GraphicsContext, _ lane: ChompLane, _ geo: ChompLaneGeo) {
        let u = geo.u
        let origin = CGPoint(x: geo.mouthX - 0.06 * geo.B, y: geo.mouthY)
        for b in lane.bursts {
            let age = sim.now - b.time
            guard age >= 0, age < 1 else { continue }
            let n = b.big ? 8 : 3
            let life = b.big ? 0.75 : 0.45
            guard age < life else { continue }
            let fade = 1 - FB.smooth(age / life)
            let col = b.color ?? plan.palette.top.opacity(0.9)
            for i in 0..<n {
                let a = -Double.pi * (0.12 + 0.76 * FB.hash(b.slot, i))
                let speed = (70 + 110 * FB.hash(b.slot, i + 20)) * Double(u) * (b.big ? 1 : 0.7)
                let px = origin.x + CGFloat(cos(a) * speed * age) - CGFloat(age * 40) * u
                let py = origin.y + CGFloat(sin(a) * speed * age + 0.5 * 520 * Double(u) * age * age)
                let s = (2.2 + 2.2 * FB.hash(b.slot, i + 40)) * u
                g.fill(Path.rotatedRect(center: CGPoint(x: px, y: py), size: CGSize(width: s, height: s), angle: age * 9 + Double(i)),
                       with: .color(col.opacity(fade)))
            }
            if b.big {
                let rp = FB.clamp(age / 0.35)
                let rr = (9 + 24 * rp) * u
                g.stroke(Path(ellipseIn: CGRect(x: origin.x - rr, y: origin.y - rr, width: rr * 2, height: rr * 2)),
                         with: .color(col.opacity(0.55 * (1 - rp))), lineWidth: 1.6 * u)
            }
        }
    }

    // MARK: Props

    private func drawQuestionBlock(_ g: inout GraphicsContext, _ geo: ChompLaneGeo, since: Double) {
        let u = geo.u
        let S = 0.4 * geo.laneH
        let cx = geo.mouthX + 0.56 * geo.laneH
        let drop = plan.reduceMotion ? 0 : (1 - FB.bounceOut(since / 0.75)) * Double(geo.laneH) * 0.95
        let bob = CGFloat(sin(t * 2.4)) * 2.4 * u
        let cy = geo.floorY - 0.2 * geo.laneH - S / 2 + bob - CGFloat(drop)
        let appear = FB.smooth(since / 0.12)
        var bg = g
        bg.opacity = appear
        bg.clip(to: Path(CGRect(x: geo.rect.minX, y: geo.rect.minY - 2, width: geo.rect.width, height: geo.rect.height + 4)))

        // Glow
        let glowR = S * (1.05 + 0.08 * CGFloat(sin(t * 3)))
        let amber = Theme.Night.warning
        bg.fill(Path(ellipseIn: CGRect(x: cx - glowR, y: cy - glowR, width: glowR * 2, height: glowR * 2)),
                with: .radialGradient(Gradient(colors: [amber.opacity(0.32), amber.opacity(0)]),
                                      center: CGPoint(x: cx, y: cy), startRadius: S * 0.3, endRadius: glowR))
        // Shadow on the floor
        let sh = S * 0.8 * (1 - 0.1 * CGFloat(sin(t * 2.4)))
        bg.fill(Path(ellipseIn: CGRect(x: cx - sh / 2, y: geo.floorY - 2.5 * u, width: sh, height: 5 * u)),
                with: .color(.black.opacity(0.45)))
        // Block: darker lip, face, rivets, glyph
        let rect = CGRect(x: cx - S / 2, y: cy - S / 2, width: S, height: S)
        bg.fill(Path.roundedRect(rect.offsetBy(dx: 0, dy: S * 0.08), S * 0.24), with: .color(Color(hex: "9A6B1E")))
        bg.fill(Path.roundedRect(rect, S * 0.24),
                with: .linearGradient(Gradient(colors: [Color(hex: "F5D27F"), Color(hex: "E0A845")]),
                                      startPoint: CGPoint(x: cx, y: rect.minY), endPoint: CGPoint(x: cx, y: rect.maxY)))
        bg.fill(Path.roundedRect(CGRect(x: rect.minX + S * 0.16, y: rect.minY + S * 0.07, width: S * 0.5, height: S * 0.07), S * 0.035),
                with: .color(.white.opacity(0.45)))
        for (dx, dy) in [(-1.0, -1.0), (1, -1), (-1, 1), (1, 1)] {
            let rc = CGPoint(x: cx + CGFloat(dx) * S * 0.33, y: cy + CGFloat(dy) * S * 0.33)
            let rr = S * 0.045
            bg.fill(Path(ellipseIn: CGRect(x: rc.x - rr, y: rc.y - rr, width: rr * 2, height: rr * 2)),
                    with: .color(Color(hex: "B07D25").opacity(0.75)))
        }
        let q = Text("?").font(Theme.allo(S * 0.66, .black)).foregroundStyle(Color(hex: "5A3A0C"))
        bg.draw(q, at: CGPoint(x: cx, y: cy + S * 0.02), anchor: .center)
    }

    private func drawFlag(_ g: inout GraphicsContext, _ geo: ChompLaneGeo, since: Double) {
        let u = geo.u
        let px = geo.mouthX + 0.5 * geo.laneH
        let poleH = 0.66 * geo.laneH
        let drop = plan.reduceMotion ? 0 : (1 - FB.bounceOut(since / 0.7)) * Double(geo.laneH)
        var fg = g
        fg.opacity = FB.smooth(since / 0.1)
        fg.clip(to: Path(CGRect(x: geo.rect.minX, y: geo.rect.minY - 2, width: geo.rect.width, height: geo.rect.height + 4)))
        fg.translateBy(x: 0, y: -CGFloat(drop))
        let top = geo.floorY - poleH
        // Base + pole
        fg.fill(Path(ellipseIn: CGRect(x: px - 9 * u, y: geo.floorY - 3 * u, width: 18 * u, height: 6 * u)),
                with: .color(.black.opacity(0.4)))
        fg.fill(Path.roundedRect(CGRect(x: px - 1.6 * u, y: top, width: 3.2 * u, height: poleH), 1.6 * u),
                with: .color(Color(hex: "D9D9DE")))
        fg.fill(Path(ellipseIn: CGRect(x: px - 3.4 * u, y: top - 3.4 * u, width: 6.8 * u, height: 6.8 * u)),
                with: .color(Theme.Night.success))
        // Checkered cloth, waving.
        let cols = 5, rows = 3
        let fw = 0.32 * geo.laneH, fh = 0.2 * geo.laneH
        let cw = fw / CGFloat(cols), ch = fh / CGFloat(rows)
        var dark = Path(), light = Path()
        for c in 0..<cols {
            let f = CGFloat(c) / CGFloat(cols)
            let wave = CGFloat(sin(t * 4.2 - Double(c) * 0.9)) * 0.028 * geo.laneH * (0.25 + f)
            for r in 0..<rows {
                let rect = CGRect(x: px + 1.6 * u + CGFloat(c) * cw, y: top + 2 * u + CGFloat(r) * ch + wave, width: cw + 0.4, height: ch + 0.4)
                if (c + r) % 2 == 0 { light.addRect(rect) } else { dark.addRect(rect) }
            }
        }
        fg.fill(light, with: .color(Color(hex: "F2F2F2")))
        fg.fill(dark, with: .color(Color(hex: "26262B")))
    }

    struct StatusLayout {
        let x: CGFloat
        let width: CGFloat
        let title: GraphicsContext.ResolvedText
        let detail: GraphicsContext.ResolvedText?
    }

    /// Where a stopped lane's status text goes (right of its prop), resolved and measured.
    private func statusLayout(_ g: inout GraphicsContext, _ s: AgentSession, _ geo: ChompLaneGeo, since: Double) -> StatusLayout? {
        guard s.state != .working, !plan.isPreview else { return nil }
        let u = geo.u
        let x: CGFloat = switch s.state {
        case .needsYou: geo.mouthX + 0.76 * geo.laneH + 22 * u
        case .finished: geo.mouthX + 0.82 * geo.laneH + 26 * u
        default: geo.mouthX + 0.42 * geo.laneH
        }
        let maxW = geo.rightX - x
        guard maxW > 60 * u else { return nil }
        let last = s.recentEvents.last.map { FBEventKind.shortText($0, max: 80) }
        let (title, detail, color): (String, String?, Color) = switch s.state {
        case .needsYou: (s.pendingQuestions.first?.title ?? "Needs you", s.pendingQuestions.first?.detail ?? last, Theme.Night.warning)
        case .finished: ("Finished", last, Theme.Night.success)
        case .idle: ("Resting", last, Theme.Night.muted)
        case .error: ("Hit an error", last, Theme.Night.danger)
        case .working: ("", nil, .clear)
        }
        let a = FB.smooth((since - 0.25) / 0.35)
        let t1 = g.resolve(Text(FB.clip(title, 48)).font(Theme.allo(15 * u, .semibold)).foregroundStyle(color.opacity(a)))
        let box = CGSize(width: maxW, height: 40 * u)
        let w1 = t1.measure(in: box).width
        var t2: GraphicsContext.ResolvedText?
        var w2: CGFloat = 0
        if let detail, !detail.isEmpty {
            let r = g.resolve(Text(FB.clip(detail, 80)).font(Theme.allo(13 * u, .regular))
                .foregroundStyle(Theme.Night.secondary.opacity(0.85 * a)))
            w2 = r.measure(in: box).width
            t2 = r
        }
        return StatusLayout(x: x, width: min(max(w1, w2), maxW), title: t1, detail: t2)
    }

    private func drawStatus(_ g: inout GraphicsContext, _ st: StatusLayout, _ geo: ChompLaneGeo, since: Double) {
        let u = geo.u
        let slide = CGFloat(1 - FB.smooth((since - 0.25) / 0.35)) * 14 * u
        let y = geo.mouthY + 2 * u
        g.draw(st.title, in: CGRect(x: st.x + slide, y: y - 22 * u, width: st.width + 2, height: 22 * u))
        if let d = st.detail {
            g.draw(d, in: CGRect(x: st.x + slide, y: y + 1 * u, width: st.width + 2, height: 20 * u))
        }
    }
}

// MARK: - The character

/// The Chomp chip: a rounded silicon die with a hinged jaw, pin "hair", pin teeth, one big eye in
/// profile (two from the front) and two tiny feet. Origin is the floor under its body center.
struct ChompCharacter {
    let pal: FBCharacterPalette
    let B: CGFloat
    let u: CGFloat

    enum Part { case back, front }
    enum Expression { case content, impatient, happy, sleepy, dizzy, alarmed }

    var W: CGFloat { B * 1.16 }
    var footH: CGFloat { B * 0.2 }
    var bodyBottom: CGFloat { -footH }
    var bodyTop: CGFloat { -footH - B }
    var radius: CGFloat { B * 0.32 }

    private func bodyFill(_ top: CGFloat, _ bottom: CGFloat) -> GraphicsContext.Shading {
        .linearGradient(Gradient(colors: pal.bodyGradient), startPoint: CGPoint(x: -W * 0.3, y: top),
                        endPoint: CGPoint(x: W * 0.3, y: bottom))
    }

    // MARK: Side (running, facing right)

    func drawSide(_ g: inout GraphicsContext, at p: CGPoint, part: Part, mouth m: Double, stride: Double, moving: Double,
                  blink: Double, squash: Double, turnScale: CGFloat, hop: CGFloat, alarmed: Bool) {
        var c = g
        let mv = CGFloat(FB.clamp(moving))
        let bob = -abs(CGFloat(sin(stride))) * 0.06 * B * mv - hop
        c.translateBy(x: p.x, y: p.y)
        if part == .back {
            // Shadow stays on the floor.
            let sw = W * 0.95 * (1 - 0.08 * abs(CGFloat(sin(stride))) * mv)
            c.fill(Path(ellipseIn: CGRect(x: -sw / 2, y: -B * 0.05, width: sw, height: B * 0.1)), with: .color(.black.opacity(0.5)))
        }
        c.scaleBy(x: turnScale * CGFloat(1 + 0.09 * squash), y: CGFloat(1 - 0.09 * squash))

        // The head is a lid: it flips up around a hinge at the back while the jaw barely drops.
        let splitY = bodyTop + B * 0.56
        let hinge = CGPoint(x: -W / 2 + W * 0.12, y: splitY)
        let lowerT = CGAffineTransform(translationX: hinge.x, y: hinge.y + bob).rotated(by: m * 0.1).translatedBy(x: -hinge.x, y: -hinge.y)
        let upperT = CGAffineTransform(translationX: hinge.x, y: hinge.y + bob).rotated(by: -m * 0.6).translatedBy(x: -hinge.x, y: -hinge.y)

        if part == .back {
            // Legs + feet (running cycle).
            let feetColor = pal.shade
            for i in 0..<2 {
                let ph = stride + Double(i) * .pi
                let fx = -W * 0.1 + W * 0.2 * CGFloat(cos(ph)) * mv + (i == 0 ? -W * 0.08 : W * 0.08) * (1 - mv)
                let lift = max(0, CGFloat(sin(ph))) * 0.16 * B * mv
                let foot = CGPoint(x: fx, y: -B * 0.06 - lift)
                let hip = CGPoint(x: (i == 0 ? -W * 0.14 : W * 0.06), y: bodyBottom - B * 0.04 + bob)
                var leg = Path()
                leg.move(to: hip)
                leg.addLine(to: CGPoint(x: foot.x, y: foot.y))
                let back = i == 0 ? 0.6 : 1.0
                c.stroke(leg, with: .color(pal.metal.opacity(0.85 * back)), style: StrokeStyle(lineWidth: B * 0.06, lineCap: .round))
                let fw = B * 0.3, fh = B * 0.14
                c.fill(Path(roundedRect: CGRect(x: foot.x - fw * 0.35, y: foot.y - fh / 2, width: fw, height: fh), cornerRadius: fh / 2),
                       with: .color(feetColor.opacity(back)))
            }
            // Mouth interior + tongue.
            if m > 0.02 {
                let front = W / 2 - B * 0.02
                let up = CGPoint(x: front, y: splitY).applying(upperT)
                let lo = CGPoint(x: front, y: splitY).applying(lowerT)
                let h = CGPoint(x: hinge.x + W * 0.06, y: hinge.y).applying(lowerT)
                var inner = Path()
                inner.move(to: h)
                inner.addLine(to: up)
                inner.addQuadCurve(to: lo, control: CGPoint(x: (up.x + lo.x) / 2 - B * 0.05, y: (up.y + lo.y) / 2))
                inner.closeSubpath()
                c.fill(inner, with: .color(Color(hex: "1A1320")))
                let tongue = Path(ellipseIn: CGRect(x: W * 0.02, y: splitY - B * 0.07, width: W * 0.36, height: B * 0.14)).applying(lowerT)
                c.fill(tongue, with: .color(Color(hex: "E3848C")))
            }
            // Lower jaw.
            let lower = UnevenRoundedRectangle(cornerRadii: .init(topLeading: 0, bottomLeading: radius * 0.9,
                                                                  bottomTrailing: radius * 0.9, topTrailing: B * 0.06),
                                               style: .continuous)
                .path(in: CGRect(x: -W / 2, y: splitY, width: W, height: bodyBottom - splitY))
                .applying(lowerT)
            c.fill(lower, with: bodyFill(bodyTop, bodyBottom))
            var shade = c
            shade.clip(to: lower)
            shade.fill(Path(CGRect(x: -W, y: bodyBottom - B * 0.14, width: W * 2, height: B * 0.4)).applying(lowerT),
                       with: .color(pal.shade.opacity(0.55)))
            // Bottom tooth.
            let tooth = Path(roundedRect: CGRect(x: W / 2 - B * 0.28, y: splitY - B * 0.07, width: B * 0.07, height: B * 0.08),
                             cornerRadius: B * 0.015).applying(lowerT)
            c.fill(tooth, with: .color(pal.metal))
            return
        }

        // Front half: pins (hair + teeth), upper jaw, eye.
        var pins = Path()
        for x in [-0.24, -0.04, 0.16] {
            pins.addRoundedRect(in: CGRect(x: W * CGFloat(x), y: bodyTop - B * 0.11, width: B * 0.085, height: B * 0.16),
                                cornerSize: CGSize(width: B * 0.02, height: B * 0.02))
        }
        for x in [W / 2 - B * 0.2, W / 2 - B * 0.38] {
            pins.addRoundedRect(in: CGRect(x: x, y: splitY - B * 0.02, width: B * 0.075, height: B * 0.1),
                                cornerSize: CGSize(width: B * 0.02, height: B * 0.02))
        }
        c.fill(pins.applying(upperT), with: .color(pal.metal))
        let upper = UnevenRoundedRectangle(cornerRadii: .init(topLeading: radius, bottomLeading: 0,
                                                              bottomTrailing: B * 0.06, topTrailing: radius),
                                           style: .continuous)
            .path(in: CGRect(x: -W / 2, y: bodyTop, width: W, height: splitY - bodyTop))
            .applying(upperT)
        c.fill(upper, with: bodyFill(bodyTop, bodyBottom))
        // Rim light + pin-1 dot.
        c.fill(Path(roundedRect: CGRect(x: -W / 2 + W * 0.16, y: bodyTop + B * 0.075, width: W * 0.42, height: B * 0.065),
                    cornerRadius: B * 0.03).applying(upperT), with: .color(pal.highlight.opacity(0.55)))
        let dotR = B * 0.045
        c.fill(Path(ellipseIn: CGRect(x: -W * 0.33 - dotR, y: bodyTop + B * 0.27 - dotR, width: dotR * 2, height: dotR * 2)).applying(upperT),
               with: .color(pal.shade.opacity(0.7)))
        // Eye
        let eyeC = CGPoint(x: W * 0.17, y: bodyTop + B * 0.29)
        let ew = B * (alarmed ? 0.3 : 0.25), eh = B * (alarmed ? 0.36 : 0.3) * CGFloat(1 - 0.88 * blink)
        c.fill(Path(roundedRect: CGRect(x: eyeC.x - ew / 2, y: eyeC.y - eh / 2, width: ew, height: eh), cornerRadius: min(ew, eh) * 0.45)
                .applying(upperT), with: .color(Color(hex: "FBFAFD")))
        if blink < 0.6 {
            let pr = B * (alarmed ? 0.05 : 0.085)
            let pc = CGPoint(x: eyeC.x + B * 0.04, y: eyeC.y + B * 0.01)
            c.fill(Path(ellipseIn: CGRect(x: pc.x - pr, y: pc.y - pr, width: pr * 2, height: pr * 2)).applying(upperT),
                   with: .color(pal.ink))
            let hr = pr * 0.32
            c.fill(Path(ellipseIn: CGRect(x: pc.x - pr * 0.35 - hr, y: pc.y - pr * 0.4 - hr, width: hr * 2, height: hr * 2)).applying(upperT),
                   with: .color(.white.opacity(0.9)))
        }
        // A determined brow while munching.
        var brow = Path()
        brow.move(to: CGPoint(x: eyeC.x - ew * 0.55, y: eyeC.y - eh / 2 - B * 0.09))
        brow.addLine(to: CGPoint(x: eyeC.x + ew * 0.5, y: eyeC.y - eh / 2 - B * 0.05))
        c.stroke(brow.applying(upperT), with: .color(pal.ink.opacity(0.55)), style: StrokeStyle(lineWidth: B * 0.045, lineCap: .round))
    }

    // MARK: Front (waiting, finished, idle…)

    func drawFront(_ g: inout GraphicsContext, at p: CGPoint, expression: Expression, t: Double, since: Double,
                   blink: Double, turnScale: CGFloat, hop: CGFloat, seed: Int) {
        var c = g
        c.translateBy(x: p.x, y: p.y)
        var lift: CGFloat = hop
        var breathe: CGFloat = 0
        var shake: CGFloat = 0
        var tap: CGFloat = 0
        switch expression {
        case .impatient:
            tap = max(0, CGFloat(sin(t * 2 * .pi * 2.1))) // foot taps ~2×/s
        case .happy:
            let hp = (t / 3.1).truncatingRemainder(dividingBy: 1)
            lift += hp < 0.22 ? CGFloat(sin(hp / 0.22 * .pi)) * 0.22 * B : 0
        case .sleepy:
            breathe = CGFloat(sin(t * 1.3)) * 0.025
        case .dizzy:
            shake = CGFloat(sin(t * 9)) * 0.03 * B
        case .alarmed:
            shake = CGFloat(sin(t * 61)) * 0.04 * B
            lift += abs(CGFloat(sin(t * 7))) * 0.08 * B
        case .content:
            breathe = CGFloat(sin(t * 2)) * 0.015
        }

        // Shadow
        let sw = W * 0.92 * (1 - lift / B * 0.5)
        c.fill(Path(ellipseIn: CGRect(x: -sw / 2, y: -B * 0.05, width: sw, height: B * 0.1)), with: .color(.black.opacity(0.5)))
        c.scaleBy(x: turnScale, y: 1)
        c.translateBy(x: shake, y: 0)

        // Legs + feet
        for i in 0..<2 {
            let side: CGFloat = i == 0 ? -1 : 1
            let fl = (i == 1 ? tap * 0.13 * B : 0)
            let foot = CGPoint(x: side * W * 0.22, y: -B * 0.065 - fl)
            var leg = Path()
            leg.move(to: CGPoint(x: side * W * 0.18, y: bodyBottom - B * 0.04 - lift))
            leg.addLine(to: CGPoint(x: foot.x, y: foot.y - lift * (i == 1 ? 0.6 : 0.6)))
            c.stroke(leg, with: .color(pal.metal.opacity(0.85)), style: StrokeStyle(lineWidth: B * 0.06, lineCap: .round))
            let fw = B * 0.26, fh = B * 0.13
            c.fill(Path(roundedRect: CGRect(x: foot.x - fw / 2 + side * B * 0.03, y: foot.y - fh / 2 - lift * 0.6, width: fw, height: fh),
                        cornerRadius: fh / 2), with: .color(pal.shade))
        }

        c.translateBy(x: 0, y: -lift - tap * 0.012 * B)
        c.scaleBy(x: 1 + breathe, y: 1 - breathe)

        // Pins on top
        var pins = Path()
        for x in [-0.27, -0.035, 0.2] {
            pins.addRoundedRect(in: CGRect(x: W * CGFloat(x), y: bodyTop - B * 0.11, width: B * 0.085, height: B * 0.16),
                                cornerSize: CGSize(width: B * 0.02, height: B * 0.02))
        }
        // Side pins, like a DIP package.
        for y in [0.38, 0.62] {
            pins.addRoundedRect(in: CGRect(x: -W / 2 - B * 0.07, y: bodyTop + B * CGFloat(y) - B * 0.035, width: B * 0.1, height: B * 0.07),
                                cornerSize: CGSize(width: B * 0.02, height: B * 0.02))
            pins.addRoundedRect(in: CGRect(x: W / 2 - B * 0.03, y: bodyTop + B * CGFloat(y) - B * 0.035, width: B * 0.1, height: B * 0.07),
                                cornerSize: CGSize(width: B * 0.02, height: B * 0.02))
        }
        c.fill(pins, with: .color(pal.metal))

        // Body
        let body = Path(roundedRect: CGRect(x: -W / 2, y: bodyTop, width: W, height: B), cornerRadius: radius, style: .continuous)
        c.fill(body, with: bodyFill(bodyTop, bodyBottom))
        var shade = c
        shade.clip(to: body)
        shade.fill(Path(CGRect(x: -W, y: bodyBottom - B * 0.13, width: W * 2, height: B * 0.2)), with: .color(pal.shade.opacity(0.5)))
        c.fill(Path(roundedRect: CGRect(x: -W * 0.3, y: bodyTop + B * 0.07, width: W * 0.42, height: B * 0.065), cornerRadius: B * 0.03),
               with: .color(pal.highlight.opacity(0.55)))

        // Face
        let eyeY = bodyTop + B * 0.42
        let ink = pal.ink
        let lw = B * 0.06
        // Glance toward the "?" block every few seconds while waiting.
        let gl = (t / 3.7 + Double(seed % 7) * 0.13).truncatingRemainder(dividingBy: 1)
        let glance = expression == .impatient ? CGFloat(FB.smooth(gl / 0.06) * (1 - FB.smooth((gl - 0.22) / 0.06))) : 0
        for side in [-1.0, 1.0] {
            let ex = CGFloat(side) * W * 0.21
            switch expression {
            case .happy:
                var arc = Path()
                arc.addArc(center: CGPoint(x: ex, y: eyeY + B * 0.05), radius: B * 0.09, startAngle: .degrees(200), endAngle: .degrees(340), clockwise: false)
                c.stroke(arc, with: .color(ink), style: StrokeStyle(lineWidth: lw, lineCap: .round))
            case .sleepy:
                var arc = Path()
                arc.addArc(center: CGPoint(x: ex, y: eyeY - B * 0.02), radius: B * 0.085, startAngle: .degrees(20), endAngle: .degrees(160), clockwise: false)
                c.stroke(arc, with: .color(ink), style: StrokeStyle(lineWidth: lw, lineCap: .round))
            case .dizzy:
                var x = Path()
                let s = B * 0.075
                x.move(to: CGPoint(x: ex - s, y: eyeY - s)); x.addLine(to: CGPoint(x: ex + s, y: eyeY + s))
                x.move(to: CGPoint(x: ex + s, y: eyeY - s)); x.addLine(to: CGPoint(x: ex - s, y: eyeY + s))
                c.stroke(x, with: .color(ink), style: StrokeStyle(lineWidth: lw, lineCap: .round))
            case .content, .impatient, .alarmed:
                let big: CGFloat = expression == .alarmed ? 1.3 : 1
                let ew = B * 0.2 * big, eh = B * 0.3 * big * CGFloat(expression == .alarmed ? 1 : 1 - 0.88 * blink)
                c.fill(Path(roundedRect: CGRect(x: ex - ew / 2, y: eyeY - eh / 2, width: ew, height: eh), cornerRadius: min(ew, eh) * 0.45),
                       with: .color(Color(hex: "FBFAFD")))
                if expression == .alarmed || blink < 0.6 {
                    let pr = B * (expression == .alarmed ? 0.04 : 0.07)
                    let pc = CGPoint(x: ex + glance * B * 0.05, y: eyeY + B * 0.02 - glance * B * 0.01)
                    c.fill(Path(ellipseIn: CGRect(x: pc.x - pr, y: pc.y - pr, width: pr * 2, height: pr * 2)), with: .color(ink))
                    let hr = pr * 0.32
                    c.fill(Path(ellipseIn: CGRect(x: pc.x - pr * 0.35 - hr, y: pc.y - pr * 0.4 - hr, width: hr * 2, height: hr * 2)),
                           with: .color(.white.opacity(0.9)))
                }
                if expression == .impatient {
                    // Brows: inner ends down.
                    var brow = Path()
                    let by = eyeY - eh / 2 - B * 0.07
                    brow.move(to: CGPoint(x: ex - CGFloat(side) * B * 0.12, y: by - B * 0.045 + B * 0.04))
                    brow.addLine(to: CGPoint(x: ex + CGFloat(side) * B * 0.1, y: by - B * 0.045))
                    c.stroke(brow, with: .color(ink.opacity(0.8)), style: StrokeStyle(lineWidth: B * 0.05, lineCap: .round))
                }
            }
        }
        // Cheeks
        for side in [-1.0, 1.0] {
            let cx = CGFloat(side) * W * 0.34
            c.fill(Path(ellipseIn: CGRect(x: cx - B * 0.075, y: bodyTop + B * 0.6, width: B * 0.15, height: B * 0.08)),
                   with: .color(pal.cheek.opacity(expression == .happy ? 0.75 : 0.5)))
        }
        // Mouth
        let my = bodyTop + B * 0.7
        var mouth = Path()
        switch expression {
        case .happy:
            mouth.move(to: CGPoint(x: -B * 0.13, y: my - B * 0.02))
            mouth.addQuadCurve(to: CGPoint(x: B * 0.13, y: my - B * 0.02), control: CGPoint(x: 0, y: my + B * 0.17))
            mouth.closeSubpath()
            c.fill(mouth, with: .color(Color(hex: "1A1320")))
            c.fill(Path(ellipseIn: CGRect(x: -B * 0.06, y: my + B * 0.04, width: B * 0.12, height: B * 0.05)), with: .color(Color(hex: "E3848C")))
        case .impatient:
            mouth.move(to: CGPoint(x: -B * 0.07, y: my + B * 0.01))
            mouth.addLine(to: CGPoint(x: B * 0.08, y: my - B * 0.01))
            c.stroke(mouth, with: .color(ink), style: StrokeStyle(lineWidth: lw * 0.9, lineCap: .round))
        case .sleepy:
            let r = B * (0.035 + 0.012 * CGFloat(sin(t * 1.3)))
            c.fill(Path(ellipseIn: CGRect(x: -r, y: my - r, width: r * 2, height: r * 2.2)), with: .color(Color(hex: "1A1320")))
        case .dizzy:
            mouth.move(to: CGPoint(x: -B * 0.1, y: my))
            mouth.addCurve(to: CGPoint(x: B * 0.1, y: my), control1: CGPoint(x: -B * 0.03, y: my - B * 0.07), control2: CGPoint(x: B * 0.03, y: my + B * 0.07))
            c.stroke(mouth, with: .color(ink), style: StrokeStyle(lineWidth: lw * 0.9, lineCap: .round))
        case .alarmed:
            c.fill(Path(ellipseIn: CGRect(x: -B * 0.07, y: my - B * 0.06, width: B * 0.14, height: B * 0.16)), with: .color(Color(hex: "1A1320")))
        case .content:
            mouth.move(to: CGPoint(x: -B * 0.08, y: my))
            mouth.addQuadCurve(to: CGPoint(x: B * 0.08, y: my), control: CGPoint(x: 0, y: my + B * 0.08))
            c.stroke(mouth, with: .color(ink), style: StrokeStyle(lineWidth: lw * 0.9, lineCap: .round))
        }

        // Extras above the head (unscaled by the body breathe, but in body space).
        switch expression {
        case .sleepy:
            for i in 0..<3 {
                let age = (t / 3 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                let s = B * CGFloat(0.12 + 0.1 * age)
                let zx = W * 0.4 + CGFloat(age) * B * 0.5 + CGFloat(sin(age * 6)) * B * 0.06
                let zy = bodyTop - B * 0.1 - CGFloat(age) * B * 1.0
                var z = Path()
                z.move(to: CGPoint(x: zx, y: zy)); z.addLine(to: CGPoint(x: zx + s, y: zy))
                z.addLine(to: CGPoint(x: zx, y: zy + s)); z.addLine(to: CGPoint(x: zx + s, y: zy + s))
                let a = sin(age * .pi) * 0.7
                c.stroke(z, with: .color(Theme.Night.secondary.opacity(a)), style: StrokeStyle(lineWidth: B * 0.04, lineCap: .round, lineJoin: .round))
            }
        case .alarmed, .dizzy:
            let col = expression == .alarmed ? Theme.Night.danger : Theme.Night.danger.opacity(0.85)
            let by = bodyTop - B * 0.42 + CGFloat(abs(sin(t * 6))) * -B * 0.06
            let r = B * 0.16
            c.fill(Path(ellipseIn: CGRect(x: W * 0.36 - r, y: by - r, width: r * 2, height: r * 2)), with: .color(col))
            c.draw(Text("!").font(Theme.allo(B * 0.24, .black)).foregroundStyle(Color(hex: "2A0D0A")),
                   at: CGPoint(x: W * 0.36, y: by), anchor: .center)
        default: break
        }
    }
}

private extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(self, lo), hi) }
}
