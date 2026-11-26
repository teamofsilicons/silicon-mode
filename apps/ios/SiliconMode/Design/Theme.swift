import SwiftUI
import UIKit
import CoreText

/// Silicon design tokens for iPhone (shared/design/tokens.json — Silicon Accounts + Silicon UI),
/// mirroring the Mac app's `Theme`. Allo Variable is bundled (UIAppFonts) and always built with
/// the Accounts configuration: ROND 20, optical size following the point size.
enum Theme {
    // MARK: Adaptive colors (light = Accounts, dark = Silicon UI neutral dark)
    static let background = Color(light: "FCFCFC", dark: "141414")
    static let canvas = Color(light: "F8F8F8", dark: "0F0F0F")
    static let surface = Color(light: "FFFFFF", dark: "191919")
    static let surfaceRaised = Color(light: "FFFFFF", dark: "1F1F1F")
    static let surfaceMuted = Color(light: "F1F1F1", dark: "242424")
    static let foreground = Color(light: "1B1B1B", dark: "F2F2F2")
    static let textSoft = Color(light: "353535", dark: "D1D1D1")
    static let textSecondary = Color(light: "505050", dark: "B4B4B4")
    static let textMuted = Color(light: "6B6B6B", dark: "8C8C8C")
    static let textFaint = Color(light: "A4A4A4", dark: "4D4D4D")
    static let border = Color(light: "E9E9E9", dark: "2B2B2B")
    static let borderSubtle = Color(light: "F3F3F3", dark: "222222")
    static let accent = Color(light: "3460F0", dark: "7D9BFF")
    static let accentStrong = Color(light: "2449C9", dark: "A9BDFF")
    static let accentSubtle = Color(light: "EEF2FE", dark: "1D2440")
    static let primary = Color(light: "181818", dark: "F2F2F2")
    static let primaryForeground = Color(light: "FFFFFF", dark: "141414")
    static let success = Color(light: "2B7148", dark: "7FC79A")
    static let warning = Color(light: "8F560D", dark: "E3B55A")
    static let danger = Color(light: "B42318", dark: "F4968C")
    static let series = [Color(light: "1F5CB1", dark: "86AEEA"), Color(light: "7A4FC4", dark: "B99AE6"),
                         Color(light: "B7791F", dark: "E3B55A"), Color(light: "2B7148", dark: "7FC79A")]

    /// The silicon gradient (lavender → peach).
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

    /// Fixed dark palette: the hero card is a little window onto the Mac's Silicon Mode screen,
    /// which is always dark (like a screensaver).
    enum Night {
        static let background = Color(hex: "0B0B0B")
        static let surface = Color(hex: "191919")
        static let foreground = Color(hex: "F2F2F2")
        static let secondary = Color(hex: "B4B4B4")
        static let muted = Color(hex: "8C8C8C")
        static let faint = Color(hex: "4D4D4D")
        static let accent = Color(hex: "7D9BFF")
        static let lavender = Color(hex: "CBBAEB")
        static let peach = Color(hex: "EDCAA3")
        static let success = Color(hex: "7FC79A")
        static let warning = Color(hex: "E3B55A")
        static let danger = Color(hex: "F4968C")
        static let panic = Color(hex: "FF4D3D")
    }

    /// Warm, faint shadow (Accounts "flat paper").
    static let shadow = Color(light: "3A2A1A14", dark: "00000066")

    // MARK: Type
    enum Weight: CGFloat {
        case thin = 100, extraLight = 200, light = 300, regular = 400, medium = 500
        case semibold = 600, bold = 700, extraBold = 800, black = 900
    }

    /// Allo Variable with the Silicon Accounts configuration.
    static func ctAllo(_ size: CGFloat, weight: CGFloat = 400, roundness: CGFloat = 20) -> CTFont {
        let key = AlloCache.Key(size: size, weight: weight, roundness: roundness)
        if let f = AlloCache.shared.get(key) { return f }
        func tag(_ s: String) -> Int { s.utf8.reduce(0) { ($0 << 8) | Int($1) } }
        let variations: [Int: CGFloat] = [tag("wght"): weight, tag("ROND"): roundness, tag("opsz"): min(max(size, 9), 32)]
        let attrs: [CFString: Any] = [kCTFontNameAttribute: "AlloVariable-Regular", kCTFontVariationAttribute: variations]
        let f = CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes(attrs as CFDictionary), size, nil)
        AlloCache.shared.set(key, f)
        return f
    }

    static func allo(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        Font(ctAllo(size, weight: weight.rawValue))
    }

    static func uiAllo(_ size: CGFloat, _ weight: Weight = .regular) -> UIFont {
        ctAllo(size, weight: weight.rawValue) as UIFont
    }

    /// Tracking in points (display −0.03em, body −0.01em).
    static func tracking(_ size: CGFloat, display: Bool = false) -> CGFloat { size * (display ? -0.03 : -0.01) }

    /// Allo does not follow Dynamic Type by itself; scale our point sizes with the user's setting.
    static func scale(for size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall: 0.82
        case .small: 0.88
        case .medium: 0.94
        case .large: 1
        case .xLarge: 1.1
        case .xxLarge: 1.2
        case .xxxLarge: 1.3
        case .accessibility1: 1.5
        case .accessibility2: 1.7
        case .accessibility3: 1.9
        case .accessibility4: 2.05
        case .accessibility5: 2.2
        @unknown default: 1
        }
    }

    static let mono = Font.system(size: 12.5, weight: .regular, design: .monospaced)

    // MARK: Shape & spacing
    enum Radius {
        static let detail: CGFloat = 6
        static let control: CGFloat = 12
        static let card: CGFloat = 22
        static let hero: CGFloat = 30
    }

    enum Space {
        static let tight: CGFloat = 4
        static let related: CGFloat = 8
        static let group: CGFloat = 12
        static let inset: CGFloat = 16
        static let block: CGFloat = 24
        static let page: CGFloat = 32
    }

    // MARK: Motion (Silicon UI springs, tuned for touch)
    enum Motion {
        static let fast = Animation.spring(duration: 0.16, bounce: 0)
        static let moderate = Animation.spring(duration: 0.26, bounce: 0)
        static let slow = Animation.spring(duration: 0.38, bounce: 0.12)
        static let expressive = Animation.spring(duration: 0.6, bounce: 0.18)
        static let exit = Animation.timingCurve(0.7, 0, 0.84, 0, duration: 0.16)
    }

    /// Navigation bar titles in Allo.
    @MainActor static func installAppearance() {
        let nav = UINavigationBar.appearance()
        nav.largeTitleTextAttributes = [.font: uiAllo(32, .semibold), .kern: tracking(32, display: true)]
        nav.titleTextAttributes = [.font: uiAllo(17, .semibold), .kern: tracking(17)]
        let seg = UISegmentedControl.appearance()
        seg.setTitleTextAttributes([.font: uiAllo(13, .medium)], for: .normal)
        seg.setTitleTextAttributes([.font: uiAllo(13, .semibold)], for: .selected)
    }
}

// MARK: - Text roles

struct AlloStyle: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicType
    let size: CGFloat
    let weight: Theme.Weight
    let display: Bool
    let fixed: Bool

    func body(content: Content) -> some View {
        let s = fixed ? size : (size * Theme.scale(for: dynamicType)).rounded()
        content.font(Theme.allo(s, weight)).tracking(Theme.tracking(s, display: display))
    }
}

extension View {
    /// Allo text with Silicon tracking; follows Dynamic Type unless `fixed`.
    func allo(_ size: CGFloat, _ weight: Theme.Weight = .regular, display: Bool = false, fixed: Bool = false) -> some View {
        modifier(AlloStyle(size: size, weight: weight, display: display, fixed: fixed))
    }
}

// MARK: - Color helpers

extension Color {
    init(hex: String) {
        let (r, g, b, a) = Color.rgba(hex)
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// Adaptive light/dark color.
    init(light: String, dark: String) {
        let l = Color.rgba(light), d = Color.rgba(dark)
        self.init(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? d : l
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: c.3)
        })
    }

    static func rgba(_ hex: String) -> (Double, Double, Double, Double) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        if s.count == 8 {
            return (Double((v >> 24) & 0xFF) / 255, Double((v >> 16) & 0xFF) / 255,
                    Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
        }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255, 1)
    }
}

/// CTFont creation with variations is not free; cache by (size, weight, roundness).
final class AlloCache: @unchecked Sendable {
    struct Key: Hashable { var size, weight, roundness: CGFloat }
    static let shared = AlloCache()
    private let lock = NSLock()
    private var fonts: [Key: CTFont] = [:]
    func get(_ k: Key) -> CTFont? { lock.lock(); defer { lock.unlock() }; return fonts[k] }
    func set(_ k: Key, _ f: CTFont) { lock.lock(); fonts[k] = f; lock.unlock() }
}
