import SwiftUI

// Silly, the Desk face's mascot: a rounded silicon chip with DIP pins down its sides, a status-LED
// antenna, and a little visor screen for a face. Seen from behind while it types; it spins its
// stool around to face you for everything else.

enum DeskPose: Equatable {
    case typing, ask, celebrate, chill, panic
    var front: Bool { self != .typing }
}

struct DeskMascot {
    let pal: FBCharacterPalette
    let t: Double
    let reduceMotion: Bool

    struct Pose {
        var pose: DeskPose
        /// Seconds since the pose began.
        var since: Double
        /// Horizontal squash while the stool spins (1 = facing fully).
        var turnScale: CGFloat
        var showFront: Bool
        var hop: CGFloat
        var led: Color
        var ledBlink: Double
        var askCount: Int
        var blink: Double
    }

    // Body box in local space; origin is the seat (body bottom centre).
    private let bw: CGFloat = 170
    private let bh: CGFloat = 150
    private var bodyRect: CGRect { CGRect(x: -bw / 2, y: -bh, width: bw, height: bh) }

    func draw(_ g: inout GraphicsContext, at origin: CGPoint, _ p: Pose) {
        var c = g
        c.translateBy(x: origin.x, y: origin.y)
        drawStool(&c, spinning: p.turnScale < 0.999)

        var b = c
        let motion = !reduceMotion
        var lift = p.hop
        var shakeX: CGFloat = 0
        switch p.pose {
        case .typing: lift += motion ? CGFloat(sin(t * 2.4)) * 1.2 : 0
        case .ask: lift += motion ? CGFloat(abs(sin(t * 2.2))) * 3 : 0
        case .celebrate: lift += motion ? CGFloat(abs(sin(t * 5.5))) * 24 : 0
        case .chill: break
        case .panic:
            shakeX = motion ? CGFloat(sin(t * 47)) * 3 : 0
            lift += motion ? CGFloat(abs(sin(t * 9))) * 8 : 0
        }
        b.translateBy(x: shakeX, y: -lift)
        b.scaleBy(x: max(p.turnScale, 0.04), y: 1)
        if p.showFront { drawFront(&b, p) } else { drawBack(&b, p) }
    }

    // MARK: Stool

    private func drawStool(_ c: inout GraphicsContext, spinning: Bool) {
        let metal = Color(hex: "4A4B55"), dark = Color(hex: "2B2C33")
        c.fill(Path(ellipseIn: CGRect(x: -96, y: 134, width: 192, height: 26)), with: .color(.black.opacity(0.35)))
        // Base: five-star legs reduced to a flat spider + casters.
        var legs = Path()
        legs.addRoundedRect(in: CGRect(x: -78, y: 124, width: 156, height: 10), cornerSize: CGSize(width: 5, height: 5))
        legs.addRoundedRect(in: CGRect(x: -40, y: 120, width: 80, height: 10), cornerSize: CGSize(width: 5, height: 5))
        c.fill(legs, with: .color(dark))
        for x in [-74.0, -2, 70] {
            c.fill(Path(ellipseIn: CGRect(x: x - 7, y: 132, width: 14, height: 14)), with: .color(Color(hex: "1C1C22")))
        }
        // Gas lift
        c.fill(Path(roundedRect: CGRect(x: -9, y: 14, width: 18, height: 110), cornerRadius: 4), with: .color(metal))
        c.fill(Path(roundedRect: CGRect(x: -6, y: 14, width: 4, height: 110), cornerRadius: 2), with: .color(.white.opacity(0.12)))
        // Seat
        let seat = CGRect(x: -70, y: -4, width: 140, height: 22)
        c.fill(Path(roundedRect: seat, cornerRadius: 11), with: .color(Color(hex: "35363F")))
        c.fill(Path(roundedRect: CGRect(x: seat.minX + 8, y: seat.minY + 2, width: seat.width - 16, height: 5), cornerRadius: 2.5),
               with: .color(.white.opacity(0.08)))
        if spinning {
            // Motion swooshes while the stool spins.
            for (i, w) in [90.0, 60].enumerated() {
                var s = Path()
                s.addArc(center: CGPoint(x: 0, y: 40 + Double(i) * 18), radius: w, startAngle: .degrees(160), endAngle: .degrees(20), clockwise: true)
                c.stroke(s, with: .color(.white.opacity(0.12)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }
    }

    // MARK: Shared parts

    private func bodyShading() -> GraphicsContext.Shading {
        .linearGradient(Gradient(colors: pal.bodyGradient), startPoint: CGPoint(x: -bw * 0.35, y: -bh),
                        endPoint: CGPoint(x: bw * 0.35, y: 0))
    }

    private func drawBody(_ c: inout GraphicsContext, back: Bool, stretch: CGFloat = 0) {
        let r = CGRect(x: bodyRect.minX, y: bodyRect.minY - stretch, width: bw, height: bh + stretch)
        // Side pins (DIP)
        var pins = Path()
        for i in 0..<4 {
            let y = r.minY + 26 + CGFloat(i) * (r.height - 52) / 3 - 7
            pins.addRoundedRect(in: CGRect(x: r.minX - 10, y: y, width: 14, height: 14), cornerSize: CGSize(width: 3, height: 3))
            pins.addRoundedRect(in: CGRect(x: r.maxX - 4, y: y, width: 14, height: 14), cornerSize: CGSize(width: 3, height: 3))
        }
        c.fill(pins, with: .color(pal.metal))
        let body = Path(roundedRect: r, cornerRadius: 46, style: .continuous)
        c.fill(body, with: bodyShading())
        var sh = c
        sh.clip(to: body)
        sh.fill(Path(CGRect(x: r.minX - 10, y: r.maxY - 24, width: r.width + 20, height: 30)), with: .color(pal.shade.opacity(0.55)))
        if back { sh.fill(body, with: .color(.black.opacity(0.1))) }
        c.fill(Path(roundedRect: CGRect(x: r.minX + 30, y: r.minY + 10, width: 74, height: 9), cornerRadius: 4.5),
               with: .color(pal.highlight.opacity(back ? 0.3 : 0.55)))
    }

    private func drawAntenna(_ c: inout GraphicsContext, _ p: Pose, stretch: CGFloat = 0) {
        let top = bodyRect.minY - stretch
        var stalk = Path()
        stalk.move(to: CGPoint(x: 0, y: top + 2))
        stalk.addLine(to: CGPoint(x: 0, y: top - 26))
        c.stroke(stalk, with: .color(pal.metal), style: StrokeStyle(lineWidth: 5, lineCap: .round))
        let lc = CGPoint(x: 0, y: top - 36)
        let on = 0.55 + 0.45 * p.ledBlink
        c.fill(Path(ellipseIn: CGRect(x: lc.x - 38, y: lc.y - 38, width: 76, height: 76)),
               with: .radialGradient(Gradient(colors: [p.led.opacity(0.45 * on), p.led.opacity(0)]), center: lc, startRadius: 4, endRadius: 38))
        c.fill(Path(ellipseIn: CGRect(x: lc.x - 10, y: lc.y - 10, width: 20, height: 20)), with: .color(p.led.opacity(0.6 + 0.4 * on)))
        c.fill(Path(ellipseIn: CGRect(x: lc.x - 5, y: lc.y - 6, width: 6, height: 6)), with: .color(.white.opacity(0.7)))
    }

    private func arm(_ c: inout GraphicsContext, from s: CGPoint, to h: CGPoint, shade: Bool = false) {
        var a = Path()
        a.move(to: s)
        let mid = CGPoint(x: (s.x + h.x) / 2 + (h.x - s.x) * 0.1, y: (s.y + h.y) / 2 + 10)
        a.addQuadCurve(to: h, control: mid)
        c.stroke(a, with: .color(shade ? pal.shade : pal.bottom), style: StrokeStyle(lineWidth: shade ? 18 : 22, lineCap: .round))
        let hr: CGFloat = shade ? 10 : 13
        c.fill(Path(ellipseIn: CGRect(x: h.x - hr, y: h.y - hr, width: hr * 2, height: hr * 2)), with: .color(shade ? pal.bottom : pal.top))
        if !shade {
            c.fill(Path(ellipseIn: CGRect(x: h.x - 6, y: h.y - 9, width: 7, height: 7)), with: .color(pal.highlight.opacity(0.7)))
        }
    }

    // MARK: Back (typing)

    private func drawBack(_ c: inout GraphicsContext, _ p: Pose) {
        // Bursty typing: hands peck at the keyboard in runs with little pauses.
        let burst = reduceMotion ? 0.6 : FB.smooth(0.5 + 0.8 * sin(t * 0.9) + 0.4 * sin(t * 2.3))
        let f = reduceMotion ? 1.6 : 3.6
        let tapL = CGFloat(burst * max(0, sin(t * 2 * .pi * f)))
        let tapR = CGFloat(burst * max(0, sin(t * 2 * .pi * f + 2.2 + 0.7 * sin(t * 1.3))))
        // Keys light up under each hand as it lands.
        for (side, tap) in [(-1.0, tapL), (1.0, tapR)] where burst > 0.25 && tap < 0.12 {
            let kx = CGFloat(side) * 110
            let kr = CGRect(x: kx - 9, y: -88, width: 18, height: 5)
            c.fill(Path(ellipseIn: kr.insetBy(dx: -10, dy: -6)), with: .color(Theme.Night.accent.opacity(0.22)))
            c.fill(Path(roundedRect: kr, cornerRadius: 2), with: .color(Theme.Night.accent.opacity(0.75)))
        }
        arm(&c, from: CGPoint(x: -70, y: -84), to: CGPoint(x: -110, y: -100 - tapL * 10), shade: true)
        arm(&c, from: CGPoint(x: 70, y: -84), to: CGPoint(x: 110, y: -100 - tapR * 10), shade: true)
        drawBody(&c, back: true)
        // Back panel: engraved die outline + heat-sink vents + a little sticker.
        let panel = CGRect(x: -54, y: -122, width: 108, height: 80)
        c.stroke(Path(roundedRect: panel, cornerRadius: 18, style: .continuous), with: .color(pal.shade.opacity(0.6)), lineWidth: 3)
        var vents = Path()
        for i in 0..<4 {
            vents.addRoundedRect(in: CGRect(x: -34, y: panel.minY + 16 + CGFloat(i) * 13, width: 68, height: 5), cornerSize: CGSize(width: 2.5, height: 2.5))
        }
        c.fill(vents, with: .color(pal.shade.opacity(0.55)))
        c.fill(Path(roundedRect: CGRect(x: -22, y: -34, width: 44, height: 16), cornerRadius: 4), with: .color(Color.white.opacity(0.55)))
        var code = Path()
        for i in 0..<9 where i % 3 != 2 {
            code.addRect(CGRect(x: -17 + CGFloat(i) * 4, y: -30, width: 2, height: 8))
        }
        c.fill(code, with: .color(pal.ink.opacity(0.6)))
        drawAntenna(&c, p)
    }

    // MARK: Front

    private enum Eyes { case open, happy, closed, relaxed, wide }
    private enum Mouth { case smile, grin, oh, yawn, scream, none }

    private func drawFront(_ c: inout GraphicsContext, _ p: Pose) {
        var eyes: Eyes = .open
        var mouth: Mouth = .smile
        var handL = CGPoint(x: -72, y: -26)
        var handR = CGPoint(x: 72, y: -26)
        var stretch: CGFloat = 0
        var mug: CGPoint?
        var steam = false
        var footTap: CGFloat = 0
        var legSwing = CGFloat(sin(t * 1.8)) * 7
        var sign = false

        switch p.pose {
        case .ask:
            eyes = .open; mouth = .oh; sign = true
            handR = CGPoint(x: 124, y: -170 + CGFloat(sin(t * 2.2)) * 4)
            handL = CGPoint(x: -76, y: -30)
            footTap = reduceMotion ? 0 : CGFloat(max(0, sin(t * 2 * .pi * 2.1)))
            legSwing = 0
        case .celebrate:
            eyes = .happy; mouth = .grin
            let w1 = reduceMotion ? 0 : CGFloat(sin(t * 14)) * 9
            let w2 = reduceMotion ? 0 : CGFloat(sin(t * 14 + 1.6)) * 9
            handL = CGPoint(x: -126, y: -206 + w1)
            handR = CGPoint(x: 126, y: -206 + w2)
            legSwing = reduceMotion ? 0 : CGFloat(sin(t * 11)) * 10
        case .chill:
            // A 22 s loop: hold the mug, sip, hold, stretch, hold.
            let cyc = t.truncatingRemainder(dividingBy: 22)
            let sip = FB.smooth((cyc - 6) / 0.6) * (1 - FB.smooth((cyc - 8.9) / 0.6))
            let str = FB.smooth((cyc - 15) / 0.7) * (1 - FB.smooth((cyc - 17.8) / 0.7))
            let rest = CGPoint(x: -74, y: -34), sipP = CGPoint(x: -20, y: -58), upL = CGPoint(x: -96, y: -222)
            let restR = CGPoint(x: 74, y: -24), upR = CGPoint(x: 96, y: -222)
            func mix(_ a: CGPoint, _ b: CGPoint, _ k: Double) -> CGPoint {
                CGPoint(x: a.x + (b.x - a.x) * CGFloat(k), y: a.y + (b.y - a.y) * CGFloat(k))
            }
            handL = mix(mix(rest, sipP, sip), upL, str)
            handR = mix(restR, upR, str)
            stretch = CGFloat(str) * 8
            eyes = sip > 0.5 || str > 0.5 ? .closed : .relaxed
            mouth = str > 0.5 ? .yawn : (sip > 0.3 ? .none : .smile)
            mug = handL
            steam = str < 0.2
        case .panic:
            eyes = .wide; mouth = .scream
            let a = reduceMotion ? 0 : CGFloat(sin(t * 21)) * 22
            handL = CGPoint(x: -128, y: -170 + a)
            handR = CGPoint(x: 128, y: -170 - a)
            legSwing = reduceMotion ? 0 : CGFloat(sin(t * 25)) * 12
        case .typing:
            break
        }

        // Legs dangle off the seat.
        for side in [-1.0, 1.0] {
            let s = CGFloat(side)
            let swing = legSwing * (side < 0 ? 1 : -1)
            let tap = side > 0 ? footTap * 12 : 0
            let hip = CGPoint(x: s * 30, y: -8)
            let foot = CGPoint(x: s * 36 + swing * 0.4, y: 58 - tap)
            var leg = Path()
            leg.move(to: hip)
            leg.addQuadCurve(to: foot, control: CGPoint(x: s * 34 + swing, y: 30))
            c.stroke(leg, with: .color(pal.metal.opacity(0.9)), style: StrokeStyle(lineWidth: 9, lineCap: .round))
            c.fill(Path(roundedRect: CGRect(x: foot.x - 17 + s * 5, y: foot.y - 7, width: 34, height: 15), cornerRadius: 7.5),
                   with: .color(pal.shade))
        }

        // Arms behind the body when resting low, in front when raised.
        let raisedL = handL.y < -110, raisedR = handR.y < -110
        if !raisedL { arm(&c, from: CGPoint(x: -66, y: -76), to: handL) }
        if !raisedR { arm(&c, from: CGPoint(x: 66, y: -76), to: handR) }

        drawBody(&c, back: false, stretch: stretch)

        // Visor face
        let visor = CGRect(x: -62, y: -128 - stretch, width: 124, height: 76)
        c.fill(Path(roundedRect: visor, cornerRadius: 26, style: .continuous),
               with: .linearGradient(Gradient(colors: [Color(hex: "241E2E"), Color(hex: "15111B")]),
                                     startPoint: CGPoint(x: 0, y: visor.minY), endPoint: CGPoint(x: 0, y: visor.maxY)))
        c.fill(Path(roundedRect: CGRect(x: visor.minX + 16, y: visor.minY + 7, width: 34, height: 6), cornerRadius: 3),
               with: .color(.white.opacity(0.09)))
        let glow = Color(hex: "F1ECFF")
        let ey = visor.minY + 34
        for side in [-1.0, 1.0] {
            let ex = CGFloat(side) * 25
            switch eyes {
            case .open, .relaxed, .wide:
                let w: CGFloat = eyes == .wide ? 24 : 17
                var h: CGFloat = eyes == .wide ? 30 : (eyes == .relaxed ? 14 : 26)
                if eyes != .wide { h *= CGFloat(1 - 0.85 * p.blink) }
                let r = CGRect(x: ex - w / 2, y: ey - h / 2 + (eyes == .relaxed ? 4 : 0), width: w, height: max(h, 3))
                c.fill(Path(roundedRect: r.insetBy(dx: -5, dy: -5), cornerRadius: 12), with: .color(glow.opacity(0.12)))
                c.fill(Path(roundedRect: r, cornerRadius: min(w, h) * 0.45), with: .color(glow))
            case .happy:
                var a = Path()
                a.addArc(center: CGPoint(x: ex, y: ey + 6), radius: 12, startAngle: .degrees(205), endAngle: .degrees(335), clockwise: false)
                c.stroke(a, with: .color(glow), style: StrokeStyle(lineWidth: 6, lineCap: .round))
            case .closed:
                var a = Path()
                a.addArc(center: CGPoint(x: ex, y: ey - 2), radius: 11, startAngle: .degrees(25), endAngle: .degrees(155), clockwise: false)
                c.stroke(a, with: .color(glow), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            }
        }
        let my = visor.minY + 60
        switch mouth {
        case .smile:
            var m = Path()
            m.addArc(center: CGPoint(x: 0, y: my - 8), radius: 9, startAngle: .degrees(30), endAngle: .degrees(150), clockwise: false)
            c.stroke(m, with: .color(glow.opacity(0.9)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        case .grin:
            var m = Path()
            m.move(to: CGPoint(x: -15, y: my - 6))
            m.addQuadCurve(to: CGPoint(x: 15, y: my - 6), control: CGPoint(x: 0, y: my + 14))
            m.closeSubpath()
            c.fill(m, with: .color(glow.opacity(0.95)))
        case .oh:
            c.stroke(Path(ellipseIn: CGRect(x: -6, y: my - 8, width: 12, height: 12)), with: .color(glow.opacity(0.9)), lineWidth: 3.5)
        case .yawn:
            c.fill(Path(ellipseIn: CGRect(x: -9, y: my - 12, width: 18, height: 20)), with: .color(glow.opacity(0.9)))
        case .scream:
            c.stroke(Path(ellipseIn: CGRect(x: -11, y: my - 13, width: 22, height: 24)), with: .color(glow), lineWidth: 4)
        case .none: break
        }
        // Cheeks
        for side in [-1.0, 1.0] {
            c.fill(Path(ellipseIn: CGRect(x: CGFloat(side) * 63 - 11, y: -46, width: 22, height: 12)), with: .color(pal.cheek.opacity(0.55)))
        }
        drawAntenna(&c, p, stretch: stretch)

        if raisedL { arm(&c, from: CGPoint(x: -80, y: -92 - stretch), to: handL) }
        if raisedR { arm(&c, from: CGPoint(x: 80, y: -92 - stretch), to: handR) }
        if let mug { DeskMascot.drawMug(&c, at: CGPoint(x: mug.x + 4, y: mug.y + 16), t: t, steam: steam) ; drawHandOver(&c, mug) }
        if sign { drawSign(&c, hand: handR, count: p.askCount) }
        if p.pose == .celebrate && !reduceMotion { drawSparkles(&c) }
        if p.pose == .panic { drawExclaim(&c) }
    }

    private func drawHandOver(_ c: inout GraphicsContext, _ h: CGPoint) {
        c.fill(Path(ellipseIn: CGRect(x: h.x - 12, y: h.y - 12, width: 24, height: 24)), with: .color(pal.top))
    }

    private func drawSign(_ c: inout GraphicsContext, hand: CGPoint, count: Int) {
        var s = c
        let sway = reduceMotion ? 0 : sin(t * 2.2) * 0.06
        s.translateBy(x: hand.x, y: hand.y)
        s.rotate(by: .radians(sway))
        // Stick
        s.fill(Path(roundedRect: CGRect(x: -4, y: -96, width: 8, height: 104), cornerRadius: 4), with: .color(Color(hex: "9A7652")))
        // Board
        let board = CGRect(x: -76, y: -186, width: 152, height: 100)
        s.fill(Path(roundedRect: board.offsetBy(dx: 0, dy: 7), cornerRadius: 20, style: .continuous), with: .color(Color(hex: "9A6B1E")))
        s.fill(Path(roundedRect: board, cornerRadius: 20, style: .continuous),
               with: .linearGradient(Gradient(colors: [Color(hex: "F5D27F"), Color(hex: "E0A845")]),
                                     startPoint: CGPoint(x: 0, y: board.minY), endPoint: CGPoint(x: 0, y: board.maxY)))
        s.fill(Path(roundedRect: CGRect(x: board.minX + 22, y: board.minY + 9, width: 60, height: 7), cornerRadius: 3.5),
               with: .color(.white.opacity(0.45)))
        // Glyphs come from the canvas's symbols (laid out once), with a fallback.
        if let q = s.resolveSymbol(id: DeskSymbol.signMark) {
            s.draw(q, at: CGPoint(x: 0, y: board.midY + 2), anchor: .center)
        } else {
            s.draw(Text("?").font(Theme.allo(70, .black)).foregroundStyle(Color(hex: "5A3A0C")),
                   at: CGPoint(x: 0, y: board.midY + 2), anchor: .center)
        }
        if count > 1 {
            let bc = CGPoint(x: board.maxX - 6, y: board.minY + 6)
            s.fill(Path(ellipseIn: CGRect(x: bc.x - 20, y: bc.y - 20, width: 40, height: 40)), with: .color(Color(hex: "1E1826")))
            if let n = s.resolveSymbol(id: DeskSymbol.signCount) {
                s.draw(n, at: bc, anchor: .center)
            } else {
                s.draw(Text("\(count)").font(Theme.allo(22, .bold)).foregroundStyle(Color(hex: "F5D27F")), at: bc, anchor: .center)
            }
        }
        // The hand wraps the stick.
        s.fill(Path(ellipseIn: CGRect(x: -13, y: -13, width: 26, height: 26)), with: .color(pal.top))
    }

    private func drawSparkles(_ c: inout GraphicsContext) {
        for i in 0..<6 {
            let per = 1.1 + FB.hash(i, 3) * 0.6
            let ph = (t / per + FB.hash(i, 5)).truncatingRemainder(dividingBy: 1)
            let a = sin(ph * .pi)
            let ang = FB.hash(i, 7) * 2 * .pi
            let rad = 120 + 50 * FB.hash(i, 9)
            let p = CGPoint(x: CGFloat(cos(ang) * rad), y: -110 + CGFloat(sin(ang) * rad * 0.7))
            let s = CGFloat(6 + 8 * a)
            var star = Path()
            star.move(to: CGPoint(x: p.x, y: p.y - s))
            star.addQuadCurve(to: CGPoint(x: p.x + s, y: p.y), control: p)
            star.addQuadCurve(to: CGPoint(x: p.x, y: p.y + s), control: p)
            star.addQuadCurve(to: CGPoint(x: p.x - s, y: p.y), control: p)
            star.addQuadCurve(to: CGPoint(x: p.x, y: p.y - s), control: p)
            c.fill(star, with: .color(FBStyle.confetti[i % FBStyle.confetti.count].opacity(a)))
        }
    }

    private func drawExclaim(_ c: inout GraphicsContext) {
        let p = CGPoint(x: 96, y: -232)
        c.fill(Path(ellipseIn: CGRect(x: p.x - 26, y: p.y - 26, width: 52, height: 52)), with: .color(Theme.Night.danger))
        if let mark = c.resolveSymbol(id: DeskSymbol.exclaim) {
            c.draw(mark, at: p, anchor: .center)
        } else {
            c.draw(Text("!").font(Theme.allo(36, .black)).foregroundStyle(Color(hex: "2A0D0A")), at: p, anchor: .center)
        }
    }

    /// A mug (bottom centre at `p`) with optional steam. Also used for the mug on the desk.
    static func drawMug(_ c: inout GraphicsContext, at p: CGPoint, t: Double, steam: Bool, scale: CGFloat = 1) {
        var m = c
        m.translateBy(x: p.x, y: p.y)
        m.scaleBy(x: scale, y: scale)
        m.stroke(Path(roundedRect: CGRect(x: 10, y: -27, width: 14, height: 16), cornerRadius: 7), with: .color(Color(hex: "E6DED2")), lineWidth: 4.5)
        let body = CGRect(x: -16, y: -36, width: 32, height: 36)
        m.fill(Path(roundedRect: body, cornerRadius: 7, style: .continuous), with: .color(Color(hex: "EEE7DC")))
        m.fill(Path(CGRect(x: body.minX, y: body.minY + 12, width: body.width, height: 7)), with: .color(Color(hex: "CBBAEB")))
        m.fill(Path(ellipseIn: CGRect(x: body.minX + 3, y: body.minY - 2, width: body.width - 6, height: 6)), with: .color(Color(hex: "3A2A22")))
        guard steam else { return }
        for i in 0..<2 {
            let ph = (t / 2.6 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
            let x0 = CGFloat(i == 0 ? -5 : 6)
            var w = Path()
            let y0 = body.minY - 6 - CGFloat(ph) * 10
            w.move(to: CGPoint(x: x0, y: y0))
            w.addCurve(to: CGPoint(x: x0, y: y0 - 30), control1: CGPoint(x: x0 + 9, y: y0 - 10), control2: CGPoint(x: x0 - 9, y: y0 - 20))
            m.stroke(w, with: .color(.white.opacity(0.28 * sin(ph * .pi))), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
        }
    }
}
