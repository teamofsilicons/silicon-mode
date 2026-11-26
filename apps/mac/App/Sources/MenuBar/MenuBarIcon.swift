import SwiftUI
import AppKit
import QuartzCore
import SiliconModeKit

// MARK: - Glyph

/// The status-item glyph: a side-profile laptop whose lid follows the real lid angle.
/// Plain values so the driver can spring between states; drawn with Core Graphics so the
/// same code makes the crisp template image *and* the SwiftUI `MenuBarIcon`.
///
/// States: idle (lid ≈ real angle) · paused (pause bars) · countdown (lid eases shut along a
/// dotted path) · active (lid closed + sparkles) · panic (!) · needs-you (knock-out for a dot).
struct MenuBarGlyph: Equatable, Sendable {
    /// Displayed lid angle in degrees (0 = shut).
    var lid: Double = MenuBarGlyph.restingLid
    var sparkle: Double = 0
    var pause: Double = 0
    var alert: Double = 0
    /// Countdown: dotted arc showing the lid's path from `pathFrom` to shut (0 = hidden).
    var path: Double = 0
    var pathFrom: Double = 75
    /// 0…1: size of the knock-out ring that frames the needs-you dot.
    var badge: Double = 0
    /// Degrees of rotation for the needs-you wiggle.
    var wiggle: Double = 0

    static let canvas = CGSize(width: 24, height: 16)
    static let hinge = CGPoint(x: 6.6, y: 3.2)
    static let lidLength: CGFloat = 11.4
    static let badgeCenter = CGPoint(x: 20.7, y: 12.9)
    static let badgeRadius: CGFloat = 3
    static let closedLid: Double = 12
    static let restingLid: Double = 108

    /// Draws in a y-up context sized `canvas` (points).
    func draw(in cg: CGContext, ink: CGColor) {
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.setFillColor(ink)
        cg.setStrokeColor(ink)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)

        if wiggle != 0 {
            cg.translateBy(x: 13, y: 2.4)
            cg.rotate(by: wiggle * .pi / 180)
            cg.translateBy(x: -13, y: -2.4)
        }

        // Base slab.
        let base = CGRect(x: 5.1, y: 1.1, width: 17.8, height: 2.4)
        cg.addPath(CGPath(roundedRect: base, cornerWidth: 1.2, cornerHeight: 1.2, transform: nil))
        cg.fillPath()

        let h = Self.hinge
        let L = Self.lidLength
        let a = min(max(lid, 0), 124) * .pi / 180

        // Countdown path: dotted arc the lid tip will travel.
        if path > 0.01 {
            let from = min(max(pathFrom, Self.closedLid), 124) * .pi / 180
            let to = Self.closedLid * .pi / 180
            cg.saveGState()
            cg.setAlpha(min(1, path) * 0.55)
            cg.setLineWidth(1.25)
            cg.setLineDash(phase: 0, lengths: [0.01, 2.3])
            cg.addArc(center: h, radius: L, startAngle: from, endAngle: to, clockwise: true)
            cg.strokePath()
            cg.restoreGState()
        }

        // Lid.
        cg.setLineWidth(2.1)
        cg.move(to: h)
        cg.addLine(to: CGPoint(x: h.x + L * cos(a), y: h.y + L * sin(a)))
        cg.strokePath()

        // Sparkles (active).
        if sparkle > 0.01 {
            let s = CGFloat(sparkle)
            Self.addSparkle(cg, center: CGPoint(x: 16.4, y: 11.2), radius: 3.9 * s)
            Self.addSparkle(cg, center: CGPoint(x: 11.3, y: 14.1), radius: 1.6 * s)
            cg.fillPath()
        }

        // Pause bars (auto-entry paused / off).
        if pause > 0.01 {
            let p = CGFloat(pause)
            let hgt = 6.0 * p
            for x in [15.0, 18.3] {
                let r = CGRect(x: x, y: 10.2 - hgt / 2, width: 1.9, height: hgt)
                cg.addPath(CGPath(roundedRect: r, cornerWidth: 0.95, cornerHeight: min(0.95, hgt / 2), transform: nil))
            }
            cg.fillPath()
        }

        // Panic "!".
        if alert > 0.01 {
            let p = CGFloat(alert)
            let bar = CGRect(x: 19.6, y: 8.6, width: 2.0, height: 6.6 * p)
            cg.addPath(CGPath(roundedRect: bar, cornerWidth: 1, cornerHeight: min(1, bar.height / 2), transform: nil))
            cg.addEllipse(in: CGRect(x: 19.6, y: 5.4, width: 2.0 * p, height: 2.0 * p))
            cg.fillPath()
        }

        // Knock-out ring around the needs-you dot (the dot itself is a colored layer on top).
        if badge > 0.01 {
            let r = (Self.badgeRadius + 1.7) * CGFloat(badge)
            let c = Self.badgeCenter
            cg.setBlendMode(.clear)
            cg.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        }
    }

    /// Four-point sparkle with concave sides.
    static func addSparkle(_ cg: CGContext, center c: CGPoint, radius r: CGFloat) {
        guard r > 0.05 else { return }
        let k = r * 0.16
        cg.move(to: CGPoint(x: c.x, y: c.y + r))
        cg.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + k, y: c.y + k))
        cg.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x + k, y: c.y - k))
        cg.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - k, y: c.y - k))
        cg.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x - k, y: c.y + k))
        cg.closePath()
    }

    /// A template image for the status item (the system tints it for the menu bar).
    func templateImage() -> NSImage {
        let glyph = self
        let image = NSImage(size: Self.canvas, flipped: false) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            glyph.draw(in: cg, ink: CGColor(gray: 0, alpha: 1))
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: Target from app state

    /// What the glyph should show for the current app state.
    @MainActor
    static func target(for model: AppModel, displayAngle: Double?) -> MenuBarGlyph {
        var g = MenuBarGlyph()
        let real = min(max(displayAngle ?? restingLid, closedLid + 4), 122)
        switch model.phase {
        case .idle:
            g.lid = real
            g.pause = (model.autoPausedUntil != nil || !model.settings.autoEnterEnabled) ? 1 : 0
        case .countdown(_, let duration):
            let remaining = model.countdownRemaining ?? duration
            let p = duration > 0 ? min(1, max(0, 1 - remaining / duration)) : 1
            let eased = p * p * (3 - 2 * p)
            // Ease most of the way shut; entering finishes the close (with the sparkle pop).
            g.lid = real + (closedLid + 10 - real) * eased
            g.path = 1
            g.pathFrom = real
        case .active(let a):
            g.lid = closedLid
            g.sparkle = a.isPanicking ? 0 : 1
            g.alert = a.isPanicking ? 1 : 0
        }
        g.badge = needsYouCount(model) > 0 ? 1 : 0
        return g
    }

    @MainActor
    static func needsYouCount(_ model: AppModel) -> Int {
        max(model.counts.needsYou, model.pendingQuestions.count)
    }
}

// MARK: - SwiftUI view

/// The status item glyph as a SwiftUI view (snapshots, empty state, onboarding).
/// The real status item uses `MenuBarIconDriver`, which springs the same glyph as a template image.
struct MenuBarIcon: View {
    @Environment(AppModel.self) private var model
    /// Explicit glyph; nil = the live app state.
    var glyph: MenuBarGlyph?
    var scale: CGFloat = 1
    var ink: Color = .primary

    var body: some View {
        let g = glyph ?? MenuBarGlyph.target(for: model, displayAngle: model.angle)
        let size = MenuBarGlyph.canvas
        Canvas { ctx, canvasSize in
            let color = ink.resolve(in: ctx.environment).cgColor
            ctx.withCGContext { cg in
                cg.translateBy(x: 0, y: canvasSize.height)
                cg.scaleBy(x: scale, y: -scale)
                g.draw(in: cg, ink: color)
            }
        }
        .frame(width: size.width * scale, height: size.height * scale)
        .overlay(alignment: .topLeading) {
            if g.badge > 0.01 {
                let r = MenuBarGlyph.badgeRadius * scale
                let c = MenuBarGlyph.badgeCenter
                Circle()
                    .fill(Color(nsColor: .systemOrange))
                    .frame(width: 2 * r, height: 2 * r)
                    .scaleEffect(g.badge)
                    .offset(x: c.x * scale - r, y: (size.height - c.y) * scale - r)
            }
        }
        .accessibilityLabel("Silicon Mode")
    }
}

// MARK: - Status item driver

/// Keeps the status item's template image in sync with the app, springing between states
/// with a tiny 60 Hz stepper that only runs while something is moving (idle = zero work).
@MainActor
final class MenuBarIconDriver {
    private weak var button: NSStatusBarButton?
    private let dot = BadgeDotView()
    private var shown = MenuBarGlyph()
    private var target = MenuBarGlyph()
    private var velocity = [Double](repeating: 0, count: 6)
    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0
    private var wiggleStart: CFTimeInterval?
    private var displayAngle: Double?
    private var lastNeedsYou = 0
    private var lastTooltip = ""
    private var started = false

    private var frameObserver: NSObjectProtocol?

    init(button: NSStatusBarButton) {
        self.button = button
        button.imagePosition = .imageOnly
        button.addSubview(dot)
        button.setAccessibilityLabel("Silicon Mode")
        // The button gets its real size after the first image; keep the dot on the glyph.
        button.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: button, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let button = self.button else { return }
                self.layoutDot(in: button)
            }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        let model = AppModel.shared
        displayAngle = model.angle
        target = MenuBarGlyph.target(for: model, displayAngle: displayAngle)
        shown = target
        lastNeedsYou = MenuBarGlyph.needsYouCount(model)
        render()
        dot.setVisible(target.badge > 0.5, animated: false)
        observe()
    }

    // MARK: Observation

    private func observe() {
        withObservationTracking {
            refreshTarget()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func refreshTarget() {
        let model = AppModel.shared
        // Hysteresis so sensor jitter (±1°) never redraws the menu bar.
        if let a = model.angle {
            if displayAngle == nil || abs(a - (displayAngle ?? a)) >= 2 { displayAngle = a }
        } else {
            displayAngle = nil
        }
        let next = MenuBarGlyph.target(for: model, displayAngle: displayAngle)
        let needs = MenuBarGlyph.needsYouCount(model)
        if needs > lastNeedsYou, !reduceMotion { wiggleStart = CACurrentMediaTime() }
        if (needs > 0) != (lastNeedsYou > 0) || needs > lastNeedsYou {
            dot.setVisible(needs > 0, animated: !reduceMotion)
        }
        lastNeedsYou = needs
        updateTooltip(model, needs: needs)
        guard next != target || wiggleStart != nil else { return }
        target = next
        if reduceMotion {
            shown = target
            render()
        } else {
            kick()
        }
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func updateTooltip(_ model: AppModel, needs: Int) {
        var parts = ["Silicon Mode"]
        switch model.phase {
        case .idle: parts.append(model.autoPausedUntil != nil ? "Paused" : "Off")
        case .countdown: parts.append("Entering…")
        case .active(let a): parts.append(a.isPanicking ? "Panic" : "Active")
        }
        if needs > 0 { parts.append(needs == 1 ? "1 agent needs you" : "\(needs) agents need you") }
        else if model.counts.working > 0 { parts.append("\(model.counts.working) working") }
        let tip = parts.joined(separator: " · ")
        guard tip != lastTooltip else { return }
        lastTooltip = tip
        button?.toolTip = tip
        button?.setAccessibilityValue(tip)
    }

    // MARK: Springs

    private func kick() {
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func step() {
        let now = CACurrentMediaTime()
        let dt = min(1.0 / 20.0, max(0, now - lastTick))
        lastTick = now

        // (value, target, response, damping)
        var channels: [(Double, Double, Double, Double)] = [
            (shown.lid, target.lid, 0.42, 0.74),
            (shown.sparkle, target.sparkle, 0.36, 0.52),
            (shown.pause, target.pause, 0.30, 0.80),
            (shown.alert, target.alert, 0.24, 0.55),
            (shown.path, target.path, 0.30, 1.00),
            (shown.badge, target.badge, 0.30, 0.60),
        ]
        let sub = 4
        let h = dt / Double(sub)
        var settled = true
        for i in channels.indices {
            let (start, goal, response, damping) = channels[i]
            let k = pow(2 * .pi / response, 2)
            let c = 4 * .pi * damping / response
            var x = start
            var v = velocity[i]
            for _ in 0..<sub {
                v += (-k * (x - goal) - c * v) * h
                x += v * h
            }
            let eps = i == 0 ? 0.05 : 0.002
            if abs(x - goal) < eps && abs(v) < eps * 4 { x = goal; v = 0 } else { settled = false }
            velocity[i] = v
            channels[i].0 = x
        }
        shown.lid = channels[0].0
        shown.sparkle = max(0, channels[1].0)
        shown.pause = max(0, channels[2].0)
        shown.alert = max(0, channels[3].0)
        shown.path = max(0, channels[4].0)
        shown.badge = max(0, channels[5].0)
        shown.pathFrom = target.pathFrom

        if let ws = wiggleStart {
            let t = now - ws
            if t > 0.9 {
                wiggleStart = nil
                shown.wiggle = 0
            } else {
                shown.wiggle = 11 * exp(-t * 5.2) * sin(t * 2 * .pi * 4.4)
                settled = false
            }
        }
        render()
        if settled {
            timer?.invalidate()
            timer = nil
        }
    }

    private func render() {
        guard let button else { return }
        button.image = shown.templateImage()
        layoutDot(in: button)
    }

    private func layoutDot(in button: NSStatusBarButton) {
        let b = button.bounds
        guard b.width > 0 else { return }
        let size = MenuBarGlyph.canvas
        let origin = CGPoint(x: ((b.width - size.width) / 2).rounded(), y: ((b.height - size.height) / 2).rounded())
        let c = MenuBarGlyph.badgeCenter
        let y = button.isFlipped ? origin.y + (size.height - c.y) : origin.y + c.y
        let r = MenuBarGlyph.badgeRadius
        let frame = CGRect(x: origin.x + c.x - r, y: y - r, width: 2 * r, height: 2 * r)
        if dot.frame != frame {
            dot.frame = frame
            dot.recenter()
        }
    }
}

/// The colored needs-you dot that sits in the glyph's knock-out (a template image can't be orange).
final class BadgeDotView: NSView {
    private let dot = CALayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        dot.backgroundColor = NSColor.systemOrange.cgColor
        dot.bounds = CGRect(x: 0, y: 0, width: 2 * MenuBarGlyph.badgeRadius, height: 2 * MenuBarGlyph.badgeRadius)
        dot.cornerRadius = MenuBarGlyph.badgeRadius
        dot.opacity = 0
        layer?.addSublayer(dot)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        recenter()
    }

    func recenter() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.backgroundColor = NSColor.systemOrange.cgColor
        }
    }

    func setVisible(_ visible: Bool, animated: Bool) {
        dot.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.opacity = visible ? 1 : 0
        dot.transform = CATransform3DIdentity
        CATransaction.commit()
        guard animated else { return }
        if visible {
            let pop = CASpringAnimation(keyPath: "transform.scale")
            pop.fromValue = 0.1
            pop.toValue = 1
            pop.mass = 1
            pop.stiffness = 420
            pop.damping = 13
            pop.duration = pop.settlingDuration
            dot.add(pop, forKey: "pop")
        } else {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.18
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.fromValue = 1
            shrink.toValue = 0.2
            shrink.duration = 0.18
            dot.add(fade, forKey: "fade")
            dot.add(shrink, forKey: "shrink")
        }
    }
}
