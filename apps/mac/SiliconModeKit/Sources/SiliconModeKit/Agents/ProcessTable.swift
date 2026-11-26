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
            let (path, args) = arguments(of: pid)
            out.append(ProcessEntry(pid: pid, ppid: kp.kp_eproc.e_ppid, name: name, path: path, args: args, startTime: start))
        }
        return out
    }

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
