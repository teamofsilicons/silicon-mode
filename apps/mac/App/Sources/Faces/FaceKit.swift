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
    var paused: Bool = false

    func bool(_ key: String, _ fallback: Bool = false) -> Bool { options[key]?.bool ?? fallback }
    func number(_ key: String, _ fallback: Double = 0) -> Double { options[key]?.number ?? fallback }
    func string(_ key: String, _ fallback: String = "") -> String { options[key]?.string ?? fallback }

    static let sample = FaceContext(sessions: SampleAgents.sessions, counts: AgentCounts(SampleAgents.sessions),
                                    options: [:], showClock: true, isPreview: true, isPanicking: false)
}

extension FaceContext {
    /// What a face is allowed to see. Questions are not part of any face: they are answered on the
    /// Questions piece (which always stays, even with the furniture hidden). So a face never gets
    /// a question, and an agent waiting on you is drawn like a quiet, paused one (`idle`): no "?"
    /// signs, blocks or badges, no question text (nor the question and permission events in the
    /// agent's history), no alarm.
    var withoutQuestions: FaceContext {
        func asks(_ e: AgentEvent) -> Bool { e.kind == .question || e.kind == .permission }
        guard sessions.contains(where: { s in
            s.state == .needsYou || !s.pendingQuestions.isEmpty || s.recentEvents.contains(where: asks)
                || (s.identity?.members.contains { $0.state == .needsYou } ?? false)
        }) else { return self }
        var c = self
        c.sessions = sessions.map { s in
            var s = s
            if s.state == .needsYou { s.state = .idle }
            s.pendingQuestions = []
            s.recentEvents.removeAll(where: asks)
            if var id = s.identity {
                id.members = id.members.map { m in
                    var m = m
                    if m.state == .needsYou { m.state = .idle }
                    return m
                }
                s.identity = id
            }
            return s
        }
        c.counts = AgentCounts(c.sessions)
        return c
    }

    /// Frame interval for calm scenes, where nothing on the face moves faster than about 60 pt/s
    /// and no burst is playing: 20 fps (never faster than `frameInterval`). Slow motion looks the
    /// same at 20 fps, and every skipped frame saves a full SwiftUI pass plus a full-screen
    /// composite.
    var calmFrameInterval: Double { max(frameInterval, 1.0 / 20) }

    /// The interval a full-screen face animates at: previews always 30 fps, calm scenes 20 fps.
    func animationInterval(calm: Bool) -> Double {
        isPreview ? 1.0 / 30 : (calm ? calmFrameInterval : frameInterval)
    }
}

// MARK: - Face time

/// Face time that stands still while the face is paused (`FaceContext.paused`, e.g. under the
/// unlock sheet), so a face resumes exactly where it stopped instead of jumping or replaying the
/// paused seconds. One clock per face; every timeline of the face reads it.
@MainActor
final class FacePauseClock {
    /// Seconds spent paused so far.
    private var held: TimeInterval = 0
    private var pausedAt: Date?

    /// The live date minus the time spent paused (frozen while paused).
    func date(_ now: Date, paused: Bool) -> Date {
        if paused {
            let at = pausedAt ?? now
            pausedAt = at
            return at.addingTimeInterval(-held)
        }
        if let at = pausedAt {
            held += max(0, now.timeIntervalSince(at))
            pausedAt = nil
        }
        return now.addingTimeInterval(-held)
    }
}

/// Everything a face's child timelines need to agree on the animation clock.
struct FaceTiming: Equatable {
    let start: Date
    /// Snapshot items pin the animation clock here.
    let fixed: Double?
    let clock: FacePauseClock
    let paused: Bool

    /// Seconds of (unpaused) face time at a timeline date.
    @MainActor
    func t(_ date: Date) -> Double {
        FaceA.elapsed(since: start, now: clock.date(date, paused: paused), fixed: fixed)
    }

    nonisolated static func == (a: FaceTiming, b: FaceTiming) -> Bool {
        a.start == b.start && a.fixed == b.fixed && a.clock === b.clock && a.paused == b.paused
    }
}

/// A periodic schedule that can pause: the start date, then entries on a fixed grid (multiples of
/// `interval` since the reference date); just the start date while paused. Never yields a date
/// before the start, so face time never steps backwards when a timeline restarts.
struct FacePeriodicSchedule: TimelineSchedule {
    var interval: Double
    var paused = false

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(cursor: startDate, interval: paused ? nil : max(interval, 1.0 / 120))
    }

    struct Entries: Sequence, IteratorProtocol {
        var cursor: Date?
        let interval: Double?

        mutating func next() -> Date? {
            guard let d = cursor else { return nil }
            cursor = interval.map { i in
                Date(timeIntervalSinceReferenceDate: (floor(d.timeIntervalSinceReferenceDate / i) + 1) * i)
            }
            return d
        }
    }
}

/// Hysteresis for a face's calm state: calm only after the scene has been quiet for `settle`
/// seconds, busy again on the first busy frame.
struct FaceCalmGate {
    private(set) var calm = false
    private var quietSince: Double?
    var settle: Double = 0.8

    mutating func update(quiet: Bool, t: Double) {
        guard quiet else { quietSince = nil; calm = false; return }
        if quietSince == nil || t < (quietSince ?? t) { quietSince = t }
        calm = t - (quietSince ?? t) >= settle
    }

    mutating func reset() { quietSince = nil; calm = false }
}

// MARK: - Agent marks

/// A session's mark on a face: a Silicon's avatar (photo or monogram, TOS badge) through
/// `AgentAvatarView`, anything else its provider mark. `siliconScale` shrinks the rounded-square
/// avatar inside round puck/planet frames so its corners stay clear of the face's state rings.
struct FaceAgentMark: View, Equatable {
    let provider: String
    let identity: AgentIdentity?
    var size: CGFloat
    var siliconScale: CGFloat = 1

    init(provider: String, identity: AgentIdentity?, size: CGFloat, siliconScale: CGFloat = 1) {
        self.provider = provider
        self.identity = identity?.isSilicon == true ? identity : nil
        self.size = size
        self.siliconScale = siliconScale
    }

    init(_ session: AgentSession, size: CGFloat, siliconScale: CGFloat = 1) {
        self.init(provider: session.provider, identity: session.identity, size: size, siliconScale: siliconScale)
    }

    var isSilicon: Bool { identity != nil }

    var body: some View {
        if let identity {
            AgentAvatarView(provider: provider, identity: identity, size: size * siliconScale, showsState: false)
                .frame(width: size, height: size)
        } else {
            ProviderMark(provider: provider, size: size)
        }
    }
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
    /// Draws the face. Every face gets its context through `FaceContext.withoutQuestions`.
    let make: @MainActor (FaceContext) -> AnyView

    init(id: String, name: String, summary: String, options: [FaceOptionSpec],
         make: @escaping @MainActor (FaceContext) -> AnyView) {
        self.id = id
        self.name = name
        self.summary = summary
        self.options = options
        self.make = { ctx in make(ctx.withoutQuestions) }
    }

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
