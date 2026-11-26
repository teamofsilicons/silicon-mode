import Testing
import Foundation
@testable import SiliconModeKit

/// Reports a fixed list of sessions, in the order given.
private final class FixedProvider: AgentProvider, @unchecked Sendable {
    let info = AgentProviderInfo(id: "fixed", name: "Fixed", colorHex: "000000", symbol: "circle", monogram: "F")
    let sessions: [AgentSession]
    init(_ sessions: [AgentSession]) { self.sessions = sessions }
    func scan(_ ctx: ScanContext) async -> [AgentSession] { sessions }
    func answer(_ question: AgentQuestion, with answer: AgentAnswer) async throws {}
}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func session(_ id: String, _ state: AgentState, updated: TimeInterval, question: TimeInterval? = nil) -> AgentSession {
    let qs = question.map {
        [AgentQuestion(id: "q-\(id)", sessionID: "fixed:\(id)", provider: "fixed", kind: .permission, title: "Allow?",
                       createdAt: t0.addingTimeInterval($0))]
    } ?? []
    return AgentSession(provider: "fixed", nativeID: id, title: id, state: state, updatedAt: t0.addingTimeInterval(updated),
                        pendingQuestions: qs)
}

@Suite struct AgentOrderTests {
    /// The hub lists sessions in `urgencyOrder`: callers that add rows re-sort with the same rule.
    @Test func hubListsSessionsInUrgencyOrder() async {
        let scanned = [session("idle", .idle, updated: 50), session("old-work", .working, updated: 10),
                       session("done", .finished, updated: 40), session("ask", .needsYou, updated: 5, question: 5),
                       session("new-work", .working, updated: 30), session("broken", .error, updated: 20)]
        let hub = AgentHub(providers: [FixedProvider(scanned)])
        let snap = await hub.refresh()
        #expect(snap.sessions.map(\.nativeID) == ["ask", "new-work", "old-work", "broken", "done", "idle"])
        #expect(snap.sessions == scanned.sorted(by: AgentSession.urgencyOrder))
    }

    /// Added rows land where the hub would have put them, and the counts follow; the snapshot
    /// they were added to is untouched.
    @Test func addingMergesInHubOrderAndRecounts() {
        let real = [session("ask", .needsYou, updated: 5, question: 5), session("work", .working, updated: 30),
                    session("done", .finished, updated: 40)]
        let base = AgentHub.Snapshot(sessions: real, counts: AgentCounts(real), takenAt: t0)
        let demo = session("demo", .needsYou, updated: 60, question: 1)

        let shown = base.adding([demo])
        #expect(shown.sessions.map(\.nativeID) == ["demo", "ask", "work", "done"])
        #expect(shown.counts.needsYou == 2 && shown.counts.running == 3 && shown.counts.total == 4)
        #expect(shown.takenAt == t0)
        #expect(shown.pendingQuestions.map(\.id) == ["q-demo", "q-ask"])
        #expect(base.counts.running == 2 && base.sessions.count == 3 && base.pendingQuestions.map(\.id) == ["q-ask"])
    }

    @Test func addingSkipsSessionsAlreadyThere() {
        let real = [session("work", .working, updated: 30)]
        let base = AgentHub.Snapshot(sessions: real, counts: AgentCounts(real), takenAt: t0)
        #expect(base.adding([]) == base)
        #expect(base.adding([session("work", .needsYou, updated: 90)]) == base)
    }
}
