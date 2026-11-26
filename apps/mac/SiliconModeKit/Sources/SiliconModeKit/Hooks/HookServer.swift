import Foundation

/// Unix-socket server that `silicon-mode-hook` connects to. Tracks hook-reported session state
/// and can hold blocking hook calls (e.g. Claude Code `PermissionRequest`) open until the human
/// answers from the menu bar / overlay / phone, or `holdDuration()` elapses.
public final class HookServer: HookStateReader, @unchecked Sendable {
    /// How long to hold an answerable prompt for `agent` (seconds; 0 = pass through immediately).
    /// Claude Code shows its own dialog in parallel with the PermissionRequest hook (first answer
    /// wins), so holding never delays it; Codex runs the hook *before* showing its prompt, so the
    /// app only holds Codex prompts while Silicon Mode is active.
    public var holdDuration: @Sendable (_ agent: String) -> TimeInterval = { _ in 0 }
    /// Called (on any queue) whenever hook-derived state changes.
    public var onChange: @Sendable () -> Void = {}
    public let socketPath: String

    public init(socketPath: String = HookWire.socketPath) {
        self.socketPath = socketPath
    }

    public func start() throws {}
    public func stop() {}

    /// Deliver an answer to a held prompt. Returns false if it is no longer pending.
    @discardableResult
    public func resolve(questionID: String, answer: AgentAnswer) -> Bool { false }

    public func state(agent: String, sessionID: String) -> HookSessionState? { nil }
    public func sessions(agent: String) -> [HookSessionState] { [] }
}
