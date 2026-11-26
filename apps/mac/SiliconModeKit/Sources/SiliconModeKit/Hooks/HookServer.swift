import Foundation
import Darwin

/// Unix-socket server that `silicon-mode-hook` connects to. Tracks hook-reported session state
/// and can hold blocking hook calls (e.g. Claude Code `PermissionRequest`) open until the human
/// answers from the menu bar / overlay / phone, or `holdDuration()` elapses.
///
/// Protocol: the helper sends one `HookWire.Request` JSON line; the server answers with one
/// `HookWire.Response` line. Observation events are answered immediately with a pass-through;
/// `PermissionRequest` is held (no thread blocks while it is held: every connection is a
/// non-blocking fd watched by a dispatch source on one serial queue).
///
/// A held prompt is released (pass-through: the agent's own prompt decides) when:
/// - `holdDuration(agent)` has elapsed (re-evaluated every second, so leaving Silicon Mode
///   releases Codex prompts immediately),
/// - the helper disconnects (the agent killed it at its hook timeout),
/// - the session moved on: `UserPromptSubmit`, `Stop`, `SessionEnd`, a matching `PostToolUse`,
///   Claude's live registry leaving `waiting`, or a provider reporting newer transcript
///   progress via `reconcile(…)`.
public final class HookServer: HookStateReader, @unchecked Sendable {
    public enum ServerError: Error, Equatable, Sendable {
        case pathTooLong
        case alreadyRunning
        case socket(Int32)
        case bind(Int32)
        case listen(Int32)
    }

    /// How long to hold an answerable prompt for `agent` (seconds; 0 = pass through immediately).
    /// Claude Code shows its own dialog in parallel with the PermissionRequest hook (first answer
    /// wins), so holding never delays it; Codex runs the hook *before* showing its prompt, so the
    /// app only holds Codex prompts while Silicon Mode is active.
    public var holdDuration: @Sendable (_ agent: String) -> TimeInterval {
        get { lock.withLock { _holdDuration } }
        set { lock.withLock { _holdDuration = newValue } }
    }
    /// Called (on any queue) whenever hook-derived state changes.
    public var onChange: @Sendable () -> Void {
        get { lock.withLock { _onChange } }
        set { lock.withLock { _onChange = newValue } }
    }
    public let socketPath: String
    /// Claude Code's live-session registry (`<pid>.json` with `status`), used to notice that a
    /// held prompt was answered in the terminal / desktop app.
    public var claudeRegistryDirectory: String {
        get { lock.withLock { _registryDir } }
        set { lock.withLock { _registryDir = newValue } }
    }

    /// Seconds a client may take to send its request line.
    var requestTimeout: TimeInterval = 10
    /// Display-only questions (prompts we did not hold) expire after this long.
    var displayOnlyTTL: TimeInterval = 30 * 60
    /// Hook sessions with no event for this long are forgotten.
    var sessionTTL: TimeInterval = 12 * 3600

    private let lock = NSLock()
    private var _holdDuration: @Sendable (String) -> TimeInterval = { _ in 0 }
    private var _onChange: @Sendable () -> Void = {}
    private var _registryDir = NSHomeDirectory() + "/.claude/sessions"
    private var store = Store()
    private var _running = false

    private let queue = DispatchQueue(label: "ai.tos.mode.hook-server", qos: .userInitiated)
    // Queue-confined.
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var conns: [UInt64: Conn] = [:]
    private var nextConnID: UInt64 = 1
    private var lastPrune = Date.distantPast

    public init(socketPath: String = HookWire.socketPath) {
        self.socketPath = socketPath
    }

    // MARK: Lifecycle

    public func start() throws {
        try queue.sync { try openListener() }
    }

    public func stop() {
        queue.sync {
            acceptSource?.cancel(); acceptSource = nil
            timer?.cancel(); timer = nil
            for c in conns.values { c.source.cancel() }
            conns.removeAll()
            if listenFD >= 0 { unlink(socketPath) }
            listenFD = -1
        }
        // Closing the connections made every waiting helper pass through.
        let changed = lock.withLock { () -> Bool in
            _running = false
            let ids = Array(store.held.keys)
            for id in ids { removeHeld(id, state: nil) }
            return !ids.isEmpty
        }
        if changed { notify() }
    }

    /// Whether the socket is listening. Safe to call from any thread (including `onChange`).
    public var isRunning: Bool { lock.withLock { _running } }

    // MARK: Answers

    /// Deliver an answer to a held prompt. Returns false if it is no longer pending.
    @discardableResult
    public func resolve(questionID: String, answer: AgentAnswer) -> Bool {
        let outcome: (connID: UInt64, stdout: String?)? = lock.withLock {
            guard let heldID = store.questionIndex[questionID], var h = store.held[heldID],
                  h.questions.contains(where: { $0.id == questionID }) else { return nil }
            guard !answer.optionIDs.isEmpty || !(answer.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            h.answers[questionID] = answer
            if h.kind == .askUser, h.answers.count < h.questions.count {
                store.held[heldID] = h
                return (0, nil) // partial: wait for the remaining questions
            }
            let out = HookDecision.stdout(for: h)
            removeHeld(heldID, state: .working)
            return (h.connID, out)
        }
        guard let outcome else { return false }
        if outcome.connID != 0 {
            let response = HookWire.Response(stdout: outcome.stdout)
            queue.async { self.finish(outcome.connID, response) }
        }
        notify()
        return true
    }

    // MARK: HookStateReader

    public func state(agent: String, sessionID: String) -> HookSessionState? {
        lock.withLock { snapshot(Store.key(agent, sessionID)) }
    }

    public func sessions(agent: String) -> [HookSessionState] {
        lock.withLock {
            store.sessions.keys.filter { $0.hasPrefix(agent + Store.sep) }.compactMap { snapshot($0) }
        }
    }

    /// Ids of every question currently held open (answerable).
    public var heldQuestionIDs: [String] { lock.withLock { Array(store.questionIndex.keys) } }

    // MARK: Provider feedback

    /// Progress a provider saw in an agent's transcript. Prompts the agent has visibly moved past
    /// are released (pass-through) so stale questions disappear.
    struct Progress: Sendable {
        /// Newest turn boundary (prompt submitted, turn finished, interrupted).
        var boundary: Date?
        /// Tool calls that got a result: name, canonical input, result time.
        var resolvedTools: [(name: String, inputKey: String, at: Date)] = []
    }

    func reconcile(agent: String, sessionID: String, progress: Progress) {
        let (released, connIDs) = lock.withLock { () -> (Bool, [UInt64]) in
            let key = Store.key(agent, sessionID)
            var released = false
            var ids: [UInt64] = []
            for (heldID, h) in store.held where h.sessionKey == key {
                var moved = false
                if let b = progress.boundary, b > h.createdAt.addingTimeInterval(0.5) { moved = true }
                if !moved {
                    let sameName = store.held.values.filter { $0.sessionKey == key && $0.toolName == h.toolName }.count
                    moved = progress.resolvedTools.contains { t in
                        t.name == h.toolName && t.at > h.createdAt.addingTimeInterval(-1)
                            && (t.inputKey == h.inputKey || sameName == 1)
                    }
                }
                if moved {
                    ids.append(h.connID)
                    removeHeld(heldID, state: nil)
                    released = true
                }
            }
            if var s = store.sessions[key] {
                let before = s.displayOnly.count
                let tools = store.displayTool
                s.displayOnly.removeAll { q in
                    if let b = progress.boundary, b > q.createdAt.addingTimeInterval(0.5) { return true }
                    let tool = tools[q.id] ?? ""
                    return progress.resolvedTools.contains { $0.name == tool && $0.at > q.createdAt.addingTimeInterval(-1) }
                }
                for q in store.sessions[key]?.displayOnly ?? [] where !s.displayOnly.contains(where: { $0.id == q.id }) {
                    store.displayTool.removeValue(forKey: q.id)
                }
                if s.displayOnly.count != before {
                    released = true
                    if s.state == .needsYou, s.displayOnly.isEmpty, !store.held.values.contains(where: { $0.sessionKey == key }) {
                        s.state = .working
                    }
                    store.sessions[key] = s
                }
            }
            return (released, ids)
        }
        for id in connIDs { queue.async { self.finish(id, .passThrough) } }
        if released { notify() }
    }

    // MARK: - Internals: state

    private struct Store {
        static let sep = "\u{1}"
        static func key(_ agent: String, _ sid: String) -> String { agent + sep + sid }

        var sessions: [String: SessionRecord] = [:]
        var held: [String: Held] = [:]
        /// questionID → held id
        var questionIndex: [String: String] = [:]
        /// display-only question id → tool name
        var displayTool: [String: String] = [:]
    }

    private struct SessionRecord {
        var agent: String
        var sessionID: String
        var cwd: String?
        var transcriptPath: String?
        var lastEvent: String
        var lastEventAt: Date
        var state: AgentState
        var pid: Int32?
        /// Prompts we saw but did not hold (shown, answered in the agent's own UI).
        var displayOnly: [AgentQuestion] = []
    }

    enum HeldKind: Sendable { case permission, askUser, plan }

    struct Held: Sendable {
        var id: String
        var connID: UInt64
        var agent: String
        var sessionKey: String
        var pid: Int32?
        var kind: HeldKind
        var toolName: String
        var inputKey: String
        /// Raw `tool_input` JSON (re-parsed when building the answer).
        var toolInput: Data?
        /// Raw `permission_suggestions` JSON array (Claude "always allow").
        var suggestions: Data?
        var questions: [AgentQuestion]
        var answers: [String: AgentAnswer] = [:]
        var createdAt: Date
        var sawWaiting = false
    }

    /// Must hold `lock`.
    private func snapshot(_ key: String) -> HookSessionState? {
        guard let s = store.sessions[key] else { return nil }
        var pending: [AgentQuestion] = []
        for h in store.held.values where h.sessionKey == key {
            pending += h.questions.filter { h.answers[$0.id] == nil }
        }
        pending.sort { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
        pending += s.displayOnly
        let state: AgentState = pending.isEmpty ? s.state : .needsYou
        return HookSessionState(agent: s.agent, sessionID: s.sessionID, cwd: s.cwd, transcriptPath: s.transcriptPath,
                                lastEvent: s.lastEvent, lastEventAt: s.lastEventAt, state: state,
                                pending: pending, pid: s.pid)
    }

    /// Must hold `lock`. Removes a held prompt and its questions; optionally sets the session state.
    private func removeHeld(_ heldID: String, state: AgentState?) {
        guard let h = store.held.removeValue(forKey: heldID) else { return }
        for q in h.questions { store.questionIndex.removeValue(forKey: q.id) }
        if var s = store.sessions[h.sessionKey] {
            if let state { s.state = state }
            else if s.state == .needsYou, !store.held.values.contains(where: { $0.sessionKey == h.sessionKey }), s.displayOnly.isEmpty {
                s.state = .working
            }
            store.sessions[h.sessionKey] = s
        }
    }

    /// Must hold `lock`. Releases every prompt of a session; returns their connection ids.
    private func releaseAll(_ key: String) -> [UInt64] {
        let ids = store.held.filter { $0.value.sessionKey == key }
        for (heldID, _) in ids { removeHeld(heldID, state: nil) }
        if var s = store.sessions[key] {
            for q in s.displayOnly { store.displayTool.removeValue(forKey: q.id) }
            s.displayOnly.removeAll()
            store.sessions[key] = s
        }
        return ids.map(\.value.connID)
    }

    private func notify() {
        let cb = onChange
        cb()
    }

    // MARK: - Internals: request handling

    private enum Reply {
        case now(HookWire.Response)
        case hold
    }

    /// Applies one hook event. Called on `queue` without `lock` held.
    private func handle(_ req: HookWire.Request, connID: UInt64, peerPID: Int32?) -> Reply {
        let payload = CoreJSON.object(req.payload) ?? [:]
        let event = (req.event?.isEmpty == false ? req.event : nil) ?? payload.str("hook_event_name") ?? ""
        let agent = req.agent
        guard let sid = payload.nonEmpty("session_id") ?? payload.nonEmpty("sessionId") ?? payload.nonEmpty("thread_id") else {
            return .now(.passThrough)
        }
        let now = Date()
        let key = Store.key(agent, sid)
        let toolName = payload.str("tool_name") ?? ""
        let toolInput = payload.obj("tool_input") ?? [:]
        let pid = req.ppid > 1 ? req.ppid : peerPID
        let hold = event == "PermissionRequest" ? max(0, holdDuration(agent)) : 0

        var reply = Reply.now(.passThrough)
        let releasedConns: [UInt64] = lock.withLock {
            var s = store.sessions[key] ?? SessionRecord(agent: agent, sessionID: sid, cwd: nil, transcriptPath: nil,
                                                         lastEvent: event, lastEventAt: now, state: .working, pid: pid)
            s.lastEvent = event
            s.lastEventAt = now
            if let c = payload.nonEmpty("cwd") ?? (req.cwd.isEmpty ? nil : req.cwd) { s.cwd = c }
            if let t = payload.nonEmpty("transcript_path") { s.transcriptPath = t }
            if let pid { s.pid = pid }
            var released: [UInt64] = []

            switch event {
            case "SessionStart":
                if payload.str("source") != "compact" { s.state = .idle }
            case "UserPromptSubmit", "UserPromptExpansion":
                store.sessions[key] = s
                released = releaseAll(key)
                s = store.sessions[key] ?? s
                s.state = .working
            case "PreToolUse":
                s.state = .working
                if toolName == "AskUserQuestion" || toolName == "ExitPlanMode" {
                    let qs = HookQuestions.build(agent: agent, sessionKey: key, sessionID: sid, heldID: "pre-" + UUID().uuidString,
                                                 toolName: toolName, input: toolInput, suggestions: [], cwd: s.cwd,
                                                 answerable: false, now: now)
                    for q in qs.questions { store.displayTool[q.id] = toolName }
                    s.displayOnly.removeAll { store.displayTool[$0.id] == toolName }
                    s.displayOnly += qs.questions
                    s.state = .needsYou
                }
            case "PostToolUse", "PostToolUseFailure", "PermissionDenied":
                let ikey = CoreJSON.canonical(toolInput)
                let sameName = store.held.values.filter { $0.sessionKey == key && $0.toolName == toolName }
                for h in sameName where h.inputKey == ikey || sameName.count == 1 {
                    released.append(h.connID)
                    removeHeld(h.id, state: nil)
                }
                s.displayOnly.removeAll { store.displayTool[$0.id] == toolName }
                s.state = .working
            case "PermissionRequest":
                // A display-only copy from PreToolUse is superseded by the real prompt.
                s.displayOnly.removeAll { store.displayTool[$0.id] == toolName }
                let heldID = UUID().uuidString.lowercased()
                let suggestions = payload.arr("permission_suggestions") ?? []
                let built = HookQuestions.build(agent: agent, sessionKey: key, sessionID: sid, heldID: heldID,
                                                toolName: toolName, input: toolInput, suggestions: suggestions,
                                                cwd: s.cwd, answerable: hold > 0, now: now)
                s.state = .needsYou
                if hold > 0 {
                    let h = Held(id: heldID, connID: connID, agent: agent, sessionKey: key, pid: s.pid, kind: built.kind,
                                 toolName: toolName, inputKey: CoreJSON.canonical(toolInput),
                                 toolInput: CoreJSON.data(toolInput), suggestions: suggestions.isEmpty ? nil : CoreJSON.data(suggestions),
                                 questions: built.questions, createdAt: now)
                    store.held[heldID] = h
                    for q in built.questions { store.questionIndex[q.id] = heldID }
                    reply = .hold
                } else {
                    for q in built.questions { store.displayTool[q.id] = toolName }
                    s.displayOnly += built.questions
                }
            case "Notification":
                let type = payload.str("notification_type") ?? ""
                let message = (payload.str("message") ?? "").lowercased()
                switch type {
                case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
                    s.state = .needsYou
                case "idle_prompt", "agent_completed":
                    if s.state != .needsYou { s.state = .finished }
                case "":
                    if message.contains("permission") || message.contains("needs your") { s.state = .needsYou }
                    else if message.contains("waiting for your input") { if s.state != .needsYou { s.state = .finished } }
                default:
                    break
                }
            case "Stop":
                store.sessions[key] = s
                released = releaseAll(key)
                s = store.sessions[key] ?? s
                s.state = .finished
            case "StopFailure":
                store.sessions[key] = s
                released = releaseAll(key)
                s = store.sessions[key] ?? s
                s.state = .error
            case "Interrupt":
                store.sessions[key] = s
                released = releaseAll(key)
                s = store.sessions[key] ?? s
                s.state = .idle
            case "SessionEnd":
                store.sessions[key] = s
                released = releaseAll(key)
                store.sessions.removeValue(forKey: key)
                return released
            case "SubagentStart", "SubagentStop", "PreCompact", "PostCompact", "TaskCreated", "TaskCompleted":
                if s.state != .needsYou { s.state = .working }
            default:
                break
            }
            store.sessions[key] = s
            return released
        }
        for id in releasedConns where id != connID { finish(id, .passThrough) }
        return reply
    }

    // MARK: - Internals: sockets (all on `queue`)

    private final class Conn {
        let id: UInt64
        let fd: Int32
        let source: DispatchSourceRead
        let opened = Date()
        var peerPID: Int32?
        var buffer = Data()
        var requestDone = false
        init(id: UInt64, fd: Int32, source: DispatchSourceRead) { self.id = id; self.fd = fd; self.source = source }
    }

    private func openListener() throws {
        if listenFD >= 0 { return }
        let path = socketPath
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        var addr = sockaddr_un()
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLen else { throw ServerError.pathTooLong }
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: Array(path.utf8) + [0])
        }

        // Stale socket? If something answers, another instance owns it.
        if FileManager.default.fileExists(atPath: path) {
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            if probe >= 0 {
                let rc = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
                }
                close(probe)
                if rc == 0 { throw ServerError.alreadyRunning }
            }
            unlink(path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socket(errno) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let old = umask(0o077)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(old)
        guard rc == 0 else { let e = errno; close(fd); throw ServerError.bind(e) }
        chmod(path, 0o600)
        guard listen(fd, 128) == 0 else { let e = errno; close(fd); unlink(path); throw ServerError.listen(e) }
        listenFD = fd
        lock.withLock { _running = true }

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptAll() }
        src.setCancelHandler { close(fd) }
        src.resume()
        acceptSource = src

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func acceptAll() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { break }
            // Same user only.
            var cred = xucred()
            var len = socklen_t(MemoryLayout<xucred>.size)
            if getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &cred, &len) != 0 || cred.cr_uid != getuid() {
                close(fd)
                continue
            }
            var peer: pid_t = 0
            var plen = socklen_t(MemoryLayout<pid_t>.size)
            let havePeer = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &plen) == 0
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

            let id = nextConnID
            nextConnID += 1
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            let conn = Conn(id: id, fd: fd, source: src)
            conn.peerPID = havePeer ? peer : nil
            src.setEventHandler { [weak self] in self?.readable(id) }
            src.setCancelHandler { close(fd) }
            conns[id] = conn
            src.resume()
        }
    }

    private func readable(_ id: UInt64) {
        guard let c = conns[id] else { return }
        var buf = [UInt8](repeating: 0, count: 65536)
        var eof = false
        while true {
            let n = buf.withUnsafeMutableBytes { read(c.fd, $0.baseAddress, $0.count) }
            if n > 0 {
                if !c.requestDone { c.buffer.append(contentsOf: buf[0..<n]) }
                continue
            }
            if n == 0 { eof = true }
            else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { eof = true }
            break
        }
        if !c.requestDone, let nl = c.buffer.firstIndex(of: 0x0A) {
            c.requestDone = true
            let line = c.buffer[c.buffer.startIndex..<nl]
            c.buffer = Data()
            guard let req = try? JSONDecoder().decode(HookWire.Request.self, from: line) else {
                finish(id, .passThrough)
                return
            }
            switch handle(req, connID: id, peerPID: c.peerPID) {
            case .now(let r):
                finish(id, r)
                notify()
                return
            case .hold:
                notify()
            }
        } else if !c.requestDone, c.buffer.count > 32 << 20 {
            finish(id, .passThrough)
            return
        }
        if eof { clientGone(id) }
    }

    /// The helper disconnected (agent killed it, or it gave up): forget its held prompt.
    private func clientGone(_ id: UInt64) {
        let changed = lock.withLock { () -> Bool in
            guard let h = store.held.values.first(where: { $0.connID == id }) else { return false }
            removeHeld(h.id, state: nil)
            return true
        }
        if let c = conns.removeValue(forKey: id) { c.source.cancel() }
        if changed { notify() }
    }

    /// Write the response line and close.
    private func finish(_ id: UInt64, _ response: HookWire.Response) {
        guard let c = conns.removeValue(forKey: id) else { return }
        if var data = try? JSONEncoder().encode(response) {
            data.append(0x0A)
            // Small payload: switch to blocking for a reliable full write.
            _ = fcntl(c.fd, F_SETFL, fcntl(c.fd, F_GETFL) & ~O_NONBLOCK)
            var tv = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(c.fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            data.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = write(c.fd, raw.baseAddress!.advanced(by: off), raw.count - off)
                    if n <= 0 { break }
                    off += n
                }
            }
        }
        c.source.cancel()
    }

    private func tick() {
        let now = Date()
        // Slow clients.
        for c in conns.values where !c.requestDone && now.timeIntervalSince(c.opened) > requestTimeout {
            finish(c.id, .passThrough)
        }

        // Held prompts: hold policy and Claude's registry.
        let held = lock.withLock { Array(store.held.values) }
        var expire: [String] = []
        var sawWaiting: [String] = []
        if !held.isEmpty {
            let policy = holdDuration
            var cache: [String: Double] = [:]
            for h in held {
                let limit = cache[h.agent] ?? max(0, policy(h.agent))
                cache[h.agent] = limit
                if now.timeIntervalSince(h.createdAt) >= limit { expire.append(h.id); continue }
                if h.agent == "claude-code", let pid = h.pid, now.timeIntervalSince(h.createdAt) > 0.5 {
                    switch registryStatus(pid: pid) {
                    case "waiting"?: if !h.sawWaiting { sawWaiting.append(h.id) }
                    case let s? where h.sawWaiting && s != "waiting": expire.append(h.id)
                    default: break
                    }
                }
            }
        }

        var changed = false
        let conns: [UInt64] = lock.withLock {
            for id in sawWaiting { store.held[id]?.sawWaiting = true }
            var ids: [UInt64] = []
            for id in expire {
                guard let h = store.held[id] else { continue }
                ids.append(h.connID)
                removeHeld(id, state: nil)
                changed = true
            }
            if now.timeIntervalSince(lastPrune) > 30 {
                lastPrune = now
                if prune(now: now) { changed = true }
            }
            return ids
        }
        for id in conns { finish(id, .passThrough) }
        if changed { notify() }
    }

    /// Must hold `lock`.
    private func prune(now: Date) -> Bool {
        var changed = false
        for (key, var s) in store.sessions {
            let age = now.timeIntervalSince(s.lastEventAt)
            let dead = s.pid.map { kill($0, 0) != 0 && errno == ESRCH } ?? false
            let hasHeld = store.held.values.contains { $0.sessionKey == key }
            if !hasHeld && (age > sessionTTL || (dead && age > 600)) {
                for q in s.displayOnly { store.displayTool.removeValue(forKey: q.id) }
                store.sessions.removeValue(forKey: key)
                changed = true
                continue
            }
            let before = s.displayOnly.count
            s.displayOnly.removeAll { now.timeIntervalSince($0.createdAt) > displayOnlyTTL || dead }
            if s.displayOnly.count != before {
                if s.state == .needsYou, s.displayOnly.isEmpty, !hasHeld { s.state = dead ? .idle : .working }
                store.sessions[key] = s
                changed = true
            }
        }
        return changed
    }

    private func registryStatus(pid: Int32) -> String? {
        let path = claudeRegistryDirectory + "/\(pid).json"
        guard let data = CoreFS.read(path, max: 64 << 10), let obj = CoreJSON.object(data) else { return nil }
        return obj.str("status")
    }
}

// MARK: - Questions and decisions

/// Builds `AgentQuestion`s for a held prompt.
enum HookQuestions {
    struct Built {
        var kind: HookServer.HeldKind
        var questions: [AgentQuestion]
    }

    static func build(agent: String, sessionKey: String, sessionID: String, heldID: String, toolName: String,
                      input: JSONObject, suggestions: [Any], cwd: String?, answerable: Bool, now: Date) -> Built {
        let sessionRef = "\(agent):\(sessionID)"
        let base = "\(agent):hook:\(heldID)"
        if toolName == "AskUserQuestion" {
            let qs = input.objs("questions")
            var out: [AgentQuestion] = []
            for (i, q) in qs.enumerated() {
                let opts = q.objs("options").enumerated().map { j, o in
                    AgentQuestion.Option(id: "o\(j)", label: o.str("label") ?? "Option \(j + 1)", detail: o.nonEmpty("description"),
                                         style: j == 0 ? .primary : .neutral)
                }
                out.append(AgentQuestion(id: "\(base)#\(i)", sessionID: sessionRef, provider: agent, kind: .question,
                                         title: q.nonEmpty("header") ?? "Question",
                                         detail: q.str("question"), options: opts, allowsFreeText: true,
                                         multiSelect: q.bool("multiSelect") ?? false,
                                         createdAt: now.addingTimeInterval(Double(i) * 0.001), answerable: answerable))
            }
            if out.isEmpty {
                out.append(AgentQuestion(id: "\(base)#0", sessionID: sessionRef, provider: agent, kind: .question,
                                         title: "Question", detail: input.str("question"), allowsFreeText: true,
                                         createdAt: now, answerable: answerable))
            }
            return Built(kind: .askUser, questions: out)
        }
        if toolName == "ExitPlanMode" {
            var opts = [AgentQuestion.Option(id: "allow", label: "Approve", style: .primary)]
            if !suggestions.isEmpty { opts.append(.init(id: "allow_always", label: "Approve, auto-accept edits", style: .neutral)) }
            opts.append(.init(id: "deny", label: "Keep planning", style: .neutral))
            let plan = input.str("plan").map { String($0.prefix(1500)) }
            return Built(kind: .plan, questions: [
                AgentQuestion(id: base, sessionID: sessionRef, provider: agent, kind: .permission, title: "Approve the plan?",
                              detail: plan, options: opts, allowsFreeText: true, createdAt: now, answerable: answerable),
            ])
        }
        let t = ToolSummary.permissionTitle(name: toolName, input: input, cwd: cwd)
        var opts = AgentQuestion.permissionOptions()
        if suggestions.isEmpty || agent != "claude-code" { opts.removeAll { $0.id == "allow_always" } }
        return Built(kind: .permission, questions: [
            AgentQuestion(id: base, sessionID: sessionRef, provider: agent, kind: .permission, title: t.title,
                          detail: t.detail, options: opts, allowsFreeText: false, createdAt: now, answerable: answerable),
        ])
    }
}

/// Builds the exact stdout the agent's hook runner expects.
enum HookDecision {
    static let deniedMessage = "Denied from Silicon Mode."

    static func stdout(for h: HookServer.Held) -> String? {
        var decision: JSONObject
        switch h.kind {
        case .askUser:
            var input = h.toolInput.flatMap { CoreJSON.object($0) } ?? [:]
            let qs = input.objs("questions")
            var answers: JSONObject = (input.obj("answers")) ?? [:]
            for (i, q) in h.questions.enumerated() {
                guard let a = h.answers[q.id] else { continue }
                let labels = a.optionIDs.compactMap { id in q.options.first { $0.id == id }?.label }
                var parts = labels
                if let t = a.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { parts.append(t) }
                let key = (i < qs.count ? qs[i].str("question") : nil) ?? q.detail ?? q.title
                answers[key] = parts.joined(separator: ", ")
            }
            input["answers"] = answers
            decision = ["behavior": "allow", "updatedInput": input]
        case .permission, .plan:
            guard let q = h.questions.first, let a = h.answers[q.id] else { return nil }
            let choice = a.optionIDs.first ?? "deny"
            let text = a.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            switch choice {
            case "allow", "allow_always", "approve", "yes":
                decision = ["behavior": "allow"]
                if choice == "allow_always", let s = h.suggestions, let arr = CoreJSON.any(s) as? [Any], !arr.isEmpty {
                    decision["updatedPermissions"] = arr
                }
            default:
                var message = h.kind == .plan ? "Keep planning." : deniedMessage
                if let text, !text.isEmpty { message = h.kind == .plan ? text : "\(deniedMessage) \(text)" }
                decision = ["behavior": "deny", "message": message]
            }
        }
        let out: JSONObject = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        return CoreJSON.string(out)
    }
}
