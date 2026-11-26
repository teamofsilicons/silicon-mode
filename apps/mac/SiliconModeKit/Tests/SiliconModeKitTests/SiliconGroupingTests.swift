import Testing
import Foundation
@testable import SiliconModeKit

/// One row per Silicon: its ISI sessions grouped, with the Silicon's identity. Every id, name and
/// token here is made up.
@Suite struct SiliconGroupingTests {
    static let scoutID = "5111c0de-0000-4000-8000-000000000001"
    static let tidyID = "5111c0de-0000-4000-8000-000000000002"
    static let uuid = "00000000-0000-4000-8000-0000000000aa"

    /// Keeps the temporary home alive for the whole test.
    final class Fixture {
        let home: TempHome
        let world: FakeWorld
        let p: SiliconProvider
        init(_ home: TempHome, _ world: FakeWorld, _ p: SiliconProvider) { self.home = home; self.world = world; self.p = p }
    }

    /// A Silicon "si:demo" with two ISIs: scout asked a question (needs you), tidy is running.
    private func world(account: String? = nil, extraSilicon: Bool = false) -> Fixture {
        let home = TempHome(), world = FakeWorld()
        home.write(".silicon-interpreter/daemon.json", text: #"{"pid":946,"port":1823,"token":"fake-daemon-token","version":"t"}"#)
        world.alive.withLock { $0.insert(946) }
        home.fixture("si-home/.silicon/sessions/active/scout/\(Self.scoutID).json", "silicon_session.json")
        home.fixture("si-home/.silicon/sessions/events/\(Self.scoutID).jsonl", "silicon_events.jsonl")
        let tidyRecord = #"{"id":"\#(Self.tidyID)","session_id":"\#(Self.tidyID)","isi":"tidy","title":"","description":"","first":"2026-11-01T08:00:00Z","last":"2026-11-20T10:03:10Z","archived_at":null,"status":"running"}"#
        home.write("si-home/.silicon/sessions/active/tidy/\(Self.tidyID).json", text: tidyRecord, mtime: MoreFixtures.now.addingTimeInterval(-30))
        let tidyEvents = [
            #"{"v":1,"type":"start","text":"Tidy the inbox","at":"2026-11-20T09:40:00.000Z","seq":1,"model":"demo-haiku"}"#,
            #"{"v":1,"type":"end","at":"2026-11-20T09:41:00.000Z","seq":2}"#,
            #"{"v":1,"type":"start","text":"Heartbeat: check the inbox","at":"2026-11-20T10:03:00.000Z","seq":3,"model":"demo-haiku"}"#,
            #"{"v":1,"type":"tool.call","tool":"Bash","id":"t1","args":{"command":"export API_KEY=sk-ant-abcdefghijklmnopqrstuvwxyz0123456789"},"at":"2026-11-20T10:03:10.000Z","seq":4}"#,
        ].joined(separator: "\n") + "\n"
        home.write("si-home/.silicon/sessions/events/\(Self.tidyID).jsonl", text: tidyEvents, mtime: MoreFixtures.now.addingTimeInterval(-30))
        if let account { home.write("si-home/.accounts/session.json", text: account) }
        var list = #"[{"id":"si:demo","home":"\#(home.abs("si-home"))","state":"connected"}"#
        if extraSilicon {
            home.write("si-two/.silicon/sessions/active/solo/\(Self.tidyID).json",
                       text: tidyRecord.replacingOccurrences(of: "\"tidy\"", with: "\"solo\""), mtime: MoreFixtures.now.addingTimeInterval(-30))
            list += #",{"id":"si:two","home":"\#(home.abs("si-two"))","state":"connected"}"#
        }
        list += "]"
        world.http.withLock { $0 = { _, body in
            switch json(body)["action"] as? String {
            case "list": return LocalHTTPResponse(status: 200, body: Data(list.utf8))
            case "send": return LocalHTTPResponse(status: 200, body: Data(#"{"delivery_id":"d1"}"#.utf8))
            default: return nil
            }
        } }
        return Fixture(home, world, SiliconProvider(env: world.env(home)))
    }

    @Test func groupsISIsIntoOneRow() async throws {
        let f = world(); let p = f.p
        defer { withExtendedLifetime(f) {} }
        let rows = await p.scan(scanContext([]))
        #expect(rows.count == 1)
        let s = try #require(rows.first)
        #expect(s.id == "silicon:si:demo")
        #expect(s.state == .needsYou)                       // most urgent of needs you (scout) and working (tidy)
        #expect(s.cwd == nil)
        #expect(s.pid == 946)
        // Latest activity across ISIs (tidy's files are newer).
        #expect(s.updatedAt == MoreFixtures.now.addingTimeInterval(-30))
        // Elapsed time is the current turn of the most urgent ISI (scout's last start), not when the
        // persistent session was created.
        #expect(s.startedAt == MoreDates.parse("2026-11-20T09:50:05Z"))
        // Model of the most recently active ISI.
        #expect(s.model == "demo-haiku")
        // Members: most urgent first.
        #expect(s.identity?.members == [.init(name: "scout", state: .needsYou), .init(name: "tidy", state: .working)])
        #expect(s.identity?.membersSummary == "scout needs you · tidy working")
    }

    @Test func mergesEventsByTimeWithUniqueIDs() async throws {
        let f = world(); let p = f.p
        defer { withExtendedLifetime(f) {} }
        let s = try #require(await p.scan(scanContext([])).first)
        let times = s.recentEvents.map(\.at)
        #expect(times == times.sorted())
        #expect(Set(s.recentEvents.map(\.id)).count == s.recentEvents.count)
        #expect(s.recentEvents.map(\.text).contains("Tidy the inbox"))
        #expect(s.recentEvents.map(\.text).contains("Draft the weekly report"))
        #expect(s.recentEvents.last?.kind == .tool)
        // Non-core provider events are redacted before they reach any screen.
        let ran = try #require(s.recentEvents.last?.text)
        #expect(ran.hasPrefix("Ran: export API_KEY="))
        #expect(!ran.contains("sk-ant-abcdefghijklmnop"))
        #expect(ran.contains("•••"))
    }

    @Test func questionsPointAtTheGroupAndStillRouteToTheISI() async throws {
        let f = world(); let p = f.p, world = f.world
        defer { withExtendedLifetime(f) {} }
        let s = try #require(await p.scan(scanContext([])).first)
        let q = try #require(s.pendingQuestions.first)
        #expect(q.sessionID == "silicon:si:demo")
        #expect(q.title == "scout asks")
        try await p.answer(q, with: AgentAnswer(questionID: q.id, text: "Go ahead.", source: .overlay))
        let sent = json(try #require(world.httpLog.current.last).body)
        let args = try #require(sent["args"] as? [String: String])
        #expect(args == ["silicon": "si:demo", "isi": "scout", "message": "Go ahead.", "id": Self.scoutID])
    }

    @Test func turnStartFollowsTheWorkingISIWhenNothingNeedsYou() async throws {
        let f = world(); let p = f.p, home = f.home
        defer { withExtendedLifetime(f) {} }
        // Scout's turn ends without a question: finished. Tidy keeps running: the group is working,
        // and its elapsed time is tidy's current turn (the heartbeat that started at 10:03).
        let events = MoreFixtures.text("silicon_events.jsonl").replacingOccurrences(of: "Should I send it to the team now?", with: "Sent.")
        home.write("si-home/.silicon/sessions/events/\(Self.scoutID).jsonl", text: events)
        let s = try #require(await p.scan(scanContext([])).first)
        #expect(s.state == .working)
        #expect(s.pendingQuestions.isEmpty)
        #expect(s.startedAt == MoreDates.parse("2026-11-20T10:03:00Z"))
        #expect(s.identity?.members.map(\.state) == [.working, .finished])
    }

    @Test func identityComesFromTheAccountsSessionFileOnly() async throws {
        let account = #"""
        {"access_token":"fake-access-token-not-real","refresh_token":"fake-refresh-token-not-real",
         "account":{"uuid":"\#(Self.uuid)","id":"si:demo","display_name":"Demo Silicon","kind":"silicon"},
         "expires_at":"2026-12-01T00:00:00Z"}
        """#
        let f = world(account: account); let p = f.p
        defer { withExtendedLifetime(f) {} }
        let s = try #require(await p.scan(scanContext([])).first)
        #expect(s.title == "Demo Silicon")
        #expect(s.identity?.displayName == "Demo Silicon")
        #expect(s.identity?.uuid == Self.uuid)
        #expect(s.identity?.avatarURL?.absoluteString == "https://iris.teamofsilicons.com/pfp/silicon?id=\(Self.uuid)")
        #expect(s.identity?.allowedAvatarURL != nil)
        // Nothing token-shaped leaves the provider.
        let encoded = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        #expect(!encoded.contains("fake-access-token"))
        #expect(!encoded.contains("fake-refresh-token"))
    }

    @Test func accountDecodingKeepsOnlyAccountFields() {
        let a = SiliconProvider.account(fromSessionFile: Data(#"{"token":"x","account":{"uuid":"  \#(Self.uuid.uppercased()) ","id":"si:demo","display_name":"  "}}"#.utf8))
        #expect(a == SiliconProvider.Account(uuid: Self.uuid, id: "si:demo", displayName: nil))
        // Not a uuid: dropped (no photo URL can be built from it).
        let b = SiliconProvider.account(fromSessionFile: Data(#"{"account":{"uuid":"nope","display_name":"Bot"}}"#.utf8))
        #expect(b == SiliconProvider.Account(uuid: nil, id: nil, displayName: "Bot"))
        #expect(SiliconProvider.account(fromSessionFile: Data(#"{"access_token":"x"}"#.utf8)) == nil)
        #expect(SiliconProvider.account(fromSessionFile: Data("not json".utf8)) == nil)
        #expect(SiliconProvider.account(fromSessionFile: Data(#"{"account":{"uuid":7}}"#.utf8)) == nil)
    }

    @Test func identityFollowsTheSessionFile() async throws {
        let f = world(); let p = f.p, home = f.home
        defer { withExtendedLifetime(f) {} }
        #expect(try #require(await p.scan(scanContext([])).first).title == "Demo")
        home.write("si-home/.accounts/session.json", text: #"{"account":{"uuid":"\#(Self.uuid)","display_name":"Renamed"}}"#,
                   mtime: MoreFixtures.now.addingTimeInterval(-5))
        let s = try #require(await p.scan(scanContext([], now: MoreFixtures.now.addingTimeInterval(11))).first)
        #expect(s.title == "Renamed")
    }

    @Test func oneRowPerSilicon() async throws {
        let f = world(extraSilicon: true); let p = f.p
        defer { withExtendedLifetime(f) {} }
        let rows = await p.scan(scanContext([]))
        #expect(rows.map(\.id).sorted() == ["silicon:si:demo", "silicon:si:two"])
        let two = try #require(rows.first { $0.nativeID == "si:two" })
        #expect(two.state == .working)
        #expect(two.title == "Two")
        #expect(two.identity?.members == [.init(name: "solo", state: .working)])
    }

    @Test func groupPicksTheMostUrgentStateAndNoRowWithoutSessions() {
        let p = SiliconProvider(env: FakeWorld().env(TempHome()))
        let si = SiliconProvider.Connected(id: "si:x", home: "/nonexistent", state: "connected")
        #expect(p.group(si, parts: [], account: nil, pid: 1, maxEvents: 10) == nil)
        let t0 = Date(timeIntervalSince1970: 1000)
        func part(_ isi: String, _ st: AgentState, _ at: Double, turn: Double?) -> SiliconProvider.Part {
            SiliconProvider.Part(isi: isi, state: st, updatedAt: t0.addingTimeInterval(at),
                                 turnStartedAt: turn.map { t0.addingTimeInterval($0) }, model: nil, events: [], questions: [])
        }
        let g = p.group(si, parts: [part("a", .idle, 50, turn: 40), part("b", .error, 10, turn: 5), part("a", .finished, 20, turn: 15)],
                        account: nil, pid: 1, maxEvents: 10)
        #expect(g?.state == .error)
        #expect(g?.updatedAt == t0.addingTimeInterval(50))
        #expect(g?.startedAt == t0.addingTimeInterval(5))
        // One member per ISI, at its most urgent state.
        #expect(g?.identity?.members == [.init(name: "b", state: .error), .init(name: "a", state: .finished)])
    }
}
