import Foundation
import SQLite3
@testable import SiliconModeKit

/// Synthetic fixtures for the agents-more providers (no real user content anywhere).
enum MoreFixtures {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/more")
    static func data(_ name: String) -> Data { (try? Data(contentsOf: dir.appendingPathComponent(name))) ?? Data() }
    static func text(_ name: String) -> String { String(decoding: data(name), as: UTF8.self) }

    /// 2026-11-20T10:05:00Z — fixtures are timestamped a few minutes before this.
    static let now = Date(timeIntervalSince1970: 1_795_168_800 + 300)
}

/// A throwaway home directory laid out like the real one.
final class TempHome {
    let url: URL
    var path: String { url.path }

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("sm-more-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { remove() }

    func remove() {
        // Restore permissions first (some tests make folders read-only).
        if let e = FileManager.default.enumerator(atPath: path) {
            for case let rel as String in e { chmod((path as NSString).appendingPathComponent(rel), 0o755) }
        }
        try? FileManager.default.removeItem(at: url)
    }

    func abs(_ rel: String) -> String { (path as NSString).appendingPathComponent(rel) }

    @discardableResult
    func write(_ rel: String, _ data: Data, mtime: Date? = MoreFixtures.now.addingTimeInterval(-60)) -> String {
        let p = abs(rel)
        try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: p, contents: data)
        if let mtime { touch(rel, mtime) }
        return p
    }

    @discardableResult
    func write(_ rel: String, text: String, mtime: Date? = MoreFixtures.now.addingTimeInterval(-60)) -> String {
        write(rel, Data(text.utf8), mtime: mtime)
    }

    @discardableResult
    func fixture(_ rel: String, _ name: String, mtime: Date? = MoreFixtures.now.addingTimeInterval(-60)) -> String {
        write(rel, MoreFixtures.data(name), mtime: mtime)
    }

    func mkdir(_ rel: String) {
        try? FileManager.default.createDirectory(atPath: abs(rel), withIntermediateDirectories: true)
    }

    func touch(_ rel: String, _ date: Date) {
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: abs(rel))
    }

    /// Builds a SQLite database from a `.sql` fixture (or inline SQL).
    @discardableResult
    func database(_ rel: String, sqlFixture: String? = nil, sql: String? = nil,
                  mtime: Date? = MoreFixtures.now.addingTimeInterval(-60)) -> String {
        let p = abs(rel)
        try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var db: OpaquePointer?
        sqlite3_open(p, &db)
        let script = sql ?? MoreFixtures.text(sqlFixture ?? "")
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, script, nil, nil, &err) != SQLITE_OK, let err {
            print("fixture SQL error: \(String(cString: err))")
            sqlite3_free(err)
        }
        sqlite3_close(db)
        if let mtime { touch(rel, mtime) }
        return p
    }

    /// An executable stub (for `env.which`).
    func executable(_ rel: String) {
        write(rel, text: "#!/bin/sh\nexit 0\n", mtime: nil)
        chmod(abs(rel), 0o755)
    }
}

/// Fake processes, liveness, CPU, HTTP and subprocesses.
final class FakeWorld: @unchecked Sendable {
    let alive = Locked<Set<Int32>>([])
    let cwds = Locked<[Int32: String]>([:])
    let cpu = Locked<[Int32: UInt64]>([:])
    let httpLog = Locked<[(url: URL, headers: [String: String], body: Data)]>([])
    let runLog = Locked<[[String]]>([])
    let http = Locked<(URL, Data) -> LocalHTTPResponse?>({ _, _ in nil })
    let run = Locked<([String]) -> CommandOutput?>({ _ in nil })
    let index = OrchestratorIndex()

    func env(_ home: TempHome, vars: [String: String] = [:]) -> MoreEnvironment {
        MoreEnvironment(
            home: home.url, vars: vars,
            cwdOf: { [cwds] p in cwds.current[p.pid] },
            isAlive: { [alive] pid in alive.current.contains(pid) },
            cpuTime: { [cpu] pid in cpu.current[pid] ?? 0 },
            httpPost: { [http, httpLog] url, headers, body, _ in
                httpLog.withLock { $0.append((url, headers, body)) }
                return http.current(url, body)
            },
            run: { [run, runLog] exe, args, _ in
                runLog.withLock { $0.append([exe] + args) }
                return run.current(args)
            },
            index: index)
    }

    /// Registers a live process with a cwd.
    @discardableResult
    func spawn(_ pid: Int32, ppid: Int32 = 1, name: String, path: String? = nil, args: [String], cwd: String? = nil,
               start: Date = MoreFixtures.now.addingTimeInterval(-600)) -> ProcessEntry {
        alive.withLock { $0.insert(pid) }
        if let cwd { cwds.withLock { $0[pid] = cwd } }
        return ProcessEntry(pid: pid, ppid: ppid, name: name, path: path, args: args, startTime: start)
    }
}

func scanContext(_ procs: [ProcessEntry], now: Date = MoreFixtures.now, window: TimeInterval = 30 * 60) -> ScanContext {
    ScanContext(now: now, processes: procs, activeWindow: window, idleAfter: 10 * 60, maxEvents: 10)
}

func json(_ body: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
}
