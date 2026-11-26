import SwiftUI
import SiliconModeKit

/// Shared plumbing for the Bounce, Orbit and Clock faces ("faces-a"): a deterministic animation
/// clock, stable hashing, easing, the silicon palette, burn-in drift and the panic wash.
enum FaceA {
    // MARK: Time

    /// Seconds since the face appeared. The snapshot harness's `--time` wins, then a per-view
    /// fixed time (snapshot items), then the live clock.
    @MainActor
    static func elapsed(since start: Date, now: Date, fixed: Double?) -> Double {
        if let t = SnapshotHarness.time ?? fixed { return t }
        return max(0, now.timeIntervalSince(start))
    }

    /// True when the face is being rendered for a deterministic snapshot.
    @MainActor
    static func isFrozen(_ fixed: Double?) -> Bool { SnapshotHarness.time != nil || fixed != nil }

    /// Wall-clock time to display. Snapshots get a fixed, pretty moment (Thursday 26 November,
    /// 10:41:52 local) plus the snapshot time, so clocks render identically every run.
    @MainActor
    static func wallDate(now: Date, fixed: Double?) -> Date {
        guard let t = SnapshotHarness.time ?? fixed else { return now }
        var c = DateComponents()
        c.year = 2026; c.month = 11; c.day = 26; c.hour = 10; c.minute = 41; c.second = 52
        let base = Calendar.current.date(from: c) ?? Date(timeIntervalSinceReferenceDate: 0)
        return base.addingTimeInterval(t)
    }

    // MARK: Deterministic randomness

    /// FNV-1a over UTF-8: stable across launches (unlike `Hasher`).
    static func hash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x0000_0100_0000_01B3 }
        return h
    }

    /// SplitMix64 finalizer: a well-mixed 64-bit value from (seed, k).
    static func mix(_ seed: UInt64, _ k: UInt64) -> UInt64 {
        var z = seed &+ (k &+ 1) &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Deterministic uniform value in [0, 1).
    static func unit(_ seed: UInt64, _ k: UInt64) -> Double {
        Double(mix(seed, k) >> 11) / Double(1 << 53)
    }

    /// Tiny seeded generator for simulations.
    struct RNG {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
        mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
    }

    // MARK: Math

    static func clamp(_ x: Double, _ a: Double = 0, _ b: Double = 1) -> Double { min(max(x, a), b) }
    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = clamp((x - a) / (b - a)); return t * t * (3 - 2 * t)
    }
    static func easeOutCubic(_ t: Double) -> Double { let u = 1 - clamp(t); return 1 - u * u * u }
    static func easeInCubic(_ t: Double) -> Double { let u = clamp(t); return u * u * u }
    static func easeOutBack(_ t: Double, _ s: Double = 1.4) -> Double {
        let u = clamp(t) - 1; return 1 + (s + 1) * u * u * u + s * u * u
    }

    /// Underdamped spring step response (0 → 1 with a little overshoot), t in seconds.
    static func spring(_ t: Double, response: Double = 0.45, damping: Double = 0.72) -> Double {
        guard t > 0 else { return 0 }
        let w0 = 2 * Double.pi / response
        if damping >= 1 { return 1 - (1 + w0 * t) * exp(-w0 * t) }
        let wd = w0 * (1 - damping * damping).squareRoot()
        let e = exp(-damping * w0 * t)
        return 1 - e * (cos(wd * t) + (damping * w0 / wd) * sin(wd * t))
    }

    /// Smooth value noise in [-1, 1] from a sum of incommensurate sines (cheap, deterministic).
    static func wave(_ x: Double, _ seed: Double) -> Double {
        (sin(x * 1.0 + seed) * 0.5 + sin(x * 2.31 + seed * 1.7) * 0.3 + sin(x * 4.13 + seed * 2.9) * 0.2)
    }

    // MARK: Palette

    struct RGB: Sendable {
        var r, g, b: Double
        init(_ hex: UInt32) {
            r = Double((hex >> 16) & 0xFF) / 255; g = Double((hex >> 8) & 0xFF) / 255; b = Double(hex & 0xFF) / 255
        }
        init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
        func mix(_ o: RGB, _ t: Double) -> RGB {
            RGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t)
        }
        func color(_ a: Double = 1) -> Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    }

    static let lavender = RGB(0xCBBAEB)
    static let peach = RGB(0xEDCAA3)
    static let accent = RGB(0x7D9BFF)
    static let amber = RGB(0xE3B55A)
    static let green = RGB(0x7FC79A)
    static let red = RGB(0xF4968C)
    static let grey = RGB(0x8C8C8C)
    static let night = RGB(0x0B0B0B)

    /// A point on the silicon gradient (lavender → peach).
    static func silicon(_ f: Double, _ a: Double = 1) -> Color { lavender.mix(peach, clamp(f)).color(a) }

    static func stateRGB(_ s: AgentState) -> RGB {
        switch s {
        case .needsYou: amber
        case .working: accent
        case .finished: green
        case .idle: grey
        case .error: red
        }
    }

    static var siliconGradient: Gradient {
        Gradient(colors: [lavender.color(), peach.color()])
    }

    // MARK: Layout helpers

    /// Scale unit relative to a 16" MacBook Pro screen (982 pt tall).
    static func unit(for size: CGSize) -> CGFloat { max(0.18, min(size.width / 1512, size.height / 982)) }

    /// Slow Lissajous drift so nothing sits on the same pixels for hours (burn-in / retention).
    static func drift(_ t: Double, amplitude: CGFloat) -> CGSize {
        CGSize(width: amplitude * sin(t * 2 * .pi / 331 + 0.7),
               height: amplitude * 0.7 * sin(t * 2 * .pi / 467 + 2.1))
    }

    /// Sessions a face should draw: most urgent first, capped.
    static func visibleSessions(_ sessions: [AgentSession], max: Int) -> [AgentSession] {
        Array(sessions.sorted { a, b in
            a.state.rank != b.state.rank ? a.state.rank < b.state.rank : a.id < b.id
        }.prefix(max))
    }

    /// Short human title for a session.
    static func title(_ s: AgentSession, max: Int = 28) -> String {
        let raw = s.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = raw.isEmpty ? (s.projectName ?? ProviderCatalog.info(for: s.provider).name) : raw
        return EventText.clip(base, max: max)
    }

    /// "3 agents working · 1 needs you" parts, most urgent first.
    static func summaryParts(_ c: AgentCounts) -> [(count: Int, label: String, state: AgentState)] {
        var parts: [(Int, String, AgentState)] = []
        if c.needsYou > 0 { parts.append((c.needsYou, c.needsYou == 1 ? "needs you" : "need you", .needsYou)) }
        if c.working > 0 { parts.append((c.working, c.working == 1 ? "agent working" : "agents working", .working)) }
        if c.error > 0 { parts.append((c.error, c.error == 1 ? "error" : "errors", .error)) }
        if c.finished > 0 { parts.append((c.finished, "finished", .finished)) }
        if parts.isEmpty && c.idle > 0 { parts.append((c.idle, "idle", .idle)) }
        // Put the "working" phrase first when present so it reads "3 agents working · 1 needs you".
        if let w = parts.firstIndex(where: { $0.2 == .working }), w != 0 { parts.insert(parts.remove(at: w), at: 0) }
        return parts.map { (count: $0.0, label: $0.1, state: $0.2) }
    }

    /// The summary as styled text: numbers tinted by state, separators faint.
    static func summaryText(_ c: AgentCounts, size: CGFloat) -> Text {
        let parts = summaryParts(c)
        guard !parts.isEmpty else {
            return Text("No agents running").foregroundStyle(Theme.Night.muted)
        }
        var out = Text("")
        for (i, p) in parts.enumerated() {
            if i > 0 { out = out + Text("  ·  ").foregroundStyle(Theme.Night.faint) }
            out = out + Text("\(p.count)").foregroundStyle(Theme.stateColor(p.state)).monospacedDigit()
                + Text(" \(p.label)").foregroundStyle(Theme.Night.secondary)
        }
        return out
    }
}

/// A gentle full-screen wash in danger red that throbs while panicking (the overlay adds its own
/// panic visual; this keeps the face itself in character).
struct FaceAPanicWash: View {
    let active: Bool
    var body: some View {
        if active {
            TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                let p = 0.5 + 0.5 * sin(t * 2 * .pi * 3.2)
                RadialGradient(colors: [.clear, FaceA.red.color(0.10 + 0.32 * p)],
                               center: .center, startRadius: 120, endRadius: 900)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            }
            .transition(.opacity)
        }
    }
}

/// The Silicon mark: a disc on the silicon gradient with the "si" monogram. Used when no agents
/// are running and for the `silicon` provider.
struct FaceASiliconMark: View {
    var size: CGFloat = 64
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [FaceA.lavender.color(), FaceA.peach.color()],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().strokeBorder(.white.opacity(0.35), lineWidth: max(0.5, size * 0.012))
            Text("si")
                .font(Theme.allo(size * 0.44, .semibold))
                .tracking(-size * 0.012)
                .foregroundStyle(Color(hex: "1B1B1B"))
                .offset(y: -size * 0.02)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Silicon")
    }
}

/// Richer demo sessions for snapshots (six providers, every state).
enum FaceASamples {
    static let sessions: [AgentSession] = {
        let now = Date()
        func s(_ p: String, _ id: String, _ title: String, _ st: AgentState, _ ago: Double) -> AgentSession {
            AgentSession(provider: p, nativeID: id, title: title, cwd: "/Users/you/code/\(id)", state: st,
                         startedAt: now.addingTimeInterval(-ago), updatedAt: now)
        }
        return SampleAgents.sessions + [
            s("gemini-cli", "g1", "Summarize design review notes", .working, 2400),
            s("cursor-cli", "cu1", "Port charts to Swift Charts", .working, 600),
            s("grok", "gk1", "Benchmark tokenizer", .idle, 5000),
            s("copilot-cli", "cp1", "Bump dependencies", .error, 1200),
        ]
    }()
}
