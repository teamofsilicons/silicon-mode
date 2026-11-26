import Testing
import Foundation
@testable import SiliconModeKit

@Suite struct ModeAgentLedgerTests {
    static let entry = Date(timeIntervalSince1970: 1_000_000)

    private func s(_ id: String, _ state: AgentState, updated: Double = 0, provider: String = "codex",
                   pid: Int32? = nil, question: Bool = false) -> AgentSession {
        let nativeID = id
        var q: [AgentQuestion] = []
        if question {
            q = [AgentQuestion(id: "q-\(id)", sessionID: "\(provider):\(nativeID)", provider: provider, kind: .permission, title: "Allow?")]
        }
        return AgentSession(provider: provider, nativeID: nativeID, title: id, state: state,
                            updatedAt: Self.entry.addingTimeInterval(updated), pid: pid, pendingQuestions: q)
    }

    private func ids(_ l: ModeAgentLedger) -> [String] { l.visible.map(\.nativeID) }
    private func state(_ l: ModeAgentLedger, _ id: String) -> AgentState? { l.visible.first { $0.nativeID == id }?.state }

    @Test func runningIsAlwaysShown() {
        var l = ModeAgentLedger(enteredAt: Self.entry)
        l.ingest([s("w", .working, updated: -3600), s("n", .needsYou, updated: -7200)])
        #expect(Set(ids(l)) == ["w", "n"])
    }

    @Test func idleNeverRunningIsHidden() {
        var l = ModeAgentLedger(enteredAt: Self.entry)
        l.ingest([s("i", .idle, updated: 60)])   // even when updated after entry
        #expect(l.visible.isEmpty)
    }

    @Test func idleSeenRunningShowsAsFinished() {
        var l = ModeAgentLedger(enteredAt: Self.entry)
        l.ingest([s("a", .working)])
        l.ingest([s("a", .idle, updated: 900)])
        #expect(ids(l) == ["a"])
        #expect(state(l, "a") == .finished)
    }

    @Test func idleAfterAnErrorShowsAsError() {
        var l = ModeAgentLedger(enteredAt: Self.entry)
        l.ingest([s("a", .working)])
        l.ingest([s("a", .error, updated: 10)])
        l.ingest([s("a", .idle, updated: 700)])
        #expect(state(l, "a") == .error)
    }

    @Test func finishedRules() {
        var l = ModeAgentLedger(enteredAt: Self.entry)
        l.ingest([
            s("before", .finished, updated: -120),   // finished before entry, never seen running: hidden
            s("after", .finished, updated: 30),      // finished after entry: shown
            s("at", .finished, updated: 0),          // exactly at entry: shown
        ])
        #expect(Set(ids(l)) == ["after", "at"])
        // Seen running, then finished with an old timestamp: shown.
        var m = ModeAgentLedger(enteredAt: Self.entry)
        m.ingest([s("x", .working, updated: -600)])
        m.ingest([s("x", .finished, updated: -500)])
        #expect(ids(m) == ["x"])
        #expect(state(m, "x") == .finished)
    }

    @Test func errorRules() {
        var l = ModeAgentLedger(enteredAt: Self.entry)
        l.ingest([s("old", .error, updated: -60), s("new", .error, updated: 5)])
        #expect(ids(l) == ["new"])
        var m = ModeAgentLedger(enteredAt: Self.entry)
        m.ingest([s("x", .needsYou, updated: -900)])
        m.ingest([s("x", .error, updated: -800)])
        #expect(ids(m) == ["x"])
        #expect(state(m, "x") == .error)
    }

    @Test func runningAtEntryCountsAsSeenRunning() {
        // Seeded with the snapshot at entry: these were running.
        var l = ModeAgentLedger(enteredAt: Self.entry)
        l.ingest([s("a", .working, updated: -3000), s("b", .needsYou, updated: -3000), s("c", .idle, updated: -3000)])
        #expect(l.wasSeenRunning("codex:a") && l.wasSeenRunning("codex:b") && !l.wasSeenRunning("codex:c"))
        l.ingest([s("a", .idle, updated: -3000), s("b", .finished, updated: -3000), s("c", .idle, updated: -3000)])
        #expect(Set(ids(l)) == ["a", "b"])
        #expect(state(l, "a") == .finished)
    }

    @Test func disappearingAfterRunningKeepsLastCopy() {
        var l = ModeAgentLedger(enteredAt: Self.entry)
        l.ingest([s("gone", .working, updated: 10, question: false), s("err", .working, updated: 10)])
        l.ingest([s("err", .error, updated: 20)])          // "gone" left the snapshot
        #expect(Set(ids(l)) == ["gone", "err"])
        #expect(state(l, "gone") == .finished)
        l.ingest([])                                       // both gone now
        #expect(state(l, "gone") == .finished)
        #expect(state(l, "err") == .error)                 // last state was error
        let ghost = l.visible.first { $0.nativeID == "gone" }
        #expect(ghost?.title == "gone")
    }

    @Test func ghostsDropTheirQuestions() {
        var l = ModeAgentLedger(enteredAt: Self.entry)
        l.ingest([s("n", .needsYou, updated: 10, question: true)])
        #expect(l.visible.first?.pendingQuestions.count == 1)
        l.ingest([])
        #expect(state(l, "n") == .finished)
        #expect(l.visible.first?.pendingQuestions.isEmpty == true)
    }

    @Test func disappearingNeverShownIsForgotten() {
        var l = ModeAgentLedger(enteredAt: Self.entry)
        l.ingest([s("i", .idle), s("f", .finished, updated: -60)])
        l.ingest([])
        #expect(l.visible.isEmpty)
        // And coming back idle later still doesn't show it.
        l.ingest([s("i", .idle, updated: 120)])
        #expect(l.visible.isEmpty)
    }

    @Test func shownFinishedThatDisappearsIsKept() {
        // Finished after entry (shown) but never seen running, then its process is cleaned up.
        var l = ModeAgentLedger(enteredAt: Self.entry)
        l.ingest([s("f", .finished, updated: 30)])
        l.ingest([])
        #expect(ids(l) == ["f"])
        #expect(state(l, "f") == .finished)
    }

    @Test func comingBackReplacesTheGhost() {
        var l = ModeAgentLedger(enteredAt: Self.entry)
        l.ingest([s("a", .working, updated: 1)])
        l.ingest([])
        #expect(state(l, "a") == .finished)
        l.ingest([s("a", .working, updated: 50)])
        #expect(state(l, "a") == .working)
        #expect(l.visible.count == 1)
    }

    @Test func processOnlyGhostReplacedByItsRealSessionIsDropped() {
        var l = ModeAgentLedger(enteredAt: Self.entry)
        l.ingest([s("pid-4242", .working, provider: "goose", pid: 4242)])
        // The same process now reported under its session file's id.
        l.ingest([s("sess-1", .working, provider: "goose", pid: 4242)])
        #expect(ids(l) == ["sess-1"])
        // A ghost of another provider with the same pid stays.
        var m = ModeAgentLedger(enteredAt: Self.entry)
        m.ingest([s("pid-7", .working, provider: "goose", pid: 7)])
        m.ingest([s("other", .working, provider: "aider", pid: 7)])
        #expect(Set(ids(m)) == ["pid-7", "other"])
    }

    @Test func sortedByUrgencyThenRecency() {
        var l = ModeAgentLedger(enteredAt: Self.entry)
        l.ingest([
            s("f-old", .finished, updated: 10), s("w-old", .working, updated: 5), s("e", .error, updated: 7),
            s("n", .needsYou, updated: 1), s("f-new", .finished, updated: 90), s("w-new", .working, updated: 60),
        ])
        #expect(ids(l) == ["n", "w-new", "w-old", "e", "f-new", "f-old"])
    }

    @Test func duplicateIDsInOneSnapshotCountOnce() {
        var l = ModeAgentLedger(enteredAt: Self.entry)
        l.ingest([s("a", .working), s("a", .idle)])
        #expect(l.visible.count == 1)
        #expect(state(l, "a") == .working)
    }

    @Test func ghostsAreCapped() {
        var l = ModeAgentLedger(enteredAt: Self.entry, ghostLimit: 3)
        l.ingest((0..<6).map { s("g\($0)", .working, updated: Double($0)) })
        l.ingest([])
        #expect(Set(ids(l)) == ["g3", "g4", "g5"])   // the most recent ghosts stay
    }

    @Test func freshLedgerStartsEmpty() {
        let l = ModeAgentLedger(enteredAt: Self.entry)
        #expect(l.visible.isEmpty)
        #expect(l.enteredAt == Self.entry)
    }
}

@Suite struct ModeLogBookTests {
    static let t0 = Date(timeIntervalSince1970: 2_000_000)

    private func e(_ id: String, _ at: Double, _ text: String = "", kind: AgentEvent.Kind = .tool) -> AgentEvent {
        AgentEvent(id: id, at: Self.t0.addingTimeInterval(at), kind: kind, text: text.isEmpty ? id : text)
    }

    private func s(_ id: String, _ events: [AgentEvent]) -> AgentSession {
        AgentSession(provider: "claude-code", nativeID: id, title: id, state: .working, updatedAt: Self.t0, recentEvents: events)
    }

    @Test func seedsFromRecentEventsOnFirstSight() {
        var b = ModeLogBook()
        #expect(b.revision == 0)
        b.ingest([s("a", [e("1", 1), e("2", 2), e("3", 3)])])
        #expect(b.events(for: "claude-code:a").map(\.id) == ["1", "2", "3"])
        #expect(b.revision == 1)
        #expect(b.events(for: "claude-code:nope").isEmpty)
    }

    @Test func accumulatesBeyondTheSnapshotWindow() {
        var b = ModeLogBook()
        // A provider keeps only the last 3 events per snapshot; the book keeps them all.
        b.ingest([s("a", [e("1", 1), e("2", 2), e("3", 3)])])
        b.ingest([s("a", [e("3", 3), e("4", 4), e("5", 5)])])
        b.ingest([s("a", [e("5", 5), e("6", 6), e("7", 7)])])
        #expect(b.events(for: "claude-code:a").map(\.id) == ["1", "2", "3", "4", "5", "6", "7"])
        #expect(b.count(for: "claude-code:a") == 7)
    }

    @Test func upsertsCoalescedEventsInPlace() {
        var b = ModeLogBook()
        b.ingest([s("a", [e("1", 1, "Ran tests"), e("2", 2, "Read A.swift")])])
        let rev = b.revision
        // Coalescing rewrote the last line's text and time.
        b.ingest([s("a", [e("1", 1, "Ran tests"), e("2", 5, "Read 3 files")])])
        let lines = b.events(for: "claude-code:a")
        #expect(lines.map(\.id) == ["1", "2"])
        #expect(lines.last?.text == "Read 3 files")
        #expect(lines.last?.at == Self.t0.addingTimeInterval(5))
        #expect(b.revision == rev + 1)
    }

    @Test func revisionOnlyBumpsOnChange() {
        var b = ModeLogBook()
        let snap = [s("a", [e("1", 1)]), s("b", [])]
        b.ingest(snap)
        let rev = b.revision
        b.ingest(snap)
        b.ingest(snap)
        #expect(b.revision == rev)
        b.ingest([s("a", [e("1", 1, "changed")])])
        #expect(b.revision == rev + 1)
    }

    @Test func keepsTimeOrderAcrossSources() {
        var b = ModeLogBook()
        b.ingest([s("a", [e("x1", 10), e("x2", 30)])])
        // A merged source (another ISI) reports an event that happened in between.
        b.ingest([s("a", [e("x1", 10), e("y1", 20), e("x2", 30)])])
        #expect(b.events(for: "claude-code:a").map(\.id) == ["x1", "y1", "x2"])
        // A coalesced event that moves later is re-placed.
        b.ingest([s("a", [e("x1", 40, "moved")])])
        #expect(b.events(for: "claude-code:a").map(\.id) == ["y1", "x2", "x1"])
    }

    @Test func equalTimesKeepArrivalOrder() {
        var b = ModeLogBook()
        b.ingest([s("a", [e("p", 5), e("q", 5), e("r", 5)])])
        b.ingest([s("a", [e("s", 5)])])
        #expect(b.events(for: "claude-code:a").map(\.id) == ["p", "q", "r", "s"])
    }

    @Test func capsPerSessionDroppingOldest() {
        var b = ModeLogBook(capacity: 5)
        b.ingest([s("a", (0..<4).map { e("e\($0)", Double($0)) })])
        b.ingest([s("a", (4..<8).map { e("e\($0)", Double($0)) })])
        #expect(b.events(for: "claude-code:a").map(\.id) == ["e3", "e4", "e5", "e6", "e7"])
        // A line already trimmed off the front doesn't come back (and doesn't count as a change).
        let rev = b.revision
        b.ingest([s("a", [e("e0", 0)])])
        #expect(b.events(for: "claude-code:a").first?.id == "e3")
        #expect(b.revision == rev)
        #expect(ModeLogBook().capacity == 3000)
    }

    @Test func sessionsAreSeparateAndSurviveLeaving() {
        var b = ModeLogBook()
        b.ingest([s("a", [e("1", 1)]), s("b", [e("1", 2, "other session, same id")])])
        b.ingest([])   // both left the snapshot
        #expect(b.events(for: "claude-code:a").map(\.text) == ["1"])
        #expect(b.events(for: "claude-code:b").map(\.text) == ["other session, same id"])
        #expect(Set(b.sessionIDs) == ["claude-code:a", "claude-code:b"])
    }
}
