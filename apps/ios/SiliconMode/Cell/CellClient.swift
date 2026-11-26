import Foundation
import CryptoKit

enum CellConfig {
    static let base = URL(string: "https://silicon-mode.cells.teamofsilicons.com")!
    /// Public by design (safe to ship in apps); RLS limits every row to its owner.
    static let publishableKey = "cs_publishable_59pEz0JOT9tBU-XxYS_dmDkiY1yUxmhXjKpNP-gzdVk"
    static let realtimeURL = URL(string: "wss://silicon-mode.cells.teamofsilicons.com/realtime/v1/websocket")!
    static let website = URL(string: "https://mode.teamofsilicons.com")!
}

/// A cell session: 30-minute EdDSA access JWT + single-use rotating refresh token.
struct CellSession: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Double

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token", expiresAt = "expires_at"
    }
}

enum CellError: LocalizedError, Equatable {
    /// No session, or the cell revoked it (`cell_session_required`, `refresh_token_reuse`): sign in again.
    case signedOut
    case http(Int, String)
    case transport(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .signedOut: "You're signed out."
        case .http(let code, let msg): msg.isEmpty ? "The server answered \(code)." : msg
        case .transport(let msg): msg
        case .decoding(let msg): "Unexpected response: \(msg)"
        }
    }
}

/// Owns the cell session (Keychain) and talks to the Silicon Mode cell: PostgREST tables + RPCs,
/// `/auth/user`, `/auth/refresh`, `/auth/sign-out`. Refreshes are serialized here — one in flight at
/// a time, keyed `refresh:<sha256(refresh_token)>` so a lost response can be retried safely.
actor CellClient {
    static let shared = CellClient()
    private static let sessionAccount = "cell_session"

    private(set) var session: CellSession?
    private var inflight: Task<CellSession, any Error>?
    private var onSignedOut: (@Sendable () -> Void)?
    private let http: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpAdditionalHeaders = ["User-Agent": CellClient.userAgent]
        http = URLSession(configuration: config)
        session = Keychain.load(CellSession.self, Self.sessionAccount)
    }

    static var userAgent: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "SiliconMode-iOS/\(v)"
    }

    var hasSession: Bool { session != nil }

    func setSignedOutHandler(_ handler: @escaping @Sendable () -> Void) { onSignedOut = handler }

    func adopt(_ s: CellSession) {
        inflight?.cancel()
        inflight = nil
        session = s
        Keychain.save(s, Self.sessionAccount)
    }

    func clear() {
        inflight?.cancel()
        inflight = nil
        session = nil
        Keychain.delete(Self.sessionAccount)
    }

    // MARK: Tokens

    /// A fresh access token (refreshes when fewer than `minTTL` seconds remain).
    func accessToken(minTTL: Double = 60) async throws -> String {
        guard let s = session else { throw CellError.signedOut }
        if s.expiresAt - Date().timeIntervalSince1970 > minTTL { return s.accessToken }
        return try await refreshed(from: s).accessToken
    }

    /// Refresh now (realtime closed with 4401, or a request came back 401).
    func forceRefresh() async throws -> String {
        guard let s = session else { throw CellError.signedOut }
        return try await refreshed(from: s).accessToken
    }

    private func refreshed(from s: CellSession) async throws -> CellSession {
        if let task = inflight { return try await task.value }
        let task = Task { [http] in try await Self.performRefresh(s, http: http) }
        inflight = task
        do {
            let next = try await task.value
            if inflight == task { inflight = nil }
            if session?.refreshToken == s.refreshToken {
                session = next
                Keychain.save(next, Self.sessionAccount)
            }
            return session ?? next
        } catch {
            if inflight == task { inflight = nil }
            if (error as? CellError) == .signedOut, session?.refreshToken == s.refreshToken {
                session = nil
                Keychain.delete(Self.sessionAccount)
                onSignedOut?()
            }
            throw error
        }
    }

    private static func performRefresh(_ s: CellSession, http: URLSession) async throws -> CellSession {
        var r = URLRequest(url: CellConfig.base.appending(path: "auth/refresh"))
        r.httpMethod = "POST"
        let digest = SHA256.hash(data: Data(s.refreshToken.utf8)).map { String(format: "%02x", $0) }.joined()
        r.setValue("refresh:\(digest)", forHTTPHeaderField: "Idempotency-Key")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.httpBody = try JSONEncoder().encode(["refresh_token": s.refreshToken])
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await http.data(for: r) } catch { throw CellError.transport(error.localizedDescription) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 200 {
            do { return try JSONDecoder().decode(CellSession.self, from: data) } catch { throw CellError.decoding("refresh") }
        }
        if code == 401 || code == 403 || (code == 400 && Self.errorCode(data).map(Self.isSessionGone) == true) {
            throw CellError.signedOut
        }
        throw CellError.http(code, Self.message(data))
    }

    private static func isSessionGone(_ code: String) -> Bool {
        ["cell_session_required", "refresh_token_reuse", "invalid_refresh_token", "session_revoked"].contains(code)
    }

    // MARK: Requests

    /// GET a PostgREST table/RPC path, e.g. `get("rest/v1/devices", ["select": "*", "kind": "eq.mac"])`.
    func get<T: Decodable>(_ path: String, _ query: KeyValuePairs<String, String> = [:], as type: T.Type,
                           decoder: JSONDecoder = CellJSON.decoder) async throws -> T {
        let data = try await send(method: "GET", path: path, query: Array(query).map { ($0.key, $0.value) }, body: nil)
        do { return try decoder.decode(T.self, from: data) } catch { throw CellError.decoding("\(path): \(error)") }
    }

    func rpc<T: Decodable>(_ fn: String, _ args: [String: JSONValue], as type: T.Type) async throws -> T {
        let body = try JSONEncoder().encode(args)
        let data = try await send(method: "POST", path: "rest/v1/rpc/\(fn)", query: [], body: body)
        do { return try CellJSON.decoder.decode(T.self, from: data) } catch { throw CellError.decoding("\(fn): \(error)") }
    }

    func patch(_ path: String, _ query: KeyValuePairs<String, String>, body: [String: JSONValue]) async throws {
        _ = try await send(method: "PATCH", path: path, query: Array(query).map { ($0.key, $0.value) },
                           body: try JSONEncoder().encode(body), prefer: "return=minimal")
    }

    func user() async throws -> CellUser {
        struct Envelope: Decodable { var user: CellUser }
        let data = try await send(method: "GET", path: "auth/user", query: [], body: nil)
        do { return try CellJSON.decoder.decode(Envelope.self, from: data).user } catch { throw CellError.decoding("user") }
    }

    /// Revokes the session on the cell (best effort) and forgets it locally.
    func signOut() async {
        if let s = session {
            var r = URLRequest(url: CellConfig.base.appending(path: "auth/sign-out"))
            r.httpMethod = "POST"
            r.setValue("Bearer \(s.accessToken)", forHTTPHeaderField: "Authorization")
            r.setValue(CellConfig.publishableKey, forHTTPHeaderField: "apikey")
            _ = try? await http.data(for: r)
        }
        clear()
    }

    private func send(method: String, path: String, query: [(String, String)], body: Data?, prefer: String? = nil,
                      retried: Bool = false) async throws -> Data {
        let token = try await accessToken()
        var url = CellConfig.base.appending(path: path)
        if !query.isEmpty {
            var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            c.percentEncodedQuery = query.map { "\(Self.encode($0.0))=\(Self.encode($0.1))" }.joined(separator: "&")
            url = c.url!
        }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue(CellConfig.publishableKey, forHTTPHeaderField: "apikey")
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let prefer { r.setValue(prefer, forHTTPHeaderField: "Prefer") }
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await http.data(for: r) } catch { throw CellError.transport(error.localizedDescription) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(code) { return data }
        if code == 401, !retried {
            _ = try await forceRefresh()
            return try await send(method: method, path: path, query: query, body: body, prefer: prefer, retried: true)
        }
        throw CellError.http(code, Self.message(data))
    }

    private static let queryAllowed: CharacterSet = {
        var s = CharacterSet.urlQueryAllowed
        s.remove(charactersIn: "&+=#?")
        return s
    }()

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? s
    }

    private static func errorCode(_ data: Data) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let e = o["error"] as? [String: Any] { return e["code"] as? String }
        return o["code"] as? String
    }

    private static func message(_ data: Data) -> String {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data.prefix(200), encoding: .utf8) ?? ""
        }
        if let e = o["error"] as? [String: Any] { return (e["message"] as? String) ?? (e["code"] as? String) ?? "" }
        return (o["message"] as? String) ?? ""
    }
}
