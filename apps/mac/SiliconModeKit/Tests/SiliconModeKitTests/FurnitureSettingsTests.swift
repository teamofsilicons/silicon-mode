import Testing
import Foundation
@testable import SiliconModeKit

@Suite struct FurnitureSettingsTests {
    private func decode(_ json: String) throws -> ModeSettings {
        try JSONDecoder().decode(ModeSettings.self, from: Data(json.utf8))
    }

    private func roundTrip(_ s: ModeSettings) throws -> ModeSettings {
        try JSONDecoder().decode(ModeSettings.self, from: JSONEncoder().encode(s))
    }

    @Test func defaultsKeepTodaysLook() {
        let s = ModeSettings()
        #expect(s.furniture.map(\.kind) == [.agents, .logs, .questions])
        #expect(s.furniture.map(\.slot) == [.topLeading, .bottomLeading, .topTrailing])
        #expect(s.furniture.map(\.id) == ["agents", "logs", "questions"])
        #expect(s.furnitureHidden == false)
        #expect(FurniturePiece.defaults == s.furniture)
    }

    @Test func roundTripsFurnitureAndHidden() throws {
        var s = ModeSettings()
        s.furniture = [
            FurniturePiece(id: "clock-a1", kind: .clock, slot: .topTrailing,
                           options: ["style": .string("analog"), "seconds": .bool(true), "size": .number(1.5)]),
            FurniturePiece(id: "logs", kind: .logs, slot: .bottomLeading),
            FurniturePiece(id: "questions", kind: .questions, slot: .bottomTrailing),
        ]
        s.furnitureHidden = true
        let back = try roundTrip(s)
        #expect(back.furniture == s.furniture)
        #expect(back.furnitureHidden)
    }

    @Test func missingFurnitureKeyMigratesFromOldToggles() throws {
        // Settings written before furniture existed: everything on.
        let all = try decode(#"{"showAgentCounts":true,"showAgentList":true,"showTailLogs":true,"showQuestions":true}"#)
        #expect(all.furniture.map(\.kind) == [.agents, .logs, .questions])
        #expect(all.furniture == FurniturePiece.defaults)

        // Counts alone still give the agents piece; logs off. Questions are always placed.
        let some = try decode(#"{"showAgentCounts":true,"showAgentList":false,"showTailLogs":false,"showQuestions":false}"#)
        #expect(some.furniture.map(\.kind) == [.agents, .questions])

        // The list alone too.
        let list = try decode(#"{"showAgentCounts":false,"showAgentList":true,"showTailLogs":true,"showQuestions":true}"#)
        #expect(list.furniture.map(\.kind) == [.agents, .logs, .questions])

        // Everything off: just the questions, which can't be removed.
        let none = try decode(#"{"showAgentCounts":false,"showAgentList":false,"showTailLogs":false,"showQuestions":false}"#)
        #expect(none.furniture.map(\.kind) == [.questions])

        // An empty file: defaults.
        #expect(try decode("{}").furniture == FurniturePiece.defaults)
    }

    @Test func presentFurnitureKeyWinsOverOldToggles() throws {
        let s = try decode(#"{"showAgentList":true,"furniture":[{"id":"c1","kind":"clock","slot":"bottomTrailing"}]}"#)
        #expect(s.furniture == [FurniturePiece(id: "c1", kind: .clock, slot: .bottomTrailing),
                                FurniturePiece(id: "questions", kind: .questions, slot: .topTrailing)])
        // An explicitly empty list (the user removed everything) keeps only the questions.
        #expect(try decode(#"{"furniture":[]}"#).furniture.map(\.kind) == [.questions])
    }

    @Test func oldKeysStayDecodable() throws {
        let s = try decode(#"{"showAgentCounts":false,"tailLogCount":7,"furnitureHidden":true}"#)
        #expect(s.showAgentCounts == false)
        #expect(s.tailLogCount == 7)
        #expect(s.furnitureHidden)
    }

    @Test func unknownKindsAndGarbageAreDropped() throws {
        let s = try decode(#"""
        {"furniture":[
          {"id":"w1","kind":"weather","slot":"topLeading"},
          42,
          {"id":"a","kind":"agents","slot":"nowhere"},
          {"kind":"system"},
          {"id":"c","kind":"clock","slot":"topTrailing","options":{"style":{"nested":true}}},
          null
        ]}
        """#)
        #expect(s.furniture.map(\.kind) == [.agents, .system, .clock, .questions])
        // Unknown slot → the kind's default; missing id → a fresh "<kind>-…" id; bad options → none.
        #expect(s.furniture[0].slot == .topLeading)
        #expect(s.furniture[1].id.hasPrefix("system-"))
        #expect(s.furniture[1].slot == FurnitureKind.system.defaultSlot)
        #expect(s.furniture[2].options.isEmpty)
    }

    @Test func sanitizeLimitsSingletonsCountAndIDs() {
        var pieces: [FurniturePiece] = [
            FurniturePiece(id: "agents", kind: .agents, slot: .topLeading),
            FurniturePiece(id: "agents-2", kind: .agents, slot: .topTrailing),   // second agents: dropped
            FurniturePiece(id: "logs", kind: .logs, slot: .bottomLeading),
            FurniturePiece(id: "logs-b", kind: .logs, slot: .bottomTrailing),    // second logs: dropped
            FurniturePiece(id: "q", kind: .questions, slot: .topTrailing),
            FurniturePiece(id: "q2", kind: .questions, slot: .topTrailing),      // second questions: dropped
            FurniturePiece(id: "clock", kind: .clock, slot: .topTrailing),
            FurniturePiece(id: "clock", kind: .clock, slot: .bottomTrailing),    // duplicate id: renamed
            FurniturePiece(id: "  ", kind: .system, slot: .bottomTrailing),      // blank id: named
        ]
        for i in 0..<20 { pieces.append(FurniturePiece(id: "sys\(i)", kind: .system, slot: .bottomTrailing)) }
        let s = FurniturePiece.sanitized(pieces)
        #expect(s.count == FurniturePiece.maxPieces)
        #expect(s.filter { $0.kind == .agents }.count == 1)
        #expect(s.filter { $0.kind == .logs }.count == 1)
        #expect(s.filter { $0.kind == .questions }.count == 1)
        #expect(s.first { $0.kind == .agents }?.slot == .topLeading)    // the first one wins
        #expect(Set(s.map(\.id)).count == s.count)
        #expect(s.map(\.id).contains("clock-2"))
        #expect(s.map(\.id).contains("system"))
        // Idempotent.
        #expect(FurniturePiece.sanitized(s) == s)
    }

    @Test func settingsSanitizedAppliesFurnitureRules() {
        var s = ModeSettings()
        s.furniture = [FurniturePiece(id: "x", kind: .logs, slot: .bottomLeading),
                       FurniturePiece(id: "x", kind: .clock, slot: .topTrailing),
                       FurniturePiece(id: "y", kind: .logs, slot: .bottomTrailing)]
        let clean = s.sanitized()
        #expect(clean.furniture.map(\.id) == ["x", "x-2", "questions"])
        #expect(clean.furniture.map(\.kind) == [.logs, .clock, .questions])
    }

    @Test func decodedListIsSanitized() throws {
        let s = try decode(#"{"furniture":[{"id":"a","kind":"agents"},{"id":"b","kind":"agents"},{"id":"a","kind":"clock"}]}"#)
        #expect(s.furniture.map(\.id) == ["a", "a-2", "questions"])
        #expect(s.furniture.map(\.kind) == [.agents, .clock, .questions])
    }

    @Test func questionsAreAlwaysPlaced() {
        // Removed: put back in its default corner.
        let none = FurniturePiece.sanitized([])
        #expect(none.map(\.kind) == [.questions])
        #expect(none.first?.slot == FurnitureKind.questions.defaultSlot)
        // Moved: the user's corner is kept.
        let moved = FurniturePiece.sanitized([FurniturePiece(id: "q", kind: .questions, slot: .bottomLeading)])
        #expect(moved.map(\.slot) == [.bottomLeading])
        // A full layout without questions gives up its last piece for them.
        let full = (0..<20).map { FurniturePiece(id: "c\($0)", kind: .clock, slot: .topTrailing) }
        let s = FurniturePiece.sanitized(full)
        #expect(s.count == FurniturePiece.maxPieces)
        #expect(s.last?.kind == .questions)
        // Questions placed after the cap still make it in.
        let late = FurniturePiece.sanitized(full + [FurniturePiece(id: "q", kind: .questions, slot: .bottomTrailing)])
        #expect(late.count == FurniturePiece.maxPieces)
        #expect(late.filter { $0.kind == .questions }.map(\.slot) == [.bottomTrailing])
        #expect(FurniturePiece.sanitized(late) == late)
        #expect(FurnitureKind.allCases.filter(\.isRequired) == [.questions])
    }

    @Test func makeGivesFreshUniqueIDs() {
        let a = FurniturePiece.make(.clock, slot: .topTrailing)
        let b = FurniturePiece.make(.clock, slot: .topTrailing)
        #expect(a.id != b.id)
        #expect(a.id.hasPrefix("clock-"))
        #expect(a.id.count == "clock-".count + 6)
        #expect(a.options.isEmpty)
        #expect(FurniturePiece(kind: .system, slot: .bottomLeading).id.hasPrefix("system-"))
    }

    @Test func kindRules() {
        #expect(FurnitureKind.allCases.filter(\.isSingleton) == [.agents, .logs, .questions])
        #expect(FurnitureSlot.topLeading.isTop && FurnitureSlot.topLeading.isLeading)
        #expect(!FurnitureSlot.bottomTrailing.isTop && !FurnitureSlot.bottomTrailing.isLeading)
    }
}

@Suite struct AgentIdentityTests {
    @Test func sessionWithoutIdentityDecodesFromOldEncoding() throws {
        // An encoding from before `identity` existed.
        let old = #"""
        {"id":"codex:abc","provider":"codex","nativeID":"abc","title":"T","state":"working",
         "updatedAt":0,"recentEvents":[],"pendingQuestions":[]}
        """#
        let s = try JSONDecoder().decode(AgentSession.self, from: Data(old.utf8))
        #expect(s.identity == nil)
        #expect(s.id == "codex:abc")
    }

    @Test func identityRoundTrips() throws {
        let id = AgentIdentity(kind: "silicon", handle: "si:demo_bot", uuid: "00000000-0000-4000-8000-000000000042",
                               displayName: "Demo Bot", avatarURL: AgentIdentity.irisAvatarURL(uuid: "00000000-0000-4000-8000-000000000042"),
                               members: [.init(name: "scout", state: .working), .init(name: "tidy", state: .finished)])
        let s = AgentSession(provider: "silicon", nativeID: "si:demo_bot", title: "Demo Bot", state: .working,
                             updatedAt: Date(timeIntervalSince1970: 100), identity: id)
        let back = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        #expect(back.identity?.members.count == 2)
    }

    @Test func identityToleratesUnknownMemberStates() throws {
        let json = #"{"kind":"silicon","handle":"si:x","members":[{"name":"a","state":"dreaming"},{"name":"b","state":"working"}]}"#
        let id = try JSONDecoder().decode(AgentIdentity.self, from: Data(json.utf8))
        #expect(id.members == [.init(name: "b", state: .working)])
        #expect(id.uuid == nil && id.avatarURL == nil)
    }

    @Test func namesAndMonograms() {
        #expect(AgentIdentity.prettyHandle("si:night_owl.acme") == "Night owl")
        #expect(AgentIdentity.prettyHandle("si:demo") == "Demo")
        #expect(AgentIdentity.prettyHandle("si:quiet-fox") == "Quiet fox")
        let named = AgentIdentity(kind: "silicon", handle: "si:x", displayName: "Ada Lovelace")
        #expect(named.name == "Ada Lovelace")
        #expect(named.monogram == "AL")
        let unnamed = AgentIdentity(kind: "silicon", handle: "si:scout", displayName: "  ")
        #expect(unnamed.name == "Scout")
        #expect(unnamed.monogram == "S")
        #expect(unnamed.isSilicon)
        // A name made from a handle isn't a first + last name: one letter.
        #expect(AgentIdentity(kind: "silicon", handle: "si:night_owl").monogram == "N")
    }

    @Test func membersSummaryReadsInOrder() {
        let id = AgentIdentity(kind: "silicon", handle: "si:x",
                               members: [.init(name: "scout", state: .working), .init(name: "tidy", state: .finished)])
        #expect(id.membersSummary == "scout working · tidy finished")
    }

    @Test func avatarURLsAreHttpsAllowlistedOnly() {
        let uuid = "00000000-0000-4000-8000-00000000abcd"
        let iris = AgentIdentity.irisAvatarURL(uuid: uuid)
        #expect(iris?.absoluteString == "https://iris.teamofsilicons.com/pfp/silicon?id=\(uuid)")
        #expect(AgentIdentity.irisAvatarURL(uuid: "not-a-uuid") == nil)
        func allowed(_ s: String) -> URL? { AgentIdentity(kind: "silicon", handle: "si:x", avatarURL: URL(string: s)).allowedAvatarURL }
        #expect(allowed("https://iris.teamofsilicons.com/pfp/silicon?id=\(uuid)") != nil)
        #expect(allowed("https://accounts.teamofsilicons.com/v1/photos/p1") != nil)
        #expect(allowed("http://iris.teamofsilicons.com/pfp/silicon?id=\(uuid)") == nil)
        #expect(allowed("https://tracker.example.com/pixel.png") == nil)
        #expect(allowed("https://iris.teamofsilicons.com.evil.example/x") == nil)
    }
}
