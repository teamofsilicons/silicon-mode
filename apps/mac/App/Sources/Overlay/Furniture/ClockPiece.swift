import SwiftUI
import SiliconModeKit

/// A clock on the face, in one of three styles (option `style`), on glass like every piece:
/// - `digital`: big Allo thin time over an SF Pro date line, like the Lock Screen, on a glass panel.
/// - `analog`: a minimal dial on a Liquid Glass disc; an orange seconds hand ticks only with
///   `seconds` on.
/// - `words`: "it's ten forty-two" with the lit words in silicon ink, and the weekday, on a glass panel.
///
/// It redraws once a minute (once a second with `seconds` on, for digital and analog), in its own
/// timeline, so nothing else re-renders with it. Snapshots show the frozen `FaceA.wallDate`.
struct ClockPiece: View {
    let options: [String: FaceOptionValue]
    let leading: Bool

    /// Inset of the digital and words clocks inside their glass panel.
    static let panelInset = EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20)

    static func height(style: String) -> CGFloat {
        let panel = panelInset.top + panelInset.bottom
        switch style {
        case "analog": return AnalogClock.side
        case "words": return WordsClock.height + panel
        default: return DigitalClock.height + panel
        }
    }

    var body: some View {
        let style = FurnitureOptions.clockStyle(options)
        let use24h = FurnitureOptions.bool(options, FurnitureOptions.Clock.use24h, ClockFace.localePrefers24h)
        let seconds = FurnitureOptions.bool(options, FurnitureOptions.Clock.seconds, false) && style != "words"
        // Every minute on the minute (every second with seconds): the reference date is minute-aligned.
        TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: seconds ? 1 : 60)) { tl in
            let now = FaceA.wallDate(now: tl.date, fixed: HUDRender.isSnapshot ? 0 : nil)
            Group {
                switch style {
                case "analog": AnalogClock(date: now, seconds: seconds)
                case "words": WordsClock(date: now, leading: leading).padding(Self.panelInset).hudPanel()
                default: DigitalClock(date: now, use24h: use24h, seconds: seconds, leading: leading).padding(Self.panelInset).hudPanel()
                }
            }
            .frame(maxWidth: .infinity, alignment: leading ? .leading : .trailing)
        }
        .frame(height: Self.height(style: style))
        .accessibilityElement(children: .combine)
    }
}

/// Shared parts of the time, so every style reads the same components.
struct ClockParts {
    let hour: Int, minute: Int, second: Int, weekday: String, date: String

    init(_ d: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.hour, .minute, .second], from: d)
        hour = c.hour ?? 0; minute = c.minute ?? 0; second = c.second ?? 0
        weekday = d.formatted(.dateTime.weekday(.wide))
        date = d.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

// MARK: - Digital

private struct DigitalClock: View {
    let date: Date
    let use24h: Bool
    let seconds: Bool
    let leading: Bool

    static let height: CGFloat = 104

    var body: some View {
        let p = ClockParts(date)
        let h = use24h ? p.hour : (p.hour % 12 == 0 ? 12 : p.hour % 12)
        let time = use24h ? String(format: "%02d:%02d", h, p.minute) : String(format: "%d:%02d", h, p.minute)
        VStack(alignment: leading ? .leading : .trailing, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(time)
                    .font(Theme.allo(72, .thin))
                    .tracking(Theme.tracking(72, display: true))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                if seconds || !use24h {
                    VStack(alignment: .leading, spacing: 0) {
                        if !use24h {
                            Text(p.hour < 12 ? "AM" : "PM")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                        if seconds {
                            Text(String(format: "%02d", p.second))
                                .font(.title2.weight(.light))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(height: 78)
            Text(p.date)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .accessibilityLabel(date.formatted(date: .complete, time: .shortened))
    }
}

// MARK: - Analog

private struct AnalogClock: View {
    let date: Date
    let seconds: Bool

    static let side: CGFloat = 124

    var body: some View {
        let p = ClockParts(date)
        let minute = Double(p.minute) + (seconds ? Double(p.second) / 60 : 0)
        let hour = Double(p.hour % 12) + minute / 60
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            func point(_ turns: Double, _ len: CGFloat) -> CGPoint {
                let a = turns * 2 * .pi
                return CGPoint(x: c.x + CGFloat(sin(a)) * len, y: c.y - CGFloat(cos(a)) * len)
            }
            // Ticks: majors at 12, 3, 6, 9.
            for i in 0..<12 {
                let major = i % 3 == 0
                var t = Path()
                t.move(to: point(Double(i) / 12, r - 9))
                t.addLine(to: point(Double(i) / 12, r - (major ? 19 : 14)))
                ctx.stroke(t, with: .color(Color.white.opacity(major ? 0.75 : 0.3)),
                           style: StrokeStyle(lineWidth: major ? 2 : 1.2, lineCap: .round))
            }
            func hand(_ turns: Double, _ len: CGFloat, _ width: CGFloat, _ color: Color, tail: CGFloat = 6) {
                var h = Path()
                h.move(to: point(turns + 0.5, tail))
                h.addLine(to: point(turns, len))
                ctx.stroke(h, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
            hand(hour / 12, r * 0.5, 3.4, .white)
            hand(minute / 60, r * 0.74, 2.2, Color.white.opacity(0.92))
            if seconds {
                hand(Double(p.second) / 60, r * 0.8, 1.1, .orange, tail: 12)
            }
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3.2, y: c.y - 3.2, width: 6.4, height: 6.4)),
                     with: .color(seconds ? .orange : .white))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 1.2, y: c.y - 1.2, width: 2.4, height: 2.4)),
                     with: .color(.black))
        }
        .frame(width: Self.side, height: Self.side)
        .hudGlass(in: Circle())
        .accessibilityLabel(date.formatted(date: .omitted, time: .shortened))
    }
}

// MARK: - Words

private struct WordsClock: View {
    let date: Date
    let leading: Bool

    static let height: CGFloat = 76

    var body: some View {
        let p = ClockParts(date)
        let w = Self.words(hour: p.hour, minute: p.minute)
        let ink = LinearGradient(colors: [Theme.Night.lavender, Theme.Night.peach], startPoint: .leading, endPoint: .trailing)
        let dim = Color.white.opacity(0.34)
        VStack(alignment: leading ? .leading : .trailing, spacing: 6) {
            Text("\(Text("it's ").foregroundStyle(dim))\(Text(w).foregroundStyle(ink))")
                .font(Theme.allo(30, .medium))
                .tracking(Theme.tracking(30, display: true))
                .minimumScaleFactor(0.6)
            Text("\(Text(p.weekday).foregroundStyle(.secondary)) \(Text(Self.period(p.hour)).foregroundStyle(.tertiary))")
                .font(.title3.weight(.semibold))
        }
        .lineLimit(1)
        .multilineTextAlignment(leading ? .leading : .trailing)
        .accessibilityLabel("It's \(w), \(p.weekday)")
    }

    private static let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                               "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty"]

    /// "ten forty-two", "ten oh five", "ten o'clock", "noon", "midnight" (12-hour, as spoken).
    static func words(hour: Int, minute: Int) -> String {
        if minute == 0 && hour == 0 { return "midnight" }
        if minute == 0 && hour == 12 { return "noon" }
        let h = ones[hour % 12 == 0 ? 12 : hour % 12]
        switch minute {
        case 0: return "\(h) o'clock"
        case 1...9: return "\(h) oh \(ones[minute])"
        case 10...19: return "\(h) \(ones[minute])"
        default:
            let t = tens[minute / 10], o = minute % 10
            return o == 0 ? "\(h) \(t)" : "\(h) \(t)-\(ones[o])"
        }
    }

    static func period(_ hour: Int) -> String {
        switch hour {
        case 5..<12: "morning"
        case 12..<17: "afternoon"
        case 17..<21: "evening"
        default: "night"
        }
    }
}
