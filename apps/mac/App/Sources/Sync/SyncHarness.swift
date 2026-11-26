#if SYNC_HARNESS
// Headless end-to-end harness for the Sync module (compiled only with -D SYNC_HARNESS; empty in the app).
//
// Build + run (from apps/mac):
//   xcrun swiftc -swift-version 6 -D SYNC_HARNESS -module-name SiliconModeKit -parse-as-library \
//     $(find SiliconModeKit/Sources -name '*.swift') App/Sources/Sync/*.swift -o /tmp/sync-harness
//   /tmp/sync-harness            # offline checks (ids, mapping, redaction, ledger, loopback server, keychain)
//   /tmp/sync-harness --live     # + live end-to-end against the Silicon Cell (needs `silicon-accounts` signed in)
//
// The live run signs in through the real loopback page (a simulated browser POSTs the fragment),
// pushes realistic batches through CloudSync, answers questions via rpc/answer_question and checks
// they arrive over realtime / the push reply, then signs out and deletes its test device.
import Foundation
import Security

@main
struct SyncHarnessMain {
    @MainActor static func main() async {
        #if SYNC_HARNESS_UI
        if let i = CommandLine.arguments.firstIndex(of: "--snapshots"), i + 2 < CommandLine.arguments.count {
            SyncUISnapshots.render(fontPath: CommandLine.arguments[i + 1], outDir: CommandLine.arguments[i + 2])
            exit(0)
        }
        #endif
        let live = CommandLine.arguments.contains("--live")
        let h = Harness()
        await h.offline()
        if live { await h.live() }
        print("\n\(h.passed) passed, \(h.failed) failed")
        exit(h.failed == 0 ? 0 : 1)
    }
}

@MainActor
final class Harness {
    var passed = 0
    var failed = 0

    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1; print("  ✓ \(name)") } else { failed += 1; print("  ✗ \(name) \(detail())") }
    }

    func section(_ s: String) { print("\n== \(s)") }

    func waitUntil(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return cond()
    }

    // MARK: Offline

    func offline() async {
        section("ids + mapping")
        check("uuidv5 RFC vector", SyncIDs.uuidV5(UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!, "www.example.com")
              == "2ed6657d-e927-568b-95e1-2665a8aea6a2")
        let dev = "0f8fad5b-d9cb-469f-a165-70867728950e"
        let sid = SyncIDs.session(deviceID: dev.uppercased(), provider: "claude_code", nativeID: "abc")
        check("session id lowercase + deterministic", sid == sid.lowercased() && sid == SyncIDs.session(deviceID: dev, provider: "claude_code", nativeID: "abc"))
        check("provider claude-code → claude_code", SyncIDs.wireProvider("claude-code") == "claude_code")
        check("provider sanitized", SyncIDs.wireProvider("My Agent/2") == "my_agent_2")

        let s = sampleSessions(now: Date())
        let row = SyncMapper.sessionRow(s[1], deviceID: dev)
        let json = String(decoding: try! JSONEncoder().encode(row), as: UTF8.self)
        check("no cwd in session row", !json.contains("cwd") && !json.contains("/Users/"), json)
        check("needsYou → waiting/permission", row.state == "waiting" && row.waitingReason == "permission")
        check("project = folder name", row.project == "silicon-mode")
        let q = SyncMapper.questionRow(s[1].pendingQuestions[0], deviceID: dev, sessionUUID: row.id)
        check("question roles", q.options.map(\.role) == ["allow", "allow", "deny"], "\(q.options.map(\.role))")
        check("states", ["working", "waiting", "finished", "idle", "failed"] ==
              [AgentState.working, .needsYou, .finished, .idle, .error].map(SyncMapper.state))

        section("callback parsing")
        let frag = "access_token=eyJabc.eyJexp.sig&refresh_token=csr_123&expires_at=1795669887"
        if case .tokens(let t) = CallbackPayload.parse(fragment: frag, query: nil) {
            check("fragment tokens", t.accessToken == "eyJabc.eyJexp.sig" && t.refreshToken == "csr_123"
                  && t.expiresAt == Date(timeIntervalSince1970: 1795669887))
        } else { check("fragment tokens", false) }
        check("denied", CallbackPayload.parse(fragment: nil, query: "error=access_denied") == .denied("access_denied"))
        check("invalid", CallbackPayload.parse(fragment: "foo=bar", query: nil) == .invalid)
        if case .tokens = CallbackPayload.parse(url: URL(string: "ai.tos.mode://auth/callback#\(frag)")!) { check("custom scheme url", true) }
        else { check("custom scheme url", false) }

        section("redaction")
        let r = SyncRedactor.clean("export OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuv in \(NSHomeDirectory())/code; Bearer abcdefghijklmnopqrstuvwxyz; ghp_abcdefghijklmnopqrstuvwxyz0123")
        check("secrets redacted", !r.contains("sk-proj") && !r.contains("ghp_") && !r.contains("abcdefghijklmnopqrstuvwxyz") && r.contains("~/code"), r)
        check("summary ≤ 500 scalars", SyncMapper.eventSummary(String(repeating: "é", count: 900)).unicodeScalars.count <= 500)

        section("ledger")
        var l = SyncLedger(deviceID: dev)
        let evs = (1...3).map { SyncLedger.LocalEvent(id: "e\($0)", at: "t", kind: "log", summary: "s", detail: nil) }
        check("enqueue 3", l.enqueue(sessionUUID: "S", events: evs) == 3)
        check("dedupe", l.enqueue(sessionUUID: "S", events: evs) == 0)
        check("seqs 1…3", l.outbox.map(\.seq) == [1, 2, 3])
        l.acknowledge(events: Array(l.outbox.prefix(2)))
        _ = l.enqueue(sessionUUID: "S", events: evs + [.init(id: "e4", at: "t", kind: "log", summary: "s", detail: nil)])
        check("contiguous after ack", l.outbox.map(\.seq) == [3, 4])

        section("usage rows")
        let tracker = UsageTracker(url: nil)
        let now = Date()
        tracker.sample(at: now.addingTimeInterval(-20), running: [(id: "a", provider: "claude-code"), (id: "b", provider: "codex")], siliconModeActive: true)
        tracker.sample(at: now, running: [(id: "a", provider: "claude-code"), (id: "b", provider: "codex")], siliconModeActive: true)
        let rows = tracker.recent(now: now).compactMap(SyncMapper.usageRow)
        check("usage row", rows.count >= 1 && rows.last!.maxConcurrent == 2 && rows.last!.byProvider["claude_code"] != nil, "\(rows)")
        if let u = rows.last, let d = SyncTime.parse(u.hourStart) {
            check("hour_start on a 15-min boundary", Int(d.timeIntervalSince1970) % 900 == 0)
        }

        section("loopback server")
        await loopbackChecks()

        section("keychain store")
        let ks = KeychainSessionStore(service: "ai.tos.mode.session.harness.\(UUID().uuidString.prefix(8))")
        let a = CellStoredAuth(session: CellSession(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 2_000_000_000)), user: nil)
        do { try ks.save(a); check("keychain round trip", ks.load() == a) } catch { check("keychain save", false, "\(error)") }
        ks.clear()
        check("keychain cleared", ks.load() == nil)
    }

    private func loopbackChecks() async {
        let port: UInt16 = 47_391
        let got = SyncLock<String?>(nil)
        let server = LoopbackAuthServer(port: port) { frag, _ in
            got.value = frag
            return LoopbackResult(ok: true, title: "You're signed in", message: "m", name: "N", handle: "si:x")
        }
        do { try await server.start() } catch { check("listener start", false, "\(error)"); return }
        let base = "http://127.0.0.1:\(port)"
        let (page, resp) = await httpGet("\(base)/auth/callback")
        check("page served", resp?.statusCode == 200 && page.contains("Finishing sign-in"))
        check("CSP + no-store", (resp?.value(forHTTPHeaderField: "Content-Security-Policy") ?? "").contains("script-src 'nonce-")
              && resp?.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        let secret = Self.secret(in: page)
        check("secret embedded", secret != nil && secret == server.pageSecret)
        let body = try! JSONSerialization.data(withJSONObject: ["fragment": "access_token=x", "query": ""])
        let noSecret = await httpPost("\(base)/auth/complete", body: body, headers: ["Origin": base])
        check("POST without secret → 403", noSecret.1 == 403)
        let badOrigin = await httpPost("\(base)/auth/complete", body: body, headers: ["Origin": "https://evil.example", "X-Silicon-Mode": secret ?? ""])
        check("cross-origin POST → 403", badOrigin.1 == 403)
        let ok = await httpPost("\(base)/auth/complete", body: body, headers: ["Origin": base, "X-Silicon-Mode": secret ?? ""])
        check("POST → handler", ok.1 == 200 && got.value == "access_token=x" && ok.0.contains("\"ok\":true"), "\(ok)")
        server.stop()
    }

    static func secret(in page: String) -> String? {
        guard let r = page.range(of: #""X-Silicon-Mode":""#) else { return nil }
        let rest = page[r.upperBound...]
        return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
    }

    // MARK: Live

    func live() async {
        section("live: sign-in through the loopback page")
        guard let t1 = await mintSession() else { check("SLT → /auth/silicon", false); return }
        check("SLT → /auth/silicon", true)

        // The hosted sign-in URL must be accepted by the cell (exact redirect match → 303 to Accounts).
        let (_, signInResp) = await httpGet(CellConfig.signInURL(redirectTo: CellConfig.loopbackRedirect).absoluteString, followRedirects: false)
        let loc = signInResp?.value(forHTTPHeaderField: "Location") ?? ""
        check("cell accepts loopback redirect_to", (signInResp?.statusCode ?? 0) / 100 == 3 && loc.contains("accounts.teamofsilicons.com/authorize"),
              "\(signInResp?.statusCode ?? 0)")

        let service = "ai.tos.mode.session.harness.\(UUID().uuidString.prefix(8))"
        let store = KeychainSessionStore(service: service)
        let client = CellClient(store: store)
        let account = AccountManager(client: client)
        let fragment = "access_token=\(t1.accessToken)&refresh_token=\(t1.refreshToken)&expires_at=\(Int(t1.expiresAt.timeIntervalSince1970))"
        var browserResult = ""
        account.openURL = { url in
            // Simulated browser: the cell would 302 to redirect_to#<fragment>; load our page, run its "script".
            Task { @MainActor in
                let (page, _) = await self.httpGet(CellConfig.loopbackRedirect)
                guard let secret = Self.secret(in: page) else { browserResult = "no secret"; return }
                let body = try! JSONSerialization.data(withJSONObject: ["fragment": fragment, "query": ""])
                let r = await self.httpPost("http://127.0.0.1:\(CellConfig.loopbackPort)/auth/complete", body: body,
                                            headers: ["Origin": CellConfig.loopbackOrigin, "X-Silicon-Mode": secret])
                browserResult = r.0
            }
        }
        account.signIn()
        let signedIn = await waitUntil(20) { account.isSignedIn }
        _ = await waitUntil(5) { !browserResult.isEmpty }
        check("signed in via loopback", signedIn, "state=\(account.state) browser=\(browserResult.prefix(200))")
        check("page reports success with profile", browserResult.contains("\"ok\":true") && browserResult.contains("\"handle\""))
        check("profile loaded", account.account?.uuid.count == 36 && !(account.account?.displayName.isEmpty ?? true),
              "\(String(describing: account.account))")
        check("session persisted to keychain", store.load()?.session.refreshToken == t1.refreshToken)
        check("callback ignored when not signing in", { account.handleCallback(URL(string: "ai.tos.mode://auth/callback#\(fragment)")!); return account.state == .signedIn }())

        section("live: refresh + 401 retry")
        let before = store.load()?.session.refreshToken
        await client.debugExpireSoon()
        let tok = try? await client.accessToken()
        let after = store.load()?.session.refreshToken
        check("refresh rotated + persisted before use", tok != nil && after != nil && after != before && store.load()?.session.accessToken == tok)
        await client.debugCorruptAccessToken()
        let u = try? await client.fetchUser()
        check("401 → refresh → retry", u != nil)

        section("live: CloudSync push")
        let host = FakeHost(sessions: sampleSessions(now: Date()))
        let suite = "ai.tos.mode.harness.\(UUID().uuidString.prefix(8))"
        let defaults = UserDefaults(suiteName: suite)!
        let ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(suite)-ledger.json")
        let cloud = CloudSync(client: client, defaults: defaults, ledgerURL: ledgerURL)
        cloud.deviceInfo = {
            var i = SyncDeviceInfo.current(); i.name = "Silicon Mode Sync Harness"; return i
        }
        cloud.realtimeLinger = .milliseconds(200)
        cloud.attach(host: host, account: account)
        let synced = await waitUntil(20) { cloud.status == .synced && cloud.deviceID != nil }
        check("registered + first push", synced, "status=\(cloud.status)")
        guard let dev = cloud.deviceID else { await cleanup(account: account, client: client, deviceID: nil, store: store); return }
        check("device id lowercase", dev == dev.lowercased())

        let devRows = await rest(client, "devices", ["id": "eq.\(dev)", "select": "id,name,kind,model,os_version,timezone"])
        check("devices row", devRows.first?["kind"] as? String == "mac" && devRows.first?["name"] as? String == "Silicon Mode Sync Harness", "\(devRows)")
        let sess = await rest(client, "agent_sessions", ["device_id": "eq.\(dev)", "select": "id,provider,provider_session_id,cwd,project,state,waiting_reason,title"])
        check("2 sessions", sess.count == 2, "\(sess.count)")
        check("providers normalized", Set(sess.compactMap { $0["provider"] as? String }) == ["claude_code", "codex"])
        check("no cwd stored", sess.allSatisfy { $0["cwd"] is NSNull })
        check("waiting session", sess.contains { $0["state"] as? String == "waiting" && $0["waiting_reason"] as? String == "permission" })
        let claudeUUID = SyncIDs.session(deviceID: dev, provider: "claude_code", nativeID: "harness-claude")
        check("session uuidv5", sess.contains { $0["id"] as? String == claudeUUID })
        var events = await rest(client, "events", ["device_id": "eq.\(dev)", "session_id": "eq.\(claudeUUID)", "select": "seq,kind,summary", "order": "seq"])
        check("events seq 1…3", events.compactMap { ($0["seq"] as? NSNumber)?.intValue } == [1, 2, 3], "\(events)")
        check("event redacted", !(events.compactMap { $0["summary"] as? String }.joined().contains("sk-proj")))
        let qs = await rest(client, "questions", ["device_id": "eq.\(dev)", "select": "id,state,kind,options,allow_text"])
        check("question pending", qs.count == 1 && qs.first?["state"] as? String == "pending", "\(qs)")
        let st = await rest(client, "device_status", ["device_id": "eq.\(dev)", "select": "*"])
        check("device_status", st.first?["mode"] as? String == "active" && (st.first?["agents_waiting"] as? NSNumber)?.intValue == 1
              && (st.first?["questions_pending"] as? NSNumber)?.intValue == 1 && st.first?["online"] as? Bool == true, "\(st)")
        let usage = await rest(client, "usage_hourly", ["device_id": "eq.\(dev)", "select": "hour_start,local_hour,agent_seconds,max_concurrent,by_provider"])
        check("usage_hourly rows", !usage.isEmpty, "\(usage)")

        section("live: incremental events")
        host.sessions[0].recentEvents.append(AgentEvent(id: "c4", at: Date(), kind: .tool, text: "Bash: swift test"))
        host.sessions[0].recentEvents.append(AgentEvent(id: "c5", at: Date().addingTimeInterval(0.1), kind: .assistant, text: "All 42 tests passed."))
        host.sessions[0].updatedAt = Date()
        cloud.agentsChanged()
        _ = await waitUntil(8) { cloud.ledgerSnapshot?.seqs[claudeUUID]?.next == 6 && cloud.ledgerSnapshot?.outbox.isEmpty == true }
        try? await Task.sleep(for: .milliseconds(500))
        events = await rest(client, "events", ["device_id": "eq.\(dev)", "session_id": "eq.\(claudeUUID)", "select": "seq", "order": "seq"])
        check("events seq 1…5 (contiguous, deduped)", events.compactMap { ($0["seq"] as? NSNumber)?.intValue } == [1, 2, 3, 4, 5], "\(events)")

        section("live: answer over realtime")
        let live = await waitUntil(15) { cloud.realtimeLive }
        check("realtime socket live (Silicon Mode active)", live)
        let q1 = host.sessions[1].pendingQuestions[0]
        let q1UUID = SyncIDs.question(deviceID: dev, localID: q1.id)
        let t0 = Date()
        let ans = await rpc(client, "answer_question", ["p_question": q1UUID, "p_option": "allow", "p_from": "android"])
        check("answer_question ok", ans?["ok"] as? Bool == true, "\(String(describing: ans))")
        let applied = await waitUntil(10) { host.applied.contains { $0.question.id == q1.id } }
        let latency = Date().timeIntervalSince(t0)
        check(String(format: "answer applied on Mac in %.2fs", latency), applied && latency < 8)
        check("applied with option + phone source", host.applied.first?.optionIDs == ["allow"] && host.applied.first?.source == .phone)
        _ = await waitUntil(8) { cloud.ledgerSnapshot?.pendingConsumed.isEmpty == true && cloud.ledgerSnapshot?.pendingUpdates.isEmpty == true }
        try? await Task.sleep(for: .milliseconds(300))
        var aRows = await rest(client, "answers", ["question_id": "eq.\(q1UUID)", "select": "consumed_at,outcome"])
        check("answer consumed (applied)", aRows.first?["outcome"] as? String == "applied" && !(aRows.first?["consumed_at"] is NSNull), "\(aRows)")
        var qRow = await rest(client, "questions", ["id": "eq.\(q1UUID)", "select": "state"])
        check("question → answered", qRow.first?["state"] as? String == "answered", "\(qRow)")

        section("live: answer via push_batch reply (no socket)")
        host.mode = .off
        cloud.modeChanged()
        let closed = await waitUntil(5) { !cloud.realtimeLive }
        check("socket closes when not needed", closed)
        cloud.realtimeEnabled = false
        let q2 = AgentQuestion(id: "harness-q2", sessionID: host.sessions[1].id, provider: "codex", kind: .question,
                               title: "Which database?", detail: "Pick one for the cache layer.",
                               options: [.init(id: "sqlite", label: "SQLite", style: .primary), .init(id: "redis", label: "Redis")],
                               allowsFreeText: true)
        host.sessions[1].pendingQuestions = [q2]
        host.sessions[1].state = .needsYou
        cloud.agentsChanged()
        let q2UUID = SyncIDs.question(deviceID: dev, localID: q2.id)
        _ = await waitUntil(8) { cloud.ledgerSnapshot?.pushedQuestions[q2UUID] != nil }
        let ans2 = await rpc(client, "answer_question", ["p_question": q2UUID, "p_text": "Use SQLite, keep it simple", "p_from": "web"])
        check("text answer accepted", ans2?["ok"] as? Bool == true, "\(String(describing: ans2))")
        let dup = await rpc(client, "answer_question", ["p_question": q2UUID, "p_option": "redis", "p_from": "iphone"])
        check("second answer loses the race", dup?["ok"] as? Bool == false, "\(String(describing: dup))")
        await cloud.flushNow()
        let applied2 = await waitUntil(10) { host.applied.contains { $0.question.id == q2.id } }
        check("text answer applied from the push reply (web source)",
              applied2 && host.applied.last?.text == "Use SQLite, keep it simple" && host.applied.last?.source == .web)
        _ = await waitUntil(8) { cloud.ledgerSnapshot?.pendingConsumed.isEmpty == true }
        try? await Task.sleep(for: .milliseconds(300))
        aRows = await rest(client, "answers", ["question_id": "eq.\(q2UUID)", "select": "consumed_at,outcome"])
        check("text answer consumed", aRows.first?["outcome"] as? String == "applied", "\(aRows)")
        check("applied exactly once", host.applied.filter { $0.question.id == q2.id }.count == 1)
        cloud.realtimeEnabled = true

        section("live: resolved on Mac + session end")
        let q3 = AgentQuestion(id: "harness-q3", sessionID: host.sessions[1].id, provider: "codex", kind: .permission,
                               title: "Allow Edit: Package.swift?", options: AgentQuestion.permissionOptions())
        host.sessions[1].pendingQuestions = [q3]
        host.sessions[1].state = .needsYou
        cloud.agentsChanged()
        let q3UUID = SyncIDs.question(deviceID: dev, localID: q3.id)
        _ = await waitUntil(8) { cloud.ledgerSnapshot?.pushedQuestions[q3UUID] != nil }
        let reopened = await waitUntil(10) { cloud.realtimeLive }
        check("socket opens for a pending question (mode off)", reopened)
        host.sessions[1].pendingQuestions = []      // answered in the terminal
        host.sessions[1].state = .working
        cloud.agentsChanged()
        _ = await waitUntil(8) { cloud.ledgerSnapshot?.pendingUpdates.isEmpty == true && cloud.ledgerSnapshot?.pushedQuestions[q3UUID] == nil }
        try? await Task.sleep(for: .milliseconds(300))
        qRow = await rest(client, "questions", ["id": "eq.\(q3UUID)", "select": "state"])
        check("question → resolved_on_mac", qRow.first?["state"] as? String == "resolved_on_mac", "\(qRow)")
        let codexUUID = SyncIDs.session(deviceID: dev, provider: "codex", nativeID: "harness-codex")
        host.sessions.remove(at: 1)
        cloud.agentsChanged()
        _ = await waitUntil(8) { cloud.ledgerSnapshot?.live[codexUUID] == nil }
        let ended = await rest(client, "agent_sessions", ["id": "eq.\(codexUUID)", "select": "state,ended_at"])
        check("vanished session ended", !(ended.first?["ended_at"] is NSNull) && ended.first?["ended_at"] != nil, "\(ended)")

        section("live: 401 during push")
        await client.debugCorruptAccessToken()
        host.sessions[0].recentEvents.append(AgentEvent(id: "c6", at: Date(), kind: .status, text: "Turn finished"))
        host.sessions[0].state = .finished
        cloud.agentsChanged()
        _ = await waitUntil(10) { cloud.ledgerSnapshot?.seqs[claudeUUID]?.next == 7 && cloud.ledgerSnapshot?.outbox.isEmpty == true }
        try? await Task.sleep(for: .milliseconds(300))
        events = await rest(client, "events", ["session_id": "eq.\(claudeUUID)", "select": "seq", "order": "seq"])
        check("push recovered after 401", events.count == 6 && cloud.status == .synced, "\(events.count) \(cloud.status)")

        section("live: realtime 4401 → refresh → reconnect")
        host.mode = .active
        cloud.modeChanged()
        _ = await waitUntil(10) { cloud.realtimeLive }
        host.mode = .off; host.sessions[0].pendingQuestions = []
        cloud.modeChanged()
        _ = await waitUntil(5) { !cloud.realtimeLive }
        await client.debugCorruptAccessToken()
        host.mode = .locked
        cloud.modeChanged()
        let relive = await waitUntil(20) { cloud.realtimeLive }
        check("socket recovers from a rejected token", relive)
        let st2 = await rest(client, "device_status", ["device_id": "eq.\(dev)", "select": "mode"])
        check("mode locked synced", st2.first?["mode"] as? String == "locked", "\(st2)")

        await cleanup(account: account, client: client, deviceID: dev, store: store)
        try? FileManager.default.removeItem(at: ledgerURL)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    private func cleanup(account: AccountManager, client: CellClient, deviceID: String?, store: KeychainSessionStore) async {
        section("live: sign out + cleanup")
        account.signOut()
        let out = await waitUntil(10) { store.load() == nil }
        check("signed out: keychain cleared", out && !account.isSignedIn)
        // Fresh session for verification + cleanup (the first one is revoked now).
        guard let t = await mintSession() else { check("cleanup session", false); return }
        let c2 = CellClient(store: MemorySessionStore())
        try? await c2.adopt(t)
        if let deviceID {
            let st = await rest(c2, "device_status", ["device_id": "eq.\(deviceID)", "select": "online"])
            check("Mac marked offline on sign-out", st.first?["online"] as? Bool == false, "\(st)")
        }
        // handleCallback path (bounce page → ai.tos.mode://auth/callback#…) with this session.
        let acc2 = AccountManager(client: CellClient(store: MemorySessionStore()))
        acc2.openURL = { _ in }
        await acc2.startSignIn(openBrowser: false)
        if let t3 = await mintSession() {
            let frag = "access_token=\(t3.accessToken)&refresh_token=\(t3.refreshToken)&expires_at=\(Int(t3.expiresAt.timeIntervalSince1970))"
            acc2.handleCallback(URL(string: "ai.tos.mode://auth/callback#\(frag)")!)
            let ok = await waitUntil(15) { acc2.isSignedIn }
            check("ai.tos.mode://auth/callback sign-in", ok, "\(acc2.state)")
            acc2.signOut()
            _ = await waitUntil(5) { !acc2.isSignedIn }
        }
        // Delete test devices (this run + leftovers from earlier runs).
        let mine = await rest(c2, "devices", ["name": "eq.Silicon Mode Sync Harness", "select": "id"])
        var deleted = 0
        for d in mine {
            guard let id = d["id"] as? String else { continue }
            if (try? await c2.send("DELETE", "rest/v1/devices", query: [URLQueryItem(name: "id", value: "eq.\(id)")])) != nil { deleted += 1 }
        }
        check("deleted \(deleted) test device(s)", deleted == mine.count && deleted >= (deviceID == nil ? 0 : 1))
        await c2.signOut()
    }

    // MARK: Live helpers

    func mintSession() async -> CellSession? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: NSHomeDirectory() + "/.apps/bin/silicon-accounts")
        p.arguments = ["login", "--app", "silicon-mode", "-q"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let slt = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard slt.hasPrefix("slt_") else { return nil }
        var r = URLRequest(url: CellConfig.baseURL.appending(path: "auth/silicon"))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(CellConfig.publishableKey, forHTTPHeaderField: "apikey")
        r.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["slt": slt, "app": CellConfig.appID, "cookie": false])
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
              let t = try? JSONDecoder().decode(CellTokenResponse.self, from: d) else { return nil }
        return t.session
    }

    func rest(_ c: CellClient, _ table: String, _ q: [String: String]) async -> [[String: Any]] {
        let items = q.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let d = try? await c.send("GET", "rest/v1/\(table)", query: items) else { return [] }
        return (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] ?? []
    }

    func rpc(_ c: CellClient, _ fn: String, _ args: [String: Any]) async -> [String: Any]? {
        guard let body = try? JSONSerialization.data(withJSONObject: args),
              let d = try? await c.rpc(fn, body) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    func httpGet(_ url: String, followRedirects: Bool = true) async -> (String, HTTPURLResponse?) {
        let s = followRedirects ? URLSession.shared : URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        guard let (d, r) = try? await s.data(from: URL(string: url)!) else { return ("", nil) }
        return (String(decoding: d, as: UTF8.self), r as? HTTPURLResponse)
    }

    func httpPost(_ url: String, body: Data, headers: [String: String]) async -> (String, Int) {
        var r = URLRequest(url: URL(string: url)!)
        r.httpMethod = "POST"
        r.httpBody = body
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        guard let (d, resp) = try? await URLSession.shared.data(for: r) else { return ("", 0) }
        return (String(decoding: d, as: UTF8.self), (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    // MARK: Fixtures

    func sampleSessions(now: Date) -> [AgentSession] {
        let home = NSHomeDirectory()
        let claude = AgentSession(
            provider: "claude-code", nativeID: "harness-claude", title: "Refactor the sync engine",
            cwd: "\(home)/code/silicon-mode", state: .working, startedAt: now.addingTimeInterval(-600), updatedAt: now,
            pid: 4242, model: "claude-opus",
            recentEvents: [
                AgentEvent(id: "c1", at: now.addingTimeInterval(-30), kind: .user, text: "Make cloud sync robust"),
                AgentEvent(id: "c2", at: now.addingTimeInterval(-20), kind: .tool, text: "Edit \(home)/code/silicon-mode/App/Sync.swift"),
                AgentEvent(id: "c3", at: now.addingTimeInterval(-10), kind: .tool, text: "Bash: OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwx swift build"),
            ])
        let codex = AgentSession(
            provider: "codex", nativeID: "harness-codex", title: "Fix flaky test",
            cwd: "\(home)/work/silicon-mode", state: .needsYou, startedAt: now.addingTimeInterval(-300), updatedAt: now,
            recentEvents: [AgentEvent(id: "x1", at: now.addingTimeInterval(-5), kind: .permission, text: "Wants to run: rm -rf build")],
            pendingQuestions: [AgentQuestion(id: "harness-q1", sessionID: "codex:harness-codex", provider: "codex", kind: .permission,
                                             title: "Run Bash command", detail: "rm -rf build",
                                             options: AgentQuestion.permissionOptions(), createdAt: now)])
        return [claude, codex]
    }
}

/// Stand-in for AppModel.
@MainActor
final class FakeHost: SyncHost {
    struct Applied { var question: AgentQuestion; var optionIDs: [String]; var text: String?; var source: AgentAnswer.Source }
    var sessions: [AgentSession]
    var mode: SyncLocalState.Mode = .active
    var enabled = true
    var applied: [Applied] = []
    /// Simulates the Mac being busy (answers wait until it is cleared).
    var blockApply = false
    let tracker = UsageTracker(url: nil)

    init(sessions: [AgentSession]) {
        self.sessions = sessions
        let now = Date()
        let running = sessions.map { (id: $0.id, provider: $0.provider) }
        tracker.sample(at: now.addingTimeInterval(-3700), running: running, siliconModeActive: true)
        tracker.sample(at: now.addingTimeInterval(-3690), running: running, siliconModeActive: true)
        tracker.sample(at: now.addingTimeInterval(-20), running: running, siliconModeActive: true)
        tracker.sample(at: now, running: running, siliconModeActive: true)
    }

    var cloudSyncEnabled: Bool { enabled }

    func syncLocalState() -> SyncLocalState {
        SyncLocalState(mode: mode, enteredAt: Date().addingTimeInterval(-120), lidAngle: 61.4, siliconAngle: 62,
                       caffeinated: mode != .off, face: "bounce", sessions: sessions)
    }

    func usageBuckets(days: Int?) -> [UsageBucket] {
        days.map { tracker.history(days: $0) } ?? tracker.recent()
    }

    func applyCloudAnswer(_ q: AgentQuestion, optionIDs: [String], text: String?, source: AgentAnswer.Source) async -> SyncAnswerOutcome {
        while blockApply { try? await Task.sleep(for: .milliseconds(50)) }
        applied.append(Applied(question: q, optionIDs: optionIDs, text: text, source: source))
        for i in sessions.indices {
            sessions[i].pendingQuestions.removeAll { $0.id == q.id }
            if sessions[i].pendingQuestions.isEmpty, sessions[i].state == .needsYou { sessions[i].state = .working }
        }
        return .applied
    }
}

#if SYNC_HARNESS_UI
import SwiftUI
import CoreText

/// `--snapshots <AlloVariable.ttf> <out dir>`: render every SyncPreviews variant, light + dark.
/// Build with `-D SYNC_HARNESS_UI` and add `App/Sources/Design/Theme.swift` to the swiftc inputs.
@MainActor
enum SyncUISnapshots {
    static func render(fontPath: String, outDir: String) {
        CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: fontPath) as CFURL, .process, nil)
        _ = NSApplication.shared
        // Warm-up pass: the first few offscreen renders skip glass controls.
        for (_, view) in SyncPreviews.variants.prefix(3) { _ = ImageRenderer(content: view.frame(width: 568, height: 200)).cgImage }
        for (id, view) in SyncPreviews.variants {
            for dark in [false, true] {
                let content = view
                    .frame(width: 568, height: 200)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let r = ImageRenderer(content: content)
                r.scale = 2
                NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                    guard let cg = r.cgImage else { print("render failed \(id)"); return }
                    let out = "\(outDir)/\(id)-\(dark ? "dark" : "light").png"
                    try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                    print(out)
                }
            }
        }
    }
}
#endif

final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}
#endif
