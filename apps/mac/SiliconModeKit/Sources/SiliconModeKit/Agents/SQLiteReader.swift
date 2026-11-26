import Foundation
import SQLite3

/// One SQLite cell.
public enum SQLiteValue: Sendable, Equatable, Hashable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    public var string: String? {
        switch self {
        case .text(let s): s
        case .int(let i): String(i)
        case .double(let d): String(d)
        case .blob(let d): String(data: d, encoding: .utf8)
        case .null: nil
        }
    }

    public var int: Int64? {
        switch self {
        case .int(let i): i
        case .double(let d): d.isFinite ? Int64(d) : nil
        case .text(let s): Int64(s.trimmingCharacters(in: .whitespaces)) ?? Double(s).map { Int64($0) }
        default: nil
        }
    }

    public var double: Double? {
        switch self {
        case .int(let i): Double(i)
        case .double(let d): d
        case .text(let s): Double(s.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    public var data: Data? {
        switch self {
        case .blob(let d): d
        case .text(let s): Data(s.utf8)
        default: nil
        }
    }

    /// SQLite has no bool: 0/1, "true"/"false".
    public var bool: Bool? {
        switch self {
        case .int(let i): i != 0
        case .double(let d): d != 0
        case .text(let s):
            switch s.lowercased() {
            case "1", "true", "yes": true
            case "0", "false", "no", "": false
            default: nil
            }
        default: nil
        }
    }

    public var isNull: Bool { self == .null }
}

/// One result row; look up by column name (case-sensitive, as declared in the query).
public struct SQLiteRow: Sendable {
    public let columns: [String]
    public let values: [SQLiteValue]

    public subscript(_ name: String) -> SQLiteValue {
        guard let i = columns.firstIndex(of: name) else { return .null }
        return values[i]
    }

    public subscript(_ index: Int) -> SQLiteValue {
        index < values.count ? values[index] : .null
    }
}

public enum SQLiteReadError: Error, Equatable, Sendable {
    case missing(String)
    case cantOpen(code: Int32, message: String)
    case prepare(code: Int32, message: String)
    case step(code: Int32, message: String)
}

/// Strictly read-only access to another app's SQLite database.
///
/// Open order (see docs/research/agents-more.md, rule 2):
/// 1. `file:<path>?mode=ro` — normal shared read; sees WAL content.
/// 2. If that fails (typically `SQLITE_CANTOPEN` because a read-only connection cannot create the
///    `-shm` file) and there is a non-empty `-wal`: copy `db`, `-wal`, `-shm` into a private temp
///    directory and read the copy (accurate, never touches the original).
/// 3. Otherwise `?mode=ro&immutable=1` — a snapshot of the main file (exact when no WAL is pending).
///
/// The original database is never written. Not thread-safe: open, query, close within one call.
public final class SQLiteReader {
    public enum Mode: String, Sendable { case readOnly, immutable, copied }

    public let path: String
    public private(set) var mode: Mode = .readOnly
    private var db: OpaquePointer?
    private var tempDir: URL?

    private init(path: String) { self.path = path }

    deinit { close() }

    /// Opens `path` read-only with the fallbacks described above.
    public static func open(_ path: String, busyTimeoutMS: Int32 = 250) throws -> SQLiteReader {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { throw SQLiteReadError.missing(path) }
        let r = SQLiteReader(path: path)

        // 1. Plain read-only.
        if let err = r.tryOpen(uri: uri(for: path, query: "mode=ro"), busyTimeoutMS: busyTimeoutMS) {
            r.closeHandle()
            let walPath = path + "-wal"
            let walSize = (try? fm.attributesOfItem(atPath: walPath)[.size] as? NSNumber)?.int64Value ?? 0
            // 2. WAL content pending → read a private copy so we see it.
            if walSize > 0, r.tryCopyOpen(busyTimeoutMS: busyTimeoutMS) {
                r.mode = .copied
                return r
            }
            // 3. Immutable snapshot.
            if r.tryOpen(uri: uri(for: path, query: "mode=ro&immutable=1"), busyTimeoutMS: busyTimeoutMS) == nil {
                r.mode = .immutable
                return r
            }
            r.closeHandle()
            // Last resort: copy even without WAL (e.g. exotic locking errors).
            if walSize == 0, r.tryCopyOpen(busyTimeoutMS: busyTimeoutMS) {
                r.mode = .copied
                return r
            }
            throw err
        }
        r.mode = .readOnly
        return r
    }

    /// Open, run `body`, close. Returns nil on any error (missing file, schema drift, lock…).
    public static func read<T>(_ path: String, _ body: (SQLiteReader) throws -> T) -> T? {
        guard let r = try? open(path) else { return nil }
        defer { r.close() }
        return try? body(r)
    }

    public func close() {
        closeHandle()
        if let t = tempDir {
            try? FileManager.default.removeItem(at: t)
            tempDir = nil
        }
    }

    // MARK: Queries

    /// Runs one statement and returns at most `limit` rows. Parameters bind positionally (`?`).
    public func query(_ sql: String, _ params: [SQLiteValue] = [], limit: Int = 5_000) throws -> [SQLiteRow] {
        guard let db else { throw SQLiteReadError.cantOpen(code: SQLITE_MISUSE, message: "closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw SQLiteReadError.prepare(code: rc, message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .null: sqlite3_bind_null(stmt, idx)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, transient)
            case .blob(let v):
                _ = v.withUnsafeBytes { raw in
                    sqlite3_bind_blob(stmt, idx, raw.baseAddress, Int32(v.count), transient)
                }
            }
        }
        let n = sqlite3_column_count(stmt)
        let cols = (0..<n).map { String(cString: sqlite3_column_name(stmt, $0)) }
        var rows: [SQLiteRow] = []
        while rows.count < limit {
            let s = sqlite3_step(stmt)
            if s == SQLITE_DONE { break }
            guard s == SQLITE_ROW else {
                throw SQLiteReadError.step(code: s, message: String(cString: sqlite3_errmsg(db)))
            }
            var vals: [SQLiteValue] = []
            vals.reserveCapacity(Int(n))
            for c in 0..<n {
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: vals.append(.int(sqlite3_column_int64(stmt, c)))
                case SQLITE_FLOAT: vals.append(.double(sqlite3_column_double(stmt, c)))
                case SQLITE_TEXT:
                    if let p = sqlite3_column_text(stmt, c) {
                        let len = Int(sqlite3_column_bytes(stmt, c))
                        vals.append(.text(String(decoding: UnsafeBufferPointer(start: p, count: len), as: UTF8.self)))
                    } else { vals.append(.null) }
                case SQLITE_BLOB:
                    let len = Int(sqlite3_column_bytes(stmt, c))
                    if len > 0, let p = sqlite3_column_blob(stmt, c) {
                        vals.append(.blob(Data(bytes: p, count: len)))
                    } else { vals.append(.blob(Data())) }
                default: vals.append(.null)
                }
            }
            rows.append(SQLiteRow(columns: cols, values: vals))
        }
        return rows
    }

    /// All table names (lets providers tolerate schema drift).
    public func tables() -> Set<String> {
        let rows = (try? query("SELECT name FROM sqlite_master WHERE type IN ('table','view')")) ?? []
        return Set(rows.compactMap { $0[0].string })
    }

    /// Column names of `table` (empty when it doesn't exist).
    public func columns(of table: String) -> Set<String> {
        let safe = table.replacingOccurrences(of: "\"", with: "\"\"")
        let rows = (try? query("PRAGMA table_info(\"\(safe)\")")) ?? []
        return Set(rows.compactMap { $0["name"].string })
    }

    // MARK: Opening

    static func uri(for path: String, query: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#%")
        let enc = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        return "file:\(enc)?\(query)"
    }

    /// Returns nil on success, the error otherwise.
    private func tryOpen(uri: String, busyTimeoutMS: Int32, flags: Int32 = SQLITE_OPEN_READONLY) -> SQLiteReadError? {
        var h: OpaquePointer?
        let rc = sqlite3_open_v2(uri, &h, flags | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, let h else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let h { sqlite3_close_v2(h) }
            return .cantOpen(code: rc, message: msg)
        }
        db = h
        sqlite3_busy_timeout(h, busyTimeoutMS)
        sqlite3_exec(h, "PRAGMA query_only=1", nil, nil, nil)
        // WAL/shm problems surface lazily on first read — probe now.
        var stmt: OpaquePointer?
        var prc = sqlite3_prepare_v2(h, "SELECT count(*) FROM sqlite_master", -1, &stmt, nil)
        if prc == SQLITE_OK {
            prc = sqlite3_step(stmt)
            if prc == SQLITE_ROW { prc = SQLITE_OK }
        }
        sqlite3_finalize(stmt)
        guard prc == SQLITE_OK else {
            return .cantOpen(code: prc, message: String(cString: sqlite3_errmsg(h)))
        }
        return nil
    }

    private func tryCopyOpen(busyTimeoutMS: Int32) -> Bool {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("silicon-mode-sqlite-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let name = URL(fileURLWithPath: path).lastPathComponent
            let dst = dir.appendingPathComponent(name)
            try fm.copyItem(atPath: path, toPath: dst.path)
            for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: path + suffix) {
                try? fm.copyItem(atPath: path + suffix, toPath: dst.path + suffix)
            }
            tempDir = dir
            // The copy is private, so a normal (read-write) open may replay its WAL. The original is untouched.
            if tryOpen(uri: Self.uri(for: dst.path, query: "mode=rw"), busyTimeoutMS: busyTimeoutMS,
                       flags: SQLITE_OPEN_READWRITE) == nil {
                return true
            }
            closeHandle()
            return false
        } catch {
            try? fm.removeItem(at: dir)
            tempDir = nil
            return false
        }
    }

    private func closeHandle() {
        if let db { sqlite3_close_v2(db) }
        db = nil
    }
}
