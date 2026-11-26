import SwiftUI
import SiliconModeKit

/// Clock: a giant, elegant clock (Allo thin, tabular numerals that roll — or a real split-flap),
/// the date, a breathing silicon aura, and an "agent pulse" underneath.
enum ClockFace {
    static let descriptor = FaceDescriptor(
        id: "clock",
        name: "Clock",
        summary: "A big, calm clock with your agents' pulse underneath.",
        options: [
            FaceOptionSpec(key: "style", label: "Style", kind: .choice(options: [
                (id: "aura", label: "Aura"), (id: "minimal", label: "Minimal"), (id: "flap", label: "Split-flap"),
            ], default: "aura")),
            FaceOptionSpec(key: "use24h", label: "24-hour time", kind: .toggle(default: localePrefers24h)),
            FaceOptionSpec(key: "seconds", label: "Show seconds", kind: .toggle(default: true)),
        ],
        make: { ctx in AnyView(ClockFaceView(ctx: ctx)) }
    )

    /// Whether the user's locale writes times without AM/PM.
    static let localePrefers24h: Bool = {
        let f = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "H"
        return !f.contains("a")
    }()
}

/// The digits on display at one instant, plus when each one last changed.
struct ClockReading {
    /// [H tens, H ones, M tens, M ones, S tens, S ones]; -1 = blank (12-hour leading digit).
    var digits: [Int]
    /// Seconds since each digit last changed (∞ if it didn't change at its last boundary).
    var ages: [Double]
    var prev: [Int]
    var isPM: Bool

    init(date: Date, use24h: Bool) {
        let tz = TimeZone.current.secondsFromGMT(for: date)
        let x = date.timeIntervalSince1970 + Double(tz)
        let sod = x - floor(x / 86400) * 86400
        func digitsAt(_ s: Double) -> [Int] {
            let s = s < 0 ? s + 86400 : s
            let total = Int(floor(s))
            var h = (total / 3600) % 24
            let m = (total / 60) % 60, sec = total % 60
            if !use24h { h = h % 12 == 0 ? 12 : h % 12 }
            let h1 = h / 10
            return [(!use24h && h1 == 0) ? -1 : h1, h % 10, m / 10, m % 10, sec / 10, sec % 10]
        }
        digits = digitsAt(sod)
        isPM = Int(sod) / 3600 >= 12
        let periods: [Double] = [3600, 3600, 600, 60, 10, 1]
        var ages = [Double](repeating: .infinity, count: 6)
        var prev = digits
        for i in 0..<6 {
            let change = floor(sod / periods[i]) * periods[i]
            let before = digitsAt(change - 0.01)
            if before[i] != digits[i] {
                ages[i] = sod - change
                prev[i] = before[i]
            }
        }
        self.ages = ages
        self.prev = prev
    }
}

/// Dense frames right after each tick (for the roll / flip), sparse frames otherwise. Keeps a
/// clock that runs for hours cheap on CPU.
struct ClockFaceSchedule: TimelineSchedule {
    var period: Double
    var dense: Double
    var idle: Double

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        mode == .lowFrequency
            ? Entries(cursor: startDate, period: 1, dense: 0, idle: 1)
            : Entries(cursor: startDate, period: period, dense: dense, idle: idle)
    }

    struct Entries: Sequence, IteratorProtocol {
        var cursor: Date
        let period: Double
        let dense: Double
        let idle: Double

        mutating func next() -> Date? {
            let d = cursor
            let x = d.timeIntervalSince1970
            let phase = x - floor(x / period) * period
            var step = phase < dense ? 1.0 / 60 : Swift.min(idle, period - phase)
            if step < 1.0 / 240 { step = 1.0 / 60 }
            cursor = d.addingTimeInterval(step)
            return d
        }
    }
}

struct ClockFaceView: View {
    let ctx: FaceContext
    var fixedTime: Double?

    @State private var start = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let style = ctx.string("style", "aura")
        let use24 = ctx.bool("use24h", ClockFace.localePrefers24h)
        let showSeconds = ctx.bool("seconds", true)
        let sessions = FaceA.visibleSessions(ctx.sessions, max: ctx.isPreview ? 4 : 6)
        let busy = style == "aura" || sessions.contains { $0.state == .working || $0.state == .needsYou }
        let schedule = ClockFaceSchedule(period: showSeconds ? 1 : 60, dense: style == "flap" ? 0.7 : 0.75,
                                         idle: ctx.isPreview ? 1.0 / 15 : (busy ? 1.0 / 30 : 1.0 / 8))
        GeometryReader { geo in
            let size = geo.size
            let u = FaceA.unit(for: size)
            TimelineView(schedule) { tl in
                let t = FaceA.elapsed(since: start, now: tl.date, fixed: fixedTime)
                let wall = FaceA.wallDate(now: tl.date, fixed: fixedTime)
                let reading = ClockReading(date: wall, use24h: use24)
                ZStack {
                    if style == "aura" { ClockAura(t: t, reduceMotion: reduceMotion, panicking: ctx.isPanicking) }
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Group {
                            if style == "flap" {
                                ClockFlapTime(reading: reading, use24h: use24, showSeconds: showSeconds,
                                              width: size.width, unit: u, reduceMotion: reduceMotion)
                            } else {
                                ClockRollTime(reading: reading, use24h: use24, showSeconds: showSeconds, aura: style == "aura",
                                              width: size.width, unit: u, t: t, reduceMotion: reduceMotion)
                            }
                        }
                        Text(wall, format: .dateTime.weekday(.wide).month(.wide).day())
                            .font(Theme.allo((ctx.isPreview ? 30 : 22) * u, .regular))
                            .tracking((style == "flap" ? 2.2 : 0.4) * u)
                            .textCase(style == "flap" ? .uppercase : nil)
                            .foregroundStyle(Theme.Night.secondary.opacity(0.8))
                            .padding(.top, (style == "flap" ? 34 : 10) * u)
                        Spacer(minLength: 0)
                        if !ctx.isPreview {
                            ClockAgentPulse(sessions: sessions, counts: ctx.counts, t: t, unit: u, reduceMotion: reduceMotion)
                                .padding(.bottom, 84 * u)
                        } else {
                            ClockPreviewDots(sessions: sessions, unit: u).padding(.bottom, 70 * u)
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .offset(FaceA.drift(t, amplitude: 16 * u))
                }
                .frame(width: size.width, height: size.height)
            }
        }
        .background(Theme.Night.background)
        .overlay(FaceAPanicWash(active: ctx.isPanicking))
        .accessibilityElement()
        .accessibilityLabel(Text(Date(), style: .time))
    }
}

// MARK: - Rolling numerals (minimal / aura)

struct ClockRollTime: View {
    let reading: ClockReading
    let use24h: Bool
    let showSeconds: Bool
    let aura: Bool
    let width: CGFloat
    let unit: CGFloat
    let t: Double
    let reduceMotion: Bool

    var body: some View {
        let big = min(width * 0.2, 300 * unit * 1.02)
        let small = big * 0.27
        let bigWeight: Theme.Weight = aura ? .extraLight : .thin
        let bigFont = Theme.allo(big, bigWeight)
        let smallFont = Theme.allo(small, .light)
        let fill: AnyShapeStyle = aura
            ? AnyShapeStyle(LinearGradient(colors: [.white, Color(hex: "E6DDF6")], startPoint: .top, endPoint: .bottom))
            : AnyShapeStyle(Theme.Night.foreground.opacity(0.94))
        let secFill: AnyShapeStyle = aura
            ? AnyShapeStyle(LinearGradient(colors: [FaceA.lavender.color(), FaceA.peach.color()], startPoint: .leading, endPoint: .trailing))
            : AnyShapeStyle(Theme.Night.muted)
        let colonA = reduceMotion ? 0.7 : 0.5 + 0.35 * (0.5 + 0.5 * cos(t * .pi))

        HStack(alignment: .lastTextBaseline, spacing: 0) {
            if reading.digits[0] >= 0 {
                ClockRollDigit(reading: reading, index: 0, font: bigFont, weight: bigWeight, size: big, fill: fill, reduceMotion: reduceMotion)
            }
            ClockRollDigit(reading: reading, index: 1, font: bigFont, weight: bigWeight, size: big, fill: fill, reduceMotion: reduceMotion)
            Text(":")
                .font(bigFont)
                .foregroundStyle(fill)
                .opacity(colonA)
                .offset(y: -big * 0.06)
                .padding(.horizontal, big * 0.015)
            ClockRollDigit(reading: reading, index: 2, font: bigFont, weight: bigWeight, size: big, fill: fill, reduceMotion: reduceMotion)
            ClockRollDigit(reading: reading, index: 3, font: bigFont, weight: bigWeight, size: big, fill: fill, reduceMotion: reduceMotion)
            if showSeconds || !use24h {
                VStack(alignment: .leading, spacing: small * 0.25) {
                    if !use24h {
                        Text(reading.isPM ? "PM" : "AM")
                            .font(Theme.allo(small * 0.42, .medium))
                            .tracking(small * 0.06)
                            .foregroundStyle(Theme.Night.muted)
                            .padding(.leading, small * 0.06)
                    }
                    if showSeconds {
                        HStack(spacing: 0) {
                            ClockRollDigit(reading: reading, index: 4, font: smallFont, weight: .light, size: small, fill: secFill, reduceMotion: reduceMotion)
                            ClockRollDigit(reading: reading, index: 5, font: smallFont, weight: .light, size: small, fill: secFill, reduceMotion: reduceMotion)
                        }
                    }
                }
                .padding(.leading, big * 0.07)
                .padding(.bottom, big * 0.035)
            }
        }
        .fixedSize()
    }
}

/// One digit that rolls up into its new value on a soft spring, like an odometer drum: it is
/// masked to its own cap-height band, so outgoing and incoming glyphs never leave the numeral.
struct ClockRollDigit: View {
    let reading: ClockReading
    let index: Int
    let font: Font
    let weight: Theme.Weight
    let size: CGFloat
    let fill: AnyShapeStyle
    let reduceMotion: Bool

    var body: some View {
        let cur = reading.digits[index], prev = reading.prev[index]
        let age = reading.ages[index]
        let ct = Theme.ctAllo(size, weight: Theme.weightValue(weight))
        let ascent = CTFontGetAscent(ct), cap = CTFontGetCapHeight(ct), leading = CTFontGetLeading(ct)
        let pad = size * 0.085
        let bandTop = ascent + leading / 2 - cap - pad
        let band = cap + pad * 2
        let travel = band * 0.98
        ZStack {
            Text("0").font(font).monospacedDigit().hidden()
            if age < 0.9, prev != cur {
                let e = reduceMotion ? FaceA.smoothstep(0, 0.3, age) : FaceA.spring(age, response: 0.46, damping: 0.78)
                let blur = reduceMotion ? 0 : max(0, sin(min(1, e) * .pi)) * size * 0.018
                digit(prev)
                    .offset(y: -e * travel)
                    .opacity(max(0, 1 - e * 1.1))
                    .blur(radius: blur)
                digit(cur)
                    .offset(y: (1 - e) * travel)
                    .opacity(min(1, max(0, e * 1.2)))
                    .blur(radius: blur)
            } else {
                digit(cur)
            }
        }
        .mask(alignment: .top) {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                                   .init(color: .black, location: 0.94), .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: band)
                .offset(y: bandTop)
        }
    }

    private func digit(_ d: Int) -> some View {
        Text(d < 0 ? "" : "\(d)").font(font).monospacedDigit().foregroundStyle(fill)
    }
}

// MARK: - Split-flap

struct ClockFlapTime: View {
    let reading: ClockReading
    let use24h: Bool
    let showSeconds: Bool
    let width: CGFloat
    let unit: CGFloat
    let reduceMotion: Bool

    var body: some View {
        let w = min(width * 0.118, 182 * unit)
        let h = w * 1.42
        let gap = w * 0.06
        HStack(alignment: .bottom, spacing: w * 0.16) {
            HStack(spacing: gap) {
                if reading.digits[0] >= 0 { flap(0, w, h) }
                flap(1, w, h)
            }
            ClockFlapColon(height: h, dot: w * 0.075)
            HStack(spacing: gap) {
                flap(2, w, h)
                flap(3, w, h)
            }
            if showSeconds || !use24h {
                VStack(alignment: .leading, spacing: h * 0.08) {
                    if !use24h {
                        Text(reading.isPM ? "PM" : "AM")
                            .font(Theme.allo(w * 0.17, .semibold))
                            .tracking(w * 0.02)
                            .foregroundStyle(Theme.Night.muted)
                    }
                    if showSeconds {
                        HStack(spacing: gap * 0.6) {
                            flap(4, w * 0.44, h * 0.44)
                            flap(5, w * 0.44, h * 0.44)
                        }
                    }
                }
            }
        }
        .fixedSize()
    }

    private func flap(_ i: Int, _ w: CGFloat, _ h: CGFloat) -> some View {
        let d = reading.digits[i], p = reading.prev[i]
        return ClockFlapDigit(current: d < 0 ? "" : "\(d)", previous: p < 0 ? "" : "\(p)", age: reading.ages[i],
                              width: w, height: h, reduceMotion: reduceMotion)
    }
}

struct ClockFlapColon: View {
    let height: CGFloat
    let dot: CGFloat
    var body: some View {
        VStack(spacing: height * 0.22) {
            Circle().fill(Theme.Night.secondary.opacity(0.7)).frame(width: dot, height: dot)
            Circle().fill(Theme.Night.secondary.opacity(0.7)).frame(width: dot, height: dot)
        }
        .frame(height: height)
    }
}

/// A real split-flap: the old top half falls forward on its hinge, then the new bottom half
/// swings down and lands with a little bounce.
struct ClockFlapDigit: View {
    let current: String
    let previous: String
    let age: Double
    let width: CGFloat
    let height: CGFloat
    let reduceMotion: Bool

    static let duration = 0.62

    var body: some View {
        let r = width * 0.085
        let hinge = max(1, height * 0.008)
        let animating = !reduceMotion && age < Self.duration && previous != current
        let p = animating ? age / Self.duration : 1
        ZStack {
            VStack(spacing: hinge) {
                half(current, top: true, radius: r)
                half(animating ? previous : current, top: false, radius: r)
                    .overlay(alignment: .top) {
                        if animating && p < 0.5 {
                            // The falling flap's shadow sweeping over the lower half.
                            LinearGradient(colors: [.black.opacity(0.55 * (p / 0.5)), .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: height / 2 * (0.3 + 0.7 * p / 0.5))
                        }
                    }
            }
            if animating {
                if p < 0.5 {
                    let q = p / 0.5
                    let angle = -90 * q * q
                    half(previous, top: true, radius: r)
                        .overlay(Color.black.opacity(0.5 * q))
                        .rotation3DEffect(.degrees(angle), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.42)
                        .frame(height: height, alignment: .top)
                        .offset(y: -hinge / 2)
                } else {
                    let q = (p - 0.5) / 0.5
                    let angle = 90 * (1 - Self.bounceOut(q))
                    half(current, top: false, radius: r)
                        .overlay(Color.white.opacity(0.07 * (1 - q)))
                        .rotation3DEffect(.degrees(angle), axis: (x: 1, y: 0, z: 0), anchor: .top, perspective: 0.42)
                        .frame(height: height, alignment: .bottom)
                        .offset(y: hinge / 2)
                }
            }
            // Hinge pins.
            HStack {
                Capsule().fill(Color(hex: "2A2A2A")).frame(width: width * 0.035, height: height * 0.07)
                Spacer()
                Capsule().fill(Color(hex: "2A2A2A")).frame(width: width * 0.035, height: height * 0.07)
            }
            .padding(.horizontal, -width * 0.012)
        }
        .frame(width: width, height: height)
        .shadow(color: .black.opacity(0.5), radius: height * 0.04, y: height * 0.02)
    }

    static func bounceOut(_ x: Double) -> Double {
        // Lands, then a small settling bounce.
        let n = 7.5625, d = 2.75
        if x < 1 / d { return n * x * x }
        if x < 2 / d { let y = x - 1.5 / d; return n * y * y + 0.75 }
        if x < 2.5 / d { let y = x - 2.25 / d; return n * y * y + 0.9375 }
        let y = x - 2.625 / d; return n * y * y + 0.984375
    }

    private func half(_ s: String, top: Bool, radius r: CGFloat) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: top ? r : r * 0.15, bottomLeadingRadius: top ? r * 0.15 : r,
                                           bottomTrailingRadius: top ? r * 0.15 : r, topTrailingRadius: top ? r : r * 0.15,
                                           style: .continuous)
        return ZStack {
            shape.fill(LinearGradient(colors: top ? [Color(hex: "212121"), Color(hex: "1A1A1A")] : [Color(hex: "171717"), Color(hex: "121212")],
                                      startPoint: .top, endPoint: .bottom))
            Text(s)
                .font(Theme.allo(height * 0.74, .regular))
                .monospacedDigit()
                .foregroundStyle(Color(hex: "EDEDED"))
                .frame(width: width, height: height)
                .offset(y: -height * 0.015)
                .frame(width: width, height: height / 2, alignment: top ? .top : .bottom)
                .clipped()
            shape.strokeBorder(.white.opacity(top ? 0.07 : 0.035), lineWidth: 1)
        }
        .frame(width: width, height: height / 2)
        .clipShape(shape)
    }
}

// MARK: - Aura

/// Breathing silicon-gradient light behind the numerals.
struct ClockAura: View {
    let t: Double
    let reduceMotion: Bool
    let panicking: Bool

    var body: some View {
        Canvas { g, size in
            let w = size.width, h = size.height
            let tt = reduceMotion ? t * 0.3 : t
            let breath = 0.86 + 0.14 * sin(tt * 2 * .pi / 8)
            let rect = Path(CGRect(origin: .zero, size: size))
            let lav = panicking ? FaceA.red : FaceA.lavender
            let pea = panicking ? FaceA.red : FaceA.peach
            // Deeper, more saturated versions of the silicon pair read as color (not grey) on black.
            let deepLav = panicking ? lav : FaceA.RGB(0x8E74D9)
            let deepPea = panicking ? pea : FaceA.RGB(0xD9925A)
            let c1 = CGPoint(x: w * (0.34 + 0.05 * cos(tt * 2 * .pi / 47)), y: h * (0.38 + 0.05 * sin(tt * 2 * .pi / 47)))
            let c2 = CGPoint(x: w * (0.66 + 0.05 * cos(tt * 2 * .pi / 53 + 2)), y: h * (0.48 + 0.05 * sin(tt * 2 * .pi / 53 + 2)))
            let c3 = CGPoint(x: w * (0.5 + 0.08 * sin(tt * 2 * .pi / 71)), y: h * (0.3 + 0.04 * cos(tt * 2 * .pi / 61)))
            let rad = max(w, h) * 0.42
            g.blendMode = .plusLighter
            g.fill(rect, with: .radialGradient(Gradient(colors: [deepLav.color(0.34 * breath), deepLav.color(0.1 * breath), .clear]),
                                               center: c1, startRadius: 0, endRadius: rad * (1 + 0.06 * sin(tt / 3))))
            g.fill(rect, with: .radialGradient(Gradient(colors: [deepPea.color(0.28 * breath), deepPea.color(0.08 * breath), .clear]),
                                               center: c2, startRadius: 0, endRadius: rad * (1 + 0.06 * cos(tt / 3.4))))
            g.fill(rect, with: .radialGradient(Gradient(colors: [FaceA.accent.color(0.06 * breath), .clear]),
                                               center: c3, startRadius: 0, endRadius: rad * 0.8))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Agent pulse

struct ClockAgentPulse: View {
    let sessions: [AgentSession]
    let counts: AgentCounts
    let t: Double
    let unit: CGFloat
    let reduceMotion: Bool

    var body: some View {
        VStack(spacing: 20 * unit) {
            if sessions.isEmpty {
                ClockHeartline(t: t, unit: unit, reduceMotion: reduceMotion)
                    .frame(width: 320 * unit, height: 34 * unit)
            } else {
                HStack(alignment: .top, spacing: 30 * unit) {
                    ForEach(sessions) { s in
                        VStack(spacing: 9 * unit) {
                            HStack(spacing: 9 * unit) {
                                ProviderMark(provider: s.provider, size: 22 * unit)
                                ClockEqualizer(state: s.state, seed: Double(FaceA.hash(s.id) % 1000) / 37, t: t,
                                               unit: unit, reduceMotion: reduceMotion)
                                    .frame(width: 9 * 5.4 * unit, height: 28 * unit)
                            }
                            Text(FaceA.title(s, max: 18))
                                .font(Theme.allo(11 * unit, .medium))
                                .foregroundStyle(Theme.Night.muted)
                                .lineLimit(1)
                                .frame(maxWidth: 120 * unit)
                        }
                    }
                }
            }
            FaceA.summaryText(counts, size: 15 * unit)
                .font(Theme.allo(15 * unit, .medium))
                .tracking(Theme.tracking(15 * unit))
        }
        .fixedSize()
    }
}

/// Nine little bars per agent, symmetric about the middle, animated by state.
struct ClockEqualizer: View {
    let state: AgentState
    let seed: Double
    let t: Double
    let unit: CGFloat
    let reduceMotion: Bool

    var body: some View {
        Canvas { g, size in
            let n = 9
            let bw = size.width / CGFloat(n) * 0.56
            let step = size.width / CGFloat(n)
            let tt = reduceMotion ? t * 0.25 : t
            let rgb = FaceA.stateRGB(state)
            for i in 0..<n {
                let x = Double(i)
                var v: Double
                switch state {
                case .working:
                    let env = 0.55 + 0.45 * exp(-pow((x - 4) / 3.2, 2))
                    v = 0.16 + 0.84 * env * abs(FaceA.wave(tt * 3.3 + x * 0.62, seed + x * 0.9))
                case .needsYou:
                    let pulse = 0.5 + 0.5 * sin(tt * 2 * .pi / 1.3 - x * 0.18)
                    v = 0.18 + 0.62 * pulse * exp(-pow((x - 4) / 3.4, 2))
                case .finished:
                    let pos = (tt.truncatingRemainder(dividingBy: 4.2)) / 4.2 * 14 - 2.5
                    v = 0.12 + 0.3 * exp(-pow(x - pos, 2) / 1.6)
                case .error:
                    v = 0.14 + 0.26 * abs(sin(tt * 7 + x * 2.1 + seed))
                case .idle:
                    v = 0.1
                }
                let hgt = max(bw, size.height * v)
                let rect = CGRect(x: step * CGFloat(i) + (step - bw) / 2, y: (size.height - hgt) / 2, width: bw, height: hgt)
                g.fill(Path(roundedRect: rect, cornerRadius: bw / 2),
                       with: .color(rgb.color(0.55 + 0.45 * min(1, v * 1.3))))
            }
        }
    }
}

/// With nothing running: a calm line with a soft swell travelling across it now and then.
struct ClockHeartline: View {
    let t: Double
    let unit: CGFloat
    let reduceMotion: Bool

    var body: some View {
        Canvas { g, size in
            let w = Double(size.width), h = Double(size.height)
            let period = 5.5
            let ph = (t.truncatingRemainder(dividingBy: period)) / period
            let pos = -0.2 + ph * 1.4
            var path = Path()
            let n = 90
            for k in 0...n {
                let x = Double(k) / Double(n)
                let bump = reduceMotion ? 0 : exp(-pow((x - pos) / 0.06, 2)) * sin((x - pos) * 60) * 0.42
                let y = h / 2 - bump * h
                if k == 0 { path.move(to: CGPoint(x: x * w, y: y)) } else { path.addLine(to: CGPoint(x: x * w, y: y)) }
            }
            g.stroke(path, with: .linearGradient(
                Gradient(stops: [.init(color: .clear, location: 0), .init(color: FaceA.lavender.color(0.75), location: 0.25),
                                 .init(color: FaceA.peach.color(0.75), location: 0.75), .init(color: .clear, location: 1)]),
                startPoint: .zero, endPoint: CGPoint(x: w, y: 0)),
                style: StrokeStyle(lineWidth: max(1, 1.5 * Double(unit)), lineCap: .round, lineJoin: .round))
        }
    }
}

/// Preview-only: one colored dot per agent (the full pulse is too small to read at 320×200).
struct ClockPreviewDots: View {
    let sessions: [AgentSession]
    let unit: CGFloat
    var body: some View {
        HStack(spacing: 10 * unit) {
            ForEach(sessions) { s in
                Circle().fill(Theme.stateColor(s.state)).frame(width: 14 * unit, height: 14 * unit)
            }
        }
    }
}
