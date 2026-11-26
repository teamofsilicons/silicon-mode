import SwiftUI
import SiliconModeKit

/// A provider's mark: the provider's logo in white on a disc of the provider color, falling back
/// to a monogram. Used by faces, the HUD, settings and the menu bar.
///
/// Logo vectors are embedded (no runtime file IO) and parsed once by `SVGPathParser`. Path data
/// comes from simple-icons (CC0 1.0, https://simpleicons.org) except the Grok mark, which is drawn
/// here. Copies of the source SVGs live in `App/Resources/Logos/` for provenance.
struct ProviderMark: View {
    let provider: String
    var size: CGFloat = 24

    var body: some View {
        let info = ProviderCatalog.info(for: provider)
        Group {
            if ProviderLogos.isSilicon(provider) {
                FaceASiliconMark(size: size)
            } else {
                ZStack {
                    Circle().fill(ProviderLogos.color(for: provider))
                    Circle().strokeBorder(.white.opacity(0.14), lineWidth: max(0.5, size * 0.02))
                    if let logo = ProviderLogos.logo(for: provider) {
                        ProviderLogoShape(path: logo.path)
                            .fill(.white)
                            .frame(width: size * logo.scale, height: size * logo.scale)
                            .offset(x: size * logo.dx, y: size * logo.dy)
                    } else {
                        let mono = ProviderLogos.monogram(for: provider, fallback: info.monogram)
                        Text(mono)
                            .font(Theme.allo(size * (mono.count > 1 ? 0.36 : 0.46), .semibold))
                            .tracking(-size * 0.01)
                            .foregroundStyle(.white)
                            .minimumScaleFactor(0.5)
                    }
                }
                .frame(width: size, height: size)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(info.name)
    }
}

/// A 24×24 logo path scaled (aspect-fit, centered) into its frame.
struct ProviderLogoShape: Shape {
    let path: Path
    var viewBox: CGFloat = 24

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / viewBox
        let dx = rect.midX - viewBox * s / 2, dy = rect.midY - viewBox * s / 2
        return path.applying(CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: dx, ty: dy))
    }
}

/// Provider → logo, color and monogram.
enum ProviderLogos {
    struct Logo: Sendable {
        let path: Path
        /// Logo box as a fraction of the disc diameter (optical balance per mark).
        var scale: CGFloat = 0.56
        var dx: CGFloat = 0
        var dy: CGFloat = 0
    }

    static func isSilicon(_ provider: String) -> Bool { canonical(provider) == "silicon" }

    /// Maps provider ids and their variants ("antigravity-cli", "cursor-agent"…) to a logo family.
    static func canonical(_ provider: String) -> String {
        let p = provider.lowercased()
        if p.hasPrefix("claude") || p == "anthropic" { return "claude" }
        if p.hasPrefix("codex") || p.hasPrefix("openai") || p == "chatgpt" { return "openai" }
        if p.hasPrefix("gemini") || p.hasPrefix("antigravity") || p == "agy" || p == "google" { return "gemini" }
        if p.hasPrefix("opencode") { return "opencode" }
        if p.hasPrefix("cursor") { return "cursor" }
        if p.contains("copilot") { return "copilot" }
        if p.hasPrefix("grok") || p == "xai" { return "grok" }
        if p.hasPrefix("qwen") { return "qwen" }
        if p.hasPrefix("windsurf") || p.hasPrefix("codeium") { return "windsurf" }
        if p.hasPrefix("zed") { return "zed" }
        if p.hasPrefix("silicon") { return "silicon" }
        return p
    }

    static func logo(for provider: String) -> Logo? {
        switch canonical(provider) {
        case "claude": claude
        case "openai": openai
        case "gemini": gemini
        case "opencode": opencode
        case "cursor": cursor
        case "copilot": copilot
        case "grok": grok
        case "qwen": qwen
        case "windsurf": windsurf
        case "zed": zed
        default: nil
        }
    }

    /// The catalog's color when it knows the provider, else a brand-ish fallback for the logos we
    /// carry, else the catalog's neutral default.
    static func color(for provider: String) -> Color {
        if ProviderCatalog.known.contains(where: { $0.id == provider }) {
            return ProviderCatalog.info(for: provider).color
        }
        let hex: String? = switch canonical(provider) {
        case "claude": "D97757"
        case "openai": "10A37F"
        case "gemini": "4F7CEC"
        case "opencode": "6E6E6E"
        case "cursor": "2F2F2F"
        case "copilot": "8250DF"
        case "grok": "2B2B2B"
        case "qwen": "615CED"
        case "windsurf": "0B8F7A"
        case "zed": "084CCF"
        case "hermes": "A8833F"
        case "openclaw": "E0533D"
        case "omni": "4C86FF"
        case "pi": "8B5CF6"
        default: nil
        }
        return hex.map { Color(hex: $0) } ?? ProviderCatalog.info(for: provider).color
    }

    static func monogram(for provider: String, fallback: String) -> String {
        switch canonical(provider) {
        case "pi": "π"
        case "hermes": "H"
        case "openclaw": "OC"
        case "omni": "Ω"
        case "amp": "A"
        case "aider": "ai"
        case "goose": "G"
        case "kiro": "K"
        case "crush": "C"
        default: fallback.isEmpty ? String(provider.prefix(1)).uppercased() : fallback
        }
    }

    // MARK: Vectors (24×24 viewBox)

    static let claude = Logo(path: SVGPathParser.parse(
        "m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z"
    ), scale: 0.6)

    static let openai = Logo(path: SVGPathParser.parse(
        "M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708 0 0 1-.5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464zM2.3408 7.8956a4.485 4.485 0 0 1 2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543-2.0201 1.1685a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.872zm16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .071 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.667zm2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1 .0284-.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.02-1.1638a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927.6813zm1.0976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067-1.4997Z"
    ), scale: 0.6)

    static let gemini = Logo(path: SVGPathParser.parse(
        "M11.04 19.32Q12 21.51 12 24q0-2.49.93-4.68.96-2.19 2.58-3.81t3.81-2.55Q21.51 12 24 12q-2.49 0-4.68-.93a12.3 12.3 0 0 1-3.81-2.58 12.3 12.3 0 0 1-2.58-3.81Q12 2.49 12 0q0 2.49-.96 4.68-.93 2.19-2.55 3.81a12.3 12.3 0 0 1-3.81 2.58Q2.49 12 0 12q2.49 0 4.68.96 2.19.93 3.81 2.55t2.55 3.81"
    ), scale: 0.6)

    static let opencode = Logo(path: SVGPathParser.parse("M22 24H2V0h20zM17 4.8H7v14.4h10z"), scale: 0.46)

    static let cursor = Logo(path: SVGPathParser.parse(
        "M11.503.131 1.891 5.678a.84.84 0 0 0-.42.726v11.188c0 .3.162.575.42.724l9.609 5.55a1 1 0 0 0 .998 0l9.61-5.55a.84.84 0 0 0 .42-.724V6.404a.84.84 0 0 0-.42-.726L12.497.131a1.01 1.01 0 0 0-.996 0M2.657 6.338h18.55c.263 0 .43.287.297.515L12.23 22.918c-.062.107-.229.064-.229-.06V12.335a.59.59 0 0 0-.295-.51l-9.11-5.257c-.109-.063-.064-.23.061-.23"
    ), scale: 0.58)

    static let copilot = Logo(path: SVGPathParser.parse(
        "M23.922 16.997C23.061 18.492 18.063 22.02 12 22.02 5.937 22.02.939 18.492.078 16.997A.641.641 0 0 1 0 16.741v-2.869a.883.883 0 0 1 .053-.22c.372-.935 1.347-2.292 2.605-2.656.167-.429.414-1.055.644-1.517a10.098 10.098 0 0 1-.052-1.086c0-1.331.282-2.499 1.132-3.368.397-.406.89-.717 1.474-.952C7.255 2.937 9.248 1.98 11.978 1.98c2.731 0 4.767.957 6.166 2.093.584.235 1.077.546 1.474.952.85.869 1.132 2.037 1.132 3.368 0 .368-.014.733-.052 1.086.23.462.477 1.088.644 1.517 1.258.364 2.233 1.721 2.605 2.656a.841.841 0 0 1 .053.22v2.869a.641.641 0 0 1-.078.256Zm-11.75-5.992h-.344a4.359 4.359 0 0 1-.355.508c-.77.947-1.918 1.492-3.508 1.492-1.725 0-2.989-.359-3.782-1.259a2.137 2.137 0 0 1-.085-.104L4 11.746v6.585c1.435.779 4.514 2.179 8 2.179 3.486 0 6.565-1.4 8-2.179v-6.585l-.098-.104s-.033.045-.085.104c-.793.9-2.057 1.259-3.782 1.259-1.59 0-2.738-.545-3.508-1.492a4.359 4.359 0 0 1-.355-.508Zm2.328 3.25c.549 0 1 .451 1 1v2c0 .549-.451 1-1 1-.549 0-1-.451-1-1v-2c0-.549.451-1 1-1Zm-5 0c.549 0 1 .451 1 1v2c0 .549-.451 1-1 1-.549 0-1-.451-1-1v-2c0-.549.451-1 1-1Zm3.313-6.185c.136 1.057.403 1.913.878 2.497.442.544 1.134.938 2.344.938 1.573 0 2.292-.337 2.657-.751.384-.435.558-1.15.558-2.361 0-1.14-.243-1.847-.705-2.319-.477-.488-1.319-.862-2.824-1.025-1.487-.161-2.192.138-2.533.529-.269.307-.437.808-.438 1.578v.021c0 .265.021.562.063.893Zm-1.626 0c.042-.331.063-.628.063-.894v-.02c-.001-.77-.169-1.271-.438-1.578-.341-.391-1.046-.69-2.533-.529-1.505.163-2.347.537-2.824 1.025-.462.472-.705 1.179-.705 2.319 0 1.211.175 1.926.558 2.361.365.414 1.084.751 2.657.751 1.21 0 1.902-.394 2.344-.938.475-.584.742-1.44.878-2.497Z"
    ), scale: 0.62)

    static let qwen = Logo(path: SVGPathParser.parse(
        "M23.919 14.545 20.817 9.17l1.47-2.544a.56.56 0 0 0 0-.566l-1.633-2.83a.57.57 0 0 0-.49-.283h-6.207L12.487.402a.57.57 0 0 0-.49-.284H8.732a.56.56 0 0 0-.49.284L5.139 5.775h-2.94a.56.56 0 0 0-.49.284L.077 8.887a.56.56 0 0 0 0 .567L3.18 14.83l-1.47 2.545a.56.56 0 0 0 0 .566l1.634 2.83a.57.57 0 0 0 .49.283h6.205l1.47 2.545a.57.57 0 0 0 .49.284h3.266a.57.57 0 0 0 .49-.284l3.104-5.375h2.94a.57.57 0 0 0 .49-.283l1.634-2.828a.55.55 0 0 0-.004-.568M8.733.686l1.634 2.828-1.634 2.828H21.8L20.164 9.17H7.425L5.63 6.06Zm1.306 19.801-6.205-.002 1.634-2.83h3.265L2.201 6.344h3.267q3.182 5.517 6.367 11.032zm10.124-5.66L18.53 12l-6.532 11.315-1.634-2.83c2.129-3.673 4.25-7.351 6.373-11.028h3.592l3.102 5.374z"
    ), scale: 0.58)

    static let windsurf = Logo(path: SVGPathParser.parse(
        "M23.55 5.067c-1.2038-.002-2.1806.973-2.1806 2.1765v4.8676c0 .972-.8035 1.7594-1.7597 1.7594-.568 0-1.1352-.286-1.4718-.7659l-4.9713-7.1003c-.4125-.5896-1.0837-.941-1.8103-.941-1.1334 0-2.1533.9635-2.1533 2.153v4.8957c0 .972-.7969 1.7594-1.7596 1.7594-.57 0-1.1363-.286-1.4728-.7658L.4076 5.1598C.2822 4.9798 0 5.0688 0 5.2882v4.2452c0 .2147.0656.4228.1884.599l5.4748 7.8183c.3234.462.8006.8052 1.3509.9298 1.3771.313 2.6446-.747 2.6446-2.0977v-4.893c0-.972.7875-1.7593 1.7596-1.7593h.003a1.798 1.798 0 0 1 1.4718.7658l4.9723 7.0994c.4135.5905 1.05.941 1.8093.941 1.1587 0 2.1515-.9645 2.1515-2.153v-4.8948c0-.972.7875-1.7594 1.7596-1.7594h.194a.22.22 0 0 0 .2204-.2202v-4.622a.22.22 0 0 0-.2203-.2203Z"
    ), scale: 0.6)

    static let zed = Logo(path: SVGPathParser.parse(
        "M2.25 1.5a.75.75 0 0 0-.75.75v16.5H0V2.25A2.25 2.25 0 0 1 2.25 0h20.095c1.002 0 1.504 1.212.795 1.92L10.764 14.298h3.486V12.75h1.5v1.922a1.125 1.125 0 0 1-1.125 1.125H9.264l-2.578 2.578h11.689V9h1.5v9.375a1.5 1.5 0 0 1-1.5 1.5H5.185L2.562 22.5H21.75a.75.75 0 0 0 .75-.75V5.25H24v16.5A2.25 2.25 0 0 1 21.75 24H1.655C.653 24 .151 22.788.86 22.08L13.19 9.75H9.75v1.5h-1.5V9.375A1.125 1.125 0 0 1 9.375 8.25h5.314l2.625-2.625H5.625V15h-1.5V5.625a1.5 1.5 0 0 1 1.5-1.5h13.19L21.438 1.5z"
    ), scale: 0.54)

    /// Grok (xAI): an open ring with a bold stroke escaping through its upper-right gap, like
    /// matter leaving an event horizon. Drawn here (simple-icons has no xAI/Grok mark).
    static let grok: Logo = {
        let c = CGPoint(x: 11.2, y: 12.8), r: CGFloat = 8.4
        var ring = Path()
        ring.addArc(center: c, radius: r, startAngle: .degrees(-18), endAngle: .degrees(252), clockwise: false)
        var p = ring.strokedPath(StrokeStyle(lineWidth: 2.5, lineCap: .round))
        var bolt = Path()
        bolt.move(to: CGPoint(x: 8.6, y: 15.6))
        bolt.addLine(to: CGPoint(x: 20.6, y: 1.8))
        bolt.addLine(to: CGPoint(x: 23.2, y: 1.8))
        bolt.addLine(to: CGPoint(x: 11.4, y: 16.6))
        bolt.addQuadCurve(to: CGPoint(x: 8.6, y: 15.6), control: CGPoint(x: 9.6, y: 17.6))
        bolt.closeSubpath()
        p.addPath(bolt)
        return Logo(path: p, scale: 0.6, dx: 0.01, dy: 0)
    }()
}

/// Minimal SVG path-data parser (M L H V C S Q T A Z, absolute and relative, implicit repeats,
/// compact number syntax like ".5.5" and packed arc flags) producing a SwiftUI `Path`.
enum SVGPathParser {
    static func parse(_ d: String) -> Path {
        var s = Scanner(Array(d.utf8))
        var path = Path()
        var cur = CGPoint.zero, start = CGPoint.zero
        var lastCubic: CGPoint?, lastQuad: CGPoint?
        var cmd: UInt8 = 0

        while true {
            s.skipSeparators()
            guard let c = s.peek() else { break }
            if s.isCommand(c) {
                cmd = c; s.advance()
            } else if cmd == 0 {
                break   // garbage before the first command
            }
            let rel = cmd >= 97   // lowercase
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y) }

            switch cmd | 0x20 {   // lowercase
            case UInt8(ascii: "m"):
                guard let x = s.number(), let y = s.number() else { return path }
                cur = pt(x, y); start = cur
                path.move(to: cur)
                cmd = rel ? UInt8(ascii: "l") : UInt8(ascii: "L")   // implicit lineto
                lastCubic = nil; lastQuad = nil
            case UInt8(ascii: "l"):
                guard let x = s.number(), let y = s.number() else { return path }
                cur = pt(x, y); path.addLine(to: cur)
                lastCubic = nil; lastQuad = nil
            case UInt8(ascii: "h"):
                guard let x = s.number() else { return path }
                cur = CGPoint(x: rel ? cur.x + x : x, y: cur.y); path.addLine(to: cur)
                lastCubic = nil; lastQuad = nil
            case UInt8(ascii: "v"):
                guard let y = s.number() else { return path }
                cur = CGPoint(x: cur.x, y: rel ? cur.y + y : y); path.addLine(to: cur)
                lastCubic = nil; lastQuad = nil
            case UInt8(ascii: "c"):
                guard let x1 = s.number(), let y1 = s.number(), let x2 = s.number(), let y2 = s.number(),
                      let x = s.number(), let y = s.number() else { return path }
                let c1 = pt(x1, y1), c2 = pt(x2, y2), e = pt(x, y)
                path.addCurve(to: e, control1: c1, control2: c2)
                lastCubic = c2; lastQuad = nil; cur = e
            case UInt8(ascii: "s"):
                guard let x2 = s.number(), let y2 = s.number(), let x = s.number(), let y = s.number() else { return path }
                let c1 = lastCubic.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let c2 = pt(x2, y2), e = pt(x, y)
                path.addCurve(to: e, control1: c1, control2: c2)
                lastCubic = c2; lastQuad = nil; cur = e
            case UInt8(ascii: "q"):
                guard let x1 = s.number(), let y1 = s.number(), let x = s.number(), let y = s.number() else { return path }
                let c1 = pt(x1, y1), e = pt(x, y)
                path.addQuadCurve(to: e, control: c1)
                lastQuad = c1; lastCubic = nil; cur = e
            case UInt8(ascii: "t"):
                guard let x = s.number(), let y = s.number() else { return path }
                let c1 = lastQuad.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let e = pt(x, y)
                path.addQuadCurve(to: e, control: c1)
                lastQuad = c1; lastCubic = nil; cur = e
            case UInt8(ascii: "a"):
                guard let rx = s.number(), let ry = s.number(), let rot = s.number(),
                      let large = s.flag(), let sweep = s.flag(), let x = s.number(), let y = s.number() else { return path }
                let e = pt(x, y)
                addArc(&path, from: cur, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep, to: e)
                cur = e; lastCubic = nil; lastQuad = nil
            case UInt8(ascii: "z"):
                path.closeSubpath(); cur = start
                lastCubic = nil; lastQuad = nil
                cmd = 0   // a number after Z without a command is invalid; a command must follow
                s.skipSeparators()
                if let n = s.peek(), !s.isCommand(n) { return path }
            default:
                return path
            }
        }
        return path
    }

    /// SVG elliptical arc → cubic Béziers (W3C SVG 1.1 implementation notes, F.6.5).
    static func addArc(_ path: inout Path, from p0: CGPoint, rx rx0: CGFloat, ry ry0: CGFloat, rotation: CGFloat,
                       large: Bool, sweep: Bool, to p1: CGPoint) {
        if p0 == p1 { return }
        var rx = abs(rx0), ry = abs(ry0)
        if rx == 0 || ry == 0 { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180, cp = cos(phi), sp = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cp * dx + sp * dy, y1 = -sp * dx + cp * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { let k = lambda.squareRoot(); rx *= k; ry *= k }
        let rx2 = rx * rx, ry2 = ry * ry
        let num = max(0, rx2 * ry2 - rx2 * y1 * y1 - ry2 * x1 * x1)
        let den = rx2 * y1 * y1 + ry2 * x1 * x1
        var coef = den == 0 ? 0 : (num / den).squareRoot()
        if large == sweep { coef = -coef }
        let cxp = coef * (rx * y1 / ry), cyp = coef * -(ry * x1 / rx)
        let cx = cp * cxp - sp * cyp + (p0.x + p1.x) / 2
        let cy = sp * cxp + cp * cyp + (p0.y + p1.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let len = ((ux * ux + uy * uy) * (vx * vx + vy * vy)).squareRoot()
            guard len > 0 else { return 0 }
            var a = acos(min(1, max(-1, (ux * vx + uy * vy) / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let ux = (x1 - cxp) / rx, uy = (y1 - cyp) / ry
        let vx = (-x1 - cxp) / rx, vy = (-y1 - cyp) / ry
        let theta1 = angle(1, 0, ux, uy)
        var dTheta = angle(ux, uy, vx, vy)
        if !sweep && dTheta > 0 { dTheta -= 2 * .pi }
        if sweep && dTheta < 0 { dTheta += 2 * .pi }

        let segments = max(1, Int((abs(dTheta) / (.pi / 2)).rounded(.up)))
        let delta = dTheta / CGFloat(segments)
        let k = 4 / 3 * tan(delta / 4)
        func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * x * cp - ry * y * sp, y: cy + rx * x * sp + ry * y * cp)
        }
        var th = theta1
        for i in 0..<segments {
            let c1 = cos(th), s1 = sin(th)
            let th2 = th + delta
            let c2 = cos(th2), s2 = sin(th2)
            let end = i == segments - 1 ? p1 : map(c2, s2)
            path.addCurve(to: end, control1: map(c1 - k * s1, s1 + k * c1), control2: map(c2 + k * s2, s2 - k * c2))
            th = th2
        }
    }

    struct Scanner {
        let b: [UInt8]
        var i = 0
        init(_ b: [UInt8]) { self.b = b }

        func peek() -> UInt8? { i < b.count ? b[i] : nil }
        mutating func advance() { i += 1 }

        func isCommand(_ c: UInt8) -> Bool {
            switch c {
            case UInt8(ascii: "e"), UInt8(ascii: "E"): false
            case 65...90, 97...122: true
            default: false
            }
        }

        mutating func skipSeparators() {
            while i < b.count, b[i] == 32 || b[i] == 44 || b[i] == 9 || b[i] == 10 || b[i] == 13 { i += 1 }
        }

        mutating func flag() -> Bool? {
            skipSeparators()
            guard i < b.count else { return nil }
            let c = b[i]
            guard c == 48 || c == 49 else { return nil }
            i += 1
            return c == 49
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            let startIndex = i
            if i < b.count, b[i] == 43 || b[i] == 45 { i += 1 }   // + -
            var sawDigit = false, sawDot = false
            while i < b.count {
                let c = b[i]
                if c >= 48 && c <= 57 { sawDigit = true; i += 1 }
                else if c == 46 && !sawDot { sawDot = true; i += 1 }   // "."
                else { break }
            }
            if sawDigit, i < b.count, b[i] == 101 || b[i] == 69 {   // exponent
                var j = i + 1
                if j < b.count, b[j] == 43 || b[j] == 45 { j += 1 }
                if j < b.count, b[j] >= 48 && b[j] <= 57 {
                    i = j
                    while i < b.count, b[i] >= 48 && b[i] <= 57 { i += 1 }
                }
            }
            guard sawDigit, let str = String(bytes: b[startIndex..<i], encoding: .ascii), let v = Double(str) else {
                i = startIndex
                return nil
            }
            return CGFloat(v)
        }
    }
}
