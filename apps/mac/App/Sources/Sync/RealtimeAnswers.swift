import Foundation

/// Live `answers` INSERTs for this Mac over the cell's realtime socket (docs/research/cells.md §5).
///
/// `authenticate` → `ready` → `subscribe answers INSERT device_id=eq.<mac>` (resuming from the saved
/// cursor). Pings every 20 s; a silent socket is dropped after 60 s. Close 4401 → refresh the session
/// once and reconnect with the cursor; 4404/1008 stop; 4429 backs off; anything else reconnects with
/// exponential backoff (0.5 s … 30 s). Duplicate `event_id`s are ignored.
actor RealtimeAnswers {
    enum Status: Sendable, Equatable {
        case connecting
        case live
        case reconnecting(after: TimeInterval)
        case stopped(String)
    }

    private enum Outcome { case authExpired(String), fatal(String), quota, dropped(wasLive: Bool), cancelled }

    private let client: CellClient
    private let deviceID: String
    private var cursor: Int64?
    private let onAnswer: @Sendable (CloudAnswer) -> Void
    private let onCursor: @Sendable (Int64) -> Void
    private let onStatus: @Sendable (Status) -> Void
    /// Something may have been missed (no cursor / cursor expired): fetch unconsumed answers via REST.
    private let onResync: @Sendable () -> Void

    private let http: URLSession
    private var loop: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var lastHeard = Date()
    private var recentEventIDs: [String] = []
    private(set) var isLive = false

    var pingInterval: TimeInterval = 20
    var silenceTimeout: TimeInterval = 60

    init(client: CellClient, deviceID: String, cursor: Int64?,
         onAnswer: @escaping @Sendable (CloudAnswer) -> Void,
         onCursor: @escaping @Sendable (Int64) -> Void,
         onStatus: @escaping @Sendable (Status) -> Void,
         onResync: @escaping @Sendable () -> Void) {
        self.client = client
        self.deviceID = deviceID.lowercased()
        self.cursor = cursor
        self.onAnswer = onAnswer
        self.onCursor = onCursor
        self.onStatus = onStatus
        self.onResync = onResync
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        http = URLSession(configuration: cfg)
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { await run() }
    }

    func stop() {
        loop?.cancel(); loop = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        isLive = false
    }

    // MARK: Loop

    private func run() async {
        var backoff: TimeInterval = 0.5
        var authRetries = 0
        while !Task.isCancelled {
            switch await connectOnce() {
            case .cancelled:
                return
            case .fatal(let why):
                onStatus(.stopped(why))
                loop = nil
                return
            case .authExpired(let token):
                authRetries += 1
                do {
                    _ = try await client.refreshAfterRejection(of: token)
                } catch let e as CellError {
                    if case .sessionEnded = e { onStatus(.stopped("signed out")); loop = nil; return }
                    if case .notSignedIn = e { onStatus(.stopped("signed out")); loop = nil; return }
                    await pause(&backoff)
                    continue
                } catch { }
                if authRetries > 3 { await pause(&backoff) }   // refresh "worked" but the socket keeps rejecting
            case .quota:
                var b: TimeInterval = 60
                await pause(&b)
            case .dropped(let wasLive):
                if wasLive { backoff = 0.5; authRetries = 0 }
                await pause(&backoff)
            }
        }
    }

    private func pause(_ backoff: inout TimeInterval) async {
        let wait = backoff * Double.random(in: 0.8...1.2)
        onStatus(.reconnecting(after: wait))
        try? await Task.sleep(for: .seconds(wait))
        backoff = min(backoff * 2, 30)
    }

    private func connectOnce() async -> Outcome {
        let token: String
        do { token = try await client.accessToken() } catch let e as CellError {
            switch e {
            case .notSignedIn, .sessionEnded: return .fatal("signed out")
            default: return .dropped(wasLive: false)
            }
        } catch { return .dropped(wasLive: false) }
        if Task.isCancelled { return .cancelled }

        let ws = http.webSocketTask(with: CellConfig.realtimeURL)
        ws.maximumMessageSize = 1 << 20
        socket = ws
        isLive = false
        lastHeard = Date()
        onStatus(.connecting)
        ws.resume()

        let pinger = Task { [pingInterval, silenceTimeout] in
            var nonce = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(pingInterval))
                if Task.isCancelled { break }
                if Date().timeIntervalSince(self.lastHeard) > silenceTimeout {
                    ws.cancel(with: .goingAway, reason: nil); break
                }
                nonce += 1
                try? await ws.send(.string(#"{"type":"ping","nonce":\#(nonce)}"#))
            }
        }
        // `ready` must arrive promptly.
        let readyWatch = Task {
            try? await Task.sleep(for: .seconds(15))
            if !Task.isCancelled, !self.isLive, self.socket === ws { ws.cancel(with: .goingAway, reason: nil) }
        }
        defer { pinger.cancel(); readyWatch.cancel() }

        do {
            try await ws.send(.string(Self.json([
                "type": "authenticate", "apikey": CellConfig.publishableKey, "access_token": token,
            ])))
            while !Task.isCancelled {
                let msg = try await ws.receive()
                lastHeard = Date()
                let text: String
                switch msg {
                case .string(let s): text = s
                case .data(let d): text = String(decoding: d, as: UTF8.self)
                @unknown default: continue
                }
                guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { continue }
                try await handle(obj, ws)
            }
            ws.cancel(with: .normalClosure, reason: nil)
            return .cancelled
        } catch {
            let wasLive = isLive
            isLive = false
            let code = ws.closeCode.rawValue
            ws.cancel()
            if socket === ws { socket = nil }
            if Task.isCancelled { return .cancelled }
            switch code {
            case 4401: return .authExpired(token)
            case 4404: return .fatal("cell unavailable")
            case 1008: return .fatal("protocol error")
            case 4429: return .quota
            default: return .dropped(wasLive: wasLive)
            }
        }
    }

    private func handle(_ obj: [String: Any], _ ws: URLSessionWebSocketTask) async throws {
        switch obj["type"] as? String {
        case "ready":
            try await subscribe(ws)
        case "subscribed":
            isLive = true
            onStatus(.live)
            if let c = (obj["cursor"] as? NSNumber)?.int64Value { setCursor(c) }
            // Anything inserted before we (re)subscribed without a cursor arrives via push_batch.
            onResync()
        case "change":
            if let c = (obj["cursor"] as? NSNumber)?.int64Value { setCursor(c) }
            if let eid = obj["event_id"] as? String {
                if recentEventIDs.contains(eid) { return }
                recentEventIDs.append(eid)
                if recentEventIDs.count > 200 { recentEventIDs.removeFirst(recentEventIDs.count - 200) }
            }
            guard obj["table"] as? String == "answers", obj["operation"] as? String == "INSERT",
                  let row = obj["new"] as? [String: Any],
                  (row["device_id"] as? String)?.lowercased() == deviceID,
                  row["consumed_at"] == nil || row["consumed_at"] is NSNull,
                  let data = try? JSONSerialization.data(withJSONObject: row),
                  let answer = try? JSONDecoder().decode(CloudAnswer.self, from: data) else { return }
            onAnswer(answer)
        case "error":
            let code = obj["code"] as? String ?? ""
            SyncLog.info("realtime error \(code)")
            if code == "cursor_expired" {
                cursor = nil
                try await subscribe(ws)
                onResync()
            } else if (obj["id"] as? String) == "answers" {
                // Subscription rejected: reconnect from scratch.
                ws.cancel(with: .goingAway, reason: nil)
            }
        default:
            break
        }
    }

    private func subscribe(_ ws: URLSessionWebSocketTask) async throws {
        var sub: [String: Any] = [
            "type": "subscribe", "id": "answers", "schema": "public", "table": "answers", "events": ["INSERT"],
            "filters": [["column": "device_id", "op": "eq", "value": deviceID]],
        ]
        if let cursor { sub["after"] = cursor }
        try await ws.send(.string(Self.json(sub)))
    }

    private func setCursor(_ c: Int64) {
        guard c != cursor else { return }
        cursor = c
        onCursor(c)
    }

    private static func json(_ o: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: o)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
