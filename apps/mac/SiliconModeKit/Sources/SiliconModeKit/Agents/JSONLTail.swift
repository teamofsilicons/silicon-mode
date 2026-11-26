import Foundation
import Darwin

/// Incremental reader for append-only JSONL transcripts (Claude Code, Codex rollouts, pi).
///
/// - Reads only bytes appended since the last call (`pread` from a stored offset).
/// - Detects replacement (inode change) and truncation, and reports a reset so the caller can
///   drop derived state before the fresh lines arrive.
/// - The first read of a large file starts `initialBackfill` bytes before EOF (the tail is what
///   matters for state and recent events) and drops the partial first line.
/// - A cheap `stat` decides "unchanged" without opening the file.
/// - Lines longer than `maxLineBytes` are skipped (huge tool outputs, request blobs).
///
/// Not thread-safe: each tail is owned by one provider and used under its lock.
final class JSONLTail {
    struct Update {
        /// The file was replaced or truncated (or this is the first read): derived state must restart.
        var reset: Bool
        /// Complete new lines (without the trailing newline).
        var lines: [Data]
        /// True when the first read skipped the beginning of the file.
        var skippedHead: Bool
    }

    let path: String
    var initialBackfill: UInt64
    var maxLineBytes: Int
    /// Bytes per read call when catching up.
    var chunkSize = 1 << 20

    private(set) var inode: UInt64 = 0
    /// File offset just past the last byte consumed (complete lines + `partial`).
    private(set) var offset: UInt64 = 0
    private(set) var lastStat: CoreFileStat?
    private var partial = Data()
    private var discardingLongLine = false
    private var started = false

    init(path: String, initialBackfill: UInt64 = 512 << 10, maxLineBytes: Int = 4 << 20) {
        self.path = path
        self.initialBackfill = initialBackfill
        self.maxLineBytes = maxLineBytes
    }

    /// Modification time from the last poll.
    var mtime: Date? { lastStat?.mtime }

    /// Read whatever was appended. Returns nil when the file is missing or unchanged.
    func poll() -> Update? {
        guard let st = CoreFS.stat(path) else {
            if started { resetState() }
            lastStat = nil
            return nil
        }
        if started, st.inode == inode, st.size == offset {
            lastStat = st
            return nil
        }
        lastStat = st
        var reset = false
        var skippedHead = false
        if !started || st.inode != inode || st.size < offset {
            reset = true
            resetState()
            started = true
            inode = st.inode
            if st.size > initialBackfill {
                offset = st.size - initialBackfill
                skippedHead = true
                discardingLongLine = true // drop the partial first line
            }
        } else if st.size - offset > max(initialBackfill * 8, 16 << 20) {
            // Fell far behind (huge burst): jump to the tail rather than parse everything.
            reset = true
            resetState()
            started = true
            inode = st.inode
            offset = st.size - initialBackfill
            skippedHead = true
            discardingLongLine = true
        }

        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return reset ? Update(reset: true, lines: [], skippedHead: skippedHead) : nil }
        defer { close(fd) }

        var lines: [Data] = []
        var buf = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, chunkSize, off_t(offset)) }
            if n <= 0 { break }
            offset += UInt64(n)
            buf.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                var start = 0
                var i = 0
                while i < n {
                    if bytes[i] == 0x0A {
                        if discardingLongLine {
                            discardingLongLine = false
                            partial.removeAll(keepingCapacity: true)
                        } else if partial.isEmpty {
                            if i > start { lines.append(Data(bytes[start..<i])) }
                        } else {
                            partial.append(contentsOf: bytes[start..<i])
                            lines.append(partial)
                            partial = Data()
                        }
                        start = i + 1
                    }
                    i += 1
                }
                if start < n, !discardingLongLine {
                    partial.append(contentsOf: bytes[start..<n])
                    if partial.count > maxLineBytes {
                        partial.removeAll()
                        discardingLongLine = true
                    }
                }
            }
            if n < chunkSize { break }
        }
        // Drop oversized complete lines too.
        lines.removeAll { $0.count > maxLineBytes }
        return Update(reset: reset, lines: lines, skippedHead: skippedHead)
    }

    private func resetState() {
        offset = 0
        partial.removeAll()
        discardingLongLine = false
        started = false
    }

    /// The first complete line of a file (e.g. a Codex `session_meta` or pi `session` header).
    static func firstLine(of path: String, maxBytes: Int = 1 << 20) -> Data? {
        lines(of: path, maxBytes: maxBytes, limit: 1).first
    }

    /// Up to `limit` complete lines from the head of a file.
    static func lines(of path: String, maxBytes: Int, limit: Int) -> [Data] {
        guard let data = CoreFS.read(path, max: maxBytes), !data.isEmpty else { return [] }
        var out: [Data] = []
        var start = data.startIndex
        while out.count < limit, let nl = data[start...].firstIndex(of: 0x0A) {
            if nl > start { out.append(data[start..<nl]) }
            start = data.index(after: nl)
        }
        return out
    }
}

/// Cheap line classification before JSON decoding.
enum LinePrefix {
    /// The value of a leading `{"type":"…"` key, if the line starts with one.
    static func leadingType(_ line: Data) -> String? {
        let prefix: [UInt8] = Array(#"{"type":""#.utf8)
        guard line.count > prefix.count else { return nil }
        var ok = true
        line.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            for i in 0..<prefix.count where b[i] != prefix[i] { ok = false; break }
        }
        guard ok else { return nil }
        let rest = line.dropFirst(prefix.count).prefix(64)
        guard let q = rest.firstIndex(of: 0x22) else { return nil }
        return String(decoding: rest[rest.startIndex..<q], as: UTF8.self)
    }

    /// True if `needle` occurs within the first `within` bytes.
    static func contains(_ line: Data, _ needle: String, within: Int = 256) -> Bool {
        let n = Array(needle.utf8)
        let hay = line.prefix(within)
        guard hay.count >= n.count, let first = n.first else { return false }
        return hay.withUnsafeBytes { raw -> Bool in
            let b = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i <= b.count - n.count {
                if b[i] == first {
                    var j = 1
                    while j < n.count && b[i + j] == n[j] { j += 1 }
                    if j == n.count { return true }
                }
                i += 1
            }
            return false
        }
    }
}
