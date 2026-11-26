import SwiftUI

/// A side view of the Mac at its live lid angle: base, lid (its screen glowing while Silicon Mode is
/// on), the angle arc, the Silicon Mode angle and the panic threshold (0.9 ×), and one glowing
/// particle per agent orbiting the machine. Animatable in `angle`, so lid moves glide.
struct HingeGlyph: View, Animatable {
    var angle: Double
    var siliconAngle: Double?
    var state: SiliconModeState
    var agents: [AgentDot]
    var t: Double
    var night: Bool = true
    var online: Bool = true

    struct AgentDot: Equatable {
        var color: Color
        var needsYou: Bool
    }

    nonisolated var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    var body: some View {
        Canvas { ctx, size in draw(&ctx, size) }
            .accessibilityElement()
            .accessibilityLabel("Lid at \(Int(angle.rounded())) degrees")
    }

    private var ink: Color { night ? Theme.Night.foreground : Theme.foreground }
    private var faint: Color { night ? Color.white.opacity(0.14) : Theme.textFaint.opacity(0.6) }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let L = min(size.width * 0.56, size.height * 0.9)
        let hinge = CGPoint(x: size.width * 0.5 - L * 0.42, y: size.height * 0.78)
        let theta = max(0, min(150, angle)) * .pi / 180
        let lidEnd = CGPoint(x: hinge.x + cos(theta) * L * 0.97, y: hinge.y - sin(theta) * L * 0.97)
        let baseEnd = CGPoint(x: hinge.x + L, y: hinge.y)
        let r = L * 0.42
        let isOn = state.isOn
        let panic = state == .panic
        let flash = panic ? 0.5 + 0.5 * sin(t * .pi * 2 * 2.2) : 0

        // Orbit paths (behind the machine).
        let center = CGPoint(x: hinge.x + L * 0.42, y: hinge.y - L * 0.32)
        if !agents.isEmpty {
            var orbit = Path()
            orbit.addEllipse(in: CGRect(x: center.x - L * 0.72, y: center.y - L * 0.34, width: L * 1.44, height: L * 0.68))
            ctx.stroke(orbit, with: .color(faint.opacity(0.55)), style: StrokeStyle(lineWidth: 0.75, dash: [2, 5]))
        }
        drawAgents(&ctx, center: center, L: L, front: false)

        // Faint protractor track 0…150°.
        var track = Path()
        track.addArc(center: hinge, radius: r, startAngle: .degrees(0), endAngle: .degrees(-150), clockwise: true)
        ctx.stroke(track, with: .color(faint), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 4]))

        // Live arc from base to lid.
        var arc = Path()
        arc.addArc(center: hinge, radius: r, startAngle: .degrees(0), endAngle: .degrees(-max(0.5, min(150, angle))), clockwise: true)
        let arcShading: GraphicsContext.Shading = panic
            ? .color(Theme.Night.panic.opacity(0.6 + 0.4 * flash))
            : .linearGradient(Gradient(colors: [Theme.Night.peach, Theme.Night.lavender]),
                              startPoint: CGPoint(x: hinge.x + r, y: hinge.y), endPoint: CGPoint(x: hinge.x, y: hinge.y - r))
        ctx.stroke(arc, with: isOn ? arcShading : .color(ink.opacity(0.35)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

        // Silicon Mode angle + panic threshold ticks.
        if let sa = siliconAngle, sa > 1 {
            tick(&ctx, hinge: hinge, r: r, deg: sa, color: night ? Theme.Night.lavender : Theme.siliconInkFrom, len: 9)
            tick(&ctx, hinge: hinge, r: r, deg: sa * 0.9, color: Theme.Night.danger.opacity(night ? 0.8 : 0.9), len: 6)
        }

        // Base.
        let baseRect = CGRect(x: hinge.x - 3, y: hinge.y - 3.5, width: L + 3, height: 7)
        ctx.fill(Path(roundedRect: baseRect, cornerRadius: 3.5, style: .continuous), with: .color(ink.opacity(0.92)))
        // Feet + trackpad lip.
        ctx.fill(Path(roundedRect: CGRect(x: baseEnd.x - L * 0.36, y: hinge.y - 4.5, width: L * 0.22, height: 1.4), cornerRadius: 0.7),
                 with: .color(ink.opacity(0.35)))

        // Screen glow on the lid's inner face.
        if isOn && online {
            let glowColor: Color = panic ? Theme.Night.panic.opacity(0.5 + 0.5 * flash) : Theme.Night.lavender
            var lid = Path()
            lid.move(to: hinge)
            lid.addLine(to: lidEnd)
            ctx.drawLayer { g in
                g.addFilter(.blur(radius: 9))
                let normal = CGPoint(x: sin(theta) * 7, y: cos(theta) * 7)
                g.translateBy(x: normal.x, y: normal.y)
                g.stroke(lid, with: panic ? .color(glowColor)
                         : .linearGradient(Gradient(colors: [Theme.Night.peach.opacity(0.9), Theme.Night.lavender]),
                                           startPoint: hinge, endPoint: lidEnd),
                         style: StrokeStyle(lineWidth: 9, lineCap: .round))
            }
        }

        // Lid.
        var lidPath = Path()
        lidPath.move(to: hinge)
        lidPath.addLine(to: lidEnd)
        ctx.stroke(lidPath, with: .color(ink), style: StrokeStyle(lineWidth: 6, lineCap: .round))
        if isOn && online {
            // Lit display strip.
            var screen = Path()
            let inset = 0.12
            screen.move(to: CGPoint(x: hinge.x + (lidEnd.x - hinge.x) * inset, y: hinge.y + (lidEnd.y - hinge.y) * inset))
            screen.addLine(to: CGPoint(x: hinge.x + (lidEnd.x - hinge.x) * 0.94, y: hinge.y + (lidEnd.y - hinge.y) * 0.94))
            let normal = CGPoint(x: sin(theta) * 2.2, y: cos(theta) * 2.2)
            ctx.stroke(screen.offsetBy(dx: normal.x, dy: normal.y),
                       with: panic ? .color(Theme.Night.panic.opacity(0.6 + 0.4 * flash))
                       : .linearGradient(Gradient(colors: [Theme.Night.peach, Theme.Night.lavender]), startPoint: hinge, endPoint: lidEnd),
                       style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        }

        // Hinge.
        ctx.fill(Path(ellipseIn: CGRect(x: hinge.x - 4.5, y: hinge.y - 4.5, width: 9, height: 9)), with: .color(ink))
        ctx.fill(Path(ellipseIn: CGRect(x: hinge.x - 1.6, y: hinge.y - 1.6, width: 3.2, height: 3.2)),
                 with: .color(night ? Theme.Night.background : Theme.surface))

        drawAgents(&ctx, center: center, L: L, front: true)
    }

    private func tick(_ ctx: inout GraphicsContext, hinge: CGPoint, r: CGFloat, deg: Double, color: Color, len: CGFloat) {
        let a = deg * .pi / 180
        var p = Path()
        p.move(to: CGPoint(x: hinge.x + cos(a) * (r - len / 2), y: hinge.y - sin(a) * (r - len / 2)))
        p.addLine(to: CGPoint(x: hinge.x + cos(a) * (r + len / 2), y: hinge.y - sin(a) * (r + len / 2)))
        ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    /// Particles on a tilted ellipse; the back half is drawn behind the Mac, the front half over it.
    private func drawAgents(_ ctx: inout GraphicsContext, center: CGPoint, L: CGFloat, front: Bool) {
        let n = agents.count
        guard n > 0 else { return }
        let speed = state.isOn ? 0.34 : 0.12
        for (i, a) in agents.prefix(10).enumerated() {
            let phase = Double(i) / Double(min(n, 10)) * .pi * 2
            let u = t * speed * (1 + Double(i % 3) * 0.07) + phase
            let depth = sin(u)                 // -1 back … +1 front
            if (depth >= 0) != front { continue }
            let p = CGPoint(x: center.x + cos(u) * L * 0.72, y: center.y + sin(u) * L * 0.34)
            let scale = 0.72 + 0.28 * (depth + 1) / 2
            let pulse = a.needsYou ? 0.6 + 0.4 * sin(t * 5 + phase) : 1
            let rad = 4.2 * scale
            ctx.drawLayer { g in
                g.addFilter(.blur(radius: 5))
                g.fill(Path(ellipseIn: CGRect(x: p.x - rad * 2, y: p.y - rad * 2, width: rad * 4, height: rad * 4)),
                       with: .color(a.color.opacity(0.55 * pulse * (online ? 1 : 0.4))))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - rad, y: p.y - rad, width: rad * 2, height: rad * 2)),
                     with: .color(a.color.opacity((0.55 + 0.45 * scale) * (online ? 1 : 0.5))))
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - rad * 0.4 - 0.8, y: p.y - rad * 0.4 - 0.8, width: rad * 0.7, height: rad * 0.7)),
                     with: .color(.white.opacity(0.7 * scale)))
        }
    }
}
