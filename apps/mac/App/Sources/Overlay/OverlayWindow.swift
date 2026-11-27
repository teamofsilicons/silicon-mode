import AppKit
import SwiftUI

/// Borderless, transparent panel used for every overlay surface (countdown strip, its button,
/// and the full-screen Silicon Mode windows). Non-activating so the countdown never steals focus
/// from what the user is doing; the Silicon Mode window on the built-in display opts into key
/// status so the PIN pad receives keystrokes.
final class OverlayPanel: NSPanel {
    /// Only the window that hosts the PIN pad should become key.
    var acceptsKey = false

    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }

    init(frame: NSRect, level: NSWindow.Level) {
        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = false
        isFloatingPanel = true
        worksWhenModal = true
        acceptsMouseMovedEvents = true
        appearance = NSAppearance(named: .darkAqua)
        setFrame(frame, display: false)
    }

    /// Never moved or clipped below the menu bar: the countdown strip and Silicon Mode cover the
    /// whole display, menu bar and notch included. (NSWindow otherwise keeps a window's top edge
    /// under the menu bar when it orders it on screen.)
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// The view that should hold keyboard focus (the SwiftUI root that takes input).
    private(set) weak var inputView: NSView?

    /// Silicon Mode's layers (`hostLayered`), kept so a prewarmed panel can hold them out of the
    /// window and the exit can freeze the top one.
    private var layerContainer: NSView?
    private var faceLayer: NSView?
    private var topLayer: NSView?
    /// The top layer's last frame, left on screen (fading) after `freezeTopLayer`.
    private var frozenTopLayer: CALayer?
    /// Silicon Mode's blur-fade (`OverlayTransition`): the desktop blur behind the window, the
    /// night base over it. The face and top layers are animated in place.
    private var backdrop: NSVisualEffectView?
    private var backdropLayer: CALayer?
    private var backdropFilter: NSObject?
    private var base: NSView?
    /// The face's blur while it fades (removed once in: it would cost every frame).
    private var faceFilter: NSObject?

    /// Install a SwiftUI root as the panel's content.
    func host<V: View>(_ view: V, timingLabel: String? = nil) {
        let hosting = OverlayHostingView(rootView: view)
        hosting.timingLabel = timingLabel
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
        inputView = hosting
    }

    /// Install Silicon Mode's two layers as sibling hosting views in one container:
    /// - `face` underneath. It is never hit-tested, and its frames (30 per second) re-render only
    ///   the face's own small SwiftUI graph.
    /// - `top` above it, transparent: furniture, chrome, the unlock sheet and panic. It changes only
    ///   when they do, so a face frame never re-renders furniture and vice versa.
    /// Liquid Glass in `top` samples the face beneath it: both are layers of the same window.
    func hostLayered<Face: View, Top: View>(face: Face, top: Top) {
        hostFace(face)
        hostTop(top)
    }

    /// The container and the face layer (see `hostLayered`).
    func hostFace<Face: View>(_ face: Face) {
        let bounds = NSRect(origin: .zero, size: frame.size)
        let container = NSView(frame: bounds)
        container.wantsLayer = true
        container.autoresizingMask = [.width, .height]

        // The face never takes pointer events: its wrapper answers no hit test, so hover and click
        // hit-testing never walk the full-screen face tree.
        let faceLayer = PassthroughView(frame: bounds)
        faceLayer.autoresizingMask = [.width, .height]
        let faceHost = OverlayHostingView(rootView: face)
        faceHost.timingLabel = "face-layout"
        faceHost.frame = bounds
        faceHost.autoresizingMask = [.width, .height]
        faceHost.sizingOptions = []
        faceHost.safeAreaRegions = []
        faceLayer.addSubview(faceHost)

        // Under the face: the desktop blur, then the night base. Both start invisible, like the
        // face itself: a window built ahead of time shows nothing until its entrance.
        let backdrop = NSVisualEffectView(frame: bounds)
        backdrop.autoresizingMask = [.width, .height]
        backdrop.blendingMode = .behindWindow
        backdrop.material = .fullScreenUI
        backdrop.state = .active
        backdrop.appearance = NSAppearance(named: .darkAqua)
        backdrop.alphaValue = 0
        container.addSubview(backdrop)
        self.backdrop = backdrop

        let base = PassthroughView(frame: bounds)
        base.autoresizingMask = [.width, .height]
        base.wantsLayer = true
        base.layer?.backgroundColor = NSColor(Theme.Night.background).cgColor
        base.alphaValue = 0
        container.addSubview(base)
        self.base = base

        faceLayer.wantsLayer = true
        faceLayer.alphaValue = 0
        container.addSubview(faceLayer)

        contentView = container
        layerContainer = container
        self.faceLayer = faceLayer
    }

    /// The top layer above the face (replacing any previous one); it takes keyboard input.
    func hostTop<Top: View>(_ top: Top) {
        guard let c = layerContainer else { return }
        removeTop()
        let topHost = OverlayHostingView(rootView: top)
        topHost.timingLabel = "top-layout"
        topHost.frame = c.bounds
        topHost.autoresizingMask = [.width, .height]
        topHost.sizingOptions = []
        topHost.safeAreaRegions = []
        c.addSubview(topHost, positioned: .above, relativeTo: faceLayer?.superview === c ? faceLayer : nil)
        initialFirstResponder = topHost
        inputView = topHost
        topLayer = topHost
    }

    /// Drop the top layer.
    func removeTop() {
        topLayer?.removeFromSuperview()
        topLayer = nil
        inputView = nil
        initialFirstResponder = nil
    }

    var hasTop: Bool { topLayer != nil }

    /// Lay out (build) the top layer now.
    func buildTop() {
        topLayer?.layoutSubtreeIfNeeded()
    }

    /// Lay out (and so build) the SwiftUI graphs of the layers now, while the panel is ordered out.
    func buildLayers() {
        contentView?.layoutSubtreeIfNeeded()
        displayIfNeeded()
    }

    /// Take the layers out of the window, keeping their SwiftUI graphs. A hosting view inside a
    /// window keeps running its timelines (the face, at full rate) even while the window is ordered
    /// out; one outside any window does nothing until it's put back.
    func detachLayers() {
        faceLayer?.removeFromSuperview()
        topLayer?.removeFromSuperview()
    }

    /// Put the layers back (face under top), ready to order front.
    func attachLayers() {
        guard let c = layerContainer else { return }
        if let f = faceLayer, f.superview !== c {
            f.frame = c.bounds
            c.addSubview(f, positioned: .above, relativeTo: base?.superview === c ? base : nil)
        }
        if let t = topLayer, t.superview !== c {
            t.frame = c.bounds
            c.addSubview(t, positioned: .above, relativeTo: nil)
        }
        initialFirstResponder = topLayer
    }

    /// Exit: stop SwiftUI from updating the top layer (furniture, chrome, unlock sheet) and fade its
    /// last frame out with Core Animation. A model reset at exit relayouts that layer (every log
    /// line at once); doing that while the face implodes once stalled the main thread with the
    /// overlay frozen on screen.
    func freezeTopLayer(fadeDuration: Double) {
        guard let c = layerContainer, let top = topLayer, top.superview === c else { return }
        let layer = top.layer
        if let r = firstResponder as? NSView, r.isDescendant(of: top) { makeFirstResponder(nil) }
        top.removeFromSuperview()
        inputView = nil
        guard let layer, let host = c.layer else { return }
        if layer.superlayer == nil { host.addSublayer(layer) }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
        fade.toValue = 0
        fade.duration = fadeDuration
        fade.timingFunction = OverlayMotion.caEaseOut
        layer.opacity = 0
        layer.add(fade, forKey: "overlayExitFade")
        frozenTopLayer = layer
    }

    // MARK: Blur-fade

    /// Entrance, all on Core Animation (the render server runs it: building the furniture or any
    /// other main-thread work at the entry can't make it skip). The desktop blurs, the night base
    /// fades in over it, the face resolves out of a blur while settling from a little larger, then
    /// the furniture and chrome rise in. Timings: `OverlayMotion`.
    func playEntrance(reduceMotion: Bool) {
        guard let face = faceLayer?.layer, let baseLayer = base?.layer else { return }
        let M = OverlayMotion.self
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if reduceMotion {
            base?.alphaValue = 1
            faceLayer?.alphaValue = 1
            Self.animate(baseLayer, "opacity", from: 0, to: 1, duration: 0.35, delay: 0, M.caEaseInOut)
            Self.animate(face, "opacity", from: 0, to: 1, duration: 0.35, delay: 0.05, M.caEaseInOut)
            if let top = topLayer?.layer {
                Self.animate(top, "opacity", from: 0, to: 1, duration: 0.3, delay: 0.25, M.caEaseInOut)
            }
            CATransaction.commit()
            return
        }
        // Desktop blur: radius 0 → full (an unblurred backdrop looks exactly like no window).
        if configureBackdrop(), let layer = backdropLayer, let f = backdropFilter {
            backdrop?.alphaValue = 1
            f.setValue(M.backdropRadius, forKey: "inputRadius")
            layer.filters = [f]
            Self.animate(layer, "filters.gaussianBlur.inputRadius", from: 0, to: M.backdropRadius,
                         duration: M.backdropIn.duration, delay: M.backdropIn.start, M.caEaseOut)
        } else if let b = backdrop, let layer = b.layer {
            // No radius filter: the material's own blur fades in instead.
            b.alphaValue = 1
            Self.animate(layer, "opacity", from: 0, to: 1, duration: M.backdropIn.duration, delay: M.backdropIn.start, M.caEaseOut)
        }
        base?.alphaValue = 1
        Self.animate(baseLayer, "opacity", from: 0, to: 1, duration: M.baseIn.duration, delay: M.baseIn.start, M.caEaseInOut)

        faceLayer?.alphaValue = 1
        Self.animate(face, "opacity", from: 0, to: 1, duration: M.faceFadeIn.duration, delay: M.faceFadeIn.start, M.caEaseInOut)
        if let blur = Self.caFilter("gaussianBlur") {
            blur.setValue("faceBlur", forKey: "name")
            blur.setValue(0, forKey: "inputRadius")
            face.filters = [blur]
            faceFilter = blur
            Self.animate(face, "filters.faceBlur.inputRadius", from: M.faceBlur, to: 0,
                         duration: M.faceIn.duration, delay: M.faceIn.start, M.caSettle)
        }
        Self.animate(face, "transform", from: NSValue(caTransform3D: Self.scale(M.faceScaleIn, in: face.bounds)),
                     to: NSValue(caTransform3D: CATransform3DIdentity), duration: M.faceIn.duration, delay: M.faceIn.start, M.caSettle)

        if let top = topLayer?.layer {
            Self.animate(top, "opacity", from: 0, to: 1, duration: M.chromeDuration, delay: M.chromeDelay, M.caSettle)
            Self.animate(top, "transform", from: NSValue(caTransform3D: CATransform3DMakeTranslation(0, -M.chromeRise, 0)),
                         to: NSValue(caTransform3D: CATransform3DIdentity), duration: M.chromeDuration, delay: M.chromeDelay, M.caSettle)
        }
        CATransaction.commit()
    }

    /// Silicon Mode is fully in: drop what only the transition needed (the face's blur filter and
    /// the desktop blur, which the opaque window hides anyway).
    func entranceSettled() {
        faceLayer?.layer?.filters = nil
        faceFilter = nil
        backdrop?.alphaValue = 0
    }

    /// Fully in at once (a display added while Silicon Mode is up).
    func showEntered() {
        base?.alphaValue = 1
        faceLayer?.alphaValue = 1
    }

    /// Exit, the entrance backwards and quicker: the face blurs and dissolves, the base fades to
    /// the blurred desktop, the blur clears. The top layer has been frozen (`freezeTopLayer`).
    func playExit(reduceMotion: Bool) {
        guard let face = faceLayer?.layer, let baseLayer = base?.layer else { return }
        let M = OverlayMotion.self
        let faceOpacity = face.presentation()?.opacity ?? 1
        let baseOpacity = baseLayer.presentation()?.opacity ?? 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [face, baseLayer] { l.removeAllAnimations() }
        faceLayer?.alphaValue = 0
        base?.alphaValue = 0
        if reduceMotion {
            Self.animate(face, "opacity", from: faceOpacity, to: 0, duration: 0.3, delay: 0, M.caEaseInOut)
            Self.animate(baseLayer, "opacity", from: baseOpacity, to: 0, duration: 0.3, delay: 0.05, M.caEaseInOut)
            backdrop?.alphaValue = 0
            CATransaction.commit()
            return
        }
        Self.animate(face, "opacity", from: faceOpacity, to: 0, duration: M.faceFadeOut.duration, delay: M.faceFadeOut.start, M.caEaseInOut)
        if let blur = faceFilter ?? Self.caFilter("gaussianBlur") {
            blur.setValue("faceBlur", forKey: "name")
            blur.setValue(M.faceBlurExit, forKey: "inputRadius")
            face.filters = [blur]
            faceFilter = blur
            Self.animate(face, "filters.faceBlur.inputRadius", from: 0, to: M.faceBlurExit,
                         duration: M.faceBlurOut.duration, delay: M.faceBlurOut.start, M.caEaseOut)
        }
        Self.animate(face, "transform", from: NSValue(caTransform3D: CATransform3DIdentity),
                     to: NSValue(caTransform3D: Self.scale(M.faceScaleOut, in: face.bounds)),
                     duration: M.faceFadeOut.duration, delay: M.faceFadeOut.start, M.caEaseIn, holdEnd: true)
        Self.animate(baseLayer, "opacity", from: baseOpacity, to: 0, duration: M.baseOut.duration, delay: M.baseOut.start, M.caEaseInOut)

        if configureBackdrop(), let layer = backdropLayer, let f = backdropFilter {
            backdrop?.alphaValue = 1
            f.setValue(0, forKey: "inputRadius")
            layer.filters = [f]
            Self.animate(layer, "filters.gaussianBlur.inputRadius", from: M.backdropRadius, to: 0,
                         duration: M.backdropOut.duration, delay: M.backdropOut.start, M.caEaseInOut)
        } else if let b = backdrop, let layer = b.layer {
            b.alphaValue = 0
            Self.animate(layer, "opacity", from: 1, to: 0, duration: M.backdropOut.duration, delay: M.backdropOut.start, M.caEaseInOut)
        }
        CATransaction.commit()
    }

    /// Find the material's backdrop layer and give it a plain radius blur (the private
    /// `CAFilter("gaussianBlur")`, feature-detected; the material's tint layers are hidden so an
    /// unblurred backdrop is invisible). AppKit may rebuild the material's layers, so this checks
    /// the filter is still in place each time. False when unavailable: callers fade the material.
    @discardableResult
    func configureBackdrop() -> Bool {
        guard let v = backdrop else { return false }
        if v.layer?.sublayers == nil { v.layoutSubtreeIfNeeded(); v.displayIfNeeded() }
        guard let layer = Self.findBackdrop(v.layer) else { return false }
        if layer === backdropLayer, let f = backdropFilter,
           (layer.filters as? [NSObject])?.contains(where: { $0 === f }) == true { return true }
        guard let f = backdropFilter ?? Self.caFilter("gaussianBlur") else { return false }
        f.setValue("gaussianBlur", forKey: "name")
        f.setValue(0, forKey: "inputRadius")
        layer.filters = [f]
        layer.superlayer?.sublayers?.filter { $0 !== layer }.forEach { $0.isHidden = true }
        backdropLayer = layer
        backdropFilter = f
        return true
    }

    private static func findBackdrop(_ l: CALayer?) -> CALayer? {
        guard let l else { return nil }
        if String(describing: type(of: l)) == "CABackdropLayer" { return l }
        for s in l.sublayers ?? [] { if let b = findBackdrop(s) { return b } }
        return nil
    }

    private static func caFilter(_ type: String) -> NSObject? {
        guard let cls = NSClassFromString("CAFilter") as? NSObject.Type,
              cls.responds(to: NSSelectorFromString("filterWithType:")) else { return nil }
        return cls.perform(NSSelectorFromString("filterWithType:"), with: type)?.takeUnretainedValue() as? NSObject
    }

    /// Scale by `s` about the centre of `bounds` (AppKit's layers are anchored at their origin).
    private static func scale(_ s: CGFloat, in bounds: CGRect) -> CATransform3D {
        var t = CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
        t = CATransform3DScale(t, s, s, 1)
        return CATransform3DTranslate(t, -bounds.midX, -bounds.midY, 0)
    }

    /// An explicit animation from `from` to `to`, `delay` seconds from now. It shows `from` until
    /// it starts; with `holdEnd` it keeps showing `to` after it ends (the model value is unchanged).
    private static func animate(_ layer: CALayer, _ keyPath: String, from: Any, to: Any, duration: Double, delay: Double,
                                _ timing: CAMediaTimingFunction, holdEnd: Bool = false) {
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        a.fillMode = holdEnd ? .both : .backwards
        a.isRemovedOnCompletion = !holdEnd
        a.timingFunction = timing
        layer.add(a, forKey: "overlay." + keyPath)
    }

    /// Make the input view first responder unless focus already sits inside it (a reply field).
    func focusInputView() {
        guard let v = inputView else { return }
        if let r = firstResponder as? NSView, r.isDescendant(of: v) { return }
        makeFirstResponder(v)
    }

    /// Detach content and close. Safe to call more than once. Ordering out comes first: the
    /// window leaves the screen even if releasing its content is slow.
    func tearDown() {
        orderOut(nil)
        frozenTopLayer?.removeFromSuperlayer()
        frozenTopLayer = nil
        backdrop = nil
        backdropLayer = nil
        backdropFilter = nil
        base = nil
        faceFilter = nil
        contentView = nil
        inputView = nil
        layerContainer = nil
        faceLayer = nil
        topLayer = nil
        close()
    }
}

/// Hosting view that takes the first click even when the app is inactive (the countdown's
/// "Do not enter" button must work with one click while another app is frontmost).
final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    /// Names this view's layout passes in the transition timing (OverlayTiming).
    var timingLabel: String?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        guard let label = timingLabel, OverlayTiming.isTiming else { return super.layout() }
        let t0 = CACurrentMediaTime()
        super.layout()
        OverlayTiming.layout(label, seconds: CACurrentMediaTime() - t0)
    }
}

/// A purely visual layer: it and everything inside it are invisible to hit-testing.
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Screens

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    var isBuiltIn: Bool { CGDisplayIsBuiltin(displayID) != 0 }

    /// The laptop's own panel (the one whose lid we're watching), else the main screen.
    static var overlayPrimary: NSScreen? {
        screens.first(where: \.isBuiltIn) ?? main ?? screens.first
    }
}

// MARK: - Glass

enum OverlayRender {
    /// True when the process is rendering headless snapshots (ImageRenderer draws Liquid Glass
    /// subtrees as nothing at all, so overlay chrome swaps in a flat stand-in there).
    static let isSnapshot = CommandLine.arguments.contains("--snapshot")
}

extension View {
    /// Liquid Glass in the app; a flat approximation in headless snapshots.
    @ViewBuilder
    func overlayGlass<S: InsettableShape>(tint: Color? = nil, interactive: Bool = true, in shape: S) -> some View {
        if OverlayRender.isSnapshot {
            self.background {
                ZStack {
                    shape.fill(.white.opacity(0.13))
                    if let tint { shape.fill(tint) }
                    shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0.06), .white.opacity(0.16)],
                                                      startPoint: .top, endPoint: .bottom), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
            }
        } else {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        }
    }

    /// `GlassEffectContainer` in the app; passthrough in snapshots.
    @ViewBuilder
    func overlayGlassContainer(spacing: CGFloat) -> some View {
        if OverlayRender.isSnapshot {
            self
        } else {
            GlassEffectContainer(spacing: spacing) { self }
        }
    }
}
