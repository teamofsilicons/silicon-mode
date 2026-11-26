import Foundation
import Darwin
import IOKit.ps

/// One reading of the Mac's activity, for the "system activity" face furniture.
public struct SystemActivity: Equatable, Sendable {
    public enum Pressure: String, Sendable, Equatable {
        case normal, warning, critical

        /// From `kern.memorystatus_vm_pressure_level` (1 normal, 2 warning, 4 critical).
        public init(level: Int32) {
            switch level {
            case 4...: self = .critical
            case 2, 3: self = .warning
            default: self = .normal
            }
        }
    }

    public struct Battery: Equatable, Sendable {
        /// 0…1.
        public var level: Double
        public var charging: Bool
        /// On AC power (charging or full).
        public var pluggedIn: Bool
        public init(level: Double, charging: Bool, pluggedIn: Bool = false) {
            self.level = level; self.charging = charging; self.pluggedIn = pluggedIn
        }
    }

    /// All cores, 0…1.
    public var cpu: Double
    /// Recent `cpu` values, oldest first (up to the sampler's history length).
    public var cpuHistory: [Double]
    /// Bytes in use (Activity Monitor's "Memory Used": app + wired + compressed).
    public var memUsed: UInt64
    public var memTotal: UInt64
    public var pressure: Pressure
    /// Nil on Macs without a battery.
    public var battery: Battery?
    public var thermal: ProcessInfo.ThermalState
    /// Bytes per second received / sent over Ethernet and Wi-Fi (`en*`).
    public var netIn: Double
    public var netOut: Double

    public init(cpu: Double, cpuHistory: [Double], memUsed: UInt64, memTotal: UInt64, pressure: Pressure,
                battery: Battery?, thermal: ProcessInfo.ThermalState, netIn: Double, netOut: Double) {
        self.cpu = cpu; self.cpuHistory = cpuHistory; self.memUsed = memUsed; self.memTotal = memTotal
        self.pressure = pressure; self.battery = battery; self.thermal = thermal; self.netIn = netIn; self.netOut = netOut
    }

    /// Memory in use as a fraction of the total (0…1).
    public var memFraction: Double { memTotal > 0 ? min(1, Double(memUsed) / Double(memTotal)) : 0 }

    /// A fixed, plausible reading for snapshots and previews.
    public static let preview: SystemActivity = {
        let history = (0..<60).map { i -> Double in
            let t = Double(i)
            return min(1, max(0.03, 0.22 + 0.12 * sin(t / 5.3) + 0.07 * sin(t / 1.7 + 1) + (i > 48 ? 0.18 : 0)))
        }
        return SystemActivity(cpu: history.last ?? 0.34, cpuHistory: history,
                              memUsed: 11_800_000_000, memTotal: 17_179_869_184, pressure: .normal,
                              battery: Battery(level: 0.82, charging: true, pluggedIn: true), thermal: .nominal,
                              netIn: 1_420_000, netOut: 86_000)
    }()
}

// MARK: - Math (pure, testable)

/// Cumulative CPU ticks (user, system, idle, nice) as the kernel reports them (32-bit counters).
public struct CPUTicks: Equatable, Sendable {
    public var user: UInt32, system: UInt32, idle: UInt32, nice: UInt32
    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user; self.system = system; self.idle = idle; self.nice = nice
    }
}

/// Byte counters of one network interface (32-bit `if_data` counters).
public struct NetCounters: Equatable, Sendable {
    public var rx: UInt32, tx: UInt32
    public init(rx: UInt32, tx: UInt32) { self.rx = rx; self.tx = tx }
}

public enum SystemActivityMath {
    /// Busy fraction between two tick readings. Counters wrap at 2³²; deltas use wrapping subtraction.
    public static func cpuUsage(_ a: CPUTicks, _ b: CPUTicks) -> Double {
        let busy = Double(b.user &- a.user) + Double(b.nice &- a.nice) + Double(b.system &- a.system)
        let all = busy + Double(b.idle &- a.idle)
        return all > 0 ? min(1, max(0, busy / all)) : 0
    }

    /// Bytes received and sent between two readings, summed over interfaces present in both.
    /// Wrap-safe: a 32-bit counter that wrapped still yields its true delta (while < 4 GiB/interval).
    public static func netDelta(_ prev: [String: NetCounters], _ cur: [String: NetCounters]) -> (rx: UInt64, tx: UInt64) {
        var rx: UInt64 = 0, tx: UInt64 = 0
        for (name, c) in cur {
            guard let p = prev[name] else { continue }
            rx += UInt64(c.rx &- p.rx)
            tx += UInt64(c.tx &- p.tx)
        }
        return (rx, tx)
    }

    /// Appends a value, keeping at most `limit` (oldest dropped).
    public static func appending(_ value: Double, to history: [Double], limit: Int) -> [Double] {
        var h = history
        h.append(value)
        if h.count > limit { h.removeFirst(h.count - limit) }
        return h
    }
}

// MARK: - Probes (system calls)

enum SystemProbe {
    static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        return CPUTicks(user: t.0, system: t.1, idle: t.2, nice: t.3)
    }

    static let memTotal: UInt64 = {
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        return sysctlbyname("hw.memsize", &total, &size, nil, 0) == 0 ? total : 0
    }()

    /// Activity Monitor's "Memory Used" = app (internal − purgeable) + wired + compressed.
    static func memory() -> (used: UInt64, pressure: Int32)? {
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return nil }
        var page: vm_size_t = 0
        host_page_size(host, &page)
        let p = UInt64(page)
        let app = UInt64(vm.internal_page_count) &- min(UInt64(vm.purgeable_count), UInt64(vm.internal_page_count))
        let used = (app + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * p
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) != 0 { level = 1 }
        return (used, level)
    }

    /// Per-interface byte counters of `en*` interfaces (Ethernet, Wi-Fi). VPN tunnels (`utun*`) would
    /// double count, loopback and AWDL aren't traffic the user means.
    static func netCounters() -> [String: NetCounters] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }
        var out: [String: NetCounters] = [:]
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard let addr = a.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let data = a.ifa_data else { continue }
            let name = String(cString: a.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            out[name] = NetCounters(rx: d.ifi_ibytes, tx: d.ifi_obytes)
        }
        return out
    }

    /// The internal battery, or nil (desktop Macs).
    static func battery() -> SystemActivity.Battery? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let cap = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return SystemActivity.Battery(level: min(1, max(0, Double(cur) / Double(max(cap, 1)))),
                                          charging: charging, pluggedIn: onAC)
        }
        return nil
    }

    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
}

// MARK: - Sampler

/// Samples `SystemActivity` every `interval` seconds on its own queue and delivers each reading on
/// the main actor. Costs about 0.1 ms per sample. Run it only while something shows the numbers.
///
/// The first reading arrives about half a second after `start()` (CPU and network rates need two
/// samples). `stop()` drops any reading still in flight; a later `start()` begins a fresh history.
public final class SystemActivitySampler: @unchecked Sendable {
    public let interval: TimeInterval
    public let historyLength: Int
    private let deliver: @MainActor @Sendable (SystemActivity) -> Void
    private let queue = DispatchQueue(label: "ai.tos.mode.system-activity", qos: .utility)

    /// Generation of the current run (0 = stopped); readings from older runs are dropped.
    private let control = Locked<(generation: Int, running: Bool, timer: DispatchSourceTimer?)>((0, false, nil))

    /// Queue-confined sampling state.
    private struct Loop {
        var lastCPU: CPUTicks?
        var lastNet: [String: NetCounters] = [:]
        var lastAt: UInt64?
        var history: [Double] = []
        var battery: SystemActivity.Battery?
        var ticks = 0
    }
    private var loop = Loop()

    public init(interval: TimeInterval = 2, historyLength: Int = 60,
                deliver: @escaping @MainActor @Sendable (SystemActivity) -> Void) {
        self.interval = max(0.25, interval)
        self.historyLength = max(1, historyLength)
        self.deliver = deliver
    }

    deinit { control.current.timer?.cancel() }

    public var isRunning: Bool { control.current.running }

    public func start() {
        let gen: Int? = control.withLock { c in
            guard !c.running else { return nil }
            c.generation += 1
            c.running = true
            return c.generation
        }
        guard let gen else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: interval, leeway: .milliseconds(Int(interval * 100)))
        timer.setEventHandler { [weak self] in self?.tick(gen) }
        let installed = control.withLock { c -> Bool in
            guard c.running, c.generation == gen else { return false }
            c.timer = timer
            return true
        }
        guard installed else {
            // A dispatch source must be activated before it is released, even a cancelled one.
            timer.cancel()
            timer.resume()
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.loop = Loop()
            self.prime()
            timer.resume()
        }
    }

    public func stop() {
        let timer = control.withLock { c -> DispatchSourceTimer? in
            c.running = false
            c.generation += 1
            defer { c.timer = nil }
            return c.timer
        }
        timer?.cancel()
    }

    // MARK: Queue

    private func prime() {
        loop.lastCPU = SystemProbe.cpuTicks()
        loop.lastNet = SystemProbe.netCounters()
        loop.lastAt = SystemProbe.now()
        loop.battery = SystemProbe.battery()
    }

    private func tick(_ gen: Int) {
        guard control.current.generation == gen else { return }
        let now = SystemProbe.now()
        let dt = loop.lastAt.map { max(0.001, Double(now &- $0) / 1e9) } ?? interval
        loop.lastAt = now

        var cpu = 0.0
        if let c = SystemProbe.cpuTicks() {
            if let p = loop.lastCPU { cpu = SystemActivityMath.cpuUsage(p, c) }
            loop.lastCPU = c
        }
        loop.history = SystemActivityMath.appending(cpu, to: loop.history, limit: historyLength)

        let net = SystemProbe.netCounters()
        let delta = SystemActivityMath.netDelta(loop.lastNet, net)
        loop.lastNet = net

        // The battery read costs ~150 µs: refresh it every ~10 s.
        loop.ticks += 1
        if loop.ticks % max(1, Int((10 / interval).rounded())) == 0 { loop.battery = SystemProbe.battery() }

        let mem = SystemProbe.memory()
        let reading = SystemActivity(
            cpu: cpu, cpuHistory: loop.history, memUsed: mem?.used ?? 0, memTotal: SystemProbe.memTotal,
            pressure: SystemActivity.Pressure(level: mem?.pressure ?? 1), battery: loop.battery,
            thermal: ProcessInfo.processInfo.thermalState,
            netIn: Double(delta.rx) / dt, netOut: Double(delta.tx) / dt)

        let deliver = self.deliver
        let control = self.control
        DispatchQueue.main.async {
            guard control.current.generation == gen else { return }
            MainActor.assumeIsolated { deliver(reading) }
        }
    }

    /// One reading taken synchronously (two samples `gap` seconds apart). Diagnostics and tests.
    public static func sampleOnce(gap: TimeInterval = 0.2) -> SystemActivity {
        let c0 = SystemProbe.cpuTicks(), n0 = SystemProbe.netCounters(), t0 = SystemProbe.now()
        Thread.sleep(forTimeInterval: gap)
        let c1 = SystemProbe.cpuTicks(), n1 = SystemProbe.netCounters(), t1 = SystemProbe.now()
        let dt = max(0.001, Double(t1 &- t0) / 1e9)
        let cpu = (c0.flatMap { a in c1.map { SystemActivityMath.cpuUsage(a, $0) } }) ?? 0
        let d = SystemActivityMath.netDelta(n0, n1)
        let mem = SystemProbe.memory()
        return SystemActivity(cpu: cpu, cpuHistory: [cpu], memUsed: mem?.used ?? 0, memTotal: SystemProbe.memTotal,
                              pressure: SystemActivity.Pressure(level: mem?.pressure ?? 1), battery: SystemProbe.battery(),
                              thermal: ProcessInfo.processInfo.thermalState,
                              netIn: Double(d.rx) / dt, netOut: Double(d.tx) / dt)
    }
}
