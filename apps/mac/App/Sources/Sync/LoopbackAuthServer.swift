import Foundation
import Network

/// What the sign-in page shows after it hands the fragment back to the app.
struct LoopbackResult: Sendable, Equatable {
    var ok: Bool
    var title: String
    var message: String
    var name: String?
    var handle: String?

    func json() -> Data {
        var o: [String: Any] = ["ok": ok, "title": title, "message": message]
        if let name { o["name"] = name }
        if let handle { o["handle"] = handle }
        return (try? JSONSerialization.data(withJSONObject: o)) ?? Data("{}".utf8)
    }
}

/// A tiny HTTP server on 127.0.0.1:47291 that lives only while signing in.
///
/// The cell redirects the browser to `http://127.0.0.1:47291/auth/callback#access_token=…`. The
/// fragment never reaches a server, so `/auth/callback` serves a page whose script strips the
/// fragment from history and POSTs it to `/auth/complete` (same origin, per-run secret header,
/// Host/Origin checked → no cross-site or DNS-rebinding injection).
final class LoopbackAuthServer: @unchecked Sendable {
    typealias Handler = @Sendable (_ fragment: String, _ query: String) async -> LoopbackResult

    let port: UInt16
    private let handler: Handler
    private let queue = DispatchQueue(label: "ai.tos.mode.loopback-auth")
    private var listener: NWListener?
    /// Per-run secret embedded in the page; required on POST /auth/complete.
    let pageSecret: String
    private let scriptNonce: String
    private let fontData: Data?

    init(port: UInt16 = CellConfig.loopbackPort, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
        pageSecret = Self.random(24)
        scriptNonce = Self.random(18)
        fontData = Self.findFont()
    }

    var origin: String { "http://127.0.0.1:\(port)" }

    /// Binds 127.0.0.1:<port>. Throws if the port is taken.
    func start() async throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.acceptLocalOnly = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let l = try NWListener(using: params)
        listener = l
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        let once = SyncLock(false)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            l.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !once.value { once.value = true; cont.resume() }
                case .failed(let e), .waiting(let e):
                    if !once.value { once.value = true; cont.resume(throwing: e) }
                    l.cancel()
                default: break
                }
            }
            l.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [listener] in listener?.cancel() }
        listener = nil
    }

    // MARK: Connections

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, buffer: Data())
        // Drop idle/slow connections.
        queue.asyncAfter(deadline: .now() + 30) { if c.state != .cancelled { c.cancel() } }
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { c.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if buf.count > 256 * 1024 { self.respond(c, 413, "text/plain", Data("too large".utf8)); return }
            if let req = LoopbackHTTPRequest.parse(buf) {
                self.route(req, c)
            } else if done || error != nil {
                c.cancel()
            } else {
                self.receive(c, buffer: buf)
            }
        }
    }

    private func route(_ r: LoopbackHTTPRequest, _ c: NWConnection) {
        // DNS-rebinding guard: only our literal host.
        guard r.headers["host"] == "127.0.0.1:\(port)" else {
            respond(c, 421, "text/plain", Data("misdirected".utf8)); return
        }
        switch (r.method, r.path) {
        case ("GET", "/auth/callback"), ("GET", "/"):
            respond(c, 200, "text/html; charset=utf-8", Data(LoopbackPage.html(secret: pageSecret, nonce: scriptNonce).utf8),
                    extra: ["Content-Security-Policy": LoopbackPage.csp(nonce: scriptNonce)])
        case ("POST", "/auth/complete"):
            if let o = r.headers["origin"], o != origin { respond(c, 403, "text/plain", Data("forbidden".utf8)); return }
            guard r.headers["x-silicon-mode"] == pageSecret else { respond(c, 403, "text/plain", Data("forbidden".utf8)); return }
            let body = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:]
            let fragment = body["fragment"] as? String ?? ""
            let query = body["query"] as? String ?? ""
            let handler = self.handler
            Task {
                let result = await handler(fragment, query)
                self.queue.async { self.respond(c, 200, "application/json", result.json()) }
            }
        case ("GET", "/assets/allo.ttf"):
            if let fontData {
                respond(c, 200, "font/ttf", fontData, extra: ["Cache-Control": "max-age=3600"])
            } else {
                respond(c, 404, "text/plain", Data())
            }
        case ("GET", "/favicon.ico"):
            respond(c, 204, "text/plain", Data())
        default:
            respond(c, 404, "text/plain", Data("not found".utf8))
        }
    }

    private func respond(_ c: NWConnection, _ status: Int, _ type: String, _ body: Data, extra: [String: String] = [:]) {
        let reason = [200: "OK", 204: "No Content", 403: "Forbidden", 404: "Not Found", 413: "Payload Too Large",
                      421: "Misdirected Request"][status] ?? "Status"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        var headers: [String: String] = [
            "Content-Type": type,
            "Content-Length": "\(body.count)",
            "Connection": "close",
            "Cache-Control": "no-store",
            "Referrer-Policy": "no-referrer",
            "X-Content-Type-Options": "nosniff",
            "X-Frame-Options": "DENY",
        ]
        for (k, v) in extra { headers[k] = v }
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }

    // MARK: Helpers

    private static func random(_ n: Int) -> String {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return Data(b).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func findFont() -> Data? {
        let candidates = [
            Bundle.main.url(forResource: "AlloVariable", withExtension: "ttf", subdirectory: "Fonts"),
            Bundle.main.url(forResource: "AlloVariable", withExtension: "ttf"),
        ]
        for case let u? in candidates { if let d = try? Data(contentsOf: u) { return d } }
        return nil
    }
}

/// Minimal HTTP/1.1 request parsing (one request per connection).
struct LoopbackHTTPRequest {
    var method: String
    var path: String
    var query: String
    var headers: [String: String]
    var body: Data

    static func parse(_ buf: Data) -> LoopbackHTTPRequest? {
        guard let headEnd = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: buf[buf.startIndex..<headEnd.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            guard let i = l.firstIndex(of: ":") else { continue }
            headers[l[..<i].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let bodyStart = headEnd.upperBound
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard buf.count - bodyStart >= length else { return nil }
        let target = String(start[1])
        let parts = target.split(separator: "?", maxSplits: 1).map(String.init)
        return LoopbackHTTPRequest(method: String(start[0]), path: parts[0], query: parts.count > 1 ? parts[1] : "",
                           headers: headers, body: buf.subdata(in: bodyStart..<(bodyStart + length)))
    }
}
