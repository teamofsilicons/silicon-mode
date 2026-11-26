import Foundation

/// Unix-socket server that `silicon-mode-hook` connects to. Tracks hook-reported session state
/// and can hold blocking hook calls (e.g. Claude Code `PermissionRequest`) open until the human
/// answers from the menu bar / overlay / phone, or `holdDuration()` elapses.
public final class HookServer: HookStateReader, @unchecked Sendable {
    /// How long to hold an answerable prompt (seconds; 0 = answer immediately with pass-through).
    public var holdDuration: @Sendable () -> TimeInterval = { 0 }
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
