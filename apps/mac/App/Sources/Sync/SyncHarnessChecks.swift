#if SYNC_HARNESS
// Offline checks for the sync harness (SyncHarness.swift): redaction, provider ids, ledger files,
// hostile loopback HTTP, and sign-in / sign-out / CloudSync against an in-process fake cell
// (a URLProtocol: nothing leaves the machine). Compiled only with -D SYNC_HARNESS.
import Foundation
import SiliconModeKit

extension Harness {
    // MARK: Redaction

    func redactionChecks() {
        check("every redaction rule compiles", SyncRedactor.allRulesCompile)
        // Token-shaped test values are assembled at runtime so no literal in the repo looks like a key.
        func t(_ parts: String...) -> String { parts.joined() }
        let alnum = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"
        let cases: [(name: String, input: String, gone: [String], kept: [String])] = [
            ("URL password (psql)", "psql postgres://admin:S3cretPassw0rd@prod-db:5432/app", ["S3cretPassw0rd", "admin:"], ["postgres://•••@prod-db:5432/app"]),
            ("URL password in env", "export DATABASE_URL=postgres://admin:S3cretPassw0rd@db/app", ["S3cretPassw0rd"], ["DATABASE_URL=postgres://•••@db/app"]),
            ("password with @", "redis://:p@ssw0rd@cache:6379", ["p@ss", "ssw0rd"], ["@cache:6379"]),
            ("token-only URL userinfo", t("git clone https://", "ghp", "_", alnum, "@github.com/o/r.git"), ["ghp_", alnum], ["@github.com/o/r.git"]),
            ("GitLab token in URL", t("git clone https://oauth2:", "glpat", "-", "AbCdEfGhIjKlMnOpQrSt", "@gitlab.com/group/repo.git"), ["glpat", "AbCdEfGhIjKl"], ["@gitlab.com/group/repo.git"]),
            ("GitLab token", t("GITLAB_TOKEN ", "glpat", "-", "AbCdEfGhIjKlMnOpQrSt"), ["AbCdEfGhIjKl"], []),
            ("Stripe secret key", t("curl https://api.stripe.com/v1/charges -u ", "sk", "_live_", "51HxAbCdEfGhIjKlMnOpQrStUv", ":"), ["51HxAbCd"], ["api.stripe.com"]),
            ("Stripe restricted key", t("STRIPE=", "rk", "_test_", "51HxAbCdEfGhIjKlMnOp"), ["51HxAbCd"], []),
            ("JSON password", #"curl -d '{"password":"hunter2hunter2"}' https://x"#, ["hunter2"], ["password"]),
            ("JSON api key with spaces", #"{"api_key": "abcd-1234-efgh", "name": "ok"}"#, ["abcd-1234"], [#""name": "ok""#]),
            ("--password value", "mysql --password hunter2hunter2 -h db", ["hunter2"], ["--password •••", "-h db"]),
            ("--password=value", "mysql --password=hunter2hunter2", ["hunter2"], []),
            ("--token value", "gh auth login --token abc123def456ghi", ["abc123def"], ["--token •••"]),
            ("curl -u user:pass", "curl -u admin:hunter2hunter2 https://x.example", ["hunter2"], ["https://x.example"]),
            ("sshpass", "sshpass -p hunter2hunter2 ssh host", ["hunter2"], ["ssh host"]),
            ("Basic auth header", "Authorization: Basic YWRtaW46aHVudGVyMmh1bnRlcjI=", ["YWRtaW46"], ["Authorization"]),
            ("Bearer header", #"curl -H "Authorization: Bearer abc.def-123456789xyz" https://x"#, ["abc.def", "123456789xyz"], ["https://x"]),
            ("JSON Authorization", #"{"Authorization":"Token abcdef123456"}"#, ["abcdef123456"], []),
            ("standalone Bearer", "token is Bearer a1b2c3d4e5f6g7h8i9", ["a1b2c3d4"], ["Bearer •••"]),
            ("Cookie header", #"curl -H "Cookie: session=abc123def; theme=dark" https://x"#, ["abc123def", "theme=dark"], []),
            ("X-Api-Key header", "X-Api-Key: abcd1234efgh", ["abcd1234"], []),
            ("env assignment", "export API_KEY=abcd1234efgh5678", ["abcd1234"], ["API_KEY="]),
            ("YAML password", "password: hunter2hunter2", ["hunter2"], []),
            ("AWS key id", t("aws configure set aws_access_key_id ", "AKIA", "IOSFODNN7EXAMPLE"), ["IOSFODNN7"], []),
            ("AWS secret", "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", ["wJalrXUtn"], []),
            ("AWS session token", "aws_session_token = IQoJb3JpZ2luX2VjEXAMPLE", ["IQoJb3Jp"], []),
            ("GitHub PAT", t("ghp", "_", alnum), [alnum], []),
            ("GitHub fine-grained", t("github", "_pat_", "11ABCDEFG0", "123456789_abcdefghijklmnopqrstuvwxyz"), ["11ABCDEFG0"], []),
            ("Slack bot token", t("xox", "b-", "1234567890-1234567890123-", "AbCdEfGhIjKlMnOpQrStUvWx"), ["AbCdEfGh"], []),
            ("Slack webhook", t("https://hooks.slack.com/services/", "T0000/B0000/", "XXXXXXXXXXXXXXXXXXXXXXXX"), ["XXXXXXXX", "T0000"], ["hooks.slack.com/services/•••"]),
            ("OpenAI key", t("OPENAI=", "sk", "-proj-", "Abc123Def456Ghi789Jkl012Mno345"), ["Abc123Def"], []),
            ("Anthropic key", t("x ", "sk", "-ant-api03-", "Abc123Def456Ghi789Jkl012Mno345-xyz"), ["Abc123Def", "ant-api03"], []),
            ("JWT", t("eyJhbGciOiJIUzI1NiJ9", ".", "eyJzdWIiOiIxMjM0NTY3ODkwIn0", ".", "dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"), ["dozjgNry", "eyJzdWIi"], []),
            ("OpenSSH private key", "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----", ["b3BlbnNz"], ["private key"]),
            ("PGP private key block", "-----BEGIN PGP PRIVATE KEY BLOCK-----\nlQOYBFabcdef\n-----END PGP PRIVATE KEY BLOCK-----", ["lQOYBF"], []),
            ("truncated private key", "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA", ["MIIEpAIB"], []),
            ("Google API key", t("key ", "AIza", "SyA1234567890abcdefghijklmnopqrstu"), ["SyA1234567"], []),
            ("Google OAuth token", t("ya29", ".", "a0AfH6SMBabcdefghijklmnop1234"), ["a0AfH6SM"], []),
            ("Google client secret", t("GOCSPX", "-", "abcdefghijklmnopqrstuvwx12"), ["abcdefghijklmnop"], []),
            ("npm token", t("//registry.npmjs.org/:_authToken=", "npm", "_", alnum), [alnum], []),
            ("Hugging Face token", t("HF ", "hf", "_", alnum), [alnum], []),
            ("SendGrid key", t("SG", ".", "abcdefghijklmnop1234", ".", "qrstuvwxyz0123456789ABCD"), ["abcdefghijklmnop1234"], []),
            ("query token", "GET https://api.example.com/v1?access_token=abcd1234&page=2", ["abcd1234"], ["page=2"]),
            ("query key", "https://maps.example.com/api?key=zyx987&q=x", ["zyx987"], ["q=x"]),
            ("Cell refresh token", t("refresh ", "csr", "_", "abcdefghijklmnop1234"), ["abcdefghijklmnop1234"], []),
        ]
        for c in cases {
            let out = SyncRedactor.clean(c.input)
            let ok = c.gone.allSatisfy { !out.contains($0) } && c.kept.allSatisfy { out.contains($0) } && out.contains("•••")
            check("redacts \(c.name)", ok, "→ \(out)")
        }
        // Ordinary agent text must survive untouched.
        let benign = [
            "Tokens: 12k sent, 3.4k received. Cost: $0.05 message, $0.20 session.",
            "Edit ~/code/silicon-mode/App/Sync.swift",
            "git push -u origin main",
            "Run swift test --filter SyncTests",
            "A basic understanding of the problem",
            "max_tokens=4096 temperature=0.2",
            "risk-assessment-for-the-project-2024",
            "https://github.com/teamofsilicons/silicon-mode/pull/42",
            "ssh://git@github.com/org/repo.git",
            "Bearer authentication is used here",
            "The password field is required",
            "git log --oneline 3f2a9c1d8e7b6a5f4e3d2c1b0a9f8e7d6c5b4a39",
        ]
        for b in benign {
            check("keeps \"\(b.prefix(36))\"", SyncRedactor.clean(b) == b, "→ \(SyncRedactor.clean(b))")
        }
        let long = String(repeating: "a-", count: 20_000) + "password=hunter2"
        let t0 = Date()
        _ = SyncRedactor.clean(long)
        check("long hostile input stays fast", Date().timeIntervalSince(t0) < 2)
    }

    // MARK: Provider session ids

    func providerSessionIDChecks() {
        let dev = "0f8fad5b-d9cb-469f-a165-70867728950e"
        check("opaque ids sent as they are", SyncIDs.providerSessionID("8e0f6c1a-5b9d-4a43-9e1f-2a6c1d0b7e55") == "8e0f6c1a-5b9d-4a43-9e1f-2a6c1d0b7e55"
              && SyncIDs.providerSessionID("ses_abc123") == "ses_abc123" && SyncIDs.providerSessionID("pid-4242") == "pid-4242"
              && SyncIDs.providerSessionID("agent:main:main") == "agent:main:main")
        let aider = "\(NSHomeDirectory())/code/secret-project#1700000000"
        let kiro = "cwd:/Users/someone/work/client"
        let a = SyncIDs.providerSessionID(aider), k = SyncIDs.providerSessionID(kiro)
        check("path-like ids are hashed", a.hasPrefix("h:") && k.hasPrefix("h:") && !a.contains("/") && !a.contains("secret-project")
              && a.count == 66 && a != k && a == SyncIDs.providerSessionID(aider))
        let long = String(repeating: "x", count: 250)
        check("over-long ids are hashed, not clipped", SyncIDs.providerSessionID(long).hasPrefix("h:")
              && SyncIDs.providerSessionID(long) != SyncIDs.providerSessionID(long + "y"))
        check("non-ASCII ids hashed (char_length safe)", SyncIDs.providerSessionID("sessión-é").hasPrefix("h:"))
        check("session uuid = UUIDv5(device|provider|id as sent)",
              SyncIDs.session(deviceID: dev, provider: "aider", nativeID: aider) == SyncIDs.uuidV5(SyncIDs.namespace, "\(dev)|aider|\(a)")
              && SyncIDs.session(deviceID: dev, provider: "claude_code", nativeID: "abc") == SyncIDs.uuidV5(SyncIDs.namespace, "\(dev)|claude_code|abc"))
        let s = AgentSession(provider: "aider", nativeID: aider, title: "Fix", cwd: "\(NSHomeDirectory())/code/secret-project",
                             state: .working, updatedAt: Date())
        let json = String(decoding: try! JSONEncoder().encode(SyncMapper.sessionRow(s, deviceID: dev)), as: UTF8.self)
        check("no path in an Aider session row", !json.contains(NSHomeDirectory()) && !json.contains("/code/") && json.contains("\"project\":\"secret-project\""), json)
        let q = AgentQuestion(id: "q1", sessionID: s.id, provider: "codex", kind: .permission, title: "Run command",
                              options: [.init(id: "allow", label: "Yes, run curl -u admin:hunter2hunter2 https://x"),
                                        .init(id: "deny", label: "No")])
        let row = SyncMapper.questionRow(q, deviceID: dev, sessionUUID: nil)
        check("option labels redacted", !row.options.map(\.label).joined().contains("hunter2") && row.options.count == 2, "\(row.options.map(\.label))")
    }

    // MARK: Ledger files

    func ledgerChecks() {
        let old = #"{"deviceID":"d1","seqs":{"S":{"next":5,"seen":["a"],"touched":0}},"outbox":[],"live":{},"pushedQuestions":{},"closedQuestions":[],"confirmed":{},"pendingUpdates":{},"pendingConsumed":{},"handledAnswers":[],"usageBackfilled":true}"#
        let dec = try? JSONDecoder().decode(SyncLedger.self, from: Data(old.utf8))
        check("ledgers from older builds still decode", dec?.seqs["S"]?.next == 5 && dec?.usageBackfilled == true && dec?.needsReconcile == false)

        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sync-harness-\(UUID().uuidString.prefix(8))")
        let store = SyncLedgerStore(url: dir.appendingPathComponent("cloud-sync.json"))
        let dA = "aaaaaaaa-0000-4000-8000-000000000001", dB = "bbbbbbbb-0000-4000-8000-000000000002"
        let evs = (1...3).map { SyncLedger.LocalEvent(id: "e\($0)", at: "t", kind: "log", summary: "s\($0)", detail: nil) }
        var a = SyncLedger(deviceID: dA)
        a.enqueue(sessionUUID: "S", events: evs)
        store.saveNow(a)
        store.saveNow(SyncLedger(deviceID: dB))
        let backA = store.load(deviceID: dA)
        check("account A → B → A keeps A's seqs", backA.seqs["S"]?.next == 4 && !backA.needsReconcile)
        let fresh = store.load(deviceID: "cccccccc-0000-4000-8000-000000000003")
        check("unknown device → new ledger that reconciles first", fresh.seqs.isEmpty && fresh.needsReconcile)
        var legacy = SyncLedger(deviceID: "dddddddd-0000-4000-8000-000000000004")
        legacy.realtimeCursor = 7
        try? JSONEncoder().encode(legacy).write(to: store.url)
        let notMine = store.load(deviceID: dB)
        check("old shared file not taken by another device", notMine.realtimeCursor == nil && FileManager.default.fileExists(atPath: store.url.path))
        let mig = store.load(deviceID: legacy.deviceID)
        check("old shared file adopted by its device, then removed", mig.realtimeCursor == 7 && !mig.needsReconcile
              && !FileManager.default.fileExists(atPath: store.url.path)
              && FileManager.default.fileExists(atPath: store.url(for: legacy.deviceID).path))
        store.deleteAll()
        check("store cleanup", (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty ?? true)
        try? FileManager.default.removeItem(at: dir)

        let row = WireSession(id: "S", provider: "aider", providerSessionID: "h:x", title: "t", project: nil, model: nil, state: "working",
                              waitingReason: nil, startedAt: nil, lastEventAt: "now", endedAt: nil, meta: [:])
        var q = SyncLedger(deviceID: dA)
        q.enqueue(sessionUUID: "S", events: evs)
        q.quarantine(row, appVersion: "1")
        check("quarantine drops that session's queued events", q.outbox.isEmpty)
        check("held back while unchanged", q.isQuarantined(row, appVersion: "1"))
        var moved = row
        moved.lastEventAt = "later"
        check("activity alone doesn't release it", q.isQuarantined(moved, appVersion: "1"))
        var changed = row
        changed.title = "changed"
        check("a changed row gets another try", !q.isQuarantined(changed, appVersion: "1") && q.quarantined.isEmpty)
        q.quarantine(row, appVersion: "1")
        check("a new app build gets another try", !q.isQuarantined(row, appVersion: "2"))

        var t = SyncLedger(deviceID: dA)
        t.seqs["S"] = .init(next: 41)
        t.serverTail["S"] = [SyncLedger.tailKey(kind: "user", summary: "hello")]
        t.enqueue(sessionUUID: "S", events: [.init(id: "x", at: "t", kind: "user", summary: "hello", detail: nil),
                                             .init(id: "y", at: "t", kind: "user", summary: "hello", detail: nil)])
        check("events the server already has aren't resent (once each)", t.outbox.map(\.seq) == [41] && t.seqs["S"]?.seen == ["x", "y"]
              && t.serverTail.isEmpty)
    }

    // MARK: Hostile loopback HTTP

    func parserChecks() async {
        func parse(_ s: String) -> LoopbackHTTPRequest.Parse { LoopbackHTTPRequest.parse(Data(s.utf8)) }
        check("target \"?\" → 400 (used to trap)", parse("GET ? HTTP/1.1\r\nHost: x\r\n\r\n") == .bad(400))
        check("negative Content-Length → 400 (used to trap)", parse("POST /auth/complete HTTP/1.1\r\nContent-Length: -1\r\n\r\n") == .bad(400))
        check("odd Content-Length → 400", parse("POST / HTTP/1.1\r\nContent-Length: +5\r\n\r\n") == .bad(400)
              && parse("POST / HTTP/1.1\r\nContent-Length: 1e3\r\n\r\n") == .bad(400)
              && parse("POST / HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n") == .bad(400)
              && parse("POST / HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n") == .bad(400))
        check("chunked → 400", parse("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n") == .bad(400))
        check("absolute-form / bad request line → 400", parse("GET http://evil/ HTTP/1.1\r\n\r\n") == .bad(400)
              && parse("GET /\r\n\r\n") == .bad(400) && parse("get / HTTP/1.1\r\n\r\n") == .bad(400) && parse("\r\n\r\n") == .bad(400))
        check("invalid UTF-8 head → 400", LoopbackHTTPRequest.parse(Data([0xFF, 0xFE, 0x0D, 0x0A, 0x0D, 0x0A])) == .bad(400))
        check("oversized head → 431", LoopbackHTTPRequest.parse(Data(("GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: 20_000)).utf8)) == .bad(431))
        check("waits for the rest", parse("GET / HTTP/1.1\r\nHost") == .incomplete
              && parse("POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc") == .incomplete)
        if case .request(let r) = parse("GET /a?b=c HTTP/1.1\r\nHost: h\r\n\r\n") {
            check("path + query", r.path == "/a" && r.query == "b=c" && r.headers["host"] == "h")
        } else { check("path + query", false) }
        if case .request(let r) = parse("GET /a? HTTP/1.1\r\n\r\n") { check("empty query", r.path == "/a" && r.query == "") }
        else { check("empty query", false) }
        let sliced = Data("xxxxxPOST /p HTTP/1.1\r\nContent-Length: 2\r\n\r\nhi".utf8)
        if case .request(let r) = LoopbackHTTPRequest.parse(sliced[5...]) { check("Data slices", r.body == Data("hi".utf8) && r.path == "/p") }
        else { check("Data slices", false) }

        let port: UInt16 = 47_394
        let server = LoopbackAuthServer(port: port) { _, _, _ in LoopbackResult(ok: true, title: "", message: "") }
        do { try await server.start() } catch { check("listener start", false, "\(error)"); return }
        let host = "Host: 127.0.0.1:\(port)\r\n"
        let r1 = await Self.rawHTTP(port, "GET ? HTTP/1.1\r\n\(host)\r\n")
        let r2 = await Self.rawHTTP(port, "POST /auth/complete HTTP/1.1\r\n\(host)Content-Length: -1\r\n\r\n")
        let r3 = await Self.rawHTTP(port, "GET /auth/callback HTTP/1.1\r\n\(host)\r\n")
        check("server answers 400 to both and keeps running", r1.hasPrefix("HTTP/1.1 400") && r2.hasPrefix("HTTP/1.1 400") && r3.hasPrefix("HTTP/1.1 200"),
              "\(r1.prefix(20)) \(r2.prefix(20)) \(r3.prefix(20))")
        server.stop()
    }

    /// One raw request over a plain socket (bytes a browser would never send).
    nonisolated static func rawHTTP(_ port: UInt16, _ request: String) async -> String {
        await Task.detached {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return "" }
            defer { close(fd) }
            var tv = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard connected == 0 else { return "" }
            let bytes = Array(request.utf8)
            _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            var out = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = recv(fd, &buf, buf.count, 0)
                if n <= 0 { break }
                out.append(buf, count: n)
            }
            return String(decoding: out, as: UTF8.self)
        }.value
    }

    // MARK: Fake cell: sign-in, sign-out, CloudSync

    func fakeCellChecks() async {
        let cell = FakeCell()
        FakeCell.current.value = cell
        let ada = "7e3bd279-da39-417f-b6dc-8ad0924990e4", mallory = "0080c488-a9e9-4c22-aa91-1c7a639f1d7b"
        cell.addUser(uuid: ada, id: "c:ada", name: "Ada Lovelace")
        cell.addUser(uuid: mallory, id: "c:mallory", name: "Mallory")
        func body(_ s: CellSession) -> Data { try! JSONSerialization.data(withJSONObject: ["fragment": cell.fragment(s), "query": ""]) }

        section("sign-in is tied to this Mac's attempt (fake cell)")
        let store = MemorySessionStore()
        let client = CellClient(store: store, configuration: FakeCell.configuration)
        let acct = AccountManager(client: client)
        acct.loopbackPort = 47_392
        var opened: URL?
        acct.openURL = { opened = $0 }
        var asked: [String] = []
        let approve = SyncLock(false)
        acct.confirmUnboundSignIn = { a in asked.append(a.id); return approve.value }
        await acct.startSignIn(openBrowser: true)
        guard let start = opened, let key = start.fragment else { check("sign-in opens the start page", false); return }
        check("sign-in opens the loopback start page (flow key in the fragment)",
              start.host == "127.0.0.1" && start.port == 47392 && start.path == "/auth/start" && key.count >= 40)
        let base = "http://127.0.0.1:47392"
        let (sp, _) = await httpGet(start.absoluteString)
        check("start page continues to the cell with the loopback redirect",
              sp.contains("redirect_to=http%3A%2F%2F127.0.0.1%3A47392%2Fauth%2Fcallback") && !sp.contains(key))

        let evil = cell.mint(uuid: mallory)
        acct.handleCallback(URL(string: "ai.tos.mode://auth/callback#\(cell.fragment(evil))")!)
        try? await Task.sleep(for: .milliseconds(300))
        check("ai.tos.mode:// tokens ignored while the loopback is in use", !acct.isSignedIn && asked.isEmpty && store.load() == nil)

        let r1 = await httpPost("\(base)/auth/complete", body: body(evil), headers: ["Origin": base, "X-Silicon-Mode": "none"])
        _ = await waitUntil(3) { asked.count == 1 }
        check("callback without the flow key: page waits, the person is asked", r1.0.contains("\"pending\":true") && asked == ["c:mallory"], r1.0)
        check("declined → not signed in, nothing stored, still signing in", !acct.isSignedIn && store.load() == nil && acct.isSigningIn)
        let cancel = try! JSONSerialization.data(withJSONObject: ["fragment": "", "query": "error=access_denied"])
        _ = await httpPost("\(base)/auth/complete", body: cancel, headers: ["X-Silicon-Mode": "none"])
        check("an unbound cancel can't end the sign-in", acct.isSigningIn)
        let mine = cell.mint(uuid: ada)
        let r2 = await httpPost("\(base)/auth/complete", body: body(mine), headers: ["Origin": base, "X-Silicon-Mode": key])
        check("callback with the flow key signs in without asking", r2.0.contains("\"ok\":true") && acct.account?.id == "c:ada"
              && asked.count == 1 && store.load()?.session.refreshToken == mine.refreshToken, r2.0)
        let r3 = await httpPost("\(base)/auth/complete", body: body(evil), headers: ["X-Silicon-Mode": "none"])
        check("after sign-in the listener takes no more tokens", (r3.1 == 410 || r3.1 == 0) && acct.account?.id == "c:ada" && asked.count == 1, "\(r3.1)")

        section("web bounce fallback when the port is taken (fake cell)")
        let blocker = LoopbackAuthServer(port: 47_393) { _, _, _ in LoopbackResult(ok: false, title: "", message: "") }
        try? await blocker.start()
        let store2 = MemorySessionStore()
        let acct2 = AccountManager(client: CellClient(store: store2, configuration: FakeCell.configuration))
        acct2.loopbackPort = 47_393
        var opened2: URL?
        acct2.openURL = { opened2 = $0 }
        var asked2: [String] = []
        acct2.confirmUnboundSignIn = { a in asked2.append(a.id); return approve.value }
        await acct2.startSignIn(openBrowser: true)
        check("port taken → cell sign-in via the bounce page",
              opened2?.absoluteString.contains("redirect_to=https%3A%2F%2Fmode.teamofsilicons.com%2Fauth%2Fmac") == true)
        acct2.handleCallback(URL(string: "ai.tos.mode://auth/callback#\(cell.fragment(cell.mint(uuid: mallory)))")!)
        _ = await waitUntil(3) { asked2.count == 1 }
        check("bounce callback asks; declined → not signed in", asked2 == ["c:mallory"] && !acct2.isSignedIn && store2.load() == nil)
        approve.value = true
        acct2.handleCallback(URL(string: "ai.tos.mode://auth/callback#\(cell.fragment(cell.mint(uuid: ada)))")!)
        let bounced = await waitUntil(3) { acct2.isSignedIn }
        check("bounce callback confirmed → signed in", bounced && acct2.account?.id == "c:ada" && asked2.count == 2)
        blocker.stop()

        section("sign-out vs. a quick new sign-in (fake cell)")
        cell.configure { $0.signOutDelay = 0.6 }
        opened = nil
        acct.signOut()
        await acct.startSignIn(openBrowser: true)   // waits for the sign-out to finish
        check("a new sign-in starts only after the old session is revoked and wiped",
              cell.revoked.contains(mine.accessToken) && store.load() == nil && opened != nil)
        let next = cell.mint(uuid: ada)
        _ = await httpPost("\(base)/auth/complete", body: body(next), headers: ["X-Silicon-Mode": opened?.fragment ?? ""])
        try? await Task.sleep(for: .milliseconds(900))
        check("the new session survives", acct.isSignedIn && store.load()?.session.accessToken == next.accessToken
              && !cell.revoked.contains(next.accessToken))

        let old = cell.mint(uuid: ada)
        let s3 = MemorySessionStore(CellStoredAuth(session: old, user: nil))
        let c3 = CellClient(store: s3, configuration: FakeCell.configuration)
        let out = Task { await c3.signOut() }
        try? await Task.sleep(for: .milliseconds(150))
        let adopted = cell.mint(uuid: ada)
        try? await c3.adopt(adopted)
        _ = await out.value
        check("CellClient.signOut revokes its own session, keeps one adopted meanwhile",
              cell.revoked.contains(old.accessToken) && s3.load()?.session.accessToken == adopted.accessToken)
        cell.configure { $0.signOutDelay = 0 }

        section("sign-out with an expired access token (fake cell)")
        let expired = cell.mint(uuid: ada, ttl: -60)
        let s4 = MemorySessionStore(CellStoredAuth(session: expired, user: nil))
        let refreshes = cell.refreshCount
        let ok4 = await CellClient(store: s4, configuration: FakeCell.configuration).signOut()
        check("refreshes first, then the cell revokes it", ok4 && cell.refreshCount == refreshes + 1 && s4.load() == nil
              && !cell.revoked.contains(expired.accessToken) && cell.revoked.count >= 3)
        let rejected = cell.mint(uuid: ada)
        cell.invalidate(rejected.accessToken)
        let s5 = MemorySessionStore(CellStoredAuth(session: rejected, user: nil))
        let ok5 = await CellClient(store: s5, configuration: FakeCell.configuration).signOut()
        check("401 → refresh → retry", ok5 && cell.refreshCount == refreshes + 2 && s5.load() == nil)

        await cloudSyncChecks(cell, user: CellUser(uuid: ada, id: "c:ada", kind: "carbon", displayName: "Ada Lovelace", pfpURL: nil))
        FakeCell.current.value = nil
    }

    private func signedInAccount(_ cell: FakeCell, _ user: CellUser) async -> AccountManager {
        let store = MemorySessionStore(CellStoredAuth(session: cell.mint(uuid: user.uuid), user: user))
        let a = AccountManager(client: CellClient(store: store, configuration: FakeCell.configuration))
        a.restore()
        _ = await waitUntil(3) { a.isSignedIn }
        return a
    }

    private func quickSync(_ client: CellClient, _ dir: URL) -> CloudSync {
        let defaults = UserDefaults(suiteName: "ai.tos.mode.harness.\(UUID().uuidString.prefix(8))")!
        let cloud = CloudSync(client: client, defaults: defaults, ledgerURL: dir.appendingPathComponent("cloud-sync.json"))
        cloud.realtimeEnabled = false
        cloud.urgentDebounce = .milliseconds(20)
        cloud.agentDebounce = .milliseconds(20)
        cloud.heartbeatInterval = .seconds(3600)
        cloud.answerPollInterval = .seconds(3600)
        return cloud
    }

    private func cloudSyncChecks(_ cell: FakeCell, user: CellUser) async {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sync-harness-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }

        section("CloudSync: a refused row doesn't block or drop the rest (fake cell)")
        let acct = await signedInAccount(cell, user)
        let now = Date()
        var sessions = sampleSessions(now: now)
        let poisonNative = "\(NSHomeDirectory())/code/poison#1700000000"
        sessions.append(AgentSession(provider: "aider", nativeID: poisonNative, title: "POISON row", cwd: "\(NSHomeDirectory())/code/poison",
                                     state: .working, updatedAt: now,
                                     recentEvents: [AgentEvent(id: "p1", at: now, kind: .user, text: "hello")]))
        sessions.append(sessions[0])   // the same session reported twice
        let host = FakeHost(sessions: sessions)
        cell.configure {
            $0.reject = { p in
                let rows = p["sessions"] as? [[String: Any]] ?? []
                let ids = rows.compactMap { $0["id"] as? String }
                if Set(ids).count != ids.count { return (400, "21000") }
                return rows.contains { ($0["title"] as? String) == "POISON row" } ? (400, "23514") : nil
            }
        }
        let dev = cell.deviceID
        let claudeUUID = SyncIDs.session(deviceID: dev, provider: "claude_code", nativeID: "harness-claude")
        let poisonUUID = SyncIDs.session(deviceID: dev, provider: "aider", nativeID: poisonNative)
        let cloud = quickSync(acct.client, dir)
        cloud.attach(host: host, account: acct)
        let synced = await waitUntil(8) { cloud.status == .synced && cloud.ledgerSnapshot?.confirmed[claudeUUID] != nil }
        let l = cloud.ledgerSnapshot
        check("rejected batch isolated: synced, the refused session held back", synced && l?.quarantined[poisonUUID] != nil,
              "status=\(cloud.status) quarantined=\(l?.quarantined.keys.map { $0 } ?? [])")
        check("other sessions, their events and the question delivered",
              cell.events(for: claudeUUID) == [1, 2, 3] && l?.outbox.isEmpty == true && l?.pushedQuestions.count == 1,
              "events=\(cell.events(for: claudeUUID)) outbox=\(l?.outbox.count ?? -1) questions=\(l?.pushedQuestions.count ?? -1)")
        check("a session reported twice is sent once", cell.acceptedPushes.allSatisfy { p in
            let ids = (p["sessions"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            return Set(ids).count == ids.count
        } && cell.rejections(code: "21000") == 0)
        let refusedSoFar = cell.rejectedCount
        host.sessions[0].recentEvents.append(AgentEvent(id: "c9", at: Date(), kind: .assistant, text: "done"))
        await cloud.flushNow()
        check("the held-back row isn't resent", cell.rejectedCount == refusedSoFar && cell.events(for: claudeUUID) == [1, 2, 3, 4]
              && !cell.sessionIDs().contains(poisonUUID))
        host.sessions[2].title = "fixed row"
        await cloud.flushNow()
        check("once the row changes it gets another try (with its events)", cloud.ledgerSnapshot?.confirmed[poisonUUID] != nil
              && cloud.ledgerSnapshot?.quarantined[poisonUUID] == nil && cell.sessionIDs().contains(poisonUUID)
              && cell.events(for: poisonUUID) == [1], "\(cell.events(for: poisonUUID))")

        section("CloudSync: transient errors keep everything queued (fake cell)")
        let q1 = host.sessions[1].pendingQuestions[0]
        let q1UUID = SyncIDs.question(deviceID: dev, localID: q1.id)
        host.sessions[1].pendingQuestions = []
        host.sessions[1].state = .working
        host.sessions[0].recentEvents.append(AgentEvent(id: "c10", at: Date(), kind: .assistant, text: "more"))
        cell.configure { $0.failures = [(403, nil), (404, nil), (409, "refresh_in_progress"), (502, nil)] }
        for _ in 0..<4 { await cloud.flushNow() }
        let l2 = cloud.ledgerSnapshot
        check("403 / 404 / 409 / 502 drop nothing", l2?.outbox.contains { $0.sessionID == claudeUUID } == true
              && l2?.pendingUpdates[q1UUID] == "resolved_on_mac" && cell.pendingFailures == 0)
        cell.configure { $0.reject = { _ in (400, "22P02") } }   // the server refuses everything (not our rows)
        await cloud.flushNow()
        let l3 = cloud.ledgerSnapshot
        check("a refusal of everything drops and holds back nothing", l3?.outbox.contains { $0.sessionID == claudeUUID } == true
              && l3?.pendingUpdates[q1UUID] == "resolved_on_mac" && l3?.quarantined.isEmpty == true)
        cell.configure { $0.reject = nil }
        await cloud.flushNow()
        check("delivered once the server is back", cloud.ledgerSnapshot?.outbox.isEmpty == true
              && cloud.ledgerSnapshot?.pendingUpdates.isEmpty == true && cell.events(for: claudeUUID) == [1, 2, 3, 4, 5]
              && cell.updates().contains { $0 == (q1UUID, "resolved_on_mac") })

        section("CloudSync: a new ledger continues from the server (fake cell)")
        let dev2 = UUID().uuidString.lowercased()
        let claude2 = SyncIDs.session(deviceID: dev2, provider: "claude_code", nativeID: "harness-claude")
        let ghost = SyncIDs.session(deviceID: dev2, provider: "codex", nativeID: "gone")
        let ghostQ = SyncIDs.question(deviceID: dev2, localID: "gone-q")
        cell.configure {
            $0.reject = nil
            $0.deviceID = dev2
            $0.rest["events"] = [["session_id": claude2, "seq": 40, "kind": "user", "summary": "Make cloud sync robust"]]
            $0.rest["agent_sessions"] = [["id": ghost, "provider": "codex", "provider_session_id": "gone", "title": "Old work",
                                          "project": "x", "state": "working", "last_event_at": SyncTime.iso(now),
                                          "meta": ["provider_name": "Codex"]]]
            $0.rest["questions"] = [["id": ghostQ, "session_id": ghost]]
        }
        let acct2 = await signedInAccount(cell, user)
        let host2 = FakeHost(sessions: [sampleSessions(now: now)[0]])
        let cloud2 = quickSync(acct2.client, dir.appendingPathComponent("second"))
        cloud2.attach(host: host2, account: acct2)
        _ = await waitUntil(8) { cloud2.status == .synced && !(cloud2.ledgerSnapshot?.live[ghost] != nil) && cloud2.ledgerSnapshot?.confirmed[claude2] != nil }
        let seqs = cell.events(for: claude2)
        check("seqs continue after the server's; events it has aren't resent", seqs == [41, 42], "\(seqs)")
        check("a session left live on the server is ended", cell.endedSessionIDs(device: dev2).contains(ghost))
        check("a question left pending is resolved", cell.updates().contains { $0 == (ghostQ, "cancelled") })
        check("reconciled once", cloud2.ledgerSnapshot?.needsReconcile == false)
    }
}

// MARK: - Fake cell

/// Just enough of the Silicon Mode cell for offline checks: auth (refresh, user, sign-out),
/// register_device, push_batch (accept / refuse / fail on demand) and REST reads.
final class FakeCell: @unchecked Sendable {
    static let current = SyncLock<FakeCell?>(nil)

    static var configuration: URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FakeCellProtocol.self]
        return c
    }

    private let lock = NSLock()
    private var users: [String: [String: Any]] = [:]
    private var access: [String: (uuid: String, exp: Date)] = [:]
    private var refreshTokens: [String: String] = [:]
    private var _revoked: [String] = []
    private var _refreshCount = 0
    private var pushes: [[String: Any]] = []
    private var refusals: [String] = []

    // Configure through `configure` (under the lock).
    var signOutDelay: TimeInterval = 0
    var deviceID = UUID().uuidString.lowercased()
    var reject: (@Sendable ([String: Any]) -> (Int, String?)?)?
    var failures: [(Int, String?)] = []
    var rest: [String: [[String: Any]]] = [:]

    private func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }
    func configure(_ f: (FakeCell) -> Void) { locked { f(self) } }

    var revoked: [String] { locked { _revoked } }
    var refreshCount: Int { locked { _refreshCount } }
    var rejectedCount: Int { locked { refusals.count } }
    var pendingFailures: Int { locked { failures.count } }
    var acceptedPushes: [[String: Any]] { locked { pushes } }
    func rejections(code: String) -> Int { locked { refusals.filter { $0 == code }.count } }

    func addUser(uuid: String, id: String, name: String) {
        locked { users[uuid] = ["uuid": uuid, "id": id, "kind": "carbon", "display_name": name] }
    }

    func mint(uuid: String, ttl: TimeInterval = 1800) -> CellSession {
        let a = "at_" + UUID().uuidString, r = "csr_" + UUID().uuidString
        let exp = Date().addingTimeInterval(ttl)
        locked { access[a] = (uuid, exp); refreshTokens[r] = uuid }
        return CellSession(accessToken: a, refreshToken: r, expiresAt: exp)
    }

    func invalidate(_ token: String) { locked { access[token] = nil } }

    func fragment(_ s: CellSession) -> String {
        "access_token=\(s.accessToken)&refresh_token=\(s.refreshToken)&expires_at=\(Int(s.expiresAt.timeIntervalSince1970))"
    }

    /// Accepted event seqs for a session, in push order.
    func events(for session: String) -> [Int] {
        acceptedPushes.flatMap { ($0["events"] as? [[String: Any]]) ?? [] }
            .filter { $0["session_id"] as? String == session }
            .compactMap { ($0["seq"] as? NSNumber)?.intValue }
    }

    func sessionIDs() -> Set<String> {
        Set(acceptedPushes.flatMap { ($0["sessions"] as? [[String: Any]]) ?? [] }.compactMap { $0["id"] as? String })
    }

    func endedSessionIDs(device: String) -> Set<String> {
        Set(acceptedPushes.filter { $0["device_id"] as? String == device }
            .flatMap { ($0["sessions"] as? [[String: Any]]) ?? [] }
            .filter { $0["ended_at"] is String }.compactMap { $0["id"] as? String })
    }

    func updates() -> [(String, String)] {
        acceptedPushes.flatMap { ($0["question_updates"] as? [[String: Any]]) ?? [] }
            .compactMap { u in (u["id"] as? String).flatMap { id in (u["state"] as? String).map { (id, $0) } } }
    }

    func respond(_ r: URLRequest, body: Data?) -> (Int, Data, TimeInterval) {
        func json(_ o: Any) -> Data { (try? JSONSerialization.data(withJSONObject: o, options: [.fragmentsAllowed])) ?? Data() }
        func err(_ s: Int, _ code: String) -> (Int, Data, TimeInterval) { (s, json(["error": ["code": code, "message": code]]), 0) }
        let path = r.url?.path ?? ""
        let method = r.httpMethod ?? "GET"
        let bearer = r.value(forHTTPHeaderField: "Authorization").map { $0.replacingOccurrences(of: "Bearer ", with: "") }
        let obj = body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        lock.lock(); defer { lock.unlock() }
        func user(_ token: String?) -> [String: Any]? {
            guard let t = token, let a = access[t], a.exp > Date() else { return nil }
            return users[a.uuid]
        }
        switch (method, path) {
        case ("POST", "/auth/refresh"):
            guard let old = obj?["refresh_token"] as? String, let uuid = refreshTokens.removeValue(forKey: old) else {
                return err(401, "refresh_token_reuse")
            }
            _refreshCount += 1
            let a = "at_" + UUID().uuidString, rt = "csr_" + UUID().uuidString
            let exp = Date().addingTimeInterval(1800)
            access[a] = (uuid, exp); refreshTokens[rt] = uuid
            return (200, json(["access_token": a, "refresh_token": rt, "expires_at": exp.timeIntervalSince1970,
                               "user": users[uuid] ?? [:]]), 0)
        case ("GET", "/auth/user"):
            guard let u = user(bearer) else { return err(401, "cell_session_required") }
            return (200, json(["user": u]), 0)
        case ("POST", "/auth/sign-out"):
            guard user(bearer) != nil, let t = bearer else { return err(401, "cell_session_required") }
            _revoked.append(t)
            access[t] = nil
            return (200, json(["signed_out": true]), signOutDelay)
        default:
            break
        }
        guard user(bearer) != nil else { return err(401, "cell_session_required") }
        if path == "/rest/v1/rpc/register_device" { return (200, json(deviceID), 0) }
        if path == "/rest/v1/rpc/push_batch" {
            let p = obj?["p"] as? [String: Any] ?? [:]
            if !failures.isEmpty {
                let f = failures.removeFirst()
                refusals.append(f.1 ?? "\(f.0)")
                return (f.0, json(f.1.map { ["code": $0, "message": "failed"] } ?? [:]), 0)
            }
            if let refusal = reject?(p) {
                refusals.append(refusal.1 ?? "\(refusal.0)")
                return (refusal.0, json(["code": refusal.1 ?? "", "message": "rejected"]), 0)
            }
            pushes.append(p)
            return (200, json(["server_time": SyncTime.iso(Date()), "answers": [Any]()]), 0)
        }
        if method == "GET", path.hasPrefix("/rest/v1/") {
            return (200, json(rest[String(path.dropFirst("/rest/v1/".count))] ?? []), 0)
        }
        return err(404, "not_found")
    }
}

/// Routes every request of a `FakeCell.configuration` session to `FakeCell.current`.
final class FakeCellProtocol: URLProtocol, @unchecked Sendable {
    private let stopped = SyncLock(false)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let cell = FakeCell.current.value, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let body = request.httpBody ?? request.httpBodyStream.map(Self.readAll)
        let (status, data, delay) = cell.respond(request, body: body)
        let finish: @Sendable () -> Void = { [self] in
            guard !stopped.value else { return }
            let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        if delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: finish) } else { finish() }
    }

    override func stopLoading() { stopped.value = true }

    private static func readAll(_ s: InputStream) -> Data {
        s.open(); defer { s.close() }
        var d = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while s.hasBytesAvailable {
            let n = s.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            d.append(buf, count: n)
        }
        return d
    }
}
#endif
