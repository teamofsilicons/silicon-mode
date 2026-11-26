import Foundation
import CryptoKit

enum CellError: Error, Equatable, CustomStringConvertible {
    /// No session stored.
    case notSignedIn
    /// The cell rejected the session (refresh 401 / reuse / revoked): sign in again.
    case sessionEnded(String)
    /// HTTP error with the platform (`{"error":{code,message}}`) or PostgREST (`{code,message}`) body.
    case http(status: Int, code: String?, message: String?)
    /// Network / transport failure (offline, timeout, DNS…). Retryable.
    case transport(String)
    case decoding(String)
    case keychain(OSStatus)

    var description: String {
        switch self {
        case .notSignedIn: "Not signed in"
        case .sessionEnded(let c): "Session ended (\(c))"
        case .http(let s, let c, let m): "HTTP \(s) \(c ?? "") \(m ?? "")"
        case .transport(let m): "Network: \(m)"
        case .decoding(let m): "Unexpected response: \(m)"
        case .keychain(let s): "Keychain error \(s)"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .transport: true
        case .http(let s, _, _): s == 408 || s == 425 || s == 429 || s >= 500 && s != 501
        default: false
        }
    }

    /// The database refused the data itself (PostgREST passes the SQLSTATE as `code`): class 22 (data
    /// exception: too long, bad format), class 23 (integrity: check/not-null/unique, but not 23503,
    /// which means a referenced row is gone) or 21000 (cardinality: one row twice in a statement).
    /// Resending the same rows can only fail again. Platform errors (`refresh_in_progress`, rate limits),
    /// proxies (403/404 without a SQLSTATE) and transport errors are not data errors.
    var isDataRejection: Bool {
        guard case .http(_, let code?, _) = self, code.count == 5 else { return false }
        if code == "21000" { return true }
        if code.hasPrefix("22") { return true }
        return code.hasPrefix("23") && code != "23503"
    }
    var httpStatus: Int? { if case .http(let s, _, _) = self { return s }; return nil }
    var code: String? { if case .http(_, let c, _) = self { return c }; return nil }
}

/// Owns the cell session: the one place tokens are read, refreshed and persisted.
/// - Refreshes when < 60 s remain; refreshes are serialized (one in flight) and the rotated
///   token is written to the Keychain *before* it is used.
/// - `Idempotency-Key: refresh:<sha256 hex(refresh_token)>`, so a retried (lost) refresh replays.
/// - Authed calls that get 401 refresh once and retry; a second 401 ends the session.
actor CellClient {
    static let shared = CellClient(store: KeychainSessionStore())

    let store: CellSessionStore
    private let http: URLSession
    private var auth: CellStoredAuth?
    private var loaded = false
    private var refreshTask: Task<CellSession, Error>?
    private var endedHandler: (@Sendable (String) -> Void)?
    /// Bumped whenever a different session takes over (adopt) or the session is forgotten (clear);
    /// refreshes keep it. Lets a slow sign-out tell "my session" from one adopted meanwhile.
    private(set) var generation = 0

    /// Thread-safe copy of the current session for last-chance synchronous use (app termination).
    nonisolated let mirror = SyncLock<CellSession?>(nil)

    init(store: CellSessionStore, configuration: URLSessionConfiguration? = nil) {
        self.store = store
        let cfg = configuration ?? {
            let c = URLSessionConfiguration.ephemeral
            c.httpShouldSetCookies = false
            c.httpCookieAcceptPolicy = .never
            c.requestCachePolicy = .reloadIgnoringLocalCacheData
            c.timeoutIntervalForRequest = 20
            c.timeoutIntervalForResource = 60
            c.waitsForConnectivity = false
            c.httpAdditionalHeaders = ["User-Agent": "SiliconMode-Mac/\(SyncDeviceInfo.appVersion)"]
            return c
        }()
        http = URLSession(configuration: cfg)
    }

    // MARK: Session state

    /// Called once when the cell ends the session (refresh rejected / persistent 401).
    func onSessionEnded(_ h: @escaping @Sendable (String) -> Void) { endedHandler = h }

    /// Loads the Keychain copy (once).
    @discardableResult
    func restore() -> CellStoredAuth? {
        if !loaded {
            loaded = true
            auth = store.load()
            mirror.value = auth?.session
        }
        return auth
    }

    var user: CellUser? { auth?.user }
    var hasSession: Bool { restore() != nil }
    var session: CellSession? { restore()?.session }

    /// Adopt a fresh session (sign-in). Persisted before it is used.
    func adopt(_ session: CellSession, user: CellUser? = nil) throws {
        refreshTask?.cancel(); refreshTask = nil
        let a = CellStoredAuth(session: session, user: user)
        try store.save(a)
        auth = a; loaded = true
        generation += 1
        mirror.value = session
    }

    func setUser(_ u: CellUser) {
        guard var a = auth else { return }
        a.user = u
        auth = a
        try? store.save(a)
    }

    /// Forget the session locally (Keychain + memory).
    func clear() {
        refreshTask?.cancel(); refreshTask = nil
        auth = nil; loaded = true
        generation += 1
        mirror.value = nil
        store.clear()
    }

    private func end(_ reason: String) {
        guard auth != nil else { return }
        clear()
        endedHandler?(reason)
    }

    // MARK: Tokens

    /// A valid access token, refreshing first if it is about to expire.
    func accessToken() async throws -> String {
        guard let s = restore()?.session else { throw CellError.notSignedIn }
        if !s.needsRefresh() { return s.accessToken }
        return try await refresh(from: s).accessToken
    }

    /// The server rejected `token` (401/4401): refresh unless someone already did.
    func refreshAfterRejection(of token: String) async throws -> String {
        guard let s = restore()?.session else { throw CellError.notSignedIn }
        if s.accessToken != token, !s.needsRefresh() { return s.accessToken }
        return try await refresh(from: s).accessToken
    }

    private func refresh(from s: CellSession) async throws -> CellSession {
        if let t = refreshTask { return try await t.value }
        let http = self.http
        let gen = generation
        let task = Task<CellSession, Error> {
            var attempt = 0
            while true {
                do {
                    let r = try await Self.postRefresh(http: http, refreshToken: s.refreshToken)
                    // Signed out or another account adopted while this was in flight: never write the
                    // old session back over it; hand out whatever is current instead.
                    guard self.generation == gen else {
                        guard let current = self.auth?.session else { throw CellError.notSignedIn }
                        return current
                    }
                    try self.commitRefresh(r)
                    return r.session
                } catch let e as CellError {
                    switch e {
                    case .http(let status, let code, _) where (400...403).contains(status):
                        // Only end the session this refresh was for (not one adopted meanwhile).
                        if self.generation == gen { self.end(code ?? "refresh_rejected") }
                        throw CellError.sessionEnded(code ?? "refresh_rejected")
                    case .http(409, _, _) where attempt < 3:
                        // refresh_in_progress: replay with the same key shortly.
                        attempt += 1
                        try await Task.sleep(for: .milliseconds(400 * attempt))
                    default:
                        throw e
                    }
                }
            }
        }
        refreshTask = task
        do {
            let v = try await task.value
            if refreshTask == task { refreshTask = nil }
            return v
        } catch {
            if refreshTask == task { refreshTask = nil }
            throw error
        }
    }

    /// Persist the rotated token *before* anyone uses it.
    private func commitRefresh(_ r: CellTokenResponse) throws {
        var a = auth ?? CellStoredAuth(session: r.session, user: nil)
        a.session = r.session
        if let u = r.user { a.user = u }
        do { try store.save(a) } catch {
            // Keep going in memory: a lost refresh replays under the same Idempotency-Key.
            SyncLog.error("could not persist refreshed session: \(error)")
        }
        auth = a
        mirror.value = a.session
    }

    private static func postRefresh(http: URLSession, refreshToken: String) async throws -> CellTokenResponse {
        var r = URLRequest(url: CellConfig.baseURL.appending(path: "auth/refresh"))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("refresh:\(sha256Hex(refreshToken))", forHTTPHeaderField: "Idempotency-Key")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
        let (data, status) = try await perform(http, r)
        guard (200..<300).contains(status) else { throw httpError(status, data) }
        do { return try JSONDecoder().decode(CellTokenResponse.self, from: data) } catch {
            throw CellError.decoding("refresh")
        }
    }

    static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Requests

    /// Authed request to the cell. 401 → refresh once → retry; a second 401 ends the session.
    func send(_ method: String, _ path: String, json: Data? = nil, query: [URLQueryItem]? = nil,
              prefer: String? = nil, apikey: Bool = true) async throws -> Data {
        var token = try await accessToken()
        let gen = generation
        var (data, status) = try await raw(method, path, json: json, query: query, prefer: prefer, apikey: apikey, token: token)
        if status == 401 {
            token = try await refreshAfterRejection(of: token)
            (data, status) = try await raw(method, path, json: json, query: query, prefer: prefer, apikey: apikey, token: token)
            if status == 401 {
                let code = Self.httpError(status, data).code ?? "unauthorized"
                if generation == gen { end(code) }   // not a session adopted while this was in flight
                throw CellError.sessionEnded(code)
            }
        }
        guard (200..<300).contains(status) else { throw Self.httpError(status, data) }
        return data
    }

    /// `POST /rest/v1/rpc/<fn>` with named arguments.
    func rpc(_ fn: String, _ args: Data) async throws -> Data {
        try await send("POST", "rest/v1/rpc/\(fn)", json: args)
    }

    func fetchUser() async throws -> CellUser {
        let data = try await send("GET", "auth/user", apikey: false)
        let u = try Self.decodeUser(data)
        setUser(u)
        return u
    }

    /// Who an access token belongs to, without storing or using it for anything else (sign-in checks
    /// the tokens from a redirect before they replace anything).
    func fetchUser(accessToken: String) async throws -> CellUser {
        let (data, status) = try await raw("GET", "auth/user", json: nil, query: nil, prefer: nil, apikey: false, token: accessToken)
        guard (200..<300).contains(status) else { throw Self.httpError(status, data) }
        return try Self.decodeUser(data)
    }

    private static func decodeUser(_ data: Data) throws -> CellUser {
        struct Wrap: Decodable { var user: CellUser }
        guard let u = try? JSONDecoder().decode(Wrap.self, from: data).user else { throw CellError.decoding("auth/user") }
        return u
    }

    /// `POST /auth/sign-out` for the session stored *now*, then forget it locally.
    /// - The access token is refreshed first when it has expired (the cell rejects an expired JWT,
    ///   and the revocation would silently not happen), and a 401 refreshes once and retries.
    /// - Only that session is forgotten: if another one was adopted while this ran, it stays.
    @discardableResult
    func signOut() async -> Bool {
        guard restore() != nil else { return true }
        let gen = generation
        var revoked = false
        do {
            var token = try await accessToken()
            if generation == gen {
                var (data, status) = try await raw("POST", "auth/sign-out", json: nil, query: nil, prefer: nil, apikey: false, token: token)
                if status == 401, generation == gen {
                    token = try await refreshAfterRejection(of: token)
                    if generation == gen {
                        (data, status) = try await raw("POST", "auth/sign-out", json: nil, query: nil, prefer: nil, apikey: false, token: token)
                    }
                }
                revoked = (200..<300).contains(status)
                if !revoked { SyncLog.error("sign-out not confirmed by the cell: \(Self.httpError(status, data))") }
            }
        } catch CellError.sessionEnded {
            revoked = true   // the cell had already ended it
        } catch {
            SyncLog.error("sign-out could not reach the cell: \(error)")
        }
        if generation == gen { clear() }
        return revoked
    }

    private func raw(_ method: String, _ path: String, json: Data?, query: [URLQueryItem]?, prefer: String?,
                     apikey: Bool, token: String?) async throws -> (Data, Int) {
        var url = CellConfig.baseURL.appending(path: path)
        if let query, !query.isEmpty { url.append(queryItems: query) }
        var r = URLRequest(url: url)
        r.httpMethod = method
        if apikey { r.setValue(CellConfig.publishableKey, forHTTPHeaderField: "apikey") }
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json {
            r.httpBody = json
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let prefer { r.setValue(prefer, forHTTPHeaderField: "Prefer") }
        return try await Self.perform(http, r)
    }

    private static func perform(_ http: URLSession, _ r: URLRequest) async throws -> (Data, Int) {
        do {
            let (d, resp) = try await http.data(for: r)
            return (d, (resp as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let e as URLError {
            throw CellError.transport(e.code == .notConnectedToInternet ? "offline" : "\(e.code.rawValue)")
        } catch {
            throw CellError.transport(String(describing: type(of: error)))
        }
    }

    static func httpError(_ status: Int, _ data: Data) -> CellError {
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let e = obj?["error"] as? [String: Any] {
            return .http(status: status, code: e["code"] as? String, message: e["message"] as? String)
        }
        return .http(status: status, code: obj?["code"] as? String, message: obj?["message"] as? String)
    }

    // MARK: Test hooks

    #if DEBUG || SYNC_HARNESS
    /// Make the next authed call fail with 401 (exercises refresh-and-retry).
    func debugCorruptAccessToken() {
        guard var a = auth else { return }
        a.session.accessToken += "x"
        auth = a
    }
    func debugExpireSoon() {
        guard var a = auth else { return }
        a.session.expiresAt = Date().addingTimeInterval(5)
        auth = a
    }
    #endif
}
