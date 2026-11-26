import Foundation
import Security

/// A cell session (token mode): 30-min EdDSA access JWT + single-use rotating `csr_…` refresh token.
struct CellSession: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date

    /// Refresh when fewer than `margin` seconds remain (docs: 60 s).
    func needsRefresh(now: Date = Date(), margin: TimeInterval = 60) -> Bool {
        expiresAt.timeIntervalSince(now) < margin
    }

    /// Unix `exp` from the JWT payload (fallback when `expires_at` is missing).
    static func jwtExpiry(_ jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = obj["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}

/// `GET /auth/user` → `{"user":{uuid,kind,id,display_name,pfp_url,app,…}}`.
struct CellUser: Codable, Sendable, Equatable {
    var uuid: String
    var id: String
    var kind: String?
    var displayName: String
    var pfpURL: String?

    enum CodingKeys: String, CodingKey {
        case uuid, id, kind
        case displayName = "display_name"
        case pfpURL = "pfp_url"
    }

    init(uuid: String, id: String, kind: String?, displayName: String, pfpURL: String?) {
        self.uuid = uuid.lowercased(); self.id = id; self.kind = kind; self.displayName = displayName; self.pfpURL = pfpURL
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid).lowercased()
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        kind = try? c.decode(String.self, forKey: .kind)
        let dn = (try? c.decode(String.self, forKey: .displayName)) ?? ""
        displayName = dn.isEmpty ? id : dn
        pfpURL = try? c.decode(String.self, forKey: .pfpURL)
    }
}

/// `/auth/refresh` and `/auth/silicon` response.
struct CellTokenResponse: Decodable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Double?
    var expiresIn: Double?
    var user: CellUser?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token"
        case expiresAt = "expires_at", expiresIn = "expires_in", user
    }

    var session: CellSession {
        let exp = expiresAt.map { Date(timeIntervalSince1970: $0) }
            ?? expiresIn.map { Date().addingTimeInterval($0) }
            ?? CellSession.jwtExpiry(accessToken)
            ?? Date().addingTimeInterval(25 * 60)
        return CellSession(accessToken: accessToken, refreshToken: refreshToken, expiresAt: exp)
    }
}

/// What we keep in the Keychain: the session and the last known profile (instant restore).
struct CellStoredAuth: Codable, Sendable, Equatable {
    var session: CellSession
    var user: CellUser?
}

// MARK: - Callback parsing

/// Parses the sign-in result the cell appends to `redirect_to`:
/// `#access_token=…&refresh_token=csr_…&expires_at=<unix>` or `?error=access_denied`.
enum CallbackPayload: Equatable, Sendable {
    case tokens(CellSession)
    case denied(String)
    case invalid

    static func parse(fragment: String?, query: String?) -> CallbackPayload {
        let f = params(fragment), q = params(query)
        if let err = f["error"] ?? q["error"] {
            let desc = f["error_description"] ?? q["error_description"]
            return .denied(desc.map { "\(err): \($0)" } ?? err)
        }
        guard let access = f["access_token"] ?? q["access_token"], !access.isEmpty,
              let refresh = f["refresh_token"] ?? q["refresh_token"], !refresh.isEmpty else { return .invalid }
        let exp = (f["expires_at"] ?? q["expires_at"]).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
            ?? (f["expires_in"] ?? q["expires_in"]).flatMap(Double.init).map { Date().addingTimeInterval($0) }
            ?? CellSession.jwtExpiry(access)
            ?? Date().addingTimeInterval(25 * 60)
        return .tokens(CellSession(accessToken: access, refreshToken: refresh, expiresAt: exp))
    }

    /// `ai.tos.mode://auth/callback#…` (or `?…`).
    static func parse(url: URL) -> CallbackPayload {
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return parse(fragment: c?.percentEncodedFragment, query: c?.percentEncodedQuery)
    }

    private static func params(_ s: String?) -> [String: String] {
        guard var s, !s.isEmpty else { return [:] }
        if s.hasPrefix("#") || s.hasPrefix("?") { s.removeFirst() }
        var c = URLComponents()
        c.percentEncodedQuery = s.replacingOccurrences(of: "+", with: "%2B")
        var out: [String: String] = [:]
        for item in c.queryItems ?? [] { if let v = item.value { out[item.name] = v } }
        return out
    }
}

// MARK: - Storage

protocol CellSessionStore: Sendable {
    func load() -> CellStoredAuth?
    func save(_ auth: CellStoredAuth) throws
    func clear()
}

/// Generic-password Keychain item (service `ai.tos.mode.session`). Only this app reads it.
final class KeychainSessionStore: CellSessionStore {
    let service: String
    let account: String

    init(service: String = CellConfig.keychainService, account: String = CellConfig.appID) {
        self.service = service; self.account = account
    }

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func load() -> CellStoredAuth? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(CellStoredAuth.self, from: data)
    }

    func save(_ auth: CellStoredAuth) throws {
        let data = try JSONEncoder().encode(auth)
        let upd = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if upd == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Silicon Mode account session"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let s = SecItemAdd(add as CFDictionary, nil)
            guard s == errSecSuccess else { throw CellError.keychain(s) }
        } else if upd != errSecSuccess {
            throw CellError.keychain(upd)
        }
    }

    func clear() { SecItemDelete(base as CFDictionary) }
}

/// In-memory store (tests, previews).
final class MemorySessionStore: CellSessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: CellStoredAuth?
    init(_ v: CellStoredAuth? = nil) { value = v }
    func load() -> CellStoredAuth? { lock.lock(); defer { lock.unlock() }; return value }
    func save(_ auth: CellStoredAuth) throws { lock.lock(); value = auth; lock.unlock() }
    func clear() { lock.lock(); value = nil; lock.unlock() }
}
