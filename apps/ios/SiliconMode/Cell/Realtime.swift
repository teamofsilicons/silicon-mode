import Foundation
import Network

/// A table-change subscription (docs/research/cells.md §5).
struct RealtimeSubscription: Equatable, Sendable {
    var id: String
    var table: String
    var events: [String]? = nil
    var filters: [Filter] = []

    struct Filter: Equatable, Sendable {
        var column: String
        var op: String = "eq"
        var value: String
    }

    func command(after cursor: Int64?) -> [String: Any] {
        var o: [String: Any] = ["type": "subscribe", "id": id, "schema": "public", "table": table]
        if let events { o["events"] = events }
        if !filters.isEmpty { o["filters"] = filters.map { ["column": $0.column, "op": $0.op, "value": $0.value] } }
        if let cursor { o["after"] = cursor }
        return o
    }
}

/// One row change delivered by the cell.
struct RealtimeChange: Sendable {
    var subscription: String
    var table: String
    var operation: String
    var new: Data?
    var old: Data?

    func decode<T: Decodable>(_ type: T.Type, old useOld: Bool = false, decoder: JSONDecoder = CellJSON.decoder) -> T? {
        guard let d = useOld ? old : new else { return nil }
        return try? decoder.decode(T.self, from: d)
    }
}

/// The cell's realtime WebSocket: authenticate within 5 s, table subscriptions (RLS applied),
/// cursors for resume, ping every 25 s, exponential backoff 0.5 s → 30 s with jitter, one token
/// refresh on 4401, reconnect on network changes, de-duplication on `event_id`.
@MainActor
final class RealtimeClient {
    enum Status: Equatable, Sendable {
        case idle, connecting, live, waiting, stopped
    }

    var onChange: ((RealtimeChange) -> Void)?
    var onStatus: ((Status) -> Void)?
    /// A subscription's cursor expired (history is kept 24 h): re-read through REST.
    var onResync: ((String) -> Void)?

    private(set) var status: Status = .idle {
        didSet { if status != oldValue { onStatus?(status) } }
    }

    private var desired: [String: RealtimeSubscription] = [:]
    private var cursors: [String: Int64] = [:]
    private var socket: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    private var wanted = false
    private var failures = 0
    private var lastReceived = Date()
    private var seen: [String] = []
    private var seenSet: Set<String> = []
    private let path = NWPathMonitor()
    private var pathOK = true
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpAdditionalHeaders = ["User-Agent": CellClient.userAgent]
        return URLSession(configuration: c)
    }()

    private static let pingEvery: Duration = .seconds(25)
    private static let staleAfter: TimeInterval = 70

    init() {
        path.pathUpdateHandler = { [weak self] p in
            let ok = p.status == .satisfied
            Task { @MainActor in self?.networkChanged(ok) }
        }
        path.start(queue: DispatchQueue(label: "ai.tos.mode.ios.path"))
    }

    // MARK: Control

    /// Starts the socket, or (if it is already wanted) makes sure it is healthy.
    func start() {
        guard !wanted else { ensureConnected(); return }
        wanted = true
        failures = 0
        restart()
    }

    func stop() {
        wanted = false
        loop?.cancel()
        loop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        status = .idle
    }

    /// Foreground / pull-to-refresh: reconnect unless the socket is demonstrably healthy.
    func ensureConnected() {
        guard wanted else { return }
        if status == .connecting { return }
        if status == .live, Date().timeIntervalSince(lastReceived) < Self.staleAfter { return }
        failures = 0
        restart()
    }

    /// Replaces the set of subscriptions. Changed subscriptions lose their cursor (new filter).
    func setSubscriptions(_ subs: [RealtimeSubscription]) {
        let next = Dictionary(subs.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        let old = desired
        desired = next
        for (id, sub) in old where next[id] != sub {
            cursors[id] = nil
            if status == .live { send(["type": "unsubscribe", "id": id]) }
        }
        guard status == .live else { return }
        for (id, sub) in next where old[id] != sub {
            send(sub.command(after: cursors[id]))
        }
    }

    // MARK: Loop

    private func networkChanged(_ ok: Bool) {
        let was = pathOK
        pathOK = ok
        if ok, !was || status != .live { ensureConnected() }
    }

    private func restart() {
        loop?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        loop = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        while !Task.isCancelled, wanted {
            status = .connecting
            let outcome = await connectOnce()
            if Task.isCancelled || !wanted { return }
            switch outcome {
            case .stop:
                status = .stopped
                wanted = false
                return
            case .reauth:
                // Credentials expired or revoked: refresh once, then reconnect with saved cursors.
                do { _ = try await CellClient.shared.forceRefresh(); failures = 0 } catch {
                    if (error as? CellError) == .signedOut { status = .stopped; wanted = false; return }
                    failures += 1
                }
            case .quota:
                failures = max(failures, 6)
            case .retry(let wasLive):
                failures = wasLive ? 1 : failures + 1
            }
            status = .waiting
            let base = min(30.0, 0.5 * pow(2.0, Double(max(0, failures - 1))))
            try? await Task.sleep(for: .seconds(base * Double.random(in: 0.8...1.2)))
        }
    }

    private enum Outcome { case retry(wasLive: Bool), reauth, quota, stop }

    private func connectOnce() async -> Outcome {
        let token: String
        do { token = try await CellClient.shared.accessToken() } catch {
            return (error as? CellError) == .signedOut ? .stop : .retry(wasLive: false)
        }
        if Task.isCancelled { return .retry(wasLive: false) }
        var req = URLRequest(url: CellConfig.realtimeURL, timeoutInterval: 20)
        req.setValue(CellClient.userAgent, forHTTPHeaderField: "User-Agent")
        let ws = session.webSocketTask(with: req)
        ws.maximumMessageSize = 1 << 20
        socket = ws
        ws.resume()
        lastReceived = Date()
        // Credentials go in the first frame, never in the URL.
        let auth: [String: Any] = ["type": "authenticate", "apikey": CellConfig.publishableKey, "access_token": token]
        guard let authText = Self.json(auth) else { return .retry(wasLive: false) }
        do { try await ws.send(.string(authText)) } catch { return .retry(wasLive: false) }

        var live = false
        let keepalive = Task { [weak self] in
            var nonce = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pingEvery)
                guard let self, !Task.isCancelled else { return }
                if Date().timeIntervalSince(self.lastReceived) > Self.staleAfter {
                    ws.cancel(with: .goingAway, reason: nil)
                    return
                }
                nonce += 1
                try? await ws.send(.string(#"{"type":"ping","nonce":\#(nonce)}"#))
            }
        }
        defer { keepalive.cancel() }

        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do { message = try await ws.receive() } catch {
                switch ws.closeCode.rawValue {
                case 4401: return .reauth
                case 4404, 1008: return .stop
                case 4429: return .quota
                default:
                    if let http = ws.response as? HTTPURLResponse, http.statusCode == 401 { return .reauth }
                    return .retry(wasLive: live)
                }
            }
            lastReceived = Date()
            let data: Data
            switch message {
            case .string(let s): data = Data(s.utf8)
            case .data(let d): data = d
            @unknown default: continue
            }
            guard let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = frame["type"] as? String else { continue }
            switch type {
            case "ready":
                live = true
                failures = 0
                status = .live
                for sub in desired.values { send(sub.command(after: cursors[sub.id])) }
            case "subscribed":
                if let id = frame["id"] as? String, let c = Self.int64(frame["cursor"]) {
                    cursors[id] = max(cursors[id] ?? 0, c)
                }
            case "change":
                handleChange(frame)
            case "error":
                let code = frame["code"] as? String ?? ""
                if code == "cursor_expired", let id = frame["id"] as? String {
                    cursors[id] = nil
                    if let sub = desired[id] { send(sub.command(after: nil)) }
                    onResync?(id)
                } else if code == "realtime_rate_limit" {
                    ws.cancel(with: .goingAway, reason: nil)
                    return .quota
                }
            default:
                break // pong, ack
            }
        }
        ws.cancel(with: .goingAway, reason: nil)
        return .retry(wasLive: live)
    }

    private func handleChange(_ frame: [String: Any]) {
        guard let sub = frame["subscription"] as? String, desired[sub] != nil else { return }
        if let c = Self.int64(frame["cursor"]) { cursors[sub] = max(cursors[sub] ?? 0, c) }
        if let eid = frame["event_id"] as? String {
            if seenSet.contains(eid) { return }
            seenSet.insert(eid)
            seen.append(eid)
            if seen.count > 600 { seenSet.remove(seen.removeFirst()) }
        }
        func blob(_ k: String) -> Data? {
            guard let o = frame[k], !(o is NSNull) else { return nil }
            return try? JSONSerialization.data(withJSONObject: o)
        }
        onChange?(RealtimeChange(subscription: sub, table: frame["table"] as? String ?? "",
                                 operation: frame["operation"] as? String ?? "", new: blob("new"), old: blob("old")))
    }

    private func send(_ object: [String: Any]) {
        guard let ws = socket, let text = Self.json(object) else { return }
        Task { try? await ws.send(.string(text)) }
    }

    private static func json(_ o: [String: Any]) -> String? {
        guard let d = try? JSONSerialization.data(withJSONObject: o) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private static func int64(_ v: Any?) -> Int64? {
        if let n = v as? NSNumber { return n.int64Value }
        if let s = v as? String { return Int64(s) }
        return nil
    }
}
