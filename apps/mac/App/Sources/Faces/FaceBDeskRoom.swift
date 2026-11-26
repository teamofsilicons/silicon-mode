import SwiftUI
import SiliconModeKit

// The Desk face's room: a fixed 1600 × 1000 illustration space scaled to fit the screen (walls and
// floor extend to cover any aspect ratio), a static room layer, and a slow sky layer seen through
// the big window behind the desk that follows the real time of day.

// MARK: - Space

struct DeskSpace {
    static let width: CGFloat = 1600
    static let height: CGFloat = 1000
    let s: CGFloat
    let ox: CGFloat
    let oy: CGFloat

    init(_ size: CGSize) {
        s = max(0.01, min(size.width / DeskSpace.width, size.height / DeskSpace.height))
        ox = (size.width - DeskSpace.width * s) / 2
        oy = (size.height - DeskSpace.height * s) / 2
    }

    func apply(_ g: inout GraphicsContext) {
        g.translateBy(x: ox, y: oy)
        g.scaleBy(x: s, y: s)
    }

    /// The whole canvas in illustration coordinates.
    var visible: CGRect { CGRect(x: -ox / s, y: -oy / s, width: DeskSpace.width + 2 * ox / s, height: DeskSpace.height + 2 * oy / s) }
}

enum DeskGeo {
    /// The glass of the big window.
    static let glass = CGRect(x: 300, y: 84, width: 1000, height: 436)
    static let frame: CGFloat = 16
    static let mullions: [CGFloat] = [633, 967]
    static let transomY: CGFloat = 196
    static let floorY: CGFloat = 760
    static let deskX0: CGFloat = 196
    static let deskX1: CGFloat = 1404
    static let deskTop: CGFloat = 584
    static let deskFront: CGFloat = 602
    static let deskBottom: CGFloat = 628
    static let clockCenter = CGPoint(x: 1480, y: 200)
    static let clockR: CGFloat = 62
    static let mugOnDesk = CGPoint(x: 1092, y: 597)
    /// Mascot: body bottom-centre (sitting on the stool seat).
    static let seat = CGPoint(x: 800, y: 676)
}

// MARK: - Color helpers

struct FBRGB {
    var r: Double, g: Double, b: Double
    init(_ hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.hasPrefix("#") ? String(hex.dropFirst()) : hex).scanHexInt64(&v)
        r = Double((v >> 16) & 0xFF) / 255; g = Double((v >> 8) & 0xFF) / 255; b = Double(v & 0xFF) / 255
    }
    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    func mix(_ o: FBRGB, _ t: Double) -> FBRGB { FBRGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t) }
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }
}

// MARK: - Themes

struct DeskTheme {
    let wallTop: Color
    let wallBottom: Color
    let floorTop: Color
    let floorBottom: Color
    let baseboard: Color
    let deskTop: Color
    let deskEdge: Color
    let deskDark: Color
    let frame: Color
    let frameDark: Color
    let curtain: Color
    let curtainDark: Color
    let rug: Color
    let rugStripe: Color
    let shelf: Color
    let leaf: Color
    let leafDark: Color
    let pot: Color
    let warmLight: Color
    let books: [Color]

    static func named(_ id: String) -> DeskTheme {
        switch id {
        case "dusk":
            DeskTheme(wallTop: Color(hex: "2B2030"), wallBottom: Color(hex: "21182A"), floorTop: Color(hex: "1B141D"),
                      floorBottom: Color(hex: "140F16"), baseboard: Color(hex: "33263A"),
                      deskTop: Color(hex: "5A4038"), deskEdge: Color(hex: "3F2C29"), deskDark: Color(hex: "2B1E1D"),
                      frame: Color(hex: "3A2B40"), frameDark: Color(hex: "2A1F30"),
                      curtain: Color(hex: "5A3F5E"), curtainDark: Color(hex: "432E47"),
                      rug: Color(hex: "3A2636"), rugStripe: Color(hex: "EDCAA3"),
                      shelf: Color(hex: "4A3430"), leaf: Color(hex: "55704F"), leafDark: Color(hex: "3D553B"),
                      pot: Color(hex: "B07A5E"), warmLight: Color(hex: "F2B48A"),
                      books: ["CBBAEB", "EDCAA3", "8A6F9E", "D98F7A", "7E8FB8"].map { Color(hex: $0) })
        case "studio":
            DeskTheme(wallTop: Color(hex: "302D2A"), wallBottom: Color(hex: "282624"), floorTop: Color(hex: "211F1D"),
                      floorBottom: Color(hex: "191817"), baseboard: Color(hex: "3A3734"),
                      deskTop: Color(hex: "7A6650"), deskEdge: Color(hex: "54463A"), deskDark: Color(hex: "3A3129"),
                      frame: Color(hex: "403C38"), frameDark: Color(hex: "2F2C29"),
                      curtain: Color(hex: "4A4641"), curtainDark: Color(hex: "3A3733"),
                      rug: Color(hex: "35322F"), rugStripe: Color(hex: "CACACA"),
                      shelf: Color(hex: "5E4E40"), leaf: Color(hex: "5E7A57"), leafDark: Color(hex: "46603F"),
                      pot: Color(hex: "D8CFC4"), warmLight: Color(hex: "F5E3C4"),
                      books: ["E3E3E3", "7D9BFF", "EDCAA3", "585858", "7FC79A"].map { Color(hex: $0) })
        default: // night
            DeskTheme(wallTop: Color(hex: "1B1F2C"), wallBottom: Color(hex: "161924"), floorTop: Color(hex: "13151D"),
                      floorBottom: Color(hex: "0E1016"), baseboard: Color(hex: "232737"),
                      deskTop: Color(hex: "4A3A33"), deskEdge: Color(hex: "352A25"), deskDark: Color(hex: "241C19"),
                      frame: Color(hex: "262A3A"), frameDark: Color(hex: "1C1F2B"),
                      curtain: Color(hex: "2F3550"), curtainDark: Color(hex: "242940"),
                      rug: Color(hex: "1F2333"), rugStripe: Color(hex: "7D9BFF"),
                      shelf: Color(hex: "3A2E29"), leaf: Color(hex: "3F5E4B"), leafDark: Color(hex: "2E4738"),
                      pot: Color(hex: "8A5E48"), warmLight: Color(hex: "F5C98B"),
                      books: ["7D9BFF", "CBBAEB", "EDCAA3", "4E5A7E", "7FC79A"].map { Color(hex: $0) })
        }
    }
}

// MARK: - Static room layer

/// Everything in the room that doesn't move. Redrawn only when the theme, clock option or size change.
struct DeskRoomLayer: View, Equatable {
    let theme: String
    let showClock: Bool

    var body: some View {
        Canvas { g, size in
            let space = DeskSpace(size)
            space.apply(&g)
            DeskRoomPainter(th: DeskTheme.named(theme), showClock: showClock, visible: space.visible).draw(&g)
        }
    }
}

struct DeskRoomPainter {
    let th: DeskTheme
    let showClock: Bool
    let visible: CGRect

    func draw(_ g: inout GraphicsContext) {
        let v = visible.insetBy(dx: -4, dy: -4)
        let glass = DeskGeo.glass
        let fy = DeskGeo.floorY

        // Wall with a hole for the window glass.
        var wall = Path()
        wall.addRect(CGRect(x: v.minX, y: v.minY, width: v.width, height: fy - v.minY))
        wall.addRect(glass)
        g.fill(wall, with: .linearGradient(Gradient(colors: [th.wallTop, th.wallBottom]),
                                           startPoint: CGPoint(x: 0, y: v.minY), endPoint: CGPoint(x: 0, y: fy)),
               style: FillStyle(eoFill: true))
        // Soft ambient pool behind the desk.
        g.fill(Path(ellipseIn: CGRect(x: 260, y: 280, width: 1080, height: 520)),
               with: .radialGradient(Gradient(colors: [th.warmLight.opacity(0.06), .clear]),
                                     center: CGPoint(x: 800, y: 560), startRadius: 0, endRadius: 560))

        drawWindow(&g, glass)
        drawCurtains(&g)

        // Floor + baseboard
        g.fill(Path(CGRect(x: v.minX, y: fy, width: v.width, height: v.maxY - fy)),
               with: .linearGradient(Gradient(colors: [th.floorTop, th.floorBottom]),
                                     startPoint: CGPoint(x: 0, y: fy), endPoint: CGPoint(x: 0, y: v.maxY)))
        g.fill(Path(CGRect(x: v.minX, y: fy - 14, width: v.width, height: 14)), with: .color(th.baseboard))
        g.fill(Path(CGRect(x: v.minX, y: fy, width: v.width, height: 3)), with: .color(.black.opacity(0.25)))
        // Floorboards: a few faint lines.
        var boards = Path()
        for (i, y) in [800.0, 852, 920].enumerated() {
            boards.addRect(CGRect(x: v.minX, y: y, width: v.width, height: 1.5 + CGFloat(i) * 0.5))
        }
        g.fill(boards, with: .color(.black.opacity(0.18)))

        // Rug
        func trapezoid(_ inset: CGFloat) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 440 + inset * 1.2, y: 852 + inset * 0.5))
            p.addLine(to: CGPoint(x: 1160 - inset * 1.2, y: 852 + inset * 0.5))
            p.addLine(to: CGPoint(x: 1290 - inset * 1.4, y: 968 - inset * 0.5))
            p.addLine(to: CGPoint(x: 310 + inset * 1.4, y: 968 - inset * 0.5))
            p.closeSubpath()
            return p
        }
        g.fill(trapezoid(0).offsetBy(dx: 0, dy: 5), with: .color(.black.opacity(0.25)))
        g.fill(trapezoid(0), with: .color(th.rug))
        g.stroke(trapezoid(16), with: .color(th.rugStripe.opacity(0.16)), lineWidth: 3)
        g.stroke(trapezoid(26), with: .color(th.rugStripe.opacity(0.08)), lineWidth: 2)
        var fringe = Path()
        for i in 0..<40 {
            let x = 316 + CGFloat(i) * 24.2
            fringe.addRect(CGRect(x: x, y: 968, width: 2, height: 8))
        }
        g.fill(fringe, with: .color(th.rugStripe.opacity(0.12)))

        drawPoster(&g)
        drawFloorPlant(&g)
        drawShelf(&g)
        drawDesk(&g)
    }

    private func drawWindow(_ g: inout GraphicsContext, _ glass: CGRect) {
        let f = DeskGeo.frame
        let outer = glass.insetBy(dx: -f, dy: -f)
        // Glass reflections (over the sky layer below).
        var streaks = Path()
        for (i, x) in [330.0, 690, 1010].enumerated() {
            let w: CGFloat = i == 1 ? 70 : 54
            streaks.move(to: CGPoint(x: x + 120, y: glass.minY))
            streaks.addLine(to: CGPoint(x: x + 120 + w, y: glass.minY))
            streaks.addLine(to: CGPoint(x: x + w - 60, y: glass.maxY))
            streaks.addLine(to: CGPoint(x: x - 60, y: glass.maxY))
            streaks.closeSubpath()
        }
        var gl = g
        gl.clip(to: Path(glass))
        gl.fill(streaks, with: .color(.white.opacity(0.025)))

        // Frame ring + mullions + transom.
        var ring = Path()
        ring.addRect(outer)
        ring.addRect(glass)
        g.fill(ring, with: .color(th.frame), style: FillStyle(eoFill: true))
        var bars = Path()
        for x in DeskGeo.mullions { bars.addRect(CGRect(x: x - 6, y: glass.minY, width: 12, height: glass.height)) }
        bars.addRect(CGRect(x: glass.minX, y: DeskGeo.transomY - 5, width: glass.width, height: 10))
        g.fill(bars, with: .color(th.frame))
        // Inner shadow lip
        g.fill(Path(CGRect(x: glass.minX, y: glass.minY, width: glass.width, height: 4)), with: .color(th.frameDark))
        // Sill
        let sill = CGRect(x: outer.minX - 18, y: outer.maxY - 2, width: outer.width + 36, height: 16)
        g.fill(Path(roundedRect: sill, cornerRadius: 3), with: .color(th.frame))
        g.fill(Path(CGRect(x: sill.minX, y: sill.minY, width: sill.width, height: 4)), with: .color(.white.opacity(0.05)))
        g.fill(Path(CGRect(x: sill.minX + 6, y: sill.maxY, width: sill.width - 12, height: 6)), with: .color(.black.opacity(0.25)))
    }

    private func drawCurtains(_ g: inout GraphicsContext) {
        // Rod
        g.fill(Path(roundedRect: CGRect(x: 214, y: 42, width: 1172, height: 8), cornerRadius: 4), with: .color(th.frameDark))
        for x in [214.0, 1378] {
            g.fill(Path(ellipseIn: CGRect(x: x - 4, y: 38, width: 16, height: 16)), with: .color(th.frame))
        }
        // Two gathered panels with soft folds.
        for side in [0, 1] {
            let x0: CGFloat = side == 0 ? 222 : 1294
            let w: CGFloat = 86
            var panel = Path()
            panel.move(to: CGPoint(x: x0, y: 48))
            panel.addLine(to: CGPoint(x: x0 + w, y: 48))
            let inner: CGFloat = side == 0 ? x0 + w : x0
            let outerX: CGFloat = side == 0 ? x0 : x0 + w
            // Tied back at ~two-thirds height.
            panel.addQuadCurve(to: CGPoint(x: inner + (side == 0 ? -34 : 34), y: 400), control: CGPoint(x: inner + (side == 0 ? -6 : 6), y: 260))
            panel.addQuadCurve(to: CGPoint(x: inner + (side == 0 ? -8 : 8), y: 600), control: CGPoint(x: inner + (side == 0 ? -40 : 40), y: 470))
            panel.addLine(to: CGPoint(x: outerX + (side == 0 ? -10 : 10), y: 600))
            panel.addLine(to: CGPoint(x: outerX, y: 48))
            panel.closeSubpath()
            g.fill(panel, with: .linearGradient(Gradient(colors: [th.curtain, th.curtainDark]),
                                                startPoint: CGPoint(x: 0, y: 48), endPoint: CGPoint(x: 0, y: 600)))
            var folds = g
            folds.clip(to: panel)
            for i in 0..<4 {
                let fx = x0 + 12 + CGFloat(i) * 20
                folds.fill(Path(CGRect(x: fx, y: 40, width: 7, height: 600)), with: .color(.black.opacity(0.12)))
            }
            // Tie
            let ty: CGFloat = 400
            let tx = inner + (side == 0 ? -34 : 34)
            g.fill(Path(roundedRect: CGRect(x: min(tx, outerX) - 6, y: ty - 5, width: abs(tx - outerX) + 12, height: 10), cornerRadius: 5),
                   with: .color(th.rugStripe.opacity(0.35)))
        }
    }

    private func drawPoster(_ g: inout GraphicsContext) {
        // A framed print on the left wall (a calm silicon-gradient abstract).
        let r = CGRect(x: 52, y: 150, width: 136, height: 176)
        g.fill(Path(roundedRect: r.offsetBy(dx: 0, dy: 6), cornerRadius: 6), with: .color(.black.opacity(0.25)))
        g.fill(Path(roundedRect: r, cornerRadius: 6), with: .color(th.frameDark))
        let art = r.insetBy(dx: 12, dy: 12)
        g.fill(Path(roundedRect: art, cornerRadius: 3),
               with: .linearGradient(Gradient(colors: [Color(hex: "CBBAEB").opacity(0.85), Color(hex: "EDCAA3").opacity(0.85)]),
                                     startPoint: CGPoint(x: art.minX, y: art.minY), endPoint: CGPoint(x: art.maxX, y: art.maxY)))
        var gg = g
        gg.clip(to: Path(art))
        gg.fill(Path(ellipseIn: CGRect(x: art.midX - 30, y: art.minY + 34, width: 60, height: 60)), with: .color(.white.opacity(0.35)))
        gg.fill(Path(CGRect(x: art.minX, y: art.maxY - 44, width: art.width, height: 44)), with: .color(Color(hex: "1B1A1F").opacity(0.22)))
        if !showClock {
            // Without the wall clock, a second small print balances the right wall.
            let r2 = CGRect(x: 1420, y: 140, width: 120, height: 120)
            g.fill(Path(roundedRect: r2.offsetBy(dx: 0, dy: 6), cornerRadius: 6), with: .color(.black.opacity(0.25)))
            g.fill(Path(roundedRect: r2, cornerRadius: 6), with: .color(th.frameDark))
            let a2 = r2.insetBy(dx: 12, dy: 12)
            g.fill(Path(roundedRect: a2, cornerRadius: 3), with: .color(Color(hex: "7D9BFF").opacity(0.55)))
            g.fill(Path(ellipseIn: a2.insetBy(dx: 22, dy: 22)), with: .color(Color(hex: "EDCAA3").opacity(0.8)))
        }
    }

    private func drawFloorPlant(_ g: inout GraphicsContext) {
        let base = CGPoint(x: 120, y: 836)
        // Leaves (fanned ellipses), back to front.
        let leaves: [(Double, CGFloat, CGFloat)] = [(-0.95, 150, 52), (-0.55, 190, 58), (-0.15, 230, 62), (0.2, 205, 58), (0.6, 170, 54), (0.95, 130, 48),
                                                    (-0.35, 140, 46), (0.4, 150, 46)]
        for (i, l) in leaves.enumerated() {
            let ang = l.0 - .pi / 2
            let len = l.1, wid = l.2
            let stem = CGPoint(x: base.x, y: base.y - 84)
            let c = CGPoint(x: stem.x + CGFloat(cos(ang)) * len * 0.62, y: stem.y + CGFloat(sin(ang)) * len * 0.62)
            let leaf = Path.rotatedEllipse(center: c, size: CGSize(width: len, height: wid), angle: ang)
            var stemP = Path()
            stemP.move(to: stem)
            stemP.addLine(to: c)
            g.stroke(stemP, with: .color(th.leafDark), lineWidth: 4)
            g.fill(leaf, with: .color(i >= 6 ? th.leaf : (i % 2 == 0 ? th.leafDark : th.leaf)))
            var rib = Path()
            rib.move(to: CGPoint(x: c.x - CGFloat(cos(ang)) * len * 0.42, y: c.y - CGFloat(sin(ang)) * len * 0.42))
            rib.addLine(to: CGPoint(x: c.x + CGFloat(cos(ang)) * len * 0.42, y: c.y + CGFloat(sin(ang)) * len * 0.42))
            g.stroke(rib, with: .color(.black.opacity(0.15)), lineWidth: 2)
        }
        // Pot
        var pot = Path()
        pot.move(to: CGPoint(x: base.x - 50, y: base.y - 86))
        pot.addLine(to: CGPoint(x: base.x + 50, y: base.y - 86))
        pot.addLine(to: CGPoint(x: base.x + 38, y: base.y))
        pot.addLine(to: CGPoint(x: base.x - 38, y: base.y))
        pot.closeSubpath()
        g.fill(Path(ellipseIn: CGRect(x: base.x - 52, y: base.y - 8, width: 104, height: 16)), with: .color(.black.opacity(0.3)))
        g.fill(pot, with: .color(th.pot))
        g.fill(Path(roundedRect: CGRect(x: base.x - 54, y: base.y - 92, width: 108, height: 16), cornerRadius: 4), with: .color(th.pot))
        g.fill(Path(CGRect(x: base.x - 54, y: base.y - 78, width: 108, height: 4)), with: .color(.black.opacity(0.15)))
    }

    private func drawShelf(_ g: inout GraphicsContext) {
        let y: CGFloat = 418
        let x0: CGFloat = 1392, x1: CGFloat = 1576
        // Books
        var x = x0 + 14
        let heights: [CGFloat] = [64, 74, 58, 70, 52]
        for (i, h) in heights.enumerated() {
            let w: CGFloat = i == 2 ? 20 : 16
            let tilt = i == 4
            let r = CGRect(x: x, y: y - h, width: w, height: h)
            if tilt {
                g.fill(Path.rotatedRect(center: CGPoint(x: r.midX + 10, y: r.midY + 4), size: r.size, angle: 0.32),
                       with: .color(th.books[i % th.books.count].opacity(0.8)))
            } else {
                g.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(th.books[i % th.books.count].opacity(0.8)))
                g.fill(Path(CGRect(x: r.minX + 3, y: r.minY + 10, width: w - 6, height: 3)), with: .color(.black.opacity(0.2)))
            }
            x += w + 3
        }
        // Trailing plant in a little pot.
        let pc = CGPoint(x: 1540, y: y)
        var vines = Path()
        for (i, dx) in [-14.0, -2, 10].enumerated() {
            vines.move(to: CGPoint(x: pc.x + dx, y: y - 20))
            vines.addCurve(to: CGPoint(x: pc.x + dx + 8, y: y + 60 + CGFloat(i) * 26),
                           control1: CGPoint(x: pc.x + dx + 20, y: y + 10), control2: CGPoint(x: pc.x + dx - 14, y: y + 40))
        }
        g.stroke(vines, with: .color(th.leafDark), lineWidth: 3)
        for i in 0..<9 {
            let ly = y + CGFloat(i % 3) * 26 + CGFloat(i / 3) * 10
            let lx = pc.x - 12 + CGFloat(i / 3) * 12 + CGFloat(i % 2) * 6
            g.fill(Path.rotatedEllipse(center: CGPoint(x: lx, y: ly), size: CGSize(width: 16, height: 9), angle: Double(i) * 0.7),
                   with: .color(i % 2 == 0 ? th.leaf : th.leafDark))
        }
        g.fill(Path(roundedRect: CGRect(x: pc.x - 20, y: y - 30, width: 40, height: 30), cornerRadius: 5), with: .color(th.pot))
        // Board + brackets
        g.fill(Path(roundedRect: CGRect(x: x0, y: y, width: x1 - x0, height: 12), cornerRadius: 2), with: .color(th.shelf))
        g.fill(Path(CGRect(x: x0, y: y + 12, width: x1 - x0, height: 4)), with: .color(.black.opacity(0.25)))
        for bx in [x0 + 20, x1 - 30] {
            g.fill(Path(CGRect(x: bx, y: y + 12, width: 8, height: 22)), with: .color(th.frameDark))
        }
    }

    private func drawDesk(_ g: inout GraphicsContext) {
        let x0 = DeskGeo.deskX0, x1 = DeskGeo.deskX1
        let top = DeskGeo.deskTop, front = DeskGeo.deskFront, bottom = DeskGeo.deskBottom
        // Shadow on the floor
        g.fill(Path(ellipseIn: CGRect(x: x0 - 20, y: 852, width: x1 - x0 + 40, height: 34)), with: .color(.black.opacity(0.35)))
        // Left leg (front + back)
        g.fill(Path(CGRect(x: x0 + 40, y: bottom, width: 20, height: 236)), with: .color(th.deskDark))
        g.fill(Path(CGRect(x: x0 + 24, y: bottom, width: 22, height: 246)), with: .color(th.deskEdge))
        // Drawer cabinet on the right
        let cab = CGRect(x: x1 - 214, y: bottom, width: 190, height: 246)
        g.fill(Path(cab), with: .color(th.deskEdge))
        g.fill(Path(CGRect(x: cab.minX, y: cab.minY, width: cab.width, height: 6)), with: .color(.black.opacity(0.2)))
        for i in 0..<3 {
            let dr = CGRect(x: cab.minX + 12, y: cab.minY + 16 + CGFloat(i) * 76, width: cab.width - 24, height: 64)
            g.fill(Path(roundedRect: dr, cornerRadius: 4), with: .color(th.deskTop.opacity(0.55)))
            g.fill(Path(roundedRect: CGRect(x: dr.midX - 22, y: dr.minY + 12, width: 44, height: 7), cornerRadius: 3.5),
                   with: .color(th.deskDark))
        }
        // Top plane + front edge
        g.fill(Path(roundedRect: CGRect(x: x0, y: top, width: x1 - x0, height: front - top + 4), cornerRadius: 4), with: .color(th.deskTop))
        g.fill(Path(CGRect(x: x0 + 4, y: top, width: x1 - x0 - 8, height: 2)), with: .color(.white.opacity(0.06)))
        g.fill(Path(roundedRect: CGRect(x: x0, y: front, width: x1 - x0, height: bottom - front), cornerRadius: 3), with: .color(th.deskEdge))
        g.fill(Path(CGRect(x: x0, y: bottom - 4, width: x1 - x0, height: 4)), with: .color(.black.opacity(0.2)))

        // Keyboard + mouse
        let kb = CGRect(x: 674, y: top + 3, width: 252, height: 11)
        g.fill(Path(roundedRect: kb, cornerRadius: 3), with: .color(Color(hex: "2A2B31")))
        g.fill(Path(roundedRect: CGRect(x: kb.minX + 4, y: kb.minY + 2, width: kb.width - 8, height: 4), cornerRadius: 2),
               with: .color(Color(hex: "44464F")))
        g.fill(Path(roundedRect: CGRect(x: 952, y: top + 4, width: 26, height: 10), cornerRadius: 5), with: .color(Color(hex: "2A2B31")))

        // A pencil cup and a tiny cactus on the left end.
        let cup = CGRect(x: x0 + 18, y: top - 34, width: 30, height: 38)
        for (i, dx) in [6.0, 14, 22].enumerated() {
            g.fill(Path.rotatedRect(center: CGPoint(x: cup.minX + dx, y: cup.minY - 10), size: CGSize(width: 4, height: 34),
                                    angle: Double(i - 1) * 0.18),
                   with: .color(th.books[(i + 1) % th.books.count].opacity(0.9)))
        }
        g.fill(Path(roundedRect: cup, cornerRadius: 4), with: .color(th.frame))
        let cpot = CGRect(x: x0 + 58, y: top - 20, width: 26, height: 22)
        g.fill(Path(roundedRect: CGRect(x: cpot.minX + 5, y: cpot.minY - 30, width: 16, height: 36), cornerRadius: 8), with: .color(th.leaf))
        g.fill(Path(roundedRect: CGRect(x: cpot.minX - 3, y: cpot.minY - 18, width: 10, height: 16), cornerRadius: 5), with: .color(th.leaf))
        g.fill(Path(roundedRect: cpot, cornerRadius: 4), with: .color(th.pot))
    }
}

extension Path {
    static func rotatedEllipse(center c: CGPoint, size: CGSize, angle: Double) -> Path {
        Path(ellipseIn: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
            .applying(CGAffineTransform(rotationAngle: angle).concatenating(CGAffineTransform(translationX: c.x, y: c.y)))
    }
}

// MARK: - Sky (through the window)

/// The sky layer: real time of day (gradient, sun or moon, stars, clouds, a little city). Runs at a
/// low frame rate; only the window rect is drawn.
struct DeskSkyLayer: View {
    let preview: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: preview ? 1.0 / 8 : 1.0 / 15)) { tl in
            let t = FaceBClock.seconds(tl.date)
            let wall = FaceBClock.wallDate(tl.date)
            Canvas { g, size in
                let space = DeskSpace(size)
                space.apply(&g)
                DeskSky.draw(&g, t: t, wall: wall)
            }
        }
    }
}

enum DeskSky {
    /// (hour, top, bottom, stars 0…1, city lights 0…1)
    private static let keys: [(Double, FBRGB, FBRGB, Double, Double)] = [
        (0.0, FBRGB("070B1A"), FBRGB("151C36"), 1, 1),
        (4.6, FBRGB("0A0F22"), FBRGB("1C2342"), 1, 1),
        (6.0, FBRGB("2C2F5C"), FBRGB("D99A82"), 0.3, 0.7),
        (7.5, FBRGB("4C6FA8"), FBRGB("E6C6A6"), 0, 0.25),
        (10.0, FBRGB("4A7AB6"), FBRGB("A6C5E3"), 0, 0.08),
        (16.0, FBRGB("4874AE"), FBRGB("B1C9E2"), 0, 0.1),
        (18.0, FBRGB("4A4F8C"), FBRGB("EFAE7E"), 0, 0.4),
        (19.5, FBRGB("2B2450"), FBRGB("A86F8E"), 0.35, 0.8),
        (21.0, FBRGB("0D1230"), FBRGB("23284C"), 0.9, 1),
        (24.0, FBRGB("070B1A"), FBRGB("151C36"), 1, 1),
    ]

    static func hour(_ d: Date) -> Double {
        let c = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: d)
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60 + (Double(c.second ?? 0) + Double(c.nanosecond ?? 0) / 1e9) / 3600
    }

    static func sample(_ h: Double) -> (top: FBRGB, bottom: FBRGB, stars: Double, city: Double) {
        for i in 0..<(keys.count - 1) where h >= keys[i].0 && h <= keys[i + 1].0 {
            let a = keys[i], b = keys[i + 1]
            let f = FB.smooth((h - a.0) / (b.0 - a.0))
            return (a.1.mix(b.1, f), a.2.mix(b.2, f), FB.lerp(a.3, b.3, f), FB.lerp(a.4, b.4, f))
        }
        return (keys[0].1, keys[0].2, 1, 1)
    }

    /// How dark it is outside (0 day … 1 night); the room uses it for its lights.
    static func darkness(_ d: Date) -> Double { sample(hour(d)).city }

    struct Building { let rect: CGRect; let far: Bool }
    struct Lit { let rect: CGRect; let seed: Int }

    static let buildings: [Building] = {
        var out: [Building] = []
        let g = DeskGeo.glass
        for layer in 0..<2 {
            var x = g.minX - 20
            var i = 0
            while x < g.maxX + 20 {
                let far = layer == 0
                let w = CGFloat(far ? 46 + FB.hash(i, 71) * 60 : 52 + FB.hash(i, 91) * 70)
                var h = CGFloat(far ? 90 + FB.hash(i, 73) * 110 : 50 + FB.hash(i, 93) * 120)
                if !far && FB.hash(i, 97) > 0.82 { h += 70 }
                out.append(Building(rect: CGRect(x: x, y: g.maxY - h, width: w, height: h), far: far))
                x += w + CGFloat(far ? FB.hash(i, 79) * 10 : 4 + FB.hash(i, 99) * 18)
                i += 1
            }
        }
        return out
    }()

    static let windows: [Lit] = {
        var out: [Lit] = []
        let nearRects = buildings.filter { !$0.far }.map(\.rect)
        for (bi, b) in buildings.enumerated() {
            let cw: CGFloat = b.far ? 9 : 12, ch: CGFloat = b.far ? 11 : 14
            let ww: CGFloat = b.far ? 3.5 : 5, wh: CGFloat = b.far ? 4.5 : 7
            var row = 0
            var y = b.rect.minY + 10
            while y + wh < b.rect.maxY - 4 {
                var col = 0
                var x = b.rect.minX + 7
                while x + ww < b.rect.maxX - 5 {
                    let r = CGRect(x: x, y: y, width: ww, height: wh)
                    if !b.far || !nearRects.contains(where: { $0.intersects(r) }) {
                        out.append(Lit(rect: r, seed: bi * 1000 + row * 40 + col))
                    }
                    x += cw; col += 1
                }
                y += ch; row += 1
            }
        }
        return out
    }()

    static let stars: [(CGPoint, CGFloat, Double)] = (0..<84).map { i in
        let g = DeskGeo.glass
        return (CGPoint(x: g.minX + CGFloat(FB.hash(i, 501)) * g.width, y: g.minY + CGFloat(FB.hash(i, 503)) * g.height * 0.62),
                CGFloat(0.7 + FB.hash(i, 507) * 1.3), FB.hash(i, 509) * 6.28)
    }

    static func draw(_ g: inout GraphicsContext, t: Double, wall: Date) {
        let glass = DeskGeo.glass
        var c = g
        c.clip(to: Path(glass))
        let h = hour(wall)
        let sky = sample(h)
        c.fill(Path(glass), with: .linearGradient(Gradient(colors: [sky.top.color, sky.bottom.color]),
                                                  startPoint: CGPoint(x: 0, y: glass.minY), endPoint: CGPoint(x: 0, y: glass.maxY - 60)))

        // Stars (twinkling in four buckets so each bucket is one fill).
        if sky.stars > 0.01 {
            var buckets = [Path](repeating: Path(), count: 4)
            for (i, s) in stars.enumerated() {
                let r = s.1
                buckets[i % 4].addEllipse(in: CGRect(x: s.0.x - r, y: s.0.y - r, width: r * 2, height: r * 2))
            }
            for b in 0..<4 {
                let tw = 0.45 + 0.55 * (0.5 + 0.5 * sin(t * (0.5 + Double(b) * 0.23) + Double(b) * 1.7))
                c.fill(buckets[b], with: .color(.white.opacity(sky.stars * tw * 0.85)))
            }
            // An occasional shooting star.
            let period = 37.0
            let k = floor(t / period)
            let p = (t - k * period) / 1.1
            if p < 1, FB.hash(Int(k), 13) > 0.35 {
                let sx = glass.minX + CGFloat(FB.hash(Int(k), 17)) * glass.width * 0.7 + 100
                let sy = glass.minY + 20 + CGFloat(FB.hash(Int(k), 19)) * 90
                let head = CGPoint(x: sx - CGFloat(p) * 220, y: sy + CGFloat(p) * 90)
                var trail = Path()
                trail.move(to: head)
                trail.addLine(to: CGPoint(x: head.x + 70, y: head.y - 29))
                c.stroke(trail, with: .linearGradient(Gradient(colors: [.white.opacity(0.9 * sky.stars * sin(p * .pi)), .clear]),
                                                      startPoint: head, endPoint: CGPoint(x: head.x + 70, y: head.y - 29)),
                         style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }

        // Sun or moon on an arc across the window.
        let horizon = glass.maxY - 70
        if h >= 5.6 && h <= 19.4 {
            let p = (h - 5.6) / 13.8
            let sc = CGPoint(x: glass.minX + 60 + CGFloat(p) * (glass.width - 120), y: horizon - CGFloat(sin(p * .pi)) * (glass.height - 150))
            let r: CGFloat = 30
            let warm = 1 - sin(p * .pi)
            let sunCol = FBRGB("FFF4D6").mix(FBRGB("F6B27A"), warm).color
            c.fill(Path(ellipseIn: CGRect(x: sc.x - r * 4, y: sc.y - r * 4, width: r * 8, height: r * 8)),
                   with: .radialGradient(Gradient(colors: [sunCol.opacity(0.35), .clear]), center: sc, startRadius: r, endRadius: r * 4))
            c.fill(Path(ellipseIn: CGRect(x: sc.x - r, y: sc.y - r, width: r * 2, height: r * 2)), with: .color(sunCol))
        } else {
            let hh = h < 12 ? h + 24 : h
            let p = (hh - 19.4) / 10.2
            let mc = CGPoint(x: glass.minX + 80 + CGFloat(p) * (glass.width - 160), y: horizon - CGFloat(sin(p * .pi)) * (glass.height - 170))
            let r: CGFloat = 26
            c.fill(Path(ellipseIn: CGRect(x: mc.x - r * 3.5, y: mc.y - r * 3.5, width: r * 7, height: r * 7)),
                   with: .radialGradient(Gradient(colors: [Color(hex: "DCE4FF").opacity(0.18), .clear]), center: mc, startRadius: r, endRadius: r * 3.5))
            var moon = c
            moon.clip(to: Path(ellipseIn: CGRect(x: mc.x - r + 13, y: mc.y - r - 7, width: r * 2, height: r * 2)), options: .inverse)
            moon.fill(Path(ellipseIn: CGRect(x: mc.x - r, y: mc.y - r, width: r * 2, height: r * 2)), with: .color(Color(hex: "F3EFE2")))
        }

        // Clouds drifting slowly.
        let day = 1 - sky.stars
        let cloudCol = FBRGB("FFFFFF").mix(FBRGB("3A3F66"), sky.city)
        for i in 0..<4 {
            let span = glass.width + 360
            let speed = 4 + FB.hash(i, 31) * 5
            let x = glass.minX - 180 + CGFloat((Double(i) * 290 + t * speed).truncatingRemainder(dividingBy: Double(span)))
            let y = glass.minY + 40 + CGFloat(FB.hash(i, 37)) * 150
            let sc = CGFloat(0.7 + FB.hash(i, 41) * 0.6)
            var cloud = Path()
            cloud.addRoundedRect(in: CGRect(x: x - 60 * sc, y: y, width: 140 * sc, height: 26 * sc), cornerSize: CGSize(width: 13 * sc, height: 13 * sc))
            cloud.addEllipse(in: CGRect(x: x - 34 * sc, y: y - 22 * sc, width: 56 * sc, height: 46 * sc))
            cloud.addEllipse(in: CGRect(x: x + 4 * sc, y: y - 32 * sc, width: 64 * sc, height: 56 * sc))
            c.fill(cloud, with: .color(cloudCol.color.opacity(0.10 + 0.32 * day)))
        }

        // City: far row, near row, then lit windows (one fill).
        let farCol = sky.bottom.mix(FBRGB("0B0E1C"), 0.45 + 0.25 * sky.city).color
        let nearCol = sky.bottom.mix(FBRGB("080A14"), 0.7 + 0.25 * sky.city).color
        var far = Path(), near = Path()
        for b in buildings { if b.far { far.addRect(b.rect) } else { near.addRect(b.rect) } }
        c.fill(far, with: .color(farCol))
        var lit = Path(), litWarm = Path()
        let litFrac = 0.06 + 0.32 * sky.city
        for w in windows {
            // Each window flips on/off on its own slow schedule.
            let per = 25 + FB.hash(w.seed, 5) * 50
            let epoch = Int(floor((t + FB.hash(w.seed, 9) * per) / per))
            if FB.hash(w.seed, epoch) < litFrac {
                if FB.hash(w.seed, 3) < 0.22 { litWarm.addRect(w.rect) } else { lit.addRect(w.rect) }
            }
        }
        c.fill(near, with: .color(nearCol))
        // Windows on the far row sit under the near row, so draw lit windows last and let near buildings occlude by geometry.
        c.fill(lit, with: .color(Color(hex: "F5D58B").opacity(0.25 + 0.6 * sky.city)))
        c.fill(litWarm, with: .color(Color(hex: "CBBAEB").opacity(0.25 + 0.5 * sky.city)))
        // A faint horizon haze.
        c.fill(Path(CGRect(x: glass.minX, y: glass.maxY - 120, width: glass.width, height: 120)),
               with: .linearGradient(Gradient(colors: [.clear, sky.bottom.color.opacity(0.25)]),
                                     startPoint: CGPoint(x: 0, y: glass.maxY - 120), endPoint: CGPoint(x: 0, y: glass.maxY)))
    }
}
