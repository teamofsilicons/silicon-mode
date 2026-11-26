import Foundation
import CommonCrypto
import Security

/// Stores the 6-digit unlock PIN as a salted PBKDF2-SHA256 hash in the login Keychain,
/// with attempt throttling. The PIN itself is never stored.
public final class PinVault: @unchecked Sendable {
    public struct Record: Codable, Equatable, Sendable {
        public var salt: Data
        public var hash: Data
        public var iterations: UInt32
    }

    public enum VerifyResult: Equatable, Sendable {
        case ok
        case wrong(attemptsLeft: Int)
        case throttled(retryAfter: TimeInterval)
        case notSet
    }

    public let service: String
    public let account: String
    private let lock = NSLock()
    private var failures = 0
    private var lockedUntil: Date?
    /// Overridable storage (tests use memory).
    private let store: PinStore

    public static let pinLength = 6
    public var maxAttemptsBeforeThrottle = 5

    public init(service: String = "com.teamofsilicons.mode.pin", account: String = "unlock", store: PinStore? = nil) {
        self.service = service
        self.account = account
        self.store = store ?? KeychainPinStore(service: service, account: account)
    }

    public var isSet: Bool { (try? store.load()) != nil }

    public static func isValidFormat(_ pin: String) -> Bool {
        pin.count == pinLength && pin.allSatisfy { $0.isASCII && $0.isNumber }
    }

    public func set(pin: String) throws {
        guard Self.isValidFormat(pin) else { throw PinError.invalidFormat }
        var salt = Data(count: 16)
        let ok = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard ok == errSecSuccess else { throw PinError.random }
        let iterations: UInt32 = 120_000
        let hash = try Self.derive(pin: pin, salt: salt, iterations: iterations)
        try store.save(Record(salt: salt, hash: hash, iterations: iterations))
        lock.lock(); failures = 0; lockedUntil = nil; lock.unlock()
    }

    public func clear() throws { try store.delete() }

    public func verify(_ pin: String, now: Date = Date()) -> VerifyResult {
        lock.lock(); defer { lock.unlock() }
        if let until = lockedUntil, now < until { return .throttled(retryAfter: until.timeIntervalSince(now)) }
        guard let rec = try? store.load() else { return .notSet }
        guard Self.isValidFormat(pin), let h = try? Self.derive(pin: pin, salt: rec.salt, iterations: rec.iterations),
              Self.constantTimeEqual(h, rec.hash) else {
            failures += 1
            if failures >= maxAttemptsBeforeThrottle {
                // 30s, 60s, 120s … capped at 10 minutes.
                let step = failures - maxAttemptsBeforeThrottle
                let delay = min(600, 30 * pow(2, Double(step)))
                lockedUntil = now.addingTimeInterval(delay)
                return .throttled(retryAfter: delay)
            }
            return .wrong(attemptsLeft: maxAttemptsBeforeThrottle - failures)
        }
        failures = 0
        lockedUntil = nil
        return .ok
    }

    static func derive(pin: String, salt: Data, iterations: UInt32) throws -> Data {
        var out = Data(count: 32)
        let pw = Array(pin.utf8)
        let status = out.withUnsafeMutableBytes { outPtr in
            salt.withUnsafeBytes { saltPtr in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     pw.map { Int8(bitPattern: $0) }, pw.count,
                                     saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                     outPtr.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        guard status == kCCSuccess else { throw PinError.derive }
        return out
    }

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[a.startIndex + i] ^ b[b.startIndex + i] }
        return diff == 0
    }
}

public enum PinError: Error { case invalidFormat, random, derive, storage(OSStatus) }

public protocol PinStore: Sendable {
    func load() throws -> PinVault.Record?
    func save(_ r: PinVault.Record) throws
    func delete() throws
}

public final class MemoryPinStore: PinStore, @unchecked Sendable {
    private var rec: PinVault.Record?
    public init() {}
    public func load() throws -> PinVault.Record? { rec }
    public func save(_ r: PinVault.Record) throws { rec = r }
    public func delete() throws { rec = nil }
}

public struct KeychainPinStore: PinStore {
    let service: String
    let account: String

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() throws -> PinVault.Record? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &out)
        if s == errSecItemNotFound { return nil }
        guard s == errSecSuccess, let data = out as? Data else { throw PinError.storage(s) }
        return try JSONDecoder().decode(PinVault.Record.self, from: data)
    }

    public func save(_ r: PinVault.Record) throws {
        let data = try JSONEncoder().encode(r)
        let upd = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if upd == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Silicon Mode unlock PIN (hashed)"
            let s = SecItemAdd(add as CFDictionary, nil)
            guard s == errSecSuccess else { throw PinError.storage(s) }
        } else if upd != errSecSuccess {
            throw PinError.storage(upd)
        }
    }

    public func delete() throws {
        let s = SecItemDelete(base as CFDictionary)
        guard s == errSecSuccess || s == errSecItemNotFound else { throw PinError.storage(s) }
    }
}
