import Foundation

/// Rolling window of lid-angle samples with stability and velocity estimates.
/// Times are monotonic seconds (e.g. `ProcessInfo.systemUptime`).
public struct AngleSampler: Sendable {
    public struct Sample: Sendable, Equatable { public var t: Double; public var angle: Double }

    public private(set) var samples: [Sample] = []
    /// How much history to keep (seconds).
    public var retention: Double = 8

    public init() {}

    public var latest: Double? { samples.last?.angle }

    public mutating func add(t: Double, angle: Double) {
        if let last = samples.last, t < last.t { samples.removeAll() } // clock went backwards → reset
        samples.append(Sample(t: t, angle: angle))
        let cutoff = t - retention
        if let first = samples.firstIndex(where: { $0.t >= cutoff }), first > 0 {
            samples.removeFirst(first)
        }
    }

    public mutating func reset() { samples.removeAll() }

    /// True when samples span at least `window` seconds and all lie within `tolerance` degrees.
    public func isStable(now: Double, window: Double = 0.7, tolerance: Double = 2.0) -> Bool {
        guard let first = samples.first, now - first.t >= window else { return false }
        var lo = Double.infinity, hi = -Double.infinity
        for s in samples.reversed() {
            if now - s.t > window { break }
            lo = min(lo, s.angle); hi = max(hi, s.angle)
        }
        return hi - lo <= tolerance
    }

    /// How long (seconds) the angle has stayed within `tolerance` of the latest reading.
    public func stableDuration(now: Double, tolerance: Double = 2.5) -> Double {
        guard let last = samples.last else { return 0 }
        var earliest = last.t
        for s in samples.reversed() {
            if abs(s.angle - last.angle) > tolerance { break }
            earliest = s.t
        }
        return max(0, now - earliest)
    }

    /// Degrees per second over the trailing `window` (negative = closing).
    public func velocity(now: Double, window: Double = 0.35) -> Double {
        guard let last = samples.last else { return 0 }
        var ref: Sample?
        for s in samples.reversed() where last.t - s.t >= window * 0.5 {
            ref = s
            if last.t - s.t >= window { break }
        }
        guard let r = ref, last.t > r.t else { return 0 }
        return (last.angle - r.angle) / (last.t - r.t)
    }

    /// Median of the samples within `window` seconds (robust "current" angle).
    public func median(now: Double, window: Double = 0.5) -> Double? {
        let vals = samples.reversed().prefix { now - $0.t <= window }.map(\.angle).sorted()
        guard !vals.isEmpty else { return latest }
        return vals[vals.count / 2]
    }
}
