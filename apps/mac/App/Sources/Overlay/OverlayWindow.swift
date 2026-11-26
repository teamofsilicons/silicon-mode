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

    /// The view that should hold keyboard focus (the SwiftUI root that takes input).
    private(set) weak var inputView: NSView?

    /// Silicon Mode's layers (`hostLayered`), kept so a prewarmed panel can hold them out of the
    /// window and the exit can freeze the top one.
    private var layerContainer: NSView?
    private var faceLayer: NSView?
    private var topLayer: NSView?
    /// The top layer's last frame, left on screen (fading) after `freezeTopLayer`.
    private var frozenTopLayer: CALayer?

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
            c.addSubview(f, positioned: .below, relativeTo: nil)
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
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer.opacity = 0
        layer.add(fade, forKey: "overlayExitFade")
        frozenTopLayer = layer
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
