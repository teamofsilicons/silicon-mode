import Foundation
import IOKit
import IOKit.hid

/// Reads the MacBook lid-angle sensor (Apple HID device VID 0x05AC / PID 0x8104,
/// Sensor page 0x20, Orientation usage 0x8A, feature report 1 → little-endian degrees).
/// Works on 2019 16" MBP and Apple-silicon MacBook Pro/Air models (verified on MacBookPro18,1).
public final class LidSensor: @unchecked Sendable {
    public enum Availability: Equatable, Sendable {
        case available
        case vendorInterfaceOnly
        case notFound
    }

    private let lock = NSLock()
    private var device: IOHIDDevice?
    private var isOpen = false
    public private(set) var availability: Availability = .notFound
    public let modelIdentifier: String

    private static let opts = IOOptionBits(kIOHIDOptionsTypeNone)

    public init() {
        modelIdentifier = Self.readModel()
        probe()
    }

    deinit { close() }

    /// Re-scan for the sensor (e.g. after wake if reads start failing).
    public func probe() {
        lock.lock(); defer { lock.unlock() }
        closeLocked()
        device = nil
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, Self.opts)
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: 0x05AC,
            kIOHIDProductIDKey: 0x8104,
        ] as CFDictionary)
        guard IOHIDManagerOpen(manager, Self.opts) == kIOReturnSuccess else {
            availability = .notFound
            return
        }
        defer { IOHIDManagerClose(manager, Self.opts) }
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        var sawVendor = false
        for d in devices {
            let page = IOHIDDeviceGetProperty(d, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? -1
            let usage = IOHIDDeviceGetProperty(d, kIOHIDPrimaryUsageKey as CFString) as? Int ?? -1
            if page == 0x20 && usage == 0x8A {
                if Self.read(d, openFirst: true) != nil {
                    device = d
                    availability = .available
                    return
                }
            } else {
                sawVendor = true
            }
        }
        availability = sawVendor ? .vendorInterfaceOnly : .notFound
    }

    /// Current lid angle in degrees, or nil if unavailable.
    public func readAngle() -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard let d = device else { return nil }
        if !isOpen {
            guard IOHIDDeviceOpen(d, Self.opts) == kIOReturnSuccess else { return nil }
            isOpen = true
        }
        return Self.read(d, openFirst: false)
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        closeLocked()
    }

    private func closeLocked() {
        if isOpen, let d = device { IOHIDDeviceClose(d, Self.opts) }
        isOpen = false
    }

    private static func read(_ d: IOHIDDevice, openFirst: Bool) -> Double? {
        if openFirst {
            guard IOHIDDeviceOpen(d, opts) == kIOReturnSuccess else { return nil }
        }
        defer { if openFirst { IOHIDDeviceClose(d, opts) } }
        var report = [UInt8](repeating: 0, count: 8)
        var len = CFIndex(report.count)
        let r = IOHIDDeviceGetReport(d, kIOHIDReportTypeFeature, 1, &report, &len)
        guard r == kIOReturnSuccess, len >= 3 else { return nil }
        let raw = UInt16(report[2]) << 8 | UInt16(report[1])
        let angle = Double(raw)
        guard angle >= 0, angle <= 360 else { return nil }
        return angle
    }

    private static func readModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buf = [UInt8](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(decoding: buf.prefix { $0 != 0 }, as: UTF8.self)
    }
}
