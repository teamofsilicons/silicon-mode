import SwiftUI
import SiliconModeKit

/// What a face gets to draw with.
struct FaceContext {
    var sessions: [AgentSession]
    var counts: AgentCounts
    /// Resolved options (user values over the face's defaults).
    var options: [String: FaceOptionValue]
    var showClock: Bool
    /// Small thumbnail in Settings: keep it cheap and legible.
    var isPreview: Bool
    var isPanicking: Bool
    /// Seconds between animation frames for full-screen faces (settings.faceFrameRate).
    var frameInterval: Double = 1.0 / 30

    func bool(_ key: String, _ fallback: Bool = false) -> Bool { options[key]?.bool ?? fallback }
    func number(_ key: String, _ fallback: Double = 0) -> Double { options[key]?.number ?? fallback }
    func string(_ key: String, _ fallback: String = "") -> String { options[key]?.string ?? fallback }

    static let sample = FaceContext(sessions: SampleAgents.sessions, counts: AgentCounts(SampleAgents.sessions),
                                    options: [:], showClock: true, isPreview: true, isPanicking: false)
}

/// A user-tweakable face option, rendered automatically in Settings.
struct FaceOptionSpec: Identifiable {
    enum Kind {
        case toggle(default: Bool)
        case slider(min: Double, max: Double, step: Double, default: Double)
        case choice(options: [(id: String, label: String)], default: String)
    }
    let key: String
    let label: String
    let kind: Kind
    var id: String { key }

    var defaultValue: FaceOptionValue {
        switch kind {
        case .toggle(let d): .bool(d)
        case .slider(_, _, _, let d): .number(d)
        case .choice(_, let d): .string(d)
        }
    }
}

struct FaceDescriptor: Identifiable {
    let id: String
    let name: String
    let summary: String
    let options: [FaceOptionSpec]
    let make: @MainActor (FaceContext) -> AnyView

    func resolvedOptions(_ user: [String: FaceOptionValue]?) -> [String: FaceOptionValue] {
        var o: [String: FaceOptionValue] = [:]
        for spec in options { o[spec.key] = spec.defaultValue }
        for (k, v) in user ?? [:] { o[k] = v }
        return o
    }
}

enum FaceRegistry {
    static let all: [FaceDescriptor] = [
        BounceFace.descriptor,
        OrbitFace.descriptor,
        ChompFace.descriptor,
        ClockFace.descriptor,
        DeskFace.descriptor,
    ]

    static func face(_ id: String) -> FaceDescriptor { all.first { $0.id == id } ?? all[0] }
}

/// Plausible sessions for previews, onboarding, and the "demo" mode.
enum SampleAgents {
    static let sessions: [AgentSession] = {
        let now = Date()
        func ev(_ t: String, _ k: AgentEvent.Kind, _ ago: Double) -> AgentEvent {
            AgentEvent(id: UUID().uuidString, at: now.addingTimeInterval(-ago), kind: k, text: t)
        }
        return [
            AgentSession(provider: "claude-code", nativeID: "demo-1", title: "Refactor auth middleware", cwd: "/Users/you/code/api",
                         state: .working, startedAt: now.addingTimeInterval(-1800), updatedAt: now,
                         recentEvents: [ev("Read src/auth/session.ts", .tool, 40), ev("Edited src/auth/middleware.ts", .tool, 12), ev("Ran: npm test -- auth", .tool, 3)]),
            AgentSession(provider: "codex", nativeID: "demo-2", title: "Fix flaky checkout test", cwd: "/Users/you/code/shop",
                         state: .needsYou, startedAt: now.addingTimeInterval(-900), updatedAt: now.addingTimeInterval(-20),
                         recentEvents: [ev("Ran: pnpm vitest checkout", .tool, 60), ev("Wants to run: git push origin fix/checkout", .permission, 20)],
                         pendingQuestions: [AgentQuestion(id: "demo-q", sessionID: "codex:demo-2", provider: "codex", kind: .permission,
                                                          title: "Run shell command", detail: "git push origin fix/checkout",
                                                          options: AgentQuestion.permissionOptions(), answerable: false)]),
            AgentSession(provider: "opencode", nativeID: "demo-3", title: "Write migration for invoices", cwd: "/Users/you/code/billing",
                         state: .finished, startedAt: now.addingTimeInterval(-3600), updatedAt: now.addingTimeInterval(-300),
                         recentEvents: [ev("Created migrations/0042_invoices.sql", .tool, 400), ev("Done: migration + tests pass", .assistant, 300)]),
        ]
    }()
}
