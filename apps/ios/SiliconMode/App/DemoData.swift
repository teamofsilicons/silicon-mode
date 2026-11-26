import Foundation
import SwiftUI

/// Offline sample data (`-SMDemo YES`): two Macs, agents, a tail, questions and six months of
/// usage. Used for design iteration and screenshots without touching the backend.
@MainActor
enum DemoData {
    static let macA = "d0000000-0000-4000-8000-00000000000a"
    static let macB = "d0000000-0000-4000-8000-00000000000b"

    static func load(into store: AppStore) {
        let now = Date()
        store.isDemo = true
        store.user = CellUser(uuid: "00000000-0000-4000-8000-000000000001", id: "c:ada", kind: "carbon", displayName: "Ada Lovelace",
                              pfpUrl: nil, app: "silicon-mode", timezone: TimeZone.current.identifier, custodian: nil)
        let mode = UserDefaults.standard.string(forKey: "SMMode") ?? "active"
        store.macs = [
            Device(id: macA, kind: "mac", name: "MacBook Pro", model: "MacBookPro18,1", createdAt: now.addingTimeInterval(-86400 * 90),
                   lastSeenAt: now, status: DeviceStatus(deviceId: macA, mode: mode, modeSince: now.addingTimeInterval(-38 * 60 - 12),
                                                         lidAngle: mode == "panic" ? 41 : (mode == "off" ? 112 : 61.5), siliconAngle: mode == "off" ? nil : 62,
                                                         caffeinated: mode != "off", face: "orbit", agentsWorking: 2, agentsWaiting: 1,
                                                         agentsFinished: 1, questionsPending: 2, online: true, updatedAt: now)),
            Device(id: macB, kind: "mac", name: "Studio", model: "Mac14,13", createdAt: now.addingTimeInterval(-86400 * 30),
                   lastSeenAt: now.addingTimeInterval(-40), status: DeviceStatus(deviceId: macB, mode: "off", modeSince: now.addingTimeInterval(-3 * 3600),
                                                                                  lidAngle: 108, siliconAngle: nil, caffeinated: false, face: "bounce",
                                                                                  agentsWorking: 1, agentsWaiting: 0, agentsFinished: 1, questionsPending: 0,
                                                                                  online: true, updatedAt: now)),
        ]
        store.hasLoadedMacs = true
        if UserDefaults.standard.bool(forKey: "SMNoMacs") {   // first run: nothing connected yet
            store.macs = []
            store.realtimeStatus = .live
            store.auth = .signedIn
            return
        }
        if store.selectedMacID == nil || !store.macs.contains(where: { $0.id == store.selectedMacID }) {
            store.select(store.macs[0])
        }
        fill(store)
        store.usage = usage(now: now)
        store.usageLoadedAt = now
        store.realtimeStatus = .live
        store.auth = UserDefaults.standard.bool(forKey: "SMSignedOut") ? .signedOut : .signedIn
        if UserDefaults.standard.bool(forKey: "SMLive") { store.startDemoTicker() }
    }

    static func selectionChanged(_ store: AppStore) { fill(store) }

    private static func fill(_ store: AppStore) {
        let now = Date()
        let mac = store.selectedMac?.id ?? macA
        func s(_ id: String, _ p: String, _ title: String, _ project: String, _ model: String, _ state: String, _ mins: Double, _ last: Double) -> AgentSessionRow {
            AgentSessionRow(id: id, deviceId: mac, provider: p, providerSessionId: id, title: title, cwd: "~/code/\(project)", project: project,
                            model: model, state: state, waitingReason: state == "waiting" ? "permission" : nil,
                            startedAt: now.addingTimeInterval(-mins * 60), lastEventAt: now.addingTimeInterval(-last),
                            endedAt: state == "finished" ? now.addingTimeInterval(-180) : nil, updatedAt: now)
        }
        if mac == macA {
            store.sessions = [
                s("s1", "claude-code", "Refactor sync engine to batch pushes", "silicon-mode", "claude-opus-5", "waiting", 46, 20),
                s("s2", "codex", "Fix flaky heatmap snapshot test", "silicon-mode", "gpt-6-codex", "working", 23, 8),
                s("s3", "claude-code", "Write onboarding copy", "silicon-accounts", "claude-sonnet-5", "working", 12, 30),
                s("s4", "opencode", "Migrate Android theme to Compose tokens", "silicon-ring", "kimi-k3", "finished", 95, 200),
            ]
            let lines: [(String, String, String)] = [
                ("s1", "question", "Allow Bash: git push origin sync-batching?"),
                ("s1", "tool_result", "BUILD SUCCEEDED"),
                ("s1", "tool_call", "Bash: xcodebuild -scheme SiliconMode build"),
                ("s2", "assistant", "The failure is a DST edge: 02:30 doesn't exist on Mar 8. Keying buckets by hour_start instants instead."),
                ("s1", "tool_call", "Edit CloudSync.swift (+84 −12)"),
                ("s4", "status", "Finished · 14 files changed"),
                ("s3", "assistant", "Drafted three variants for the first-run screen."),
                ("s2", "tool_result", "Test run: 41 passed, 1 failed (HeatmapTests.testDST)"),
                ("s2", "tool_call", "Bash: swift test --filter HeatmapTests"),
                ("s1", "tool_call", "Read apps/mac/App/Sources/Sync/CloudSync.swift"),
                ("s1", "user", "Batch the pushes and debounce new questions to 300 ms"),
            ]
            store.events = lines.enumerated().map { i, l in
                EventRow(id: Int64(1000 - i), deviceId: mac, sessionId: l.0, seq: Int64(100 - i), at: now.addingTimeInterval(-Double(i) * 41 - 15),
                         kind: l.1, summary: l.2)
            }
            store.questions = [
                QuestionRow(id: "q1", deviceId: mac, sessionId: "s1", kind: "permission", title: "Allow Bash: git push origin sync-batching?",
                            body: "git push origin sync-batching\n\nPushes 3 commits to the remote branch sync-batching.",
                            options: [QuestionOption(id: "allow_once", label: "Allow once", role: "allow"),
                                      QuestionOption(id: "allow_always", label: "Always", role: "allow"),
                                      QuestionOption(id: "deny", label: "Deny", role: "deny")],
                            allowText: false, state: "pending", createdAt: now.addingTimeInterval(-95), expiresAt: nil, resolvedAt: nil),
                QuestionRow(id: "q2", deviceId: mac, sessionId: "s2", kind: "question", title: "Which fix should I take for the DST test?",
                            body: nil,
                            options: [QuestionOption(id: "a", label: "Hour instants", role: nil),
                                      QuestionOption(id: "b", label: "Skip missing hours", role: nil)],
                            allowText: true, state: "pending", createdAt: now.addingTimeInterval(-40), expiresAt: nil, resolvedAt: nil),
            ]
            if UserDefaults.standard.bool(forKey: "SMAnswered") {
                store.questionUI["q1"] = .sent(option: "allow_once", text: nil)
                store.questionUI["q2"] = .elsewhere(from: "on the Mac", label: "Hour instants", pendingOnMac: true)
            }
        } else {
            store.sessions = [
                s("t1", "claude-code", "Render the Orbit face at 120 Hz", "silicon-mode", "claude-opus-5", "working", 31, 12),
                s("t2", "hermes", "Nightly dependency audit", "ops", "hermes-4", "finished", 240, 900),
            ]
            store.events = [
                EventRow(id: 2002, deviceId: mac, sessionId: "t1", seq: 3, at: now.addingTimeInterval(-12), kind: "assistant",
                         summary: "Moving the orbit math into a Canvas inside TimelineView(.animation)."),
                EventRow(id: 2001, deviceId: mac, sessionId: "t1", seq: 2, at: now.addingTimeInterval(-70), kind: "tool_call",
                         summary: "Read Faces/OrbitFace.swift"),
                EventRow(id: 2000, deviceId: mac, sessionId: "t2", seq: 9, at: now.addingTimeInterval(-900), kind: "status",
                         summary: "Finished · 3 advisories, none critical"),
            ]
            store.questions = []
        }
    }

    static func tick(_ store: AppStore, _ i: Int) {
        guard store.selectedMac?.id == macA else { return }
        let lines: [(String, String, String)] = [
            ("s2", "tool_call", "Bash: swift test --filter HeatmapTests"),
            ("s2", "tool_result", "Test run: 42 passed"),
            ("s3", "assistant", "Tightened the headline to six words."),
            ("s1", "tool_call", "Read apps/mac/App/Sources/App/AppModel.swift"),
        ]
        let l = lines[i % lines.count]
        let e = EventRow(id: Int64(5000 + i), deviceId: macA, sessionId: l.0, seq: Int64(500 + i), at: Date(), kind: l.1, summary: l.2)
        withAnimationSlow { store.events.insert(e, at: 0) }
        if var st = store.macs.first?.status {
            st.lidAngle = 58 + Double(i % 5)
            withAnimationSlow { store.macs[0].status = st }
        }
    }

    private static func withAnimationSlow(_ body: () -> Void) {
        withAnimation(Theme.Motion.slow, body)
    }

    /// Evening-heavy agent use with a late-morning bump, some skipped (mostly weekend) days.
    static func usage(now: Date) -> [UsageRow] {
        var out: [UsageRow] = []
        var seed: UInt64 = 7
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let nowHour = cal.component(.hour, from: now)
        for i in 0..<182 {
            let day = cal.date(byAdding: .day, value: -(181 - i), to: today)!
            let weekend = cal.isDateInWeekend(day)
            if rnd() < (weekend ? 0.3 : 0.08), i < 181 { continue }
            for h in 0..<24 {
                if i == 181, h > nowHour { break }
                var v = exp(-pow(Double(h) - 22.5, 2) / 9) + 0.75 * exp(-pow(Double(h) - 11, 2) / 7) + 0.35 * exp(-pow(Double(h) - 16, 2) / 5)
                v *= (0.45 + rnd()) * (weekend ? 0.6 : 1)
                guard v > 0.22 else { continue }
                let secs = min(4, v * 2.4) * 3600
                out.append(UsageRow(deviceId: rnd() < 0.8 ? macA : macB, localDate: StatsModel.dayKey(day), localHour: h, agentSeconds: secs,
                                    maxConcurrent: max(1, Int(1 + v * 2.2)), sessionsStarted: Int(v * 2),
                                    siliconModeSeconds: (h >= 23 || h <= 1) ? 1800 : 0,
                                    byProvider: ["claude-code": secs * 0.55, "codex": secs * 0.27, "opencode": secs * 0.12, "pi": secs * 0.06]))
            }
        }
        return out
    }
}
