import Foundation
import Darwin

/// Enumerates the current user's processes via sysctl (no `ps` spawn).
public enum ProcessTable {
    public static func snapshot(currentUserOnly: Bool = true) -> [ProcessEntry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, currentUserOnly ? KERN_PROC_UID : KERN_PROC_ALL, Int32(getuid())]
        if !currentUserOnly { mib = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0] }
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride + 16
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        size = count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &procs, &size, nil, 0) == 0 else { return [] }
        let n = size / MemoryLayout<kinfo_proc>.stride
        var out: [ProcessEntry] = []
        out.reserveCapacity(n)
        var keys: [ArgvCache.Key] = []
        keys.reserveCapacity(n)
        for i in 0..<n {
            let kp = procs[i]
            let pid = kp.kp_proc.p_pid
            guard pid > 0 else { continue }
            let name = withUnsafeBytes(of: kp.kp_proc.p_comm) { raw -> String in
                let bytes = raw.bindMemory(to: UInt8.self)
                let end = bytes.firstIndex(of: 0) ?? bytes.count
                return String(decoding: bytes[0..<end], as: UTF8.self)
            }
            let tv = kp.kp_proc.p_starttime
            let start = Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
            let key = ArgvCache.Key(pid: pid, startSec: Int64(tv.tv_sec), startUsec: Int32(tv.tv_usec), name: name)
            keys.append(key)
            let (path, args) = argvCache.arguments(for: key) { arguments(of: pid) }
            out.append(ProcessEntry(pid: pid, ppid: kp.kp_eproc.e_ppid, name: name, path: path, args: args, startTime: start))
        }
        argvCache.retain(only: keys)
        return out
    }

    /// argv per process, read once per process lifetime instead of on every scan (two
    /// KERN_PROCARGS2 sysctls for each of the user's ~500 processes every 2 s otherwise).
    static let argvCache = ArgvCache()

    /// Executable path and argv via KERN_PROCARGS2.
    public static func arguments(of pid: Int32) -> (String?, [String]) {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return (nil, []) }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return (nil, []) }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        // exec path
        let pathStart = i
        while i < size && buf[i] != 0 { i += 1 }
        let path = String(decoding: buf[pathStart..<i], as: UTF8.self)
        // skip nul padding
        while i < size && buf[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < Int(argc) && i < size {
            let s = i
            while i < size && buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[s..<i], as: UTF8.self))
            i += 1
        }
        return (path.isEmpty ? nil : path, args)
    }

    /// Current working directory of a process (same-user processes only).
    public static func cwd(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let r = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard r == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let end = bytes.firstIndex(of: 0) ?? bytes.count
            let s = String(decoding: bytes[0..<end], as: UTF8.self)
            return s.isEmpty ? nil : s
        }
    }

    public static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}

/// Caches each process's executable path and argv by (pid, start time, command name). A pid that
/// is reused gets a new start time; an `exec` (same pid and start) changes the command name; either
/// misses the cache. Failed reads (empty results) are not cached, so they are retried next scan.
public final class ArgvCache: @unchecked Sendable {
    public struct Key: Hashable, Sendable {
        public var pid: Int32
        public var startSec: Int64
        public var startUsec: Int32
        public var name: String
        public init(pid: Int32, startSec: Int64, startUsec: Int32, name: String) {
            self.pid = pid; self.startSec = startSec; self.startUsec = startUsec; self.name = name
        }
    }

    private let lock = NSLock()
    private var entries: [Int32: (key: Key, path: String?, args: [String])] = [:]

    public init() {}

    /// The cached value for `key`, or `read()`'s result (cached when non-empty).
    public func arguments(for key: Key, read: () -> (String?, [String])) -> (String?, [String]) {
        lock.lock()
        if let e = entries[key.pid], e.key == key {
            lock.unlock()
            return (e.path, e.args)
        }
        lock.unlock()
        let (path, args) = read()
        lock.lock()
        if path != nil || !args.isEmpty { entries[key.pid] = (key, path, args) } else { entries[key.pid] = nil }
        lock.unlock()
        return (path, args)
    }

    /// Drops entries for processes that are gone (call after a full enumeration).
    public func retain(only keys: [Key]) {
        let live = Set(keys.map(\.pid))
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { live.contains($0.key) }
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
}
