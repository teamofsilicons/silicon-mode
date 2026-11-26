import SwiftUI
import SiliconModeKit

/// Desk: Silly, a little silicon chip, works at a desk in a cozy room. One monitor per agent shows
/// that agent's real recent events scrolling by; the window behind follows the real time of day.
/// Silly types while agents work, spins around holding a "?" sign when one needs you, throws a tiny
/// party when one finishes, and sips coffee and stretches when everything is quiet.
enum DeskFace {
    static let descriptor = FaceDescriptor(
        id: "desk",
        name: "Desk",
        summary: "Silly the silicon mascot works away at a desk full of screens.",
        options: [
            FaceOptionSpec(key: "room", label: "Room",
                           kind: .choice(options: [("night", "Night"), ("dusk", "Dusk"), ("studio", "Studio")], default: "night")),
            FaceOptionSpec(key: "mascot", label: "Mascot color",
                           kind: .choice(options: FBStyle.characterChoices, default: "silicon")),
            FaceOptionSpec(key: "monitorText", label: "Show text on monitors", kind: .toggle(default: true)),
        ],
        make: { ctx in AnyView(DeskFaceView(ctx: ctx)) }
    )

    static let maxMonitors = 6
}

// MARK: - View

struct DeskFaceView: View {
    let ctx: FaceContext
    @State private var sim = DeskSim()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let plan = DeskPlan(ctx: ctx)
        // The whole room drifts a few points every few seconds so nothing sits on the same pixels for
        // hours; the static layers just move (no redraw).
        TimelineView(.periodic(from: .distantPast, by: DeskFaceView.driftStep)) { tl in
            let d = reduceMotion ? .zero : DeskFaceView.drift(FaceBClock.seconds(tl.date))
            layers(plan)
                .padding(-DeskFaceView.bleed)
                .offset(x: d.x, y: d.y)
                .animation(.linear(duration: DeskFaceView.driftStep), value: d)
        }
        .background(Theme.Night.background)
        .clipped()
    }

    static let bleed: CGFloat = 10
    static let driftStep: Double = 6

    static func drift(_ t: Double) -> CGPoint {
        let k = floor(t / driftStep) * driftStep
        return CGPoint(x: sin(k / 97) * 7, y: cos(k / 131) * 5)
    }

    @ViewBuilder
    private func layers(_ plan: DeskPlan) -> some View {
        ZStack {
            DeskSkyLayer(preview: ctx.isPreview)
            DeskRoomLayer(theme: plan.theme, showClock: plan.showClock).equatable()
            TimelineView(.animation(minimumInterval: ctx.isPreview ? 1.0 / 30 : ctx.frameInterval)) { tl in
                let t = FaceBClock.seconds(tl.date)
                let wall = FaceBClock.wallDate(tl.date)
                let _ = sim.advance(to: t, plan: plan, reduceMotion: reduceMotion)
                Canvas { g, size in
                    DeskPainter(sim: sim, plan: plan, t: t, wall: wall, reduceMotion: reduceMotion).draw(&g, size: size)
                } symbols: {
                    ForEach(plan.marks, id: \.self) { p in
                        ProviderMark(provider: p, size: 15).tag("mark:" + p)
                    }
                    ForEach(plan.screens) { spec in
                        DeskScreenLines(session: spec.session, width: spec.width, showText: plan.showText)
                            .equatable()
                            .tag("text:" + spec.id)
                    }
                }
            }
        }
    }
}

/// The text a monitor shows: a prompt line plus the agent's recent events, newest last.
private struct DeskScreenLines: View, Equatable {
    let session: AgentSession
    let width: CGFloat
    let showText: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            line(glyph: "~", glyphColor: Theme.Night.accent,
                 text: "\(session.projectName ?? "agent") · \(ProviderCatalog.info(for: session.provider).name)",
                 textColor: Theme.Night.muted)
            ForEach(session.recentEvents.suffix(10)) { e in
                let k = FBEventKind(e)
                line(glyph: k.glyph, glyphColor: k.color, text: FB.clip(e.text, 90),
                     textColor: k == .message || k == .user ? Theme.Night.foreground.opacity(0.85) : Theme.Night.secondary)
            }
        }
        .frame(width: max(width, 1), alignment: .leading)
    }

    @ViewBuilder
    private func line(glyph: String, glyphColor: Color, text: String, textColor: Color) -> some View {
        HStack(alignment: .center, spacing: 7) {
            if showText {
                Text(glyph).foregroundStyle(glyphColor).frame(width: 9, alignment: .leading)
                Text(text).foregroundStyle(textColor).lineLimit(1).truncationMode(.tail)
            } else {
                Capsule().fill(glyphColor.opacity(0.75)).frame(width: 9, height: 7)
                Capsule().fill(textColor.opacity(0.35))
                    .frame(width: min(width - 20, CGFloat(text.count) * 5.6 + 12), height: 7)
            }
        }
        .font(.system(size: 11.5, weight: .regular, design: .monospaced))
        .frame(height: 15)
    }
}

// MARK: - Plan (layout from the context, no time)

struct DeskMonitorSlot {
    let rect: CGRect
    /// One session, or several when extra agents stack up as tabs on the last monitor.
    let sessions: [AgentSession]
    let topRow: Bool

    var screen: CGRect { CGRect(x: rect.minX + 9, y: rect.minY + 9, width: rect.width - 18, height: rect.height - 9 - 26) }
    var body: CGRect {
        let s = screen
        return CGRect(x: s.minX + 12, y: s.minY + 30, width: s.width - 24, height: s.height - 38)
    }

    func current(_ t: Double) -> (AgentSession?, Int) {
        guard !sessions.isEmpty else { return (nil, 0) }
        let i = sessions.count == 1 ? 0 : Int(floor(t / 6)) % sessions.count
        return (sessions[i], i)
    }
}

struct DeskScreenSpec: Identifiable {
    let id: String
    let session: AgentSession
    let width: CGFloat
}

struct DeskPlan {
    let theme: String
    let palette: FBCharacterPalette
    let showText: Bool
    let showClock: Bool
    let isPreview: Bool
    let isPanicking: Bool
    let sessions: [AgentSession]
    let slots: [DeskMonitorSlot]
    let screens: [DeskScreenSpec]
    let marks: [String]
    let counts: AgentCounts

    init(ctx: FaceContext) {
        theme = ctx.string("room", "night")
        palette = FBStyle.character(ctx.string("mascot", "silicon"))
        showText = ctx.bool("monitorText", true) && !ctx.isPreview
        showClock = ctx.showClock
        isPreview = ctx.isPreview
        isPanicking = ctx.isPanicking
        sessions = ctx.sessions
        counts = AgentCounts(ctx.sessions)

        let stable: (AgentSession, AgentSession) -> Bool = {
            let a = $0.startedAt ?? $0.updatedAt, b = $1.startedAt ?? $1.updatedAt
            return a != b ? a < b : $0.id < $1.id
        }
        let ranked = ctx.sessions.sorted {
            $0.state.rank != $1.state.rank ? $0.state.rank < $1.state.rank : $0.updatedAt > $1.updatedAt
        }
        var groups: [[AgentSession]]
        if ranked.count <= DeskFace.maxMonitors {
            groups = ranked.sorted(by: stable).map { [$0] }
        } else {
            groups = ranked.prefix(DeskFace.maxMonitors - 1).sorted(by: stable).map { [$0] }
            groups.append(Array(ranked.dropFirst(DeskFace.maxMonitors - 1)))
        }
        let rects = DeskPlan.monitorRects(max(groups.count, 1))
        if groups.isEmpty { groups = [[]] }
        slots = zip(rects, groups).map { DeskMonitorSlot(rect: $0.0.rect, sessions: $0.1, topRow: $0.0.top) }
        var specs: [DeskScreenSpec] = []
        for slot in slots { for s in slot.sessions { specs.append(DeskScreenSpec(id: s.id, session: s, width: slot.body.width)) } }
        screens = specs
        marks = Array(Set(ctx.sessions.map(\.provider))).sorted()
    }

    /// Monitor bezels in illustration space: one big screen, a pair, a trio, or two rows.
    static func monitorRects(_ n: Int) -> [(rect: CGRect, top: Bool)] {
        switch n {
        case ...1: return [(CGRect(x: 520, y: 196, width: 560, height: 352), false)]
        case 2: return [(CGRect(x: 316, y: 236, width: 460, height: 312), false), (CGRect(x: 824, y: 236, width: 460, height: 312), false)]
        case 3:
            return [(CGRect(x: 262, y: 300, width: 330, height: 248), false), (CGRect(x: 624, y: 278, width: 352, height: 270), false),
                    (CGRect(x: 1008, y: 300, width: 330, height: 248), false)]
        default:
            let bottom = [262.0, 635, 1008].map { (CGRect(x: $0, y: 338, width: 330, height: 210), false) }
            let k = min(n, 6) - 3
            let tops: [Double] = k == 1 ? [635] : k == 2 ? [448, 822] : [262, 635, 1008]
            return tops.map { (CGRect(x: $0, y: 112, width: 330, height: 210), true) } + bottom
        }
    }
}

// MARK: - Simulation (pose transitions + per-monitor scroll)

@MainActor
final class DeskSim {
    private(set) var pose: DeskPose = .chill
    private(set) var poseSince: Double = 0
    private(set) var front = true
    private(set) var prevFront = true
    private(set) var turnAt = -1000.0
    private(set) var celebrateStart = -1000.0
    private(set) var celebrateID: String?
    private(set) var stateSince: [String: Double] = [:]
    private(set) var scroll: [String: Double] = [:]
    private(set) var now: Double = 0
    private var states: [String: AgentState] = [:]
    private var last: Double?

    static let celebrateLength = 4.6

    func advance(to t: Double, plan: DeskPlan, reduceMotion: Bool) {
        var first = false
        if last == nil {
            let start = FaceBClock.replayStart(for: t, history: 8)
            last = start
            now = start
            first = true
            observe(plan, first: true)
        }
        let prev = last ?? t
        var dt = t - prev
        if dt < 0 { dt = 0 }
        if !FaceBClock.isSnapshot { dt = min(dt, 0.1) }
        let speed = reduceMotion ? 6.0 : 13.0
        for s in plan.sessions {
            let base = scroll[s.id] ?? FB.hash(FB.seed(s.id), 1) * 400
            scroll[s.id] = base + (s.state == .working ? speed * dt : 0)
        }
        now = t
        last = t
        if !first { observe(plan, first: false) } else { updatePose(plan, first: false) }
        if scroll.count > plan.sessions.count + 16 || states.count > plan.sessions.count + 16 {
            let live = Set(plan.sessions.map(\.id))
            scroll = scroll.filter { live.contains($0.key) }
            states = states.filter { live.contains($0.key) }
            stateSince = stateSince.filter { live.contains($0.key) }
        }
    }

    private func observe(_ plan: DeskPlan, first: Bool) {
        for s in plan.sessions {
            let old = states[s.id]
            if old == nil || old != s.state {
                states[s.id] = s.state
                stateSince[s.id] = now
                if s.state == .finished && (old != nil || first) {
                    celebrateStart = now
                    celebrateID = s.id
                }
            }
        }
        updatePose(plan, first: first)
    }

    private func updatePose(_ plan: DeskPlan, first: Bool) {
        let c = plan.counts
        let next: DeskPose
        if plan.isPanicking { next = .panic }
        else if c.needsYou > 0 { next = .ask }
        else if now - celebrateStart < DeskSim.celebrateLength { next = .celebrate }
        else if c.working > 0 { next = .typing }
        else { next = .chill }
        guard next != pose || first else { return }
        pose = next
        poseSince = now
        if next.front != front {
            prevFront = front
            front = next.front
            if !first { turnAt = now }
        }
        if first { prevFront = front; turnAt = -1000 }
    }
}

// MARK: - Painter (live layer)

@MainActor
struct DeskPainter {
    let sim: DeskSim
    let plan: DeskPlan
    let t: Double
    let wall: Date
    let reduceMotion: Bool

    func draw(_ g: inout GraphicsContext, size: CGSize) {
        let space = DeskSpace(size)
        var c = g
        space.apply(&c)
        let dark = DeskSky.darkness(wall)

        drawFairyLights(&c, dark: dark)
        if plan.showClock { drawClock(&c) }

        // Light spill from the screens onto wall and desk.
        for slot in plan.slots {
            let (s, _) = slot.current(t)
            let col = glowColor(s)
            let r = slot.rect
            let rad = r.width * 0.95
            c.fill(Path(ellipseIn: CGRect(x: r.midX - rad, y: r.midY - rad * 0.8, width: rad * 2, height: rad * 1.6)),
                   with: .radialGradient(Gradient(colors: [col.opacity(0.13), col.opacity(0)]), center: CGPoint(x: r.midX, y: r.midY),
                                         startRadius: 0, endRadius: rad))
            if !slot.topRow {
                let dc = CGPoint(x: r.midX, y: DeskGeo.deskTop + 6)
                var dg = c
                dg.translateBy(x: dc.x, y: dc.y)
                dg.scaleBy(x: 1, y: 0.12)
                let dr = r.width * 0.6
                dg.fill(Path(ellipseIn: CGRect(x: -dr, y: -dr, width: dr * 2, height: dr * 2)),
                        with: .radialGradient(Gradient(colors: [col.opacity(0.16), col.opacity(0)]), center: .zero, startRadius: 0, endRadius: dr))
            }
        }
        for slot in plan.slots where slot.topRow { drawMonitor(&c, slot) }
        for slot in plan.slots where !slot.topRow { drawMonitor(&c, slot) }

        // Mascot (+ its mug on the desk when its hands are busy).
        let pose = sim.pose
        if pose != .chill { DeskMascot.drawMug(&c, at: DeskGeo.mugOnDesk, t: t, steam: true, scale: 0.9) }
        var turnScale: CGFloat = 1
        var showFront = sim.front
        var hop: CGFloat = 0
        let tp = reduceMotion ? 1 : (sim.now - sim.turnAt) / 0.42
        if tp < 1 {
            if tp < 0.5 { showFront = sim.prevFront; turnScale = CGFloat(1 - 2 * tp) } else { turnScale = CGFloat(2 * tp - 1) }
            hop = CGFloat(sin(tp * .pi)) * 16
        }
        let led: Color
        var blink = 0.5 + 0.5 * sin(t * 2)
        switch pose {
        case .typing: led = Theme.Night.accent; blink = 0.6 + 0.4 * sin(t * 13 + sin(t * 3) * 2)
        case .ask: led = Theme.Night.warning; blink = sin(t * 6) > 0 ? 1 : 0.15
        case .celebrate: led = Theme.Night.success; blink = 0.5 + 0.5 * sin(t * 9)
        case .chill: led = Theme.Night.lavender; blink = 0.5 + 0.5 * sin(t * 1.2)
        case .panic: led = Theme.Night.danger; blink = sin(t * 18) > 0 ? 1 : 0
        }
        let mascot = DeskMascot(pal: plan.palette, t: t, reduceMotion: reduceMotion)
        mascot.draw(&c, at: DeskGeo.seat, DeskMascot.Pose(
            pose: pose, since: sim.now - sim.poseSince, turnScale: turnScale, showFront: showFront, hop: hop,
            led: led, ledBlink: blink, askCount: plan.counts.needsYou, blink: FB.blink(t, seed: 42, period: 3.6)))

        // Confetti: from the finished agent's monitor and over Silly.
        let age = sim.now - sim.celebrateStart
        if age < 3.2 && !plan.isPanicking {
            let n = reduceMotion ? 14 : 40
            if let id = sim.celebrateID, let slot = plan.slots.first(where: { $0.sessions.contains { $0.id == id } }) {
                FBConfetti.draw(&c, origin: CGPoint(x: slot.rect.midX, y: slot.rect.minY + 20), age: age, seed: 7, scale: 1.4, count: n, life: 3.2)
            }
            FBConfetti.draw(&c, origin: CGPoint(x: DeskGeo.seat.x, y: DeskGeo.seat.y - 240), age: age - 0.25, seed: 11, scale: 1.2,
                            count: n, spread: 1.2, life: 3.0)
        }

        // Screen-space finish: panic flash + a soft vignette.
        if plan.isPanicking {
            let a = 0.12 + 0.1 * (0.5 + 0.5 * sin(t * 14))
            g.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.Night.danger.opacity(a)))
        }
        let rr = max(size.width, size.height) * 0.78
        let center = CGPoint(x: size.width / 2, y: size.height * 0.48)
        g.fill(Path(CGRect(origin: .zero, size: size)),
               with: .radialGradient(Gradient(stops: [.init(color: .clear, location: 0.55), .init(color: .black.opacity(0.42), location: 1)]),
                                     center: center, startRadius: 0, endRadius: rr))
    }

    private func glowColor(_ s: AgentSession?) -> Color {
        guard let s else { return Theme.Night.lavender }
        switch s.state {
        case .working: return Color(hex: "8FA8FF")
        case .needsYou: return Theme.Night.warning.opacity(0.7 + 0.3 * (0.5 + 0.5 * sin(t * 3)))
        case .finished: return Theme.Night.success
        case .idle: return Theme.Night.muted.opacity(0.5)
        case .error: return Theme.Night.danger
        }
    }

    // MARK: Monitors

    private func drawMonitor(_ c: inout GraphicsContext, _ slot: DeskMonitorSlot) {
        let r = slot.rect
        let (session, tabIndex) = slot.current(t)
        // Stand / arm
        if slot.topRow {
            c.fill(Path(roundedRect: CGRect(x: r.midX - 6, y: r.maxY - 6, width: 12, height: DeskGeo.deskTop - r.maxY + 6), cornerRadius: 3),
                   with: .color(Color(hex: "22232A")))
        } else {
            c.fill(Path(roundedRect: CGRect(x: r.midX - 13, y: r.maxY - 6, width: 26, height: DeskGeo.deskTop - r.maxY + 10), cornerRadius: 4),
                   with: .color(Color(hex: "24252C")))
            c.fill(Path(roundedRect: CGRect(x: r.midX - 60, y: DeskGeo.deskTop - 3, width: 120, height: 11), cornerRadius: 5.5),
                   with: .color(Color(hex: "2C2D35")))
        }
        // Bezel
        let bezel = Path(roundedRect: r, cornerRadius: 14, style: .continuous)
        c.fill(Path(roundedRect: r.offsetBy(dx: 0, dy: 6), cornerRadius: 14, style: .continuous), with: .color(.black.opacity(0.3)))
        c.fill(bezel, with: .color(Color(hex: "141519")))
        c.stroke(bezel, with: .color(.white.opacity(0.07)), lineWidth: 1.5)

        let scr = slot.screen
        let screenPath = Path(roundedRect: scr, cornerRadius: 6, style: .continuous)
        var sc = c
        sc.clip(to: screenPath)
        let tint = session.map { ProviderCatalog.info(for: $0.provider).color } ?? Theme.Night.lavender
        sc.fill(screenPath, with: .color(Color(hex: "0D0F16")))
        sc.fill(screenPath, with: .linearGradient(Gradient(colors: [tint.opacity(0.09), tint.opacity(0.02)]),
                                                  startPoint: CGPoint(x: scr.minX, y: scr.minY), endPoint: CGPoint(x: scr.maxX, y: scr.maxY)))

        if let session {
            drawScreenContent(&sc, slot, session, tint: tint)
            drawTitleBar(&sc, slot, session, tabIndex: tabIndex)
            drawOverlay(&sc, slot, session)
        } else {
            drawScreensaver(&sc, scr)
        }
        // Glare
        var glare = Path()
        glare.move(to: CGPoint(x: scr.minX, y: scr.minY))
        glare.addLine(to: CGPoint(x: scr.minX + scr.width * 0.45, y: scr.minY))
        glare.addLine(to: CGPoint(x: scr.minX, y: scr.minY + scr.height * 0.7))
        glare.closeSubpath()
        sc.fill(glare, with: .linearGradient(Gradient(colors: [.white.opacity(0.045), .clear]),
                                             startPoint: CGPoint(x: scr.minX, y: scr.minY), endPoint: CGPoint(x: scr.minX + 120, y: scr.minY + 120)))

        // Chin: provider mark + state LED.
        let chinY = r.maxY - 13.5
        if let session, let mark = c.resolveSymbol(id: "mark:" + session.provider) {
            c.draw(mark, at: CGPoint(x: r.midX, y: chinY), anchor: .center)
        }
        if let session {
            let col = Theme.stateColor(session.state)
            let a = session.state == .needsYou ? (sin(t * 6) > 0 ? 1.0 : 0.3) : 0.9
            c.fill(Path(ellipseIn: CGRect(x: r.maxX - 26, y: chinY - 3, width: 6, height: 6)), with: .color(col.opacity(a)))
        }
        // Needs-you: the whole monitor pulses amber.
        if session?.state == .needsYou {
            let a = 0.35 + 0.35 * (0.5 + 0.5 * sin(t * 4))
            c.stroke(Path(roundedRect: r.insetBy(dx: -4, dy: -4), cornerRadius: 17, style: .continuous),
                     with: .color(Theme.Night.warning.opacity(a)), lineWidth: 3)
        }
    }

    private func drawTitleBar(_ c: inout GraphicsContext, _ slot: DeskMonitorSlot, _ s: AgentSession, tabIndex: Int) {
        let scr = slot.screen
        let bar = CGRect(x: scr.minX, y: scr.minY, width: scr.width, height: 22)
        c.fill(Path(bar), with: .color(Color(hex: "0D0F16").opacity(0.85)))
        c.fill(Path(bar), with: .color(.white.opacity(0.045)))
        for (i, hex) in ["F4968C", "E3B55A", "7FC79A"].enumerated() {
            c.fill(Path(ellipseIn: CGRect(x: bar.minX + 9 + CGFloat(i) * 10, y: bar.midY - 3, width: 6, height: 6)),
                   with: .color(Color(hex: hex).opacity(0.55)))
        }
        var titleW = bar.width - 56
        if slot.sessions.count > 1 {
            // Tabs for stacked agents.
            let n = slot.sessions.count
            let tw: CGFloat = 14
            let x0 = bar.maxX - 8 - CGFloat(n) * (tw + 4)
            for i in 0..<n {
                c.fill(Path(roundedRect: CGRect(x: x0 + CGFloat(i) * (tw + 4), y: bar.midY - 2.5, width: tw, height: 5), cornerRadius: 2.5),
                       with: .color(.white.opacity(i == tabIndex ? 0.7 : 0.18)))
            }
            titleW = x0 - bar.minX - 52
        }
        if titleW > 20 {
            c.draw(Text(s.title).font(Theme.allo(11.5, .medium)).foregroundStyle(Color.white.opacity(0.62)),
                   in: CGRect(x: bar.minX + 44, y: bar.minY + 3.5, width: titleW, height: 16))
        }
        if s.state == .working && !reduceMotion {
            // A tiny spinner of dots at the right of the bar.
            let n = 3
            for i in 0..<n {
                let a = 0.25 + 0.75 * max(0, sin(t * 5 - Double(i) * 0.8))
                let x = (slot.sessions.count > 1 ? bar.maxX - 8 - CGFloat(slot.sessions.count) * 18 - 30 : bar.maxX - 34) + CGFloat(i) * 8
                c.fill(Path(ellipseIn: CGRect(x: x, y: bar.midY - 2, width: 4, height: 4)), with: .color(Theme.Night.accent.opacity(a)))
            }
        }
    }

    private func drawScreenContent(_ c: inout GraphicsContext, _ slot: DeskMonitorSlot, _ s: AgentSession, tint: Color) {
        let body = slot.body
        guard let sym = c.resolveSymbol(id: "text:" + s.id) else { return }
        var bc = c
        bc.clip(to: Path(CGRect(x: body.minX - 4, y: body.minY - 4, width: body.width + 8, height: body.height + 8)))
        let dim: Double = switch s.state {
        case .working: 1
        case .needsYou, .finished: 0.16
        case .idle: 0.4
        case .error: 0.6
        }
        bc.opacity = dim
        let h = sym.size.height
        if h + 4 <= body.height {
            // Fits: terminal style, top-aligned, with a blinking cursor after the last line.
            bc.draw(sym, in: CGRect(x: body.minX, y: body.minY, width: sym.size.width, height: h))
            if s.state == .working, sin(t * 2 * .pi * 0.9) > -0.2 {
                bc.fill(Path(CGRect(x: body.minX, y: body.minY + h + 6, width: 8, height: 13)), with: .color(Theme.Night.accent.opacity(0.85)))
            }
        } else {
            // Overflows: an endless, slow scroll through the agent's recent lines.
            let period = Double(h + 21)
            let off = CGFloat((sim.scroll[s.id] ?? 0).truncatingRemainder(dividingBy: period))
            var y = body.minY - off
            while y < body.maxY {
                bc.draw(sym, in: CGRect(x: body.minX, y: y, width: sym.size.width, height: h))
                var sep = Path()
                sep.addRect(CGRect(x: body.minX, y: y + h + 10, width: min(body.width, 120), height: 1))
                bc.fill(sep, with: .color(.white.opacity(0.08)))
                y += CGFloat(period)
            }
            // Fade the top and bottom edges into the screen (base + its faint provider tint).
            let fadeH: CGFloat = 16
            bc.opacity = 1
            let top = CGRect(x: body.minX - 4, y: body.minY - 4, width: body.width + 8, height: fadeH)
            let bottom = CGRect(x: body.minX - 4, y: body.maxY + 4 - fadeH, width: body.width + 8, height: fadeH)
            for col in [Color(hex: "0D0F16"), tint.opacity(0.055)] {
                bc.fill(Path(top), with: .linearGradient(Gradient(colors: [col, col.opacity(0)]),
                                                         startPoint: CGPoint(x: 0, y: top.minY), endPoint: CGPoint(x: 0, y: top.maxY)))
                bc.fill(Path(bottom), with: .linearGradient(Gradient(colors: [col.opacity(0), col]),
                                                            startPoint: CGPoint(x: 0, y: bottom.minY), endPoint: CGPoint(x: 0, y: bottom.maxY)))
            }
        }
    }

    private func drawOverlay(_ c: inout GraphicsContext, _ slot: DeskMonitorSlot, _ s: AgentSession) {
        let body = slot.body
        let scr = slot.screen
        let since = sim.now - (sim.stateSince[s.id] ?? sim.now)
        switch s.state {
        case .needsYou:
            let q = s.pendingQuestions.first
            let compact = body.height < 150
            let cardH: CGFloat = compact ? min(body.height - 4, 98) : 132
            let card = CGRect(x: body.minX + 4, y: body.midY - cardH / 2 + 4, width: body.width - 8, height: cardH)
            let pop = reduceMotion ? 1 : FB.backOut(since / 0.45)
            var cc = c
            cc.translateBy(x: card.midX, y: card.midY)
            cc.scaleBy(x: CGFloat(0.85 + 0.15 * pop), y: CGFloat(0.85 + 0.15 * pop))
            cc.translateBy(x: -card.midX, y: -card.midY)
            cc.opacity = FB.smooth(since / 0.2)
            let cp = Path(roundedRect: card, cornerRadius: 12, style: .continuous)
            cc.fill(cp, with: .color(Color(hex: "241C0E")))
            cc.stroke(cp, with: .color(Theme.Night.warning.opacity(0.55)), lineWidth: 1.5)
            let ic = CGPoint(x: card.minX + 24, y: card.minY + 24)
            cc.fill(Path(ellipseIn: CGRect(x: ic.x - 11, y: ic.y - 11, width: 22, height: 22)), with: .color(Theme.Night.warning))
            cc.draw(Text("?").font(Theme.allo(15, .black)).foregroundStyle(Color(hex: "3A2508")), at: ic, anchor: .center)
            cc.draw(Text(q?.title ?? "Needs you").font(Theme.allo(13.5, .semibold)).foregroundStyle(Theme.Night.warning),
                    in: CGRect(x: ic.x + 18, y: ic.y - 9, width: card.maxX - ic.x - 28, height: 18))
            let detail = q?.detail ?? s.recentEvents.last?.text ?? ""
            if plan.showText {
                cc.draw(Text(FB.clip(detail, 60)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.Night.secondary),
                        in: CGRect(x: card.minX + 14, y: card.minY + 44, width: card.width - 28, height: 16))
            }
            if !compact || card.height > 90 {
                let by = card.maxY - 34
                let opts = q?.options.prefix(2).map(\.label) ?? ["Allow", "Deny"]
                var bx = card.minX + 14
                for (i, label) in (opts.isEmpty ? ["Open"] : opts).enumerated() {
                    let w = CGFloat(label.count) * 7.5 + 28
                    let br = CGRect(x: bx, y: by, width: w, height: 22)
                    let bp = Path(roundedRect: br, cornerRadius: 11)
                    if i == 0 {
                        cc.fill(bp, with: .color(Theme.Night.warning))
                        cc.draw(Text(label).font(Theme.allo(11.5, .semibold)).foregroundStyle(Color(hex: "3A2508")), at: CGPoint(x: br.midX, y: br.midY), anchor: .center)
                    } else {
                        cc.stroke(bp, with: .color(.white.opacity(0.25)), lineWidth: 1)
                        cc.draw(Text(label).font(Theme.allo(11.5, .medium)).foregroundStyle(Color.white.opacity(0.75)), at: CGPoint(x: br.midX, y: br.midY), anchor: .center)
                    }
                    bx += w + 8
                }
            }
        case .finished:
            let center = CGPoint(x: body.midX, y: body.midY - 12)
            let rad: CGFloat = min(26, body.height * 0.18)
            let p = reduceMotion ? 1 : FB.smooth(since / 0.6)
            c.fill(Path(ellipseIn: CGRect(x: center.x - rad * 2.2, y: center.y - rad * 2.2, width: rad * 4.4, height: rad * 4.4)),
                   with: .radialGradient(Gradient(colors: [Theme.Night.success.opacity(0.22), .clear]), center: center, startRadius: rad * 0.5, endRadius: rad * 2.2))
            c.stroke(Path(ellipseIn: CGRect(x: center.x - rad, y: center.y - rad, width: rad * 2, height: rad * 2)),
                     with: .color(Theme.Night.success), lineWidth: 3.5)
            var check = Path()
            check.move(to: CGPoint(x: center.x - rad * 0.45, y: center.y + rad * 0.02))
            check.addLine(to: CGPoint(x: center.x - rad * 0.1, y: center.y + rad * 0.36))
            check.addLine(to: CGPoint(x: center.x + rad * 0.48, y: center.y - rad * 0.32))
            c.stroke(check.trimmedPath(from: 0, to: p), with: .color(Theme.Night.success), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            c.draw(Text("Done").font(Theme.allo(15, .semibold)).foregroundStyle(Theme.Night.foreground),
                   at: CGPoint(x: center.x, y: center.y + rad + 16), anchor: .center)
            if plan.showText, let last = s.recentEvents.last {
                c.draw(Text(FB.clip(last.text, 44)).font(Theme.allo(11.5, .regular)).foregroundStyle(Theme.Night.muted),
                       at: CGPoint(x: center.x, y: center.y + rad + 35), anchor: .center)
            }
        case .idle:
            drawBouncer(&c, scr.insetBy(dx: 6, dy: 28), size: 22, alpha: 0.6)
            c.draw(Text("idle").font(Theme.allo(12, .medium)).foregroundStyle(Theme.Night.muted),
                   at: CGPoint(x: body.maxX - 6, y: body.maxY - 4), anchor: .bottomTrailing)
        case .error:
            let banner = CGRect(x: scr.minX, y: scr.maxY - 30, width: scr.width, height: 30)
            c.fill(Path(banner), with: .color(Theme.Night.danger.opacity(0.18)))
            c.draw(Text("✕  " + FB.clip(s.recentEvents.last?.text ?? "Error", 48)).font(Theme.allo(12, .medium))
                    .foregroundStyle(Theme.Night.danger), in: CGRect(x: banner.minX + 12, y: banner.minY + 7, width: banner.width - 24, height: 18))
        case .working:
            break
        }
    }

    private func drawScreensaver(_ c: inout GraphicsContext, _ scr: CGRect) {
        drawBouncer(&c, scr.insetBy(dx: 10, dy: 10), size: 46, alpha: 0.9)
        c.draw(Text("No agents running").font(Theme.allo(20, .semibold)).foregroundStyle(Theme.Night.secondary),
               at: CGPoint(x: scr.midX, y: scr.minY + scr.height * 0.3), anchor: .center)
        c.draw(Text("Silly's on a coffee break").font(Theme.allo(13.5, .regular)).foregroundStyle(Theme.Night.muted),
               at: CGPoint(x: scr.midX, y: scr.minY + scr.height * 0.3 + 26), anchor: .center)
    }

    /// A DVD-style bouncing silicon tile.
    private func drawBouncer(_ c: inout GraphicsContext, _ box: CGRect, size: CGFloat, alpha: Double) {
        func tri(_ x: Double) -> Double { let f = x.truncatingRemainder(dividingBy: 2); return f < 1 ? f : 2 - f }
        let sp = reduceMotion ? 0.02 : 0.05
        let x = box.minX + CGFloat(tri(t * sp * 1.3)) * (box.width - size)
        let y = box.minY + CGFloat(tri(t * sp * 1.9 + 0.4)) * (box.height - size)
        let r = CGRect(x: x, y: y, width: size, height: size)
        c.fill(Path(roundedRect: r, cornerRadius: size * 0.3, style: .continuous),
               with: .linearGradient(Gradient(colors: [Theme.Night.lavender.opacity(alpha), Theme.Night.peach.opacity(alpha)]),
                                     startPoint: CGPoint(x: r.minX, y: r.minY), endPoint: CGPoint(x: r.maxX, y: r.maxY)))
        let d = size * 0.12
        c.fill(Path(ellipseIn: CGRect(x: r.minX + size * 0.26 - d / 2, y: r.minY + size * 0.42, width: d, height: d * 1.4)), with: .color(Color(hex: "1E1826")))
        c.fill(Path(ellipseIn: CGRect(x: r.maxX - size * 0.26 - d / 2, y: r.minY + size * 0.42, width: d, height: d * 1.4)), with: .color(Color(hex: "1E1826")))
    }

    // MARK: Room extras

    private func drawClock(_ c: inout GraphicsContext) {
        let cc = DeskGeo.clockCenter, R = DeskGeo.clockR
        c.fill(Path(ellipseIn: CGRect(x: cc.x - R + 4, y: cc.y - R + 9, width: R * 2, height: R * 2)), with: .color(.black.opacity(0.28)))
        c.fill(Path(ellipseIn: CGRect(x: cc.x - R, y: cc.y - R, width: R * 2, height: R * 2)), with: .color(Color(hex: "2C2833")))
        let f = R - 7
        c.fill(Path(ellipseIn: CGRect(x: cc.x - f, y: cc.y - f, width: f * 2, height: f * 2)), with: .color(Color(hex: "EEE8DE")))
        var ticks = Path(), majors = Path()
        for i in 0..<12 {
            let a = Double(i) / 12 * 2 * .pi
            let r0 = f - (i % 3 == 0 ? 11 : 7), r1 = f - 4
            let p0 = CGPoint(x: cc.x + CGFloat(sin(a)) * r0, y: cc.y - CGFloat(cos(a)) * r0)
            let p1 = CGPoint(x: cc.x + CGFloat(sin(a)) * r1, y: cc.y - CGFloat(cos(a)) * r1)
            if i % 3 == 0 { majors.move(to: p0); majors.addLine(to: p1) } else { ticks.move(to: p0); ticks.addLine(to: p1) }
        }
        c.stroke(ticks, with: .color(Color(hex: "8C8494")), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        c.stroke(majors, with: .color(Color(hex: "3A3442")), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        let comps = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: wall)
        let sec = Double(comps.second ?? 0) + Double(comps.nanosecond ?? 0) / 1e9
        let mins = Double(comps.minute ?? 0) + sec / 60
        let hrs = Double((comps.hour ?? 0) % 12) + mins / 60
        func hand(_ frac: Double, _ len: CGFloat, _ w: CGFloat, _ col: Color, tail: CGFloat = 8) {
            let a = frac * 2 * .pi
            var p = Path()
            p.move(to: CGPoint(x: cc.x - CGFloat(sin(a)) * tail, y: cc.y + CGFloat(cos(a)) * tail))
            p.addLine(to: CGPoint(x: cc.x + CGFloat(sin(a)) * len, y: cc.y - CGFloat(cos(a)) * len))
            c.stroke(p, with: .color(col), style: StrokeStyle(lineWidth: w, lineCap: .round))
        }
        hand(hrs / 12, f * 0.52, 5.5, Color(hex: "2A2530"))
        hand(mins / 60, f * 0.78, 3.8, Color(hex: "2A2530"))
        hand(sec / 60, f * 0.84, 1.8, Color(hex: "D9634F"), tail: 14)
        c.fill(Path(ellipseIn: CGRect(x: cc.x - 4.5, y: cc.y - 4.5, width: 9, height: 9)), with: .color(Color(hex: "D9634F")))
    }

    private func drawFairyLights(_ c: inout GraphicsContext, dark: Double) {
        // Four swags between the curtain rod ends.
        let x0: CGFloat = 236, x1: CGFloat = 1364, y0: CGFloat = 54
        let swags = 4
        let sw = (x1 - x0) / CGFloat(swags)
        var wire = Path()
        var bulbs: [CGPoint] = []
        for s in 0..<swags {
            let a = CGPoint(x: x0 + CGFloat(s) * sw, y: y0)
            let b = CGPoint(x: a.x + sw, y: y0)
            let ctrl = CGPoint(x: (a.x + b.x) / 2, y: y0 + 58)
            wire.move(to: a)
            wire.addQuadCurve(to: b, control: ctrl)
            for i in 1..<6 {
                let u = CGFloat(i) / 6
                let p = CGPoint(x: (1 - u) * (1 - u) * a.x + 2 * (1 - u) * u * ctrl.x + u * u * b.x,
                                y: (1 - u) * (1 - u) * a.y + 2 * (1 - u) * u * ctrl.y + u * u * b.y)
                bulbs.append(p)
            }
        }
        c.stroke(wire, with: .color(Color.black.opacity(0.45)), lineWidth: 1.5)
        let cols = [Color(hex: "F5C98B"), Color(hex: "EDCAA3"), Color(hex: "CBBAEB"), Color(hex: "F5C98B"), Color(hex: "7D9BFF")]
        let glowK = 0.35 + 0.65 * dark
        for (i, p) in bulbs.enumerated() {
            let tw = reduceMotion ? 0.85 : 0.55 + 0.45 * sin(t * (0.7 + FB.hash(i, 21) * 0.9) + FB.hash(i, 23) * 6.28)
            let col = cols[i % cols.count]
            let bp = CGPoint(x: p.x, y: p.y + 7)
            c.fill(Path(ellipseIn: CGRect(x: bp.x - 20, y: bp.y - 20, width: 40, height: 40)),
                   with: .radialGradient(Gradient(colors: [col.opacity(0.32 * tw * glowK), col.opacity(0)]), center: bp, startRadius: 2, endRadius: 20))
            c.fill(Path(roundedRect: CGRect(x: p.x - 2.5, y: p.y, width: 5, height: 4), cornerRadius: 1), with: .color(Color(hex: "3A3A40")))
            c.fill(Path(ellipseIn: CGRect(x: bp.x - 4, y: bp.y - 5, width: 8, height: 10)), with: .color(col.opacity(0.45 + 0.55 * tw)))
        }
    }
}
