import Foundation
import Network

/// What the sign-in page shows after it hands the fragment back to the app.
struct LoopbackResult: Sendable, Equatable {
    var ok: Bool
    var title: String
    var message: String
    var name: String?
    var handle: String?
    /// Nothing decided yet: the person has to confirm in Silicon Mode (the page keeps waiting).
    var pending = false

    func json() -> Data {
        var o: [String: Any] = ["ok": ok, "title": title, "message": message]
        if let name { o["name"] = name }
        if let handle { o["handle"] = handle }
        if pending { o["pending"] = true }
        return (try? JSONSerialization.data(withJSONObject: o)) ?? Data("{}".utf8)
    }
}

/// A tiny HTTP server on 127.0.0.1:47291 that lives only while signing in.
///
/// Binding a callback to the sign-in this Mac started: the app opens `/auth/start#<flow key>` (the
/// key travels only inside that URL's fragment: never served, never sent to a server). The start
/// page moves the key into the tab's sessionStorage and continues to the cell's hosted sign-in. The
/// cell redirects that same tab to `/auth/callback#access_token=…`; the callback page strips the
/// fragment from history and POSTs it to `/auth/complete` with the key from sessionStorage.
/// A POST carrying the key (once) is **bound**. Any other POST (another tab or browser, a local
/// process) is **unbound** and the handler must not adopt its tokens without the person's say-so.
/// Host/Origin/Content-Type and a custom header are checked too (no cross-site or DNS-rebinding POSTs).
final class LoopbackAuthServer: @unchecked Sendable {
    typealias Handler = @Sendable (_ fragment: String, _ query: String, _ bound: Bool) async -> LoopbackResult

    let port: UInt16
    private let handler: Handler
    private let queue = DispatchQueue(label: "ai.tos.mode.loopback-auth")
    private var listener: NWListener?
    /// Per-attempt secret: the start URL's fragment → that tab's sessionStorage → POST header.
    let flowKey: String
    /// The cell's hosted sign-in, where the start page sends the browser.
    let signInURL: URL
    private let scriptNonce: String
    private let fontData: Data?
    /// The flow key has been presented (single use).
    private let flowUsed = SyncLock(false)
    /// The attempt is over: refuse new completions while in-flight responses flush.
    private let retired = SyncLock(false)

    /// Header the pages send on POST /auth/complete: the flow key, or `none`.
    static let flowHeader = "x-silicon-mode"
    static let maxBody = 256 * 1024

    init(port: UInt16 = CellConfig.loopbackPort, flowKey: String = LoopbackAuthServer.randomKey(),
         signInURL: URL = CellConfig.signInURL(redirectTo: CellConfig.loopbackRedirect), handler: @escaping Handler) {
        self.port = port
        self.handler = handler
        self.flowKey = flowKey
        self.signInURL = signInURL
        scriptNonce = Self.random(18)
        fontData = Self.findFont()
    }

    var origin: String { "http://127.0.0.1:\(port)" }
    var startURL: URL { CellConfig.loopbackStartURL(port: port, flowKey: flowKey) }

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

    /// The attempt finished: no more completions (the listener stays up briefly so responses flush).
    func retire() { retired.value = true }

    func stop() {
        retired.value = true
        queue.async { [listener] in listener?.cancel() }
        listener = nil
    }

    // MARK: Connections

    private func accept(_ c: NWConnection) {
        let routed = SyncLock(false)
        c.start(queue: queue)
        receive(c, buffer: Data(), routed: routed)
        // Drop idle/slow clients; a routed POST may wait for the person to confirm, so it gets longer.
        queue.asyncAfter(deadline: .now() + 30) { if !routed.value, c.state != .cancelled { c.cancel() } }
        queue.asyncAfter(deadline: .now() + 660) { if c.state != .cancelled { c.cancel() } }
    }

    private func receive(_ c: NWConnection, buffer: Data, routed: SyncLock<Bool>) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { c.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if buf.count > Self.maxBody + 16 * 1024 { self.respond(c, 413, "text/plain", Data("too large".utf8)); return }
            switch LoopbackHTTPRequest.parse(buf) {
            case .request(let req):
                routed.value = true
                self.route(req, c)
            case .bad(let status):
                routed.value = true
                self.respond(c, status, "text/plain", Data("bad request".utf8))
            case .incomplete:
                if done || error != nil { c.cancel() } else { self.receive(c, buffer: buf, routed: routed) }
            }
        }
    }

    private func route(_ r: LoopbackHTTPRequest, _ c: NWConnection) {
        // DNS-rebinding guard: only our literal host.
        guard r.headers["host"] == "127.0.0.1:\(port)" else {
            respond(c, 421, "text/plain", Data("misdirected".utf8)); return
        }
        switch (r.method, r.path) {
        case ("GET", "/auth/start"):
            page(c, LoopbackPage.startHTML(nonce: scriptNonce, signInURL: signInURL))
        case ("GET", "/auth/callback"), ("GET", "/"):
            page(c, LoopbackPage.callbackHTML(nonce: scriptNonce))
        case ("POST", "/auth/complete"):
            complete(r, c)
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

    private func page(_ c: NWConnection, _ html: String) {
        respond(c, 200, "text/html; charset=utf-8", Data(html.utf8),
                extra: ["Content-Security-Policy": LoopbackPage.csp(nonce: scriptNonce)])
    }

    private func complete(_ r: LoopbackHTTPRequest, _ c: NWConnection) {
        if let o = r.headers["origin"], o != origin { respond(c, 403, "text/plain", Data("forbidden".utf8)); return }
        // Same-origin fetch only: a custom header and a JSON body both force a CORS preflight we never answer.
        guard let presented = r.headers[Self.flowHeader], !presented.isEmpty else {
            respond(c, 403, "text/plain", Data("forbidden".utf8)); return
        }
        guard (r.headers["content-type"] ?? "").lowercased().hasPrefix("application/json") else {
            respond(c, 415, "text/plain", Data("unsupported".utf8)); return
        }
        guard !retired.value else {
            respond(c, 410, "application/json", LoopbackResult(
                ok: false, title: "This sign-in already finished",
                message: "Check Silicon Mode. To sign in again, start from its menu bar.").json())
            return
        }
        var bound = false
        if Self.constantTimeEquals(presented, flowKey) {
            guard !flowUsed.value else {
                respond(c, 409, "application/json", LoopbackResult(
                    ok: false, title: "Already used", message: "Start again from the Silicon Mode menu bar.").json())
                return
            }
            flowUsed.value = true
            bound = true
        }
        let body = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:]
        let fragment = body["fragment"] as? String ?? ""
        let query = body["query"] as? String ?? ""
        let handler = self.handler
        Task {
            let result = await handler(fragment, query, bound)
            self.queue.async { self.respond(c, 200, "application/json", result.json()) }
        }
    }

    private func respond(_ c: NWConnection, _ status: Int, _ type: String, _ body: Data, extra: [String: String] = [:]) {
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
                      409: "Conflict", 410: "Gone", 413: "Payload Too Large", 415: "Unsupported Media Type",
                      421: "Misdirected Request", 431: "Request Header Fields Too Large"][status] ?? "Status"
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

    /// 32 random bytes, base64url (a flow key).
    static func randomKey() -> String { random(32) }

    private static func random(_ n: Int) -> String {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return Data(b).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in x.indices { diff |= x[i] ^ y[i] }
        return diff == 0
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

/// Minimal HTTP/1.1 request parsing (one request per connection). Never traps on hostile input.
struct LoopbackHTTPRequest: Equatable {
    var method: String
    var path: String
    var query: String
    var headers: [String: String]
    var body: Data

    enum Parse: Equatable {
        /// Wait for more bytes.
        case incomplete
        /// Answer with this status and close.
        case bad(Int)
        case request(LoopbackHTTPRequest)
    }

    static let maxHead = 16 * 1024

    static func parse(_ buf: Data) -> Parse {
        guard let headEnd = buf.range(of: Data("\r\n\r\n".utf8)) else {
            return buf.count > maxHead ? .bad(431) : .incomplete
        }
        guard headEnd.lowerBound - buf.startIndex <= maxHead else { return .bad(431) }
        guard let head = String(data: buf[buf.startIndex..<headEnd.lowerBound], encoding: .utf8) else { return .bad(400) }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard start.count == 3,
              !start[0].isEmpty, start[0].count <= 16, start[0].allSatisfy({ $0.isASCII && $0.isUppercase }),
              start[2].hasPrefix("HTTP/1.") else { return .bad(400) }
        let target = String(start[1])
        // Origin-form only ("/path?query"): rejects "?", "*", absolute URLs and empty targets.
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let path = parts.first, path.hasPrefix("/") else { return .bad(400) }
        var headers: [String: String] = [:]
        for l in lines {
            guard let i = l.firstIndex(of: ":") else { continue }
            let name = l[..<i].trimmingCharacters(in: .whitespaces).lowercased()
            let value = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
            if name == "content-length", let prev = headers[name], prev != value { return .bad(400) }
            headers[name] = value
        }
        if headers["transfer-encoding"] != nil { return .bad(400) }   // no chunked bodies here
        let length: Int
        if let raw = headers["content-length"] {
            guard !raw.isEmpty, raw.count <= 7, raw.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let n = Int(raw), (0...LoopbackAuthServer.maxBody).contains(n) else { return .bad(400) }
            length = n
        } else {
            length = 0
        }
        let bodyStart = headEnd.upperBound
        guard buf.endIndex - bodyStart >= length else { return .incomplete }
        return .request(LoopbackHTTPRequest(method: String(start[0]), path: path, query: parts.count > 1 ? parts[1] : "",
                                            headers: headers, body: buf.subdata(in: bodyStart..<(bodyStart + length))))
    }
}
