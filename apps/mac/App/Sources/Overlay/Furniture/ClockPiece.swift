import SwiftUI
import SiliconModeKit

/// A clock on the face, in one of three styles (option `style`):
/// - `digital`: big Allo thin time with a date line.
/// - `analog`: a minimal dial on a glass disc; a peach seconds hand ticks only with `seconds` on.
/// - `words`: "it's ten forty-two" with the lit words in silicon ink, and the weekday.
///
/// It redraws once a minute (once a second with `seconds` on, for digital and analog), in its own
/// timeline, so nothing else re-renders with it. Snapshots show the frozen `FaceA.wallDate`.
struct ClockPiece: View {
    let options: [String: FaceOptionValue]
    let leading: Bool

    static func height(style: String) -> CGFloat {
        switch style {
        case "analog": AnalogClock.side
        case "words": WordsClock.height
        default: DigitalClock.height
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
                case "words": WordsClock(date: now, leading: leading)
                default: DigitalClock(date: now, use24h: use24h, seconds: seconds, leading: leading)
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
                    .foregroundStyle(Theme.Night.foreground.opacity(0.95))
                if seconds || !use24h {
                    VStack(alignment: .leading, spacing: 0) {
                        if !use24h {
                            Text(p.hour < 12 ? "AM" : "PM")
                                .font(Theme.allo(14, .medium))
                                .tracking(0.6)
                                .foregroundStyle(Theme.Night.secondary)
                        }
                        if seconds {
                            Text(String(format: "%02d", p.second))
                                .font(Theme.allo(20, .light))
                                .monospacedDigit()
                                .foregroundStyle(LinearGradient(colors: [Theme.Night.lavender, Theme.Night.peach],
                                                                startPoint: .leading, endPoint: .trailing))
                        }
                    }
                }
            }
            .frame(height: 78)
            Text(p.date)
                .font(Theme.allo(14, .medium))
                .tracking(Theme.tracking(14))
                .foregroundStyle(Theme.Night.secondary)
        }
        .lineLimit(1)
        .shadow(color: .black.opacity(0.45), radius: 16)
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
                ctx.stroke(t, with: .color(major ? Theme.Night.secondary : Theme.Night.faint),
                           style: StrokeStyle(lineWidth: major ? 2 : 1.2, lineCap: .round))
            }
            func hand(_ turns: Double, _ len: CGFloat, _ width: CGFloat, _ color: Color, tail: CGFloat = 6) {
                var h = Path()
                h.move(to: point(turns + 0.5, tail))
                h.addLine(to: point(turns, len))
                ctx.stroke(h, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
            hand(hour / 12, r * 0.5, 3.4, Theme.Night.foreground)
            hand(minute / 60, r * 0.74, 2.2, Theme.Night.foreground.opacity(0.92))
            if seconds {
                hand(Double(p.second) / 60, r * 0.8, 1.1, Theme.Night.peach, tail: 12)
            }
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3.2, y: c.y - 3.2, width: 6.4, height: 6.4)),
                     with: .color(seconds ? Theme.Night.peach : Theme.Night.foreground))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 1.2, y: c.y - 1.2, width: 2.4, height: 2.4)),
                     with: .color(Theme.Night.background))
        }
        .frame(width: Self.side, height: Self.side)
        .background(Circle().fill(Color.black.opacity(0.18)))
        .hudGlass(in: Circle())
        .hudHairline(Circle())
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
            Text("\(Text(p.weekday.lowercased()).foregroundStyle(Theme.Night.secondary)) \(Text(Self.period(p.hour)).foregroundStyle(dim))")
                .font(Theme.allo(16, .medium))
                .tracking(Theme.tracking(16))
        }
        .lineLimit(1)
        .multilineTextAlignment(leading ? .leading : .trailing)
        .shadow(color: .black.opacity(0.45), radius: 14)
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
