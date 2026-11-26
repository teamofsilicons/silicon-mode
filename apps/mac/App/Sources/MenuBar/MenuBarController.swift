import AppKit
import SwiftUI
import SiliconModeKit

/// Owns the NSStatusItem (icon = `MenuBarIconDriver`, the live `MenuBarIcon` glyph) and the
/// borderless glass NSPanel that shows `MenuBarContent` below it. Opened by clicking the icon
/// or programmatically (`toggle()`, `show()`). MenuBarExtra isn't used: it can't be opened from
/// code, sized, or animated (docs/research/macos-ui.md §3.4).
///
/// The panel is a transparent, non-activating canvas sized for the tallest card; the card is
/// top-anchored inside it, so content height changes are pure SwiftUI springs (no window
/// resizing, no jank). Transparent pixels pass clicks through to whatever is below.
@MainActor
final class MenuBarController: NSObject {
    static let shared = MenuBarController()

    let presentation = MenuPanelPresentation()
    private var item: NSStatusItem?
    private var icon: MenuBarIconDriver?
    private var panel: MenuPanel?
    private var hosting: NSHostingView<MenuPanelRoot>?
    private var eventMonitors: [Any] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var unmountTask: Task<Void, Never>?
    private var shrinkTask: Task<Void, Never>?
    private var needsInitialFit = false
    private var clickedStatusFrame: NSRect?
    /// True while one of our NSMenus is tracking (it runs its own event loop).
    private var menuTracking = false
    /// Captured from the card's environment so ⌘, and the gear can open the Settings scene.
    var openSettingsAction: OpenSettingsAction?

    var isShown: Bool { presentation.isPresented }

    // MARK: Status item

    func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "ai.tos.mode.status"
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemPressed(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            let driver = MenuBarIconDriver(button: button)
            icon = driver
            driver.start()
        }
        self.item = item
        observeMode()
    }

    /// Silicon Mode takes the whole screen: get the card out of the way when it starts.
    private func observeMode() {
        withObservationTracking {
            _ = AppModel.shared.isActive
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if AppModel.shared.isActive { self.hide() }
                self.observeMode()
            }
        }
    }

    @objc private func statusItemPressed(_ sender: NSStatusBarButton) {
        clickedStatusFrame = sender.window?.frame
        toggle()
    }

    // MARK: Show / hide

    func toggle() {
        presentation.isPresented ? hide() : show()
    }

    func show() {
        if item == nil { install() }
        if presentation.isPresented {
            panel?.makeKey()
            return
        }
        unmountTask?.cancel()
        unmountTask = nil
        let panel = makePanelIfNeeded()
        let geo = geometry()
        clickedStatusFrame = nil

        presentation.anchor = geo.anchor
        presentation.maxCardHeight = geo.maxCard
        presentation.isPresented = false
        presentation.isMounted = true
        // Start tall enough for any card; the first measurement fits the panel to the card.
        shrinkTask?.cancel()
        needsInitialFit = true
        panel.setFrame(geo.frame, display: false)
        // Render the closed state synchronously so the open spring has a "from".
        hosting?.layoutSubtreeIfNeeded()
        panel.orderFrontRegardless()
        panel.makeKey()
        setHighlighted(true)
        startMonitoring()

        Task { @MainActor [weak self] in
            guard let self, self.presentation.isMounted else { return }
            withAnimation(MB.Motion.open) { self.presentation.isPresented = true }
        }
    }

    func hide() {
        guard presentation.isPresented || presentation.isMounted else { return }
        stopMonitoring()
        setHighlighted(false)
        withAnimation(MB.Motion.close) { presentation.isPresented = false }
        unmountTask?.cancel()
        unmountTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard let self, !Task.isCancelled, !self.presentation.isPresented else { return }
            self.panel?.orderOut(nil)
            // Unmount: no observation, timelines or pulses while hidden.
            self.presentation.isMounted = false
            self.presentation.selection = nil
            self.presentation.cardFrame = .zero
        }
    }

    private func setHighlighted(_ on: Bool) {
        // The button un-highlights itself on mouse-up; set ours after that.
        Task { @MainActor [weak self] in self?.item?.button?.highlight(on) }
    }

    /// The card reports its (final, unanimated) frame. The panel hugs it so no invisible window
    /// area sits over other apps: grow at once (before the spring draws past the edge), shrink
    /// only after the spring has settled. The card is top-anchored, so resizing never moves it.
    func cardFrameChanged(_ frame: CGRect) {
        presentation.cardFrame = frame
        guard let panel, presentation.isMounted, frame.height > 1 else { return }
        let needed = (frame.maxY + MB.margin.bottom).rounded(.up) + 1
        let current = panel.frame.height
        if needed > current + 0.5 {
            shrinkTask?.cancel()
            Task { @MainActor [weak self] in self?.setPanelHeight(needed) }
        } else if needed < current - 0.5 {
            shrinkTask?.cancel()
            if needsInitialFit {
                needsInitialFit = false
                Task { @MainActor [weak self] in self?.setPanelHeight(needed) }
            } else {
                shrinkTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(650))
                    guard !Task.isCancelled else { return }
                    self?.setPanelHeight(needed)
                }
            }
        }
        needsInitialFit = false
    }

    private func setPanelHeight(_ height: CGFloat) {
        guard let panel, presentation.isMounted else { return }
        var f = panel.frame
        guard abs(f.height - height) > 0.5 else { return }
        let top = f.maxY
        f.size.height = height
        f.origin.y = top - height
        panel.setFrame(f, display: true)
    }

    // MARK: Actions used by the card

    /// Opens the Settings scene in front (we're an accessory app, so bring it forward ourselves).
    func openSettings() {
        hide()
        NSApp.activate()
        if let action = openSettingsAction {
            action()
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            if let w = NSApp.windows.first(where: { ($0.identifier?.rawValue ?? "").localizedCaseInsensitiveContains("settings") && $0.isVisible }) {
                w.orderFrontRegardless()
                w.makeKey()
            }
        }
    }

    /// Pops an NSMenu under a rect given in the card's (top-left origin) coordinates.
    func popUp(_ menu: NSMenu, below rect: CGRect) {
        guard let hosting else { return }
        let x = rect.minX
        let y = hosting.isFlipped ? rect.maxY + 6 : hosting.bounds.height - rect.maxY - 6
        menuTracking = true
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: y), in: hosting)
        menuTracking = false
    }

    /// A menu item that runs a closure.
    func menuItem(_ title: String, symbol: String? = nil, enabled: Bool = true, state: NSControl.StateValue = .off,
                  action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: enabled ? #selector(menuItemFired(_:)) : nil, keyEquivalent: "")
        item.target = self
        item.representedObject = MBMenuAction(action)
        item.isEnabled = enabled
        item.state = state
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    @objc private func menuItemFired(_ sender: NSMenuItem) {
        (sender.representedObject as? MBMenuAction)?.run()
    }

    // MARK: Panel

    private func makePanelIfNeeded() -> MenuPanel {
        if let panel { return panel }
        let panel = MenuPanel()
        let hosting = NSHostingView(rootView: MenuPanelRoot(presentation: presentation))
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        self.panel = panel
        self.hosting = hosting
        return panel
    }

    /// Card under the icon (centered on it, clamped to the screen), panel = card + shadow room.
    private func geometry() -> (frame: NSRect, anchor: UnitPoint, maxCard: CGFloat) {
        let statusFrame = clickedStatusFrame ?? item?.button?.window?.frame
        let screen = statusFrame.flatMap { s in NSScreen.screens.first { $0.frame.contains(NSPoint(x: s.midX, y: s.midY)) } }
            ?? NSScreen.main ?? NSScreen.screens.first
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var top = vis.maxY
        var iconX = vis.maxX - 180
        if let s = statusFrame, let screen, screen.frame.contains(NSPoint(x: s.midX, y: s.midY)) {
            top = min(s.minY, vis.maxY)
            iconX = s.midX
        }
        let cardTop = top - MB.gapBelowIcon
        let minX = vis.minX + 8
        let maxX = max(minX, vis.maxX - 8 - MB.width)
        let cardX = min(max(iconX - MB.width / 2, minX), maxX)
        let maxCard = max(260, min(MB.maxHeight, cardTop - vis.minY - 12))
        let m = MB.margin
        let size = NSSize(width: MB.width + m.leading + m.trailing, height: maxCard + m.top + m.bottom)
        let frame = NSRect(x: (cardX - m.leading).rounded(), y: (cardTop + m.top - size.height).rounded(),
                           width: size.width, height: size.height)
        let ax = min(max((iconX - cardX) / MB.width, 0.06), 0.94)
        return (frame, UnitPoint(x: ax, y: 0), maxCard)
    }

    // MARK: Dismissal + keyboard

    private func startMonitoring() {
        stopMonitoring()
        // Clicks in other apps (incl. through our transparent margins).
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.menuTracking else { return }
                self.hide()
            }
        }) { eventMonitors.append(m) }

        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown], handler: { [weak self] event in
            let consume = MainActor.assumeIsolated { self?.handleLocal(event) ?? false }
            return consume ? nil : event
        }) { eventMonitors.append(m) }

        let app = NotificationCenter.default
        let ws = NSWorkspace.shared.notificationCenter
        observers.append((app, app.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }))
        observers.append((ws, ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                if pid != ProcessInfo.processInfo.processIdentifier { self?.hide() }
            }
        }))
        observers.append((ws, ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }))
        observers.append((app, app.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }))
    }

    private func stopMonitoring() {
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors.removeAll()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    /// Returns true to swallow the event.
    private func handleLocal(_ event: NSEvent) -> Bool {
        guard presentation.isPresented, !menuTracking else { return false }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if let panel, event.window === panel {
                let h = hosting?.bounds.height ?? panel.frame.height
                let p = CGPoint(x: event.locationInWindow.x, y: h - event.locationInWindow.y)
                if presentation.cardFrame != .zero, !presentation.cardFrame.insetBy(dx: -2, dy: -2).contains(p) {
                    hide()
                    return true
                }
                return false
            }
            // The status item toggles itself; any other window of ours (Settings…) closes the card.
            if let w = event.window, w === item?.button?.window { return false }
            hide()
            return false
        case .keyDown:
            return handleKey(event)
        default:
            return false
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let panel, event.window === panel else { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.keyCode == 53 { hide(); return true }                    // esc
        if mods == .command {
            switch chars {
            case ",": openSettings(); return true
            case "w": hide(); return true
            case "q": NSApp.terminate(nil); return true
            default: return false
            }
        }
        // Typing in a reply field: leave everything else to the field.
        if panel.firstResponder is NSTextView { return false }
        guard mods.isEmpty else { return false }
        switch event.keyCode {
        case 125: presentation.move(1); return true                        // ↓
        case 126: presentation.move(-1); return true                       // ↑
        case 36, 76, 49: return presentation.activateSelection()           // return, enter, space
        default:
            if let d = Int(chars), (1...9).contains(d) { return presentation.pick(index: d - 1) }
            return false
        }
    }
}

/// Shared state between the controller (AppKit) and the card (SwiftUI).
@MainActor @Observable
final class MenuPanelPresentation {
    /// Content is in the hierarchy (false after the close animation → zero work while hidden).
    var isMounted = false
    /// Drives the open/close animation.
    var isPresented = false
    /// Where the card grows from (the icon), in unit coordinates of the card.
    var anchor: UnitPoint = .top
    var maxCardHeight: CGFloat = 560
    /// The card's frame in the panel (top-left origin) for outside-click checks.
    var cardFrame: CGRect = .zero

    // Keyboard navigation (ids are "q:<question>" or "a:<session>").
    var navOrder: [String] = []
    var selection: String?
    /// Expanded agent rows (session ids). Survives closing the card.
    var expanded: Set<String> = []
    /// A digit pressed while a question card is selected.
    var optionPick: OptionPick?
    /// Reply drafts survive closing the card.
    var drafts: [String: String] = [:]

    struct OptionPick: Equatable { let questionID: String; let index: Int; let nonce: Int }
    private var nonce = 0

    func move(_ delta: Int) {
        guard !navOrder.isEmpty else { return }
        withAnimation(MB.Motion.hover) {
            if let s = selection, let i = navOrder.firstIndex(of: s) {
                selection = navOrder[min(max(i + delta, 0), navOrder.count - 1)]
            } else {
                selection = delta > 0 ? navOrder.first : navOrder.last
            }
        }
    }

    func activateSelection() -> Bool {
        guard let s = selection, s.hasPrefix("a:") else { return false }
        toggleExpanded(String(s.dropFirst(2)))
        return true
    }

    func toggleExpanded(_ id: String) {
        withAnimation(MB.Motion.disclose) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    func pick(index: Int) -> Bool {
        guard let s = selection, s.hasPrefix("q:") else { return false }
        nonce += 1
        optionPick = OptionPick(questionID: String(s.dropFirst(2)), index: index, nonce: nonce)
        return true
    }
}

/// Borderless, non-activating, transparent panel that can still take key (ESC, reply fields).
final class MenuPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false               // the card draws its own soft, warm shadow
        hidesOnDeactivate = false
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = false
        worksWhenModal = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The panel's SwiftUI root: positions the card and runs the grow-from-icon animation.
struct MenuPanelRoot: View {
    let presentation: MenuPanelPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown = presentation.isPresented
        ZStack(alignment: .top) {
            if presentation.isMounted {
                MenuBarContent(maxHeight: presentation.maxCardHeight)
                    .environment(\.menuBarAppeared, shown)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        MenuBarController.shared.cardFrameChanged(frame)
                    }
                    .scaleEffect(shown || reduceMotion ? 1 : 0.86, anchor: presentation.anchor)
                    .offset(y: shown || reduceMotion ? 0 : -10)
                    .opacity(shown ? 1 : 0)
            }
        }
        .padding(MB.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .environment(AppModel.shared)
        .environment(presentation)
    }
}

/// Closure box for NSMenuItem.representedObject.
@MainActor
final class MBMenuAction: NSObject {
    let run: @MainActor () -> Void
    init(_ run: @escaping @MainActor () -> Void) { self.run = run }
}
