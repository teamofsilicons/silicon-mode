import Foundation
import AppKit
import SiliconModeKit

/// Test hooks so Silicon Mode can be exercised without physically tilting the lid.
///
/// Launch arguments:  --simulate-angle 60   --enter   --face orbit   --onboarding
/// At runtime (any shell):
///   (agent hooks call ~/.silicon-mode/bin/silicon-mode-hook); for debugging use scripts/smctl or
///   distributed notifications:
///   swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("ai.tos.mode.debug"), object: "angle=60", deliverImmediately: true)'
/// Commands (object string): angle=<deg> | angle=off | enter | cancel | turnoff | unlock=<pin> | face=<id> |
/// unlockui | setpin=<pin> | stats | menubar | onboarding | settings | setting=<key>:<json> | refresh | dump
/// `dump` writes the current state to ~/Library/Application Support/Silicon Mode/debug-state.json.
@MainActor
enum DebugCommands {
    static let notification = Notification.Name("ai.tos.mode.debug")

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
        case "answer":
            // answer=<optionID>[|free text] → first pending answerable question (as the menu bar would)
            let parts = val.split(separator: "|", maxSplits: 1).map(String.init)
            if let q = m.pendingQuestions.first(where: { $0.answerable }) {
                m.answer(q, optionIDs: parts.first.map { [$0] } ?? [], text: parts.count > 1 ? parts[1] : nil, source: .menuBar)
            }
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

    static func dump() {
        let m = AppModel.shared
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
            "pendingQuestions": m.pendingQuestions.map { ["id": $0.id, "provider": $0.provider, "title": $0.title, "answerable": $0.answerable] },
        ]
        let url = HookWire.supportDirectory.appendingPathComponent("debug-state.json")
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }
}

/// Demo agents for live QA (`demo=…`). Made-up titles and text only.
enum DebugDemo {
    static func sessions(_ kind: String) -> [AgentSession] {
        let now = Date()
        let events = [
            AgentEvent(id: "demo.1", at: now.addingTimeInterval(-40), kind: .user, text: "You: tidy up the settings keys"),
            AgentEvent(id: "demo.2", at: now.addingTimeInterval(-30), kind: .tool, text: "Read Sources/Settings/Keys.swift"),
            AgentEvent(id: "demo.3", at: now.addingTimeInterval(-20), kind: .assistant, text: "Said: Two names would work here."),
        ]
        switch kind {
        case "question":
            let q = AgentQuestion(id: "demo-q1", sessionID: "claude-code:demo-qa", provider: "claude-code", kind: .question,
                                  title: "Which name should the new key use?",
                                  detail: "The old key stays readable for one release either way.",
                                  options: [.init(id: "a", label: "touchIDFirst", detail: "Matches the toggle's wording"),
                                            .init(id: "b", label: "preferTouchID", detail: "Keeps the old name")],
                                  allowsFreeText: true, createdAt: now)
            return [AgentSession(provider: "claude-code", nativeID: "demo-qa", title: "Demo: rename the settings keys",
                                 state: .needsYou, startedAt: now.addingTimeInterval(-60), updatedAt: now,
                                 recentEvents: events, pendingQuestions: [q])]
        case "permission":
            let q = AgentQuestion(id: "demo-p1", sessionID: "codex:demo-qa", provider: "codex", kind: .permission,
                                  title: "Run command", detail: "swift test --filter Settings",
                                  options: [.init(id: "allow", label: "Allow", style: .primary),
                                            .init(id: "always", label: "Always allow"),
                                            .init(id: "deny", label: "Deny", style: .destructive)],
                                  createdAt: now)
            return [AgentSession(provider: "codex", nativeID: "demo-qa", title: "Demo: run the settings tests",
                                 state: .needsYou, startedAt: now.addingTimeInterval(-90), updatedAt: now,
                                 recentEvents: events, pendingQuestions: [q])]
        default:
            return []
        }
    }
}
