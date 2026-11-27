import AppKit
import SwiftUI

/// Progressive blur of whatever is *behind* the countdown window: strongest at the top edge,
/// fading to sharp toward the bottom of the strip (like the iPhone's top-edge blur, minus the
/// perspective change).
///
/// Technique (docs/research/macos-ui.md §7): the private `CAFilter("variableBlur")` on the
/// `CABackdropLayer` inside an `NSVisualEffectView(.behindWindow)`, with a gradient mask that
/// sets the radius per pixel. Feature-detected at runtime; if unavailable, falls back to stacked
/// alpha-masked visual effect views (public API, blur opacity fades instead of radius).
struct CountdownBackdropBlur: NSViewRepresentable {
    var visible: Bool
    var handoff: Bool
    var maxRadius: CGFloat = 46

    func makeNSView(context: Context) -> CountdownBlurNSView {
        let v = CountdownBlurNSView()
        v.maxRadius = maxRadius
        return v
    }

    func updateNSView(_ v: CountdownBlurNSView, context: Context) {
        v.setVisible(visible, handoff: handoff)
    }
}

final class CountdownBlurNSView: NSView {
    var maxRadius: CGFloat = 46
    /// What the last configured strip ended up with (debug state dump).
    nonisolated(unsafe) static var debugState = "unconfigured"

    private let host = NSView()
    private var effects: [NSVisualEffectView] = []
    private weak var backdrop: CALayer?
    private var filter: NSObject?
    private var configured = false
    private var configureAttempts = 0
    private var visible = false
    /// The stacked public blurs stand in (the variable blur wasn't ready, or doesn't exist).
    private var usingFallback = false

    // The radius mask's orientation is picked from the backdrop layer itself (see `configure`).

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        host.wantsLayer = true
        host.alphaValue = 1
        addSubview(host)
        let primary = Self.makeEffect()
        primary.frame = host.bounds
        primary.autoresizingMask = [.width, .height]
        host.addSubview(primary)
        effects = [primary]
    }

    required init?(coder: NSCoder) { nil }

    private static func makeEffect() -> NSVisualEffectView {
        let e = NSVisualEffectView()
        e.blendingMode = .behindWindow
        e.material = .fullScreenUI
        e.state = .active
        e.appearance = NSAppearance(named: .darkAqua)
        e.wantsLayer = true
        return e
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !configured else { return }
        // The backdrop layer exists only after the view is attached to a window.
        DispatchQueue.main.async { [weak self] in self?.configure() }
    }

    override func layout() {
        super.layout()
        if configured, filter != nil { reapplyIfNeeded() }
        host.frame = bounds
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if configured, filter != nil { reapplyIfNeeded() }
    }

    /// AppKit can rebuild the material's layer tree (screen change, backing scale change, the
    /// window ordered on screen); put the variable blur back if our filter went missing. True
    /// when it had to.
    @discardableResult
    private func reapplyIfNeeded() -> Bool {
        guard let filter, let current = Self.findBackdrop(effects[0].layer) else { return false }
        let ours = (current.filters as? [NSObject])?.contains { $0 === filter } ?? false
        guard current !== backdrop || !ours else { return false }
        filter.setValue(visible ? maxRadius : 0, forKey: "inputRadius")
        filter.setValue(current.contentsAreFlipped() ? Self.radiusMaskTopDown : Self.radiusMaskBottomUp, forKey: "inputMaskImage")
        current.filters = [filter]
        current.superlayer?.sublayers?.filter { $0 !== current }.forEach { $0.isHidden = true }
        backdrop = current
        Self.debugState = "reapplied; flipped=\(current.contentsAreFlipped()) frame=\(current.frame)"
        return true
    }

    // MARK: Configure

    private func configure() {
        guard !configured, window != nil else { return }
        guard let backdrop = Self.findBackdrop(effects[0].layer) else {
            // The material builds its backdrop layer on a later display pass (a prewarmed strip
            // is configured while ordered out): look again shortly before falling back.
            if Self.variableBlurAvailable, configureAttempts < 20 {
                configureAttempts += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.configure() }
            } else {
                configured = true
                installFallback()
                Self.debugState = "fallback; window visible=\(window?.isVisible ?? false) attempts=\(configureAttempts)"
                OverlayTiming.note(.countdown, "blur fallback (no backdrop layer)")
            }
            return
        }
        configured = true
        if let f = Self.makeVariableBlur() {
            f.setValue("variableBlur", forKey: "name")
            f.setValue(visible ? maxRadius : 0, forKey: "inputRadius")
            // The filter reads its mask bottom-up on an unflipped backdrop layer (row 0 = bottom
            // edge) and top-down on a flipped one; which one this is depends on the views above.
            f.setValue(backdrop.contentsAreFlipped() ? Self.radiusMaskTopDown : Self.radiusMaskBottomUp, forKey: "inputMaskImage")
            // Normalized edges wash the whole strip out evenly instead of grading it.
            f.setValue(false, forKey: "inputNormalizeEdges")
            backdrop.filters = [f]
            // Drop the material's tint/luminosity layers: we paint our own tint in SwiftUI.
            backdrop.superlayer?.sublayers?.filter { $0 !== backdrop }.forEach { $0.isHidden = true }
            self.backdrop = backdrop
            self.filter = f
            Self.debugState = "variable; flipped=\(backdrop.contentsAreFlipped()) frame=\(backdrop.frame) superFrame=\(backdrop.superlayer?.frame ?? .zero) window=\(window?.frame ?? .zero) visible=\(window?.isVisible ?? false) attempts=\(configureAttempts)"
            OverlayTiming.point(.countdown, "blur-configured")
            OverlayTiming.note(.countdown, "variable blur ready (after \(configureAttempts) retries)")
        } else {
            installFallback()
        }
    }

    private func retryVariableBlur() {
        for e in effects.dropFirst() { e.removeFromSuperview() }
        effects = [effects[0]]
        effects[0].maskImage = nil
        usingFallback = false
        configured = false
        configureAttempts = 0
        configure()
    }

    private static var variableBlurAvailable: Bool {
        (NSClassFromString("CAFilter") as? NSObject.Type)?.responds(to: NSSelectorFromString("filterWithType:")) ?? false
    }

    private static func makeVariableBlur() -> NSObject? {
        guard let cls = NSClassFromString("CAFilter") as? NSObject.Type,
              cls.responds(to: NSSelectorFromString("filterWithType:")) else { return nil }
        return cls.perform(NSSelectorFromString("filterWithType:"), with: "variableBlur")?.takeUnretainedValue() as? NSObject
    }

    /// Public fallback: several stacked behind-window blurs, each fading out at a different depth,
    /// so the combined blur opacity eases off smoothly toward the bottom.
    private func installFallback() {
        usingFallback = true
        if !visible { host.alphaValue = 0 }
        let first = effects[0]
        first.maskImage = Self.cachedAlphaMask(extent: 0.42)
        for extent in [0.7, 1.0] {
            let e = Self.makeEffect()
            e.frame = host.bounds
            e.autoresizingMask = [.width, .height]
            e.maskImage = Self.cachedAlphaMask(extent: extent)
            host.addSubview(e)
            effects.append(e)
        }
    }

    private static func findBackdrop(_ l: CALayer?) -> CALayer? {
        guard let l else { return nil }
        if String(describing: type(of: l)) == "CABackdropLayer" { return l }
        for s in l.sublayers ?? [] { if let b = findBackdrop(s) { return b } }
        return nil
    }

    /// The masks are fixed: made once per process, not per countdown.
    private static let radiusMaskTopDown = radiusMask(rowZeroIsTop: true)
    private static let radiusMaskBottomUp = radiusMask(rowZeroIsTop: false)
    private static var alphaMasks: [Double: NSImage] = [:]

    private static func cachedAlphaMask(extent: Double) -> NSImage {
        if let m = alphaMasks[extent] { return m }
        let m = alphaMask(extent: extent)
        alphaMasks[extent] = m
        return m
    }

    /// Radius mask: full radius through the top ~30% (menu bar and notch included), easing to
    /// zero at the bottom edge. `rowZeroIsTop`: whether the filter will read row 0 as the strip's
    /// top edge (a flipped backdrop layer) or its bottom.
    private static func radiusMask(rowZeroIsTop: Bool, height h: Int = 256) -> CGImage? {
        var px = [UInt8](repeating: 0, count: h * 4)
        for y in 0..<h {
            let r = Double(y) / Double(h - 1)
            let t = rowZeroIsTop ? r : 1 - r
            let k = min(max((t - 0.28) / 0.72, 0), 1)
            let a = 1 - k * k * (3 - 2 * k)
            px[y * 4 + 3] = UInt8((a * 255).rounded())
        }
        return px.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: 1, height: h, bitsPerComponent: 8, bytesPerRow: 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }

    /// Alpha mask for the fallback: opaque at the top, smoothstep to clear at `extent` (0…1).
    private static func alphaMask(extent: Double) -> NSImage {
        let img = NSImage(size: NSSize(width: 8, height: 256), flipped: true) { rect in
            let stops = 24
            var colors: [NSColor] = []
            var locs: [CGFloat] = []
            for i in 0...stops {
                let t = Double(i) / Double(stops)
                let k = min(max(t / extent, 0), 1)
                let a = 1 - k * k * (3 - 2 * k)
                colors.append(NSColor(white: 0, alpha: a))
                locs.append(CGFloat(t))
            }
            NSGradient(colors: colors, atLocations: &locs, colorSpace: .deviceRGB)?.draw(in: rect, angle: 90)
            return true
        }
        img.resizingMode = .stretch
        img.capInsets = NSEdgeInsetsZero
        return img
    }

    // MARK: Animation

    /// The strip always spans its full height (growing it from nothing made AppKit rebuild the
    /// material's layers mid-animation and drop the variable blur); it comes in and goes out by
    /// its blur radius.
    func setVisible(_ shown: Bool, handoff: Bool) {
        guard shown != visible else { return }
        visible = shown
        // A strip built ahead of time, ordered out, may not have had its backdrop layer yet and
        // fell back to the stacked blurs. On screen now: try the real variable blur again.
        if shown, usingFallback, Self.variableBlurAvailable { retryVariableBlur() }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        if shown {
            host.frame = bounds
            host.alphaValue = 1
            if filter == nil {
                // Fallback blurs: fade them in.
                host.alphaValue = 0
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = reduce ? 0.3 : 0.5
                    host.animator().alphaValue = 1
                }
                return
            }
            reapplyIfNeeded()
            animateRadius(to: maxRadius, duration: reduce ? 0.3 : 0.6)
            // Ordering the window on screen can rebuild the material's layers a beat later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                guard let self, self.visible, self.reapplyIfNeeded() else { return }
                self.filter?.setValue(0, forKey: "inputRadius")
                self.animateRadius(to: self.maxRadius, duration: 0.5)
            }
        } else if handoff {
            // Hold the blur while Silicon Mode fades in above it, then dissolve it.
            DispatchQueue.main.asyncAfter(deadline: .now() + (reduce ? 0 : 0.5)) { [weak self] in
                guard let self, !self.visible else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.42
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    self.host.animator().alphaValue = 0
                }
            }
        } else if filter != nil {
            // Cancelled: the blur eases back to nothing.
            animateRadius(to: 0, duration: 0.38)
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.32
                host.animator().alphaValue = 0
            }
        }
    }

    private func animateRadius(to radius: CGFloat, duration: Double) {
        guard let backdrop, let filter else { return }
        let from = (filter.value(forKey: "inputRadius") as? CGFloat) ?? 0
        filter.setValue(radius, forKey: "inputRadius")
        backdrop.filters = [filter]
        let a = CABasicAnimation(keyPath: "filters.variableBlur.inputRadius")
        a.fromValue = from
        a.toValue = radius
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.3, 1)
        backdrop.add(a, forKey: "overlayCountdownRadius")
    }
}

/// SwiftUI stand-in used only by the headless snapshot harness (which can't render AppKit
/// views or sample the desktop): stacked blurs of a supplied backdrop with staggered masks.
struct CountdownSimulatedBlur<Backdrop: View>: View {
    var maxRadius: CGFloat = 46
    @ViewBuilder var backdrop: Backdrop

    /// `backdrop` may be taller than this view (e.g. the whole desktop): it is top-aligned and
    /// clipped after blurring, so the blur samples real content past the strip's bottom edge.
    var body: some View {
        GeometryReader { geo in
            let stripH = geo.size.height
            ZStack(alignment: .top) {
                backdrop
                ForEach(Array([0.12, 0.25, 0.45, 0.7, 1.0].enumerated()), id: \.offset) { i, f in
                    backdrop
                        .blur(radius: maxRadius * f)
                        .mask(alignment: .top) {
                            LinearGradient(stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: max(0.0, 0.62 - Double(i) * 0.1)),
                                .init(color: .clear, location: min(1.0, 0.98 - Double(i) * 0.12)),
                            ], startPoint: .top, endPoint: .bottom)
                            .frame(height: stripH)
                        }
                }
            }
            .frame(width: geo.size.width, height: stripH, alignment: .top)
            .clipped()
        }
    }
}
