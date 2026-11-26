import SwiftUI
import SiliconModeKit

/// Snapshot-harness entries for this module (see App/SnapshotHarness.swift).
///
/// Each id pins its own moment (`-t<seconds>`) unless `--time` is passed, so
/// `--snapshot chomp-sample-t6 /tmp/x.png` is reproducible.
@MainActor
enum FaceSnapshotsB {
    static var items: [SnapshotItem] {
        var out: [SnapshotItem] = []
        // Chomp
        for t in [0.6, 3.0, 7.5] {
            out.append(item("chomp-sample-t\(fmt(t))", time: t) { face(ChompFace.descriptor, FaceBSamples.sample) })
        }
        for t in [2.0, 9.0] {
            out.append(item("chomp-busy-t\(fmt(t))", time: t) { face(ChompFace.descriptor, FaceBSamples.busy) })
        }
        out.append(item("chomp-one-t4", time: 4) { face(ChompFace.descriptor, [FaceBSamples.working(0)]) })
        out.append(item("chomp-empty-t3", time: 3) { face(ChompFace.descriptor, []) })
        out.append(item("chomp-mint-t5", time: 5) {
            face(ChompFace.descriptor, FaceBSamples.sample, options: ["character": .string("mint"), "speed": .number(1.5)])
        })
        out.append(item("chomp-panic-t2", time: 2) { face(ChompFace.descriptor, FaceBSamples.sample, panic: true) })
        out.append(item("chomp-preview", size: CGSize(width: 320, height: 200), time: 3) {
            face(ChompFace.descriptor, FaceBSamples.sample, preview: true)
        })
        out.append(item("chomp-preview-empty", size: CGSize(width: 320, height: 200), time: 3) {
            face(ChompFace.descriptor, [], preview: true)
        })
        out.append(item("chomp-external-t5", size: CGSize(width: 1920, height: 1080), time: 5) {
            face(ChompFace.descriptor, FaceBSamples.busy)
        })

        // Desk
        let desk = DeskFace.descriptor
        for t in [1.0, 4.0] {
            out.append(item("desk-sample-t\(fmt(t))", time: t) { face(desk, FaceBSamples.sample) })
        }
        out.append(item("desk-typing-t9", time: 9) { face(desk, [FaceBSamples.working(0), FaceBSamples.working(1), FaceBSamples.working(2)]) })
        out.append(item("desk-one-t9", time: 9) { face(desk, [FaceBSamples.working(0)]) })
        out.append(item("desk-celebrate-t1.4", time: 1.4) { face(desk, [FaceBSamples.working(1), SampleAgents.sessions[2]]) })
        for t in [3.0, 7.5, 16.5] {
            out.append(item("desk-chill-t\(fmt(t))", time: t) { face(desk, [FaceBSamples.busy[3]]) })
        }
        out.append(item("desk-empty-t4", time: 4) { face(desk, []) })
        out.append(item("desk-busy-t9", time: 9) { face(desk, FaceBSamples.busy) })
        out.append(item("desk-crowd-t9", time: 9) { face(desk, FaceBSamples.crowd) })
        out.append(item("desk-dusk-t5", time: 5) {
            face(desk, FaceBSamples.sample, options: ["room": .string("dusk"), "mascot": .string("peach")])
        })
        out.append(item("desk-studio-noon", time: 12 * 3600 + 9) {
            face(desk, [FaceBSamples.working(0), FaceBSamples.working(3)], options: ["room": .string("studio"), "mascot": .string("blue")])
        })
        out.append(item("desk-dawn", time: 6.4 * 3600) { face(desk, [FaceBSamples.working(1)], options: ["mascot": .string("mint")]) })
        out.append(item("desk-golden", time: 18.2 * 3600) { face(desk, [FaceBSamples.working(2)], options: ["room": .string("dusk")]) })
        out.append(item("desk-notext-t9", time: 9) {
            face(desk, [FaceBSamples.working(0), FaceBSamples.working(1)], options: ["monitorText": .bool(false)], clock: false)
        })
        out.append(item("desk-panic-t2", time: 2) { face(desk, FaceBSamples.sample, panic: true) })
        out.append(item("desk-preview", size: CGSize(width: 320, height: 200), time: 3) { face(desk, FaceBSamples.sample, preview: true) })
        out.append(item("desk-preview-empty", size: CGSize(width: 320, height: 200), time: 3) { face(desk, [], preview: true) })
        out.append(item("desk-external-t9", size: CGSize(width: 1920, height: 1080), time: 9) { face(desk, FaceBSamples.busy) })
        return out
    }

    // MARK: Helpers

    private static func fmt(_ t: Double) -> String {
        t == t.rounded() ? String(Int(t)) : String(t)
    }

    static func item(_ id: String, size: CGSize = CGSize(width: 1512, height: 982), time: Double,
                     _ make: @escaping @MainActor () -> AnyView) -> SnapshotItem {
        SnapshotItem(id: id, size: size, dark: true) {
            if SnapshotHarness.time == nil { SnapshotHarness.time = time }
            return make()
        }
    }

    static func face(_ d: FaceDescriptor, _ sessions: [AgentSession], options: [String: FaceOptionValue] = [:],
                     preview: Bool = false, panic: Bool = false, clock: Bool = true) -> AnyView {
        let ctx = FaceContext(sessions: sessions, counts: AgentCounts(sessions), options: d.resolvedOptions(options),
                              showClock: clock, isPreview: preview, isPanicking: panic)
        return d.make(ctx)
    }
}

/// Richer demo sessions for these faces' snapshots.
enum FaceBSamples {
    static let sample = SampleAgents.sessions

    private static func ev(_ t: String, _ k: AgentEvent.Kind, _ ago: Double, _ seed: String) -> AgentEvent {
        AgentEvent(id: "\(seed)-\(t.hashValue)-\(ago)", at: Date().addingTimeInterval(-ago), kind: k, text: t)
    }

    static func working(_ i: Int) -> AgentSession {
        let specs: [(String, String, String, [(String, AgentEvent.Kind)])] = [
            ("claude-code", "Ship the onboarding flow", "/Users/you/code/app", [
                ("Read Sources/Onboarding/PinPad.swift", .tool), ("Edited Sources/Onboarding/PinPad.swift", .tool),
                ("Thinking about the lockout timer", .thinking), ("Ran: swift test --filter Pin", .tool),
                ("Edited Sources/Onboarding/Flow.swift", .tool), ("Tests pass, wiring Touch ID next", .assistant),
            ]),
            ("codex", "Speed up image pipeline", "/Users/you/code/media", [
                ("Ran: cargo bench resize", .tool), ("Read src/resize/simd.rs", .tool), ("Edited src/resize/simd.rs", .tool),
                ("Ran: cargo test resize", .tool), ("2.3× faster on 4K frames", .assistant),
            ]),
            ("pi", "Draft the launch post", "/Users/you/writing", [
                ("Read notes/launch.md", .tool), ("Wrote drafts/launch-v2.md", .tool), ("Tightened the intro", .assistant),
            ]),
            ("opencode", "Migrate settings to v2", "/Users/you/code/api", [
                ("Read config/settings.ts", .tool), ("Ran: pnpm typecheck", .tool), ("Edited config/settings.ts", .tool),
                ("Ran: pnpm test settings", .tool),
            ]),
        ]
        let s = specs[i % specs.count]
        let now = Date()
        let events = s.3.enumerated().map { j, e in ev(e.0, e.1, Double((s.3.count - j) * 9), "\(s.0)\(i)") }
        return AgentSession(provider: s.0, nativeID: "fb-\(i)", title: s.1, cwd: s.2, state: .working,
                            startedAt: now.addingTimeInterval(-Double(3000 - i * 300)), updatedAt: now, recentEvents: events)
    }

    /// Five agents: three working, one idle, one errored.
    static let busy: [AgentSession] = {
        let now = Date()
        var out = [working(0), working(1), working(3)]
        out.append(AgentSession(provider: "pi", nativeID: "fb-idle", title: "Tidy the docs folder", cwd: "/Users/you/code/docs",
                                state: .idle, startedAt: now.addingTimeInterval(-5000), updatedAt: now.addingTimeInterval(-900),
                                recentEvents: [ev("Moved 12 files into guides/", .tool, 950, "idle"), ev("Waiting for next task", .status, 900, "idle")]))
        out.append(AgentSession(provider: "codex", nativeID: "fb-err", title: "Bump Postgres driver", cwd: "/Users/you/code/db",
                                state: .error, startedAt: now.addingTimeInterval(-2000), updatedAt: now.addingTimeInterval(-60),
                                recentEvents: [ev("Ran: go test ./...", .tool, 80, "err"), ev("Build failed: undefined pgx.Conn", .error, 60, "err")]))
        return out
    }()

    /// Eight agents: more than the desk has monitors, so the last one stacks tabs.
    static let crowd: [AgentSession] = {
        var out = busy + [working(2)]
        out.append(contentsOf: SampleAgents.sessions.prefix(2).map { s in
            var c = s
            c.id = "crowd-" + s.id
            return c
        })
        return out
    }()
}
