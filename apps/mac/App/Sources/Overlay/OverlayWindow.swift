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

    /// Install a SwiftUI root as the panel's content.
    func host<V: View>(_ view: V) {
        let hosting = OverlayHostingView(rootView: view)
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
        let bounds = NSRect(origin: .zero, size: frame.size)
        let container = NSView(frame: bounds)
        container.wantsLayer = true
        container.autoresizingMask = [.width, .height]

        // The face never takes pointer events: its wrapper answers no hit test, so hover and click
        // hit-testing never walk the full-screen face tree.
        let faceLayer = PassthroughView(frame: bounds)
        let faceHost = NSHostingView(rootView: face)
        let topHost = OverlayHostingView(rootView: top)
        faceHost.frame = bounds
        faceHost.autoresizingMask = [.width, .height]
        faceLayer.addSubview(faceHost)
        for v in [faceLayer, topHost] as [NSView] {
            v.frame = bounds
            v.autoresizingMask = [.width, .height]
            container.addSubview(v)
        }
        faceHost.sizingOptions = []
        faceHost.safeAreaRegions = []
        topHost.sizingOptions = []
        topHost.safeAreaRegions = []

        contentView = container
        initialFirstResponder = topHost
        inputView = topHost
    }

    /// Make the input view first responder unless focus already sits inside it (a reply field).
    func focusInputView() {
        guard let v = inputView else { return }
        if let r = firstResponder as? NSView, r.isDescendant(of: v) { return }
        makeFirstResponder(v)
    }

    /// Detach content and close. Safe to call more than once.
    func tearDown() {
        orderOut(nil)
        contentView = nil
        inputView = nil
        close()
    }
}

/// Hosting view that takes the first click even when the app is inactive (the countdown's
/// "Do not enter" button must work with one click while another app is frontmost).
final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
