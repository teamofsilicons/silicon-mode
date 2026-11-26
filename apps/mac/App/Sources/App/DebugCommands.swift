import Foundation
import AppKit
import SiliconModeKit

/// Test hooks so Silicon Mode can be exercised without physically tilting the lid. Debug builds, or a
/// Release build launched with --debug-control.
///
/// Launch arguments:  --simulate-angle 60   --enter   --face orbit   --onboarding
/// At runtime (any shell):
///   (agent hooks call ~/.silicon-mode/bin/silicon-mode-hook); for debugging use scripts/smctl or
///   distributed notifications:
///   swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("ai.tos.mode.debug"), object: "angle=60", deliverImmediately: true)'
/// Commands (object string):
///   angle=<deg> | angle=off | enter | cancel | turnoff | unlock=<pin> | unlockui | setpin=<pin> | face=<id>
///   stats | menubar | onboarding | onboarding-close | settings | setting=<key>:<json> | refresh | dump
///   type=<digits, < for delete, ! for escape> | signin | signin-headless | signout | quit-unlocked
///   demo=question | demo=permission | demo=off
///       A made-up Claude Code agent waiting on a question (demo-q1) or a command permission
///       (demo-p1). UI only: shown in the overlay, faces and menu bar, never counted by the mode
///       engine (auto-entry, panic), the usage history or cloud sync. Its question sorts first.
///       Answered, it carries on working until demo=off.
///   answer=<optionID>[|text]
///       While a demo agent is shown: its question (never a real agent's). Otherwise the oldest
///       answerable question (the first card in the overlay), as the menu bar would.
///       `answer=|text` sends a reply only.
///   answer=<questionID>:<optionID>[|text]
///       Answers that question. An option the question doesn't offer is refused, never sent.
/// Every command then writes the state to ~/Library/Application Support/Silicon Mode/debug-state.json
/// (`dump` only writes it); `lastAnswer` there says what the last `answer=` did.
@MainActor
enum DebugCommands {
    static let notification = Notification.Name("ai.tos.mode.debug")
    /// What the last `answer=` did (for the state dump).
    private static var lastAnswer: String?

    static func handleLaunchArguments() {
        let args = CommandLine.arguments
        // The control channel can change the PIN and drive the lock, so it only exists in Debug
        // builds, or in a Release build explicitly launched with --debug-control (for QA).
        #if DEBUG
        let controlEnabled = true
        #else
        let controlEnabled = args.contains("--debug-control")
        #endif
        guard controlEnabled else { return }
        if let i = args.firstIndex(of: "--simulate-angle"), i + 1 < args.count, let a = Double(args[i + 1]) {
            AppModel.shared.simulatedAngle = a
        }
        if let i = args.firstIndex(of: "--face"), i + 1 < args.count {
            AppModel.shared.settings.faceID = args[i + 1]
        }
        if args.contains("--enter") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { AppModel.shared.enterNow() }
        }
        DistributedNotificationCenter.default().addObserver(forName: notification, object: nil, queue: .main) { note in
            let cmd = note.object as? String ?? ""
            MainActor.assumeIsolated { run(cmd) }
        }
    }

    static func run(_ cmd: String) {
        let m = AppModel.shared
        let parts = cmd.split(separator: "=", maxSplits: 1).map(String.init)
        let key = parts.first ?? ""
        let val = parts.count > 1 ? parts[1] : ""
        switch key {
        case "angle": m.simulatedAngle = val == "off" ? nil : Double(val)
        case "enter": m.enterNow()
        case "cancel": m.cancelCountdown()
        case "turnoff": m.turnOff()
        case "unlock": _ = m.unlock(pin: val)
        case "face": m.settings.faceID = val
        case "unlockui": m.unlockPresented = true
        case "quit-unlocked": if !m.isActive { NSApp.terminate(nil) }
        case "setpin": try? m.pinVault.set(pin: val)
        case "stats": StatsWindow.present()
        case "menubar": MenuBarController.shared.toggle()
        case "onboarding": OnboardingPresenter.present()
        case "onboarding-close": OnboardingPresenter.close()
        case "settings":
            NSApp.activate(ignoringOtherApps: true)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        case "setting":
            // setting=<key>:<json value>, e.g. setting=countdownSeconds:3
            let kv = val.split(separator: ":", maxSplits: 1).map(String.init)
            if kv.count == 2, var dict = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(m.settings))) as? [String: Any],
               let v = try? JSONSerialization.jsonObject(with: Data(kv[1].utf8), options: .fragmentsAllowed) {
                dict[kv[0]] = v
                if let d = try? JSONSerialization.data(withJSONObject: dict),
                   let s = try? JSONDecoder().decode(ModeSettings.self, from: d) { m.settings = s }
            }
        case "refresh": Task { await m.refreshAgents() }
        case "demo": m.setDebugDemo(val)
        case "type":
            // Inject key presses through the app's own event path (same as a real keyboard).
            let codes: [Character: UInt16] = ["0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25]
            var delay = 0.0
            for ch in val {
                let code = ch == "<" ? UInt16(51) : (ch == "!" ? UInt16(53) : codes[ch] ?? 0)
                let chars = ch == "<" ? "\u{7f}" : (ch == "!" ? "\u{1b}" : String(ch))
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard let w = NSApp.keyWindow else { return }
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: w.windowNumber, context: nil, characters: chars,
                                                    charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                            NSApp.sendEvent(e)
                        }
                    }
                }
                delay += 0.18
            }
        case "answer": answer(val)
        case "signin": m.account.signIn()
        case "signin-headless":
            // Start a real sign-in (loopback listener) without opening a browser tab; a test
            // client then completes it through the loopback page, exactly like the browser does.
            m.account.openURL = { _ in }
            m.account.signIn()
        case "signout": m.account.signOut()
        default: break
        }
        dump()
    }

    /// `answer=<optionID>[|text]` or `answer=<questionID>:<optionID>[|text]` (see the header).
    /// Question ids contain colons themselves, so the second form is recognised by the id of a
    /// question that is shown and answerable, followed by ":".
    private static func answer(_ spec: String) {
        let m = AppModel.shared
        let parts = spec.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let head = parts.first ?? ""
        let text = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        let open = m.pendingQuestions.filter(\.answerable)
        let question: AgentQuestion?
        let optionID: String
        if let q = open.filter({ head.hasPrefix($0.id + ":") }).max(by: { $0.id.count < $1.id.count }) {
            question = q
            optionID = String(head.dropFirst(q.id.count + 1))
        } else if !m.debugDemoSessions.isEmpty {
            // While a demo agent is shown, the short form only ever reaches its question: answering
            // twice must not fall through to a real agent's prompt.
            question = open.first { m.isDebugDemo($0) }
            optionID = head
        } else {
            question = open.first
            optionID = head
        }
        guard let q = question else { lastAnswer = "nothing to answer"; return }
        if !optionID.isEmpty, !q.options.contains(where: { $0.id == optionID }) {
            lastAnswer = "refused: \(q.id) has no option \"\(optionID)\""
            return
        }
        guard !optionID.isEmpty || text != nil else { lastAnswer = "refused: no option or text"; return }
        m.answer(q, optionIDs: optionID.isEmpty ? [] : [optionID], text: text, source: .menuBar)
        lastAnswer = "answered \(q.id)" + (optionID.isEmpty ? "" : " with \(optionID)") + (text == nil ? "" : " and a reply")
    }

    static func dump() {
        let m = AppModel.shared
        // Exactly what cloud sync reads from the app.
        let sync = AppModelSyncHost(model: m).syncLocalState()
        let state: [String: Any] = [
            "phase": String(describing: m.phase),
            "armed": m.armed,
            "angle": m.angle as Any,
            "sensor": String(describing: m.sensorAvailability),
            "countdown": m.countdownRemaining as Any,
            "grace": m.graceRemaining as Any,
            "locked": m.isLocked,
            "panic": m.isPanicking,
            "agents": m.sessions.map { ["id": $0.id, "state": $0.state.rawValue, "title": $0.title,
                                        "events": $0.recentEvents.count, "questions": $0.pendingQuestions.count] },
            "counts": ["needsYou": m.counts.needsYou, "working": m.counts.working, "finished": m.counts.finished, "idle": m.counts.idle],
            "face": m.settings.faceID,
            "pinSet": m.pinVault.isSet,
            "signedIn": m.account.isSignedIn,
            "signInURL": m.account.signInURL?.absoluteString as Any,
            "appActive": NSApp.isActive,
            "kiosk": ["engaged": m.kiosk.engaged, "effective": m.kiosk.isEffective,
                      "options": NSApp.currentSystemPresentationOptions.rawValue],
            "keyWindow": NSApp.keyWindow.map { String(describing: type(of: $0)) } as Any,
            "sync": ["status": String(describing: m.cloud.status), "device": m.cloud.deviceID as Any,
                     "live": m.cloud.realtimeLive, "lastSynced": m.cloud.lastSyncedAt.map { $0.timeIntervalSince1970 } as Any,
                     "account": m.account.account?.id as Any, "state": String(describing: m.account.state)],
            "pendingQuestions": m.pendingQuestions.map { ["id": $0.id, "provider": $0.provider, "title": $0.title, "answerable": $0.answerable,
                                                          "options": $0.options.map(\.id), "demo": m.isDebugDemo($0)] },
            "demoAgents": m.debugDemoSessions.map(\.id),
            "lastAnswer": lastAnswer as Any,
            // What real agents alone feed: the mode engine's count, and what cloud sync reads.
            "realAgents": ["running": m.runningAgents, "sessions": m.hubSnapshot.sessions.count,
                           "syncSessions": sync.sessions.map(\.id), "syncQuestions": sync.pendingQuestions.map(\.id)],
        ]
        let url = HookWire.supportDirectory.appendingPathComponent("debug-state.json")
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }
}

/// Demo agents for live QA (`demo=…`). Made-up titles and text only. Each is shaped like the real
/// prompt it stands for, so its card behaves like one; it is shown only (see `shown`).
enum DebugDemo {
    static let questionID = "demo-q1"
    static let permissionID = "demo-p1"

    static func sessions(_ kind: String, now: Date = Date()) -> [AgentSession] {
        let events = [
            AgentEvent(id: "demo.1", at: now.addingTimeInterval(-40), kind: .user, text: "You: tidy up the settings keys"),
            AgentEvent(id: "demo.2", at: now.addingTimeInterval(-30), kind: .tool, text: "Read Sources/Settings/Keys.swift"),
            AgentEvent(id: "demo.3", at: now.addingTimeInterval(-20), kind: .assistant, text: "Said: Two names would work here."),
        ]
        switch kind {
        case "question":
            // A held Claude Code AskUserQuestion (HookQuestions): the header is the title, the question
            // the detail; options o0, o1… with the first one primary; a reply field.
            let q = AgentQuestion(id: questionID, sessionID: "claude-code:demo-question", provider: "claude-code", kind: .question,
                                  title: "Key name",
                                  detail: "Which name should the new settings key use? The old key stays readable for one release either way.",
                                  options: [.init(id: "o0", label: "touchIDFirst", detail: "Matches the toggle's wording", style: .primary),
                                            .init(id: "o1", label: "preferTouchID", detail: "Keeps the old name")],
                                  allowsFreeText: true, createdAt: now)
            return [AgentSession(provider: "claude-code", nativeID: "demo-question", title: "Demo: rename the settings keys",
                                 cwd: "/tmp/silicon-demo", state: .needsYou, startedAt: now.addingTimeInterval(-60), updatedAt: now,
                                 recentEvents: events, pendingQuestions: [q])]
        case "permission":
            // A held Claude Code Bash permission: the real option ids (allow, allow_always, deny).
            let q = AgentQuestion(id: permissionID, sessionID: "claude-code:demo-permission", provider: "claude-code", kind: .permission,
                                  title: "Run a command", detail: "swift test --filter Settings",
                                  options: AgentQuestion.permissionOptions(), createdAt: now)
            return [AgentSession(provider: "claude-code", nativeID: "demo-permission", title: "Demo: run the settings tests",
                                 cwd: "/tmp/silicon-demo", state: .needsYou, startedAt: now.addingTimeInterval(-90), updatedAt: now,
                                 recentEvents: events, pendingQuestions: [q])]
        default:
            return []
        }
    }

    /// `session` after `question` was answered: the question gone, the answer in its log and, with
    /// nothing else pending, working again.
    static func answered(_ session: AgentSession, _ question: AgentQuestion, optionIDs: [String], text: String?) -> AgentSession {
        guard session.id == question.sessionID, session.pendingQuestions.contains(where: { $0.id == question.id }) else { return session }
        var s = session
        let now = Date()
        let picked = question.options.filter { optionIDs.contains($0.id) }.map(\.label)
        let reply = (picked + [text].compactMap { $0 }).joined(separator: " · ")
        s.pendingQuestions.removeAll { $0.id == question.id }
        s.recentEvents.append(AgentEvent(id: "demo.answer.\(question.id)", at: now, kind: .user, text: "You: " + reply))
        if s.pendingQuestions.isEmpty { s.state = .working }
        s.updatedAt = now
        return s
    }

    /// What the UI shows: the hub's snapshot plus the demo agents, in the hub's order. Demo questions
    /// are dated just before the oldest real one, so they come first wherever questions are listed
    /// oldest first (overlay cards, menu bar) and a bare `answer=` reaches them, never a held real
    /// prompt.
    static func shown(_ hub: AgentHub.Snapshot, demo: [AgentSession]) -> AgentHub.Snapshot {
        guard !demo.isEmpty else { return hub }
        guard let oldest = hub.pendingQuestions.first?.createdAt else { return hub.adding(demo) }
        return hub.adding(demo.map { s in
            var s = s
            s.pendingQuestions = s.pendingQuestions.map { q in
                var q = q
                if q.createdAt >= oldest { q.createdAt = oldest.addingTimeInterval(-1) }
                return q
            }
            return s
        })
    }
}
