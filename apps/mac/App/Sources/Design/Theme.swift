import SwiftUI
import AppKit
import SiliconModeKit
import CoreText

/// Silicon design tokens (shared/design/tokens.json — from Silicon Accounts + Silicon UI).
/// Allo is bundled (Resources/Fonts, ATSApplicationFontsPath).
enum Theme {
    // MARK: Color
    enum Palette {
        // Light
        static let lBackground = Color(hex: "FCFCFC")
        static let lSurface = Color(hex: "FFFFFF")
        static let lForeground = Color(hex: "1B1B1B")
        static let lMuted = Color(hex: "6B6B6B")
        static let lBorder = Color(hex: "E9E9E9")
        // Dark
        static let dBackground = Color(hex: "141414")
        static let dSurface = Color(hex: "191919")
        static let dSurfaceRaised = Color(hex: "1F1F1F")
        static let dForeground = Color(hex: "F2F2F2")
        static let dMuted = Color(hex: "8C8C8C")
        static let dBorder = Color(hex: "2B2B2B")
        static let canvas = Color(hex: "0F0F0F")
    }

    /// Adaptive semantic colors.
    static let background = Color(light: "FCFCFC", dark: "141414")
    static let surface = Color(light: "FFFFFF", dark: "191919")
    static let surfaceMuted = Color(light: "F1F1F1", dark: "242424")
    static let foreground = Color(light: "1B1B1B", dark: "F2F2F2")
    static let textSecondary = Color(light: "505050", dark: "B4B4B4")
    static let textMuted = Color(light: "6B6B6B", dark: "8C8C8C")
    static let textFaint = Color(light: "A4A4A4", dark: "4D4D4D")
    static let border = Color(light: "E9E9E9", dark: "2B2B2B")
    static let accent = Color(light: "3460F0", dark: "7D9BFF")
    static let accentSubtle = Color(light: "EEF2FE", dark: "1D2440")
    static let primary = Color(light: "181818", dark: "F2F2F2")
    static let primaryForeground = Color(light: "FFFFFF", dark: "141414")
    static let success = Color(light: "2B7148", dark: "7FC79A")
    static let warning = Color(light: "8F560D", dark: "E3B55A")
    static let danger = Color(light: "B42318", dark: "F4968C")

    /// The "silicon gradient" (lavender → peach).
    static let siliconFrom = Color(light: "E2D8F8", dark: "463C59")
    static let siliconTo = Color(light: "FADFC6", dark: "5A422F")
    static let siliconInkFrom = Color(light: "644C8A", dark: "CBBAEB")
    static let siliconInkTo = Color(light: "8A542D", dark: "EDCAA3")
    static var siliconGradient: LinearGradient {
        LinearGradient(colors: [siliconFrom, siliconTo], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var siliconInk: LinearGradient {
        LinearGradient(colors: [siliconInkFrom, siliconInkTo], startPoint: .leading, endPoint: .trailing)
    }

    /// Fixed dark palette for the Silicon Mode overlay (it is always dark, like a screensaver).
    enum Night {
        static let background = Color(hex: "0B0B0B")
        static let surface = Color(hex: "191919")
        static let foreground = Color(hex: "F2F2F2")
        static let secondary = Color(hex: "B4B4B4")
        static let muted = Color(hex: "8C8C8C")
        static let faint = Color(hex: "4D4D4D")
        static let border = Color.white.opacity(0.08)
        static let accent = Color(hex: "7D9BFF")
        static let lavender = Color(hex: "CBBAEB")
        static let peach = Color(hex: "EDCAA3")
        static let success = Color(hex: "7FC79A")
        static let warning = Color(hex: "E3B55A")
        static let danger = Color(hex: "F4968C")
    }

    /// Color for an agent state (overlay/menu bar dots and chips).
    static func stateColor(_ s: AgentState, night: Bool = true) -> Color {
        switch s {
        case .needsYou: night ? Night.warning : warning
        case .working: night ? Night.accent : accent
        case .finished: night ? Night.success : success
        case .idle: night ? Night.muted : textMuted
        case .error: night ? Night.danger : danger
        }
    }

    // MARK: Type
    enum Weight { case thin, extraLight, light, regular, medium, semibold, bold, extraBold, black }

    static func weightValue(_ w: Weight) -> CGFloat {
        switch w {
        case .thin: 100
        case .extraLight: 200
        case .light: 300
        case .regular: 400
        case .medium: 500
        case .semibold: 600
        case .bold: 700
        case .extraBold: 800
        case .black: 900
        }
    }

    /// Allo Variable with the Silicon Accounts configuration: ROND 20, optical size follows the
    /// point size (14 text … 32 display), weight on the wght axis.
    static func ctAllo(_ size: CGFloat, weight: CGFloat = 400, roundness: CGFloat = 20) -> CTFont {
        let key = "\(size)-\(weight)-\(roundness)"
        if let f = AlloCache.shared.get(key) { return f }
        func tag(_ s: String) -> Int { s.utf8.reduce(0) { ($0 << 8) | Int($1) } }
        let variations: [Int: CGFloat] = [tag("wght"): weight, tag("ROND"): roundness, tag("opsz"): min(max(size, 9), 32)]
        let attrs: [CFString: Any] = [kCTFontNameAttribute: "AlloVariable-Regular", kCTFontVariationAttribute: variations]
        let f = CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes(attrs as CFDictionary), size, nil)
        AlloCache.shared.set(key, f)
        return f
    }

    static func allo(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        Font(ctAllo(size, weight: weightValue(weight)))
    }

    static func nsAllo(_ size: CGFloat, _ weight: Weight = .regular) -> NSFont {
        ctAllo(size, weight: weightValue(weight)) as NSFont
    }

    // Roles (compact density, as Accounts ships)
    static let display = allo(28, .semibold)
    static let h1 = allo(22, .semibold)
    static let h2 = allo(18, .semibold)
    static let h3 = allo(16, .medium)
    static let body = allo(14, .regular)     // macOS body is a notch smaller than web 16
    static let label = allo(13, .medium)
    static let small = allo(12, .regular)
    static let caption = allo(11, .medium)
    static let mono = Font.system(size: 12, weight: .regular, design: .monospaced)

    /// Tracking in points for a given size (display -0.03em, body -0.01em).
    static func tracking(_ size: CGFloat, display: Bool = false) -> CGFloat { size * (display ? -0.03 : -0.01) }

    // MARK: Shape & spacing
    enum Radius {
        static let detail: CGFloat = 4
        static let control: CGFloat = 8
        static let container: CGFloat = 12
        static let overlay: CGFloat = 18
        static let panel: CGFloat = 14
        static let surface: CGFloat = 18
    }

    enum Space {
        static let hair: CGFloat = 2
        static let tight: CGFloat = 4
        static let related: CGFloat = 8
        static let group: CGFloat = 12
        static let inset: CGFloat = 16
        static let block: CGFloat = 24
        static let page: CGFloat = 32
    }

    // MARK: Motion (Silicon UI springs)
    enum Motion {
        static let fast = Animation.spring(duration: 0.12, bounce: 0)
        static let moderate = Animation.spring(duration: 0.22, bounce: 0)
        static let slow = Animation.spring(duration: 0.35, bounce: 0.12)
        static let expressive = Animation.spring(duration: 0.6, bounce: 0.16)
        static let exit = Animation.timingCurve(0.7, 0, 0.84, 0, duration: 0.16)
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b, a: Double
        if s.count == 8 {
            r = Double((v >> 24) & 0xFF) / 255; g = Double((v >> 16) & 0xFF) / 255
            b = Double((v >> 8) & 0xFF) / 255; a = Double(v & 0xFF) / 255
        } else {
            r = Double((v >> 16) & 0xFF) / 255; g = Double((v >> 8) & 0xFF) / 255
            b = Double(v & 0xFF) / 255; a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// Adaptive light/dark color.
    init(light: String, dark: String) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight]).map {
                $0 == .darkAqua || $0 == .vibrantDark
            } ?? false
            return NSColor(Color(hex: isDark ? dark : light))
        })
    }
}

extension AgentProviderInfo {
    var color: Color { Color(hex: colorHex) }
}

extension View {
    /// Allo text with Silicon tracking.
    func alloText(_ size: CGFloat, _ weight: Theme.Weight = .regular, display: Bool = false) -> some View {
        font(Theme.allo(size, weight)).tracking(Theme.tracking(size, display: display))
    }
}

/// CTFont creation with variations is not free; cache by (size, weight, roundness).
final class AlloCache: @unchecked Sendable {
    static let shared = AlloCache()
    private let lock = NSLock()
    private var fonts: [String: CTFont] = [:]
    func get(_ k: String) -> CTFont? { lock.lock(); defer { lock.unlock() }; return fonts[k] }
    func set(_ k: String, _ f: CTFont) { lock.lock(); fonts[k] = f; lock.unlock() }
}
