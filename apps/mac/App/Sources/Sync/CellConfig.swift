import Foundation
import CryptoKit
import SystemConfiguration

/// The Silicon Mode cell (backend). Contract: docs/BACKEND.md.
enum CellConfig {
    static let baseURL = URL(string: "https://silicon-mode.cells.teamofsilicons.com")!
    /// Publishable key: public, safe to ship. Required (`apikey`) on every REST call.
    static let publishableKey = "cs_publishable_59pEz0JOT9tBU-XxYS_dmDkiY1yUxmhXjKpNP-gzdVk"
    static let appID = "silicon-mode"
    static let realtimeURL = URL(string: "wss://silicon-mode.cells.teamofsilicons.com/realtime/v1/websocket")!

    /// Loopback sign-in: the cell redirects the browser here with the tokens in the fragment.
    /// Must match the cell's `redirect_urls` exactly (port included).
    static let loopbackPort: UInt16 = 47291
    static let loopbackOrigin = "http://127.0.0.1:47291"
    static let loopbackRedirect = "http://127.0.0.1:47291/auth/callback"
    /// Fallback when the loopback port is taken: the web bounce page forwards the fragment to
    /// `ai.tos.mode://auth/callback#…` (AppDelegate → AccountManager.handleCallback).
    static let bounceRedirect = "https://mode.teamofsilicons.com/auth/mac"

    static func loopbackRedirect(port: UInt16) -> String {
        port == loopbackPort ? loopbackRedirect : "http://127.0.0.1:\(port)/auth/callback"
    }

    /// Where the app sends the browser first. The loopback start page moves the per-attempt flow key
    /// from this fragment into the tab's sessionStorage, then continues to the cell's hosted sign-in;
    /// the callback page sends it back, which ties the tokens to the tab this Mac opened.
    static func loopbackStartURL(port: UInt16 = loopbackPort, flowKey: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)/auth/start#\(flowKey)")!
    }
    static let urlScheme = "ai.tos.mode"

    /// Keychain item holding the cell session (+ cached profile).
    static let keychainService = "ai.tos.mode.session"

    /// Hosted cell sign-in (token mode).
    static func signInURL(redirectTo: String) -> URL {
        var c = URLComponents(url: baseURL.appending(path: "auth/sign-in"), resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "redirect_to", value: redirectTo),
            URLQueryItem(name: "session", value: "token"),
            URLQueryItem(name: "app", value: appID),
        ]
        // `+`/`:`/`/` inside the value must be percent-encoded for an exact redirect match.
        c.percentEncodedQuery = c.percentEncodedQuery?
            .replacingOccurrences(of: ":", with: "%3A")
            .replacingOccurrences(of: "/", with: "%2F")
        return c.url!
    }
}

// MARK: - Stable ids

/// Deterministic, lowercase ids so every client derives the same row ids (docs/BACKEND.md §Ids).
enum SyncIDs {
    /// Silicon Mode's UUIDv5 namespace.
    static let namespace = UUID(uuidString: "c1e9e86e-7372-42ea-97e5-044b6f7cf2b0")!

    /// `agent_sessions.id` = UUIDv5(ns, "<device_id>|<provider>|<provider_session_id>"), with the
    /// provider session id exactly as sent (`providerSessionID(_:)`).
    static func session(deviceID: String, provider: String, nativeID: String) -> String {
        uuidV5(namespace, "\(deviceID.lowercased())|\(provider)|\(providerSessionID(nativeID))")
    }

    /// `agent_sessions.provider_session_id` as sent. Opaque provider ids (uuids, `ses_…`, `pid-42`) go
    /// as they are. Anything else (some providers build ids from the cwd: Aider `<git root>#<start>`,
    /// Kiro `cwd:<path>`), or anything longer than the column allows, becomes `h:<sha256 hex>` of the
    /// whole id: still unique and stable, but it can't carry a path or other local detail off the Mac.
    static func providerSessionID(_ nativeID: String) -> String {
        let scalars = nativeID.unicodeScalars
        let plain = !scalars.isEmpty && scalars.count <= 200 && scalars.allSatisfy { plainIDScalars.contains($0) }
        return plain ? nativeID : "h:" + CellClient.sha256Hex(nativeID)
    }

    private static let plainIDScalars = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:=+-")

    /// `questions.id` = UUIDv5(ns, "<device_id>|q|<local question id>").
    static func question(deviceID: String, localID: String) -> String {
        uuidV5(namespace, "\(deviceID.lowercased())|q|\(localID)")
    }

    /// RFC 4122 §4.3 name-based UUID (SHA-1), lowercase.
    static func uuidV5(_ ns: UUID, _ name: String) -> String {
        var bytes = withUnsafeBytes(of: ns.uuid) { Array($0) }
        bytes.append(contentsOf: Array(name.utf8))
        var h = Array(Insecure.SHA1.hash(data: bytes)).prefix(16).map { $0 }
        h[6] = (h[6] & 0x0F) | 0x50
        h[8] = (h[8] & 0x3F) | 0x80
        let u = UUID(uuid: (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7],
                            h[8], h[9], h[10], h[11], h[12], h[13], h[14], h[15]))
        return u.uuidString.lowercased()
    }

    /// Schema: provider ~ '^[a-z0-9_.:-]{1,64}$'. "claude-code" → "claude_code".
    static func wireProvider(_ id: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_.:")
        let mapped = id.lowercased().replacingOccurrences(of: "-", with: "_").map { allowed.contains($0) ? $0 : "_" }
        let s = String(mapped.prefix(64))
        return s.isEmpty ? "unknown" : s
    }
}

// MARK: - Time

enum SyncTime {
    private static let fmt = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)
    private static let fmtWhole = Date.ISO8601FormatStyle(timeZone: .gmt)
    static func iso(_ d: Date) -> String { d.formatted(fmt) }
    static func isoWhole(_ d: Date) -> String { d.formatted(fmtWhole) }
    static func parse(_ s: String) -> Date? {
        (try? fmt.parse(s)) ?? (try? fmtWhole.parse(s)) ?? (try? Date.ISO8601FormatStyle(timeZone: .gmt).parse(s))
    }
}

// MARK: - This Mac

struct SyncDeviceInfo: Sendable, Equatable {
    var name: String
    var model: String?
    var osVersion: String
    var appVersion: String
    var timezone: String

    /// Cheap, non-blocking (no DNS: SCDynamicStore for the computer name).
    static func current() -> SyncDeviceInfo {
        let name = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return SyncDeviceInfo(
            name: String(name.prefix(120)),
            model: sysctlString("hw.model").map { String($0.prefix(80)) },
            osVersion: "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            appVersion: appVersion,
            timezone: String(TimeZone.current.identifier.prefix(64))
        )
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String
        return String((build.map { "\(short) (\($0))" } ?? short).prefix(40))
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

// MARK: - Small utilities

/// Lock-protected box for values shared across isolation domains.
final class SyncLock<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

enum SyncLog {
    static func info(_ s: @autoclosure () -> String) {
        #if DEBUG
        NSLog("SiliconMode.sync: %@", s())
        #elseif SYNC_HARNESS
        if ProcessInfo.processInfo.environment["SYNC_DEBUG"] != nil { print("    · \(s())") }
        #endif
    }
    static func error(_ s: @autoclosure () -> String) { NSLog("SiliconMode.sync: %@", s()) }
}

extension String {
    /// Clip to at most `n` Unicode scalars (Postgres char_length counts code points).
    func clippedScalars(_ n: Int) -> String {
        if unicodeScalars.count <= n { return self }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: unicodeScalars.prefix(max(0, n - 1)))
        return String(out) + "…"
    }
}
