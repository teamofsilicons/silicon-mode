import Testing
import Foundation
@testable import SiliconModeKit

/// A provider whose scans block until released. Each scan reports the question the agent shows
/// when that scan starts (like a real provider reading its files), so a scan that began before an
/// answer still carries the answered question.
private final class GatedProvider: AgentProvider, @unchecked Sendable {
    let info = AgentProviderInfo(id: "gated", name: "Gated", colorHex: "000000", symbol: "circle", monogram: "G")
    let question = Locked<String?>("q-1")
    let started = Locked(0)
    private let gates = Locked<[CheckedContinuation<Void, Never>]>([])

    var waiting: Int { gates.current.count }

    func scan(_ ctx: ScanContext) async -> [AgentSession] {
        let shown = question.current
        started.withLock { $0 += 1 }
        await withCheckedContinuation { c in gates.withLock { $0.append(c) } }
        let questions = shown.map {
            [AgentQuestion(id: $0, sessionID: "gated:s", provider: "gated", kind: .permission, title: "Allow?", createdAt: ctx.now)]
        } ?? []
        return [AgentSession(provider: "gated", nativeID: "s", title: "Gated", state: questions.isEmpty ? .working : .needsYou,
                             updatedAt: ctx.now, pendingQuestions: questions)]
    }

    func answer(_ question: AgentQuestion, with answer: AgentAnswer) async throws {
        self.question.withLock { $0 = nil }
    }

    func release() {
        let all = gates.withLock { g -> [CheckedContinuation<Void, Never>] in defer { g.removeAll() }; return g }
        all.forEach { $0.resume() }
    }
}

private func until(_ condition: @escaping () -> Bool) async throws {
    var tries = 0
    while !condition(), tries < 1000 {
        try await Task.sleep(for: .milliseconds(5))
        tries += 1
    }
    #expect(condition())
}

@Suite struct AgentHubTests {
    /// A refresh requested while a scan runs (an answer, a hook event) gets a scan that starts
    /// after it; every such caller shares that one follow-up, and snapshots come back in order.
    @Test func overlappingRefreshesCoalesceIntoOneFollowUp() async throws {
        let p = GatedProvider()
        let hub = AgentHub(providers: [p])

        let poll = Task { await hub.refresh() }
        try await until { p.waiting == 1 }
        // The user answers while the poll scan is still reading: it already saw the question.
        let q = AgentQuestion(id: "q-1", sessionID: "gated:s", provider: "gated", kind: .permission, title: "Allow?")
        try await hub.answer(q, with: AgentAnswer(questionID: "q-1", optionIDs: ["allow"], source: .menuBar))
        let afterAnswer = Task { await hub.refresh() }
        let hookBurst = (0..<5).map { _ in Task { await hub.refresh() } }
        try await Task.sleep(for: .milliseconds(50))
        #expect(p.started.current == 1)   // no overlapping scans

        p.release()
        let first = await poll.value
        #expect(first.pendingQuestions.map(\.id) == ["q-1"])
        try await until { p.waiting == 1 }
        #expect(p.started.current == 2)   // one follow-up for all six callers
        p.release()
        let second = await afterAnswer.value
        #expect(second.pendingQuestions.isEmpty)
        #expect(second.takenAt >= first.takenAt)
        for t in hookBurst { #expect(await t.value == second) }
        #expect(await hub.latest == second)
        #expect(p.started.current == 2)
    }

    @Test func sequentialRefreshesEachScan() async throws {
        let p = GatedProvider()
        let hub = AgentHub(providers: [p])
        for n in 1...3 {
            let t = Task { await hub.refresh() }
            try await until { p.waiting == 1 }
            p.release()
            _ = await t.value
            #expect(p.started.current == n)
        }
    }
}
