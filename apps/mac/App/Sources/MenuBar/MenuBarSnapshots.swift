import SwiftUI
import SiliconModeKit

/// Snapshot-harness entries for this module (see App/SnapshotHarness.swift).
///
///     "Silicon Mode" --snapshot menubar-popover /tmp/mb.png
///
/// Glass can't render offscreen, so the card is drawn with its flat look-alike over a
/// wallpaper-ish backdrop.
@MainActor
enum MenuBarSnapshots {
    static var items: [SnapshotItem] {
        [
            card("menubar-popover", dark: true, demo: .base, expanded: ["claude-code:demo-1"]),
            card("menubar-popover-light", dark: false, demo: .base, expanded: ["claude-code:demo-1"]),
            card("menubar-collapsed", dark: true, demo: .base, height: 760, selection: "a:claude-code:demo-5"),
            card("menubar-empty", dark: true, demo: emptyDemo, height: 560),
            card("menubar-empty-light", dark: false, demo: emptyDemo, height: 560),
            card("menubar-questions", dark: true, demo: questionsDemo, height: 980, selection: "q:demo-q"),
            card("menubar-questions-light", dark: false, demo: questionsDemo, height: 980),
            card("menubar-paused", dark: false, demo: pausedDemo, height: 760),
            SnapshotItem(id: "menubar-headers", size: CGSize(width: 900, height: 760), dark: true) { AnyView(HeaderGallery()) },
            SnapshotItem(id: "menubar-headers-light", size: CGSize(width: 900, height: 760), dark: false) { AnyView(HeaderGallery()) },
            // The real panel root wired to the live (unstarted) AppModel: exercises the connectors.
            SnapshotItem(id: "menubar-panel-live", size: CGSize(width: MB.width + MB.margin.leading + MB.margin.trailing, height: 560), dark: true) {
                let p = MenuPanelPresentation()
                p.isMounted = true
                p.isPresented = true
                p.maxCardHeight = 480
                return AnyView(ZStack { SnapshotBackdrop(); MenuPanelRoot(presentation: p) })
            },
            SnapshotItem(id: "menubar-icons", size: CGSize(width: 560, height: 300), dark: true) { AnyView(IconGallery()) },
            SnapshotItem(id: "menubar-icons-light", size: CGSize(width: 560, height: 300), dark: false) { AnyView(IconGallery()) },
        ]
    }

    private static func card(_ id: String, dark: Bool, demo: MenuBarDemo, height: CGFloat = 900,
                             expanded: Set<String> = [], selection: String? = nil) -> SnapshotItem {
        SnapshotItem(id: id, size: CGSize(width: MB.width + 88, height: height), dark: dark) {
            let p = MenuPanelPresentation()
            p.expanded = expanded
            p.selection = selection
            p.isMounted = true
            p.isPresented = true
            return AnyView(
                ZStack(alignment: .top) {
                    SnapshotBackdrop()
                    MenuBarContent(maxHeight: height - 60)
                        .environment(p)
                        .environment(\.menuBarDemo, demo)
                        .padding(.top, 22)
                }
            )
        }
    }

    static var emptyDemo: MenuBarDemo {
        var d = MenuBarDemo.base
        d.sessions = []
        d.accountName = "Shubham Sharma"
        return d
    }

    static var pausedDemo: MenuBarDemo {
        var d = MenuBarDemo.base
        let until = Calendar.current.date(bySettingHour: 15, minute: 0, second: 0, of: Date()) ?? Date()
        d.header = HeaderState(mode: .off(.paused(until)), angle: 64, threshold: 75, hotkey: true)
        d.pausedUntil = until
        return d
    }

    static var questionsDemo: MenuBarDemo {
        var d = MenuBarDemo.base
        d.header = HeaderState(mode: .countdown(remaining: 3.2, duration: 5), angle: 58, threshold: 75, hotkey: true)
        var sessions = MenuBarSamples.sessions
        if let i = sessions.firstIndex(where: { $0.id == "claude-code:demo-1" }) {
            sessions[i].state = .needsYou
            sessions[i].pendingQuestions = [MenuBarSamples.question]
        }
        // An agent we can only display (no hook): "Answer in opencode".
        if let i = sessions.firstIndex(where: { $0.id == "opencode:demo-3" }) {
            sessions[i].state = .needsYou
            sessions[i].pendingQuestions = [AgentQuestion(
                id: "demo-oc", sessionID: "opencode:demo-3", provider: "opencode", kind: .permission,
                title: "Edit file", detail: "migrations/0042_invoices.sql",
                options: AgentQuestion.permissionOptions(), createdAt: Date().addingTimeInterval(-240), answerable: false)]
        }
        d.sessions = sessions
        d.errors = ["demo-q": "Codex stopped listening; answer it in the terminal."]
        return d
    }
}

/// A soft desktop so the flat glass reads like it does over a wallpaper.
private struct SnapshotBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let dark = scheme == .dark
        ZStack {
            LinearGradient(colors: dark ? [Color(hex: "16213A"), Color(hex: "2A2340"), Color(hex: "3A2A26")]
                                        : [Color(hex: "DCE6F7"), Color(hex: "E9E0F4"), Color(hex: "F6E4D6")],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(dark ? Color(hex: "4B5BA8").opacity(0.35) : Color(hex: "B9C8F2").opacity(0.6))
                .frame(width: 420).blur(radius: 90).offset(x: -150, y: -120)
            Circle().fill(dark ? Color(hex: "8A5A3A").opacity(0.30) : Color(hex: "F5CDA9").opacity(0.55))
                .frame(width: 380).blur(radius: 90).offset(x: 160, y: 260)
        }
        .ignoresSafeArea()
    }
}

/// Every header state in one image.
private struct HeaderGallery: View {
    var body: some View {
        let now = Date()
        let states: [(String, HeaderState)] = [
            ("Off · ready", HeaderState(mode: .off(.ready), angle: 112, threshold: 75, hotkey: true)),
            ("Paused", HeaderState(mode: .off(.paused(now.addingTimeInterval(3600))), angle: 96, threshold: 75, hotkey: true)),
            ("Re-arming", HeaderState(mode: .off(.rearming(42)), angle: 101, threshold: 75, hotkey: true)),
            ("No sensor", HeaderState(mode: .off(.noSensor), angle: nil, threshold: 75, hotkey: false)),
            ("Countdown", HeaderState(mode: .countdown(remaining: 2.4, duration: 5), angle: 61, threshold: 75, hotkey: true)),
            ("Active · grace", HeaderState(mode: .active(since: now.addingTimeInterval(-18), grace: 42, locked: false, panicking: false), angle: 58, threshold: 75, hotkey: true)),
            ("Active · locked", HeaderState(mode: .active(since: now.addingTimeInterval(-745), grace: nil, locked: true, panicking: false), angle: 57, threshold: 75, hotkey: true)),
            ("Panic", HeaderState(mode: .active(since: now.addingTimeInterval(-900), grace: nil, locked: true, panicking: true), angle: 31, threshold: 75, hotkey: true)),
        ]
        ZStack {
            SnapshotBackdrop()
            LazyVGrid(columns: [GridItem(.fixed(MB.width), spacing: 24), GridItem(.fixed(MB.width))], spacing: 22) {
                ForEach(states, id: \.0) { _, s in
                    MenuBarHeaderView(state: s) { _ in }
                        .frame(width: MB.width)
                        .clipShape(RoundedRectangle(cornerRadius: MB.radius, style: .continuous))
                        .mbGlass(in: RoundedRectangle(cornerRadius: MB.radius, style: .continuous))
                }
            }
        }
    }
}

/// Status item glyph states on light + dark menu bars, at 1× and 4×.
private struct IconGallery: View {
    var body: some View {
        let glyphs: [(String, MenuBarGlyph)] = [
            ("idle 112°", MenuBarGlyph(lid: 112)),
            ("idle 80°", MenuBarGlyph(lid: 80)),
            ("countdown", MenuBarGlyph(lid: 40, path: 1, pathFrom: 62)),
            ("active", MenuBarGlyph(lid: MenuBarGlyph.closedLid, sparkle: 1)),
            ("paused", MenuBarGlyph(lid: 108, pause: 1)),
            ("needs you", MenuBarGlyph(lid: 108, badge: 1)),
            ("active + needs", MenuBarGlyph(lid: MenuBarGlyph.closedLid, sparkle: 1, badge: 1)),
            ("panic", MenuBarGlyph(lid: 30, alert: 1)),
        ]
        VStack(spacing: 0) {
            ForEach([true, false], id: \.self) { darkBar in
                VStack(spacing: 10) {
                    HStack(spacing: 18) {
                        ForEach(glyphs, id: \.0) { _, g in
                            MenuBarIcon(glyph: g).frame(width: 30, height: 22)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .background(darkBar ? Color(white: 0.12) : Color(white: 0.93))
                    HStack(spacing: 10) {
                        ForEach(glyphs, id: \.0) { name, g in
                            VStack(spacing: 4) {
                                MenuBarIcon(glyph: g, scale: 2.4)
                                Text(name).font(Theme.allo(9.5, .medium)).foregroundStyle(darkBar ? Color.white.opacity(0.6) : Color.black.opacity(0.55))
                            }
                            .frame(width: 58)
                        }
                    }
                }
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(darkBar ? Color(white: 0.06) : Color(white: 0.985))
                .environment(\.colorScheme, darkBar ? .dark : .light)
            }
        }
    }
}
