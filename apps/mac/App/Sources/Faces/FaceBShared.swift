import SwiftUI
import SiliconModeKit

// Shared building blocks for the Chomp and Desk faces: time sources, deterministic noise,
// event classification, and the character palettes both mascots are painted with.

// MARK: - Time

@MainActor
enum FaceBClock {
    /// Seconds that drive animation. Deterministic while the snapshot harness pins a time.
    static func seconds(_ date: Date) -> Double {
        if let t = SnapshotHarness.time { return t }
        return date.timeIntervalSinceReferenceDate
    }

    static var isSnapshot: Bool { SnapshotHarness.time != nil }

    /// The wall-clock time faces show (window sky, clocks). In snapshot mode a pinned `--time`
    /// of an hour or more reads as seconds after local midnight (79200 → 22:00) so snapshots
    /// can pick a time of day; smaller values are added to a calm 21:41.
    static func wallDate(_ date: Date) -> Date {
        guard let t = SnapshotHarness.time else { return date }
        let midnight = Calendar.current.startOfDay(for: date)
        let secs = t >= 3600 ? t.truncatingRemainder(dividingBy: 86400) : 21 * 3600 + 41 * 60 + t
        return midnight.addingTimeInterval(secs)
    }

    /// The first moment a face simulation should replay from, so a snapshot at `t` shows a
    /// world that has been running for a little while (but never replays hours of frames).
    static func replayStart(for t: Double, history: Double) -> Double {
        isSnapshot ? max(0, t - history) : t
    }
}

// MARK: - Math & noise

enum FB {
    /// SplitMix-style hash of two integers → [0, 1).
    @inline(__always)
    static func hash(_ a: Int, _ b: Int = 0) -> Double {
        var x = UInt64(bitPattern: Int64(a)) &* 0x9E37_79B9_7F4A_7C15
        x ^= UInt64(bitPattern: Int64(b)) &* 0xC2B2_AE3D_27D4_EB4F
        x ^= x >> 31; x &*= 0xBF58_476D_1CE4_E5B9
        x ^= x >> 27; x &*= 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return Double(x >> 11) / Double(UInt64(1) << 53)
    }

    /// Stable (process-independent) string seed: FNV-1a.
    static func seed(_ s: String) -> Int {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in s.utf8 { h ^= UInt64(b); h &*= 0x0000_0100_0000_01B3 }
        return Int(truncatingIfNeeded: h >> 1)
    }

    @inline(__always) static func clamp(_ x: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double { min(max(x, lo), hi) }
    @inline(__always) static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    @inline(__always) static func smooth(_ x: Double) -> Double { let t = clamp(x); return t * t * (3 - 2 * t) }
    @inline(__always) static func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double { smooth((x - e0) / (e1 - e0)) }

    /// Ease toward `target` with a framerate-independent time constant.
    @inline(__always) static func approach(_ v: Double, _ target: Double, rate: Double, dt: Double) -> Double {
        v + (target - v) * (1 - exp(-rate * dt))
    }

    /// A springy overshoot 0 → 1 (back-out), for things popping into place.
    static func backOut(_ x: Double, _ s: Double = 1.70158) -> Double {
        let t = clamp(x) - 1
        return t * t * ((s + 1) * t + s) + 1
    }

    /// A drop-and-bounce 0 → 1.
    static func bounceOut(_ x: Double) -> Double {
        let t = clamp(x)
        let n = 7.5625, d = 2.75
        if t < 1 / d { return n * t * t }
        if t < 2 / d { let u = t - 1.5 / d; return n * u * u + 0.75 }
        if t < 2.5 / d { let u = t - 2.25 / d; return n * u * u + 0.9375 }
        let u = t - 2.625 / d
        return n * u * u + 0.984375
    }

    /// Periodic blink: 1 while the eyes are shut. Seeded so characters don't blink in unison.
    static func blink(_ t: Double, seed: Int, period: Double = 4.2) -> Double {
        let p = period + hash(seed, 7) * 1.6
        let phase = (t + hash(seed, 3) * p).truncatingRemainder(dividingBy: p)
        // A quick close/open over 0.16 s, with an occasional double blink.
        let single = phase < 0.16 ? sin(phase / 0.16 * .pi) : 0
        let doubleBlink = hash(Int(floor((t + hash(seed, 3) * p) / p)), seed) > 0.72
        let second = doubleBlink && phase > 0.24 && phase < 0.4 ? sin((phase - 0.24) / 0.16 * .pi) : 0
        return max(single, second)
    }

    /// Clip a one-line label for a face.
    static func clip(_ s: String, _ n: Int) -> String { EventText.clip(s, max: n) }
}

extension CGPoint {
    @inline(__always) func rotated(by a: Double, around c: CGPoint) -> CGPoint {
        let s = sin(a), co = cos(a)
        let dx = x - c.x, dy = y - c.y
        return CGPoint(x: c.x + dx * co - dy * s, y: c.y + dx * s + dy * co)
    }
}

extension Path {
    /// A rotated rectangle (confetti, flags) without touching the context's transform.
    static func rotatedRect(center c: CGPoint, size: CGSize, angle: Double) -> Path {
        let hw = size.width / 2, hh = size.height / 2
        let pts = [CGPoint(x: -hw, y: -hh), CGPoint(x: hw, y: -hh), CGPoint(x: hw, y: hh), CGPoint(x: -hw, y: hh)]
            .map { CGPoint(x: c.x + $0.x, y: c.y + $0.y).rotated(by: angle, around: c) }
        var p = Path()
        p.addLines(pts)
        p.closeSubpath()
        return p
    }

    static func roundedRect(_ r: CGRect, _ radius: CGFloat) -> Path {
        Path(roundedRect: r, cornerRadius: min(radius, min(r.width, r.height) / 2), style: .continuous)
    }
}

// MARK: - Events → visual kinds

/// What an agent event looks like on a face.
enum FBEventKind: Int, CaseIterable, Sendable {
    case edit, run, read, message, user, thinking, ask, error, status

    init(_ e: AgentEvent) {
        switch e.kind {
        case .user: self = .user
        case .assistant: self = .message
        case .thinking: self = .thinking
        case .permission, .question: self = .ask
        case .error: self = .error
        case .status: self = .status
        case .tool, .toolResult:
            let t = e.text.lowercased()
            if t.hasPrefix("edit") || t.hasPrefix("wrote") || t.hasPrefix("write") || t.hasPrefix("creat")
                || t.hasPrefix("patch") || t.hasPrefix("appl") || t.hasPrefix("delet") || t.hasPrefix("renam") {
                self = .edit
            } else if t.hasPrefix("ran") || t.hasPrefix("run") || t.hasPrefix("$") || t.hasPrefix("exec")
                        || t.hasPrefix("bash") || t.hasPrefix("shell") {
                self = .run
            } else {
                self = .read
            }
        }
    }

    var color: Color {
        switch self {
        case .edit: Color(hex: "7FC79A")
        case .run: Color(hex: "7D9BFF")
        case .read: Color(hex: "CBBAEB")
        case .message: Color(hex: "EDCAA3")
        case .user: Color(hex: "F2F2F2")
        case .thinking: Color(hex: "9C95B5")
        case .ask: Color(hex: "E3B55A")
        case .error: Color(hex: "F4968C")
        case .status: Color(hex: "8C8C8C")
        }
    }

    /// Monospace-friendly prompt glyph for terminal-ish lines.
    var glyph: String {
        switch self {
        case .edit: "+"
        case .run: "$"
        case .read: "›"
        case .message: "◆"
        case .user: "»"
        case .thinking: "~"
        case .ask: "?"
        case .error: "!"
        case .status: "·"
        }
    }

    /// The event text with redundant verbs trimmed for tiny labels ("Ran: npm test" → "npm test").
    static func shortText(_ e: AgentEvent, max: Int) -> String {
        var s = e.text
        for p in ["Ran: ", "Run: ", "Running: "] where s.hasPrefix(p) { s = String(s.dropFirst(p.count)) }
        return FB.clip(s, max)
    }
}

// MARK: - Character palettes

struct FBCharacterPalette {
    let top: Color
    let bottom: Color
    /// Shadowed side / underside.
    let shade: Color
    /// Rim light.
    let highlight: Color
    /// Pupils, mouth, engraved details.
    let ink: Color
    let cheek: Color
    /// Pins / teeth / antenna.
    let metal: Color
    let feet: Color

    var bodyGradient: [Color] { [top, bottom] }
}

enum FBStyle {
    static let characterChoices: [(id: String, label: String)] = [
        ("silicon", "Silicon"), ("blue", "Blue"), ("mint", "Mint"), ("peach", "Peach"), ("graphite", "Graphite"),
    ]

    static func character(_ id: String) -> FBCharacterPalette {
        switch id {
        case "blue":
            FBCharacterPalette(top: Color(hex: "A9BCFF"), bottom: Color(hex: "6F8EF6"), shade: Color(hex: "4E69C9"),
                               highlight: Color(hex: "DCE4FF"), ink: Color(hex: "16182A"), cheek: Color(hex: "F4A0B4"),
                               metal: Color(hex: "D6D9E4"), feet: Color(hex: "262A3A"))
        case "mint":
            FBCharacterPalette(top: Color(hex: "BDEACD"), bottom: Color(hex: "7FC79A"), shade: Color(hex: "559C70"),
                               highlight: Color(hex: "E6F8EC"), ink: Color(hex: "13231A"), cheek: Color(hex: "F2A3A0"),
                               metal: Color(hex: "D6DCD8"), feet: Color(hex: "22302A"))
        case "peach":
            FBCharacterPalette(top: Color(hex: "F7DCC0"), bottom: Color(hex: "EBB98A"), shade: Color(hex: "C48C5D"),
                               highlight: Color(hex: "FFF1E3"), ink: Color(hex: "2A1C12"), cheek: Color(hex: "F09A8A"),
                               metal: Color(hex: "E0DAD3"), feet: Color(hex: "33271F"))
        case "graphite":
            FBCharacterPalette(top: Color(hex: "C9C9CF"), bottom: Color(hex: "8E8E96"), shade: Color(hex: "66666E"),
                               highlight: Color(hex: "EDEDF0"), ink: Color(hex: "151518"), cheek: Color(hex: "E7A0A6"),
                               metal: Color(hex: "E2E2E6"), feet: Color(hex: "2A2A2F"))
        default: // silicon: lavender → peach
            FBCharacterPalette(top: Color(hex: "D6C8F2"), bottom: Color(hex: "EDCAA3"), shade: Color(hex: "B49AC9"),
                               highlight: Color(hex: "F4EEFF"), ink: Color(hex: "1E1826"), cheek: Color(hex: "F2A08E"),
                               metal: Color(hex: "DCD8E2"), feet: Color(hex: "2B2633"))
        }
    }

    /// Confetti colors: the silicon gradient ends plus the state colors.
    static let confetti: [Color] = [
        Color(hex: "CBBAEB"), Color(hex: "EDCAA3"), Color(hex: "7D9BFF"), Color(hex: "7FC79A"),
        Color(hex: "E3B55A"), Color(hex: "F2F2F2"), Color(hex: "F4968C"),
    ]
}

// MARK: - Confetti

enum FBConfetti {
    /// Draws one confetti burst `age` seconds after it fired from `origin`. Cheap: a few dozen
    /// rotated quads, fully deterministic from `seed`.
    static func draw(_ g: inout GraphicsContext, origin: CGPoint, age: Double, seed: Int, scale: Double,
                     count: Int = 36, spread: Double = 1, life: Double = 2.6) {
        guard age >= 0, age < life else { return }
        let fade = 1 - FB.smooth(life * 0.6, life, age)
        for i in 0..<count {
            let a = -Double.pi / 2 + (FB.hash(seed, i) - 0.5) * 2.3 * spread
            let speed = (190 + FB.hash(seed, i + 100) * 260) * scale
            let vx = cos(a) * speed, vy = sin(a) * speed
            let drag = 1.6
            let k = (1 - exp(-drag * age)) / drag
            let gravity = 420 * scale
            let x = origin.x + vx * k + sin(age * (3 + FB.hash(seed, i + 7) * 4) + Double(i)) * 6 * scale
            let y = origin.y + vy * k + gravity * (age - k) / drag
            let w = (5 + FB.hash(seed, i + 300) * 5) * scale
            let h = w * (0.45 + 0.3 * abs(sin(age * 9 + Double(i))))  // fluttering
            let rot = age * (4 + FB.hash(seed, i + 400) * 8) + Double(i)
            let c = FBStyle.confetti[i % FBStyle.confetti.count]
            g.fill(Path.rotatedRect(center: CGPoint(x: x, y: y), size: CGSize(width: w, height: h), angle: rot),
                   with: .color(c.opacity(fade)))
        }
    }
}
