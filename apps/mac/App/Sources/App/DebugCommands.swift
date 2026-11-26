import Foundation
import AppKit
import SiliconModeKit

/// Test hooks so Silicon Mode can be exercised without physically tilting the lid.
///
/// Launch arguments:  --simulate-angle 60   --enter   --face orbit   --onboarding
/// At runtime (any shell):
///   ~/Library/Application\ Support/Silicon\ Mode/bin/silicon-mode-hook is the agent hook; for
///   debugging use distributed notifications:
///   swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("ai.tos.mode.debug"), object: "angle=60", deliverImmediately: true)'
/// Commands (object string): angle=<deg> | angle=off | enter | cancel | turnoff | unlock=<pin> | face=<id> | dump
/// `dump` writes the current state to ~/Library/Application Support/Silicon Mode/debug-state.json.
@MainActor
enum DebugCommands {
    static let notification = Notification.Name("ai.tos.mode.debug")

    static func handleLaunchArguments() {
        let args = CommandLine.arguments
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
        ]
        let url = HookWire.supportDirectory.appendingPathComponent("debug-state.json")
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }
}
