import Testing
import Foundation
@testable import SiliconModeKit

/// The legacy (v1 JSON storage) fallback caches file facts only: liveness and the idle decay are
/// re-derived on every scan.
extension CoreOpenCodeTests {
    private final class Storage {
        let home = CoreFixtures.tempDir("oc-legacy")
        var root: String { home + "/.local/share/opencode/storage" }

        func write(_ rel: String, _ obj: [String: Any]) throws {
            let path = root + "/" + rel
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: obj).write(to: URL(fileURLWithPath: path))
        }

        func session(_ id: String, dir: String, updated: Date) throws {
            try write("session/proj1/\(id).json", ["id": id, "title": "Legacy \(id)", "directory": dir,
                                                   "time": ["created": updated.timeIntervalSince1970 * 1000 - 60_000,
                                                            "updated": updated.timeIntervalSince1970 * 1000]])
        }

        func message(_ sid: String, _ id: String, role: String, completed: Bool, at: Date) throws {
            var time: [String: Any] = ["created": at.timeIntervalSince1970 * 1000]
            if completed { time["completed"] = at.timeIntervalSince1970 * 1000 + 500 }
            try write("message/\(sid)/\(id).json", ["id": id, "sessionID": sid, "role": role, "time": time])
        }

        deinit { try? FileManager.default.removeItem(atPath: home) }
    }

    @Test func legacyStateFollowsTheProcessAndTheClock() async throws {
        let s = Storage()
        let cwd = "/tmp/oc-legacy-proj"
        let now = Date()
        try s.session("ses_a", dir: cwd, updated: now.addingTimeInterval(-30))
        try s.message("ses_a", "msg_1", role: "user", completed: false, at: now.addingTimeInterval(-30))
        let opencode = ProcessEntry(pid: 4242, ppid: 1, name: "opencode", path: nil, args: ["opencode"], startTime: now.addingTimeInterval(-300))
        let p = OpenCodeProvider(home: s.home, cwdOf: { $0.pid == 4242 ? cwd : nil })
        func ctx(_ procs: [ProcessEntry], at t: TimeInterval = 0) -> ScanContext {
            ScanContext(now: now.addingTimeInterval(t), processes: procs, activeWindow: 30 * 60, idleAfter: 10 * 60)
        }

        #expect(await p.scan(ctx([opencode])).map(\.state) == [.working])
        // Ctrl-C: the process is gone, no file changes.
        #expect(await p.scan(ctx([], at: 5)).map(\.state) == [.idle])
        #expect(await p.scan(ctx([opencode], at: 6)).map(\.state) == [.working])

        // The reply streams into the newest message file (rewritten in place), then completes.
        try s.message("ses_a", "msg_1", role: "user", completed: true, at: now.addingTimeInterval(-30))
        try s.message("ses_a", "msg_2", role: "assistant", completed: false, at: now.addingTimeInterval(-20))
        #expect(await p.scan(ctx([opencode], at: 7)).map(\.state) == [.working])
        try s.message("ses_a", "msg_2", role: "assistant", completed: true, at: now.addingTimeInterval(-20))
        let msg2 = s.root + "/message/ses_a/msg_2.json"
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(1)], ofItemAtPath: msg2)
        #expect(await p.scan(ctx([opencode], at: 8)).map(\.state) == [.finished])

        // Finished decays to idle with time alone.
        #expect(await p.scan(ctx([], at: 11 * 60)).map(\.state) == [.idle])
        #expect(p.legacyCacheCount == 1)

        // Deleted sessions leave the cache.
        try FileManager.default.removeItem(atPath: s.root + "/session/proj1/ses_a.json")
        #expect(await p.scan(ctx([], at: 11 * 60 + 1)).isEmpty)
        #expect(p.legacyCacheCount == 0)
    }
}
