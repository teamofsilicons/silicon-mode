import Foundation

/// Wire protocol between `silicon-mode-hook` (spawned by agent hook systems such as Claude Code)
/// and the Silicon Mode app. One JSON line each way over a Unix domain socket.
///
/// The helper must never break an agent: if the app isn't running, or anything fails, it exits 0
/// with no output so the agent continues exactly as if no hook were installed.
///
/// This file is compiled into both the SiliconModeKit library and the helper tool.
public enum HookWire {
    public static let version = 1

    /// ~/Library/Application Support/Silicon Mode — settings, caches, debug state.
    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Silicon Mode", isDirectory: true)
    }

    /// ~/.silicon-mode — runtime files referenced from agent hook commands (no spaces in paths,
    /// so hook command strings stay simple to quote).
    public static var runtimeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".silicon-mode", isDirectory: true)
    }

    /// ~/.silicon-mode/run/hook.sock
    public static var socketPath: String {
        runtimeDirectory.appendingPathComponent("run/hook.sock").path
    }

    /// Stable install location of the helper that agent hook configs point at:
    /// ~/.silicon-mode/bin/silicon-mode-hook
    public static var installedHelperPath: String {
        runtimeDirectory.appendingPathComponent("bin/silicon-mode-hook").path
    }

    public struct Request: Codable, Sendable {
        public var v: Int
        /// Which agent invoked us, from the helper's first argument (e.g. "claude-code", "codex").
        public var agent: String
        /// Hook event name if known from argv (e.g. "PermissionRequest"); else parsed from payload.
        public var event: String?
        /// Raw stdin payload (JSON text as the agent sent it).
        public var payload: String
        /// The helper's parent pid (the agent process).
        public var ppid: Int32
        public var cwd: String
        /// A few environment variables useful for attribution (TERM_PROGRAM, TMUX, …).
        public var env: [String: String]
        public var sentAt: Double

        public init(agent: String, event: String?, payload: String, ppid: Int32, cwd: String, env: [String: String]) {
            self.v = HookWire.version
            self.agent = agent; self.event = event; self.payload = payload
            self.ppid = ppid; self.cwd = cwd; self.env = env
            self.sentAt = Date().timeIntervalSince1970
        }
    }

    public struct Response: Codable, Sendable {
        /// Written verbatim to the helper's stdout (e.g. Claude Code hook decision JSON).
        public var stdout: String?
        /// Written to stderr.
        public var stderr: String?
        /// Process exit code (0 = continue normally).
        public var exitCode: Int32

        public init(stdout: String? = nil, stderr: String? = nil, exitCode: Int32 = 0) {
            self.stdout = stdout; self.stderr = stderr; self.exitCode = exitCode
        }

        public static let passThrough = Response()
    }

    /// Environment keys forwarded for attribution and hold policy. Claude Code sets
    /// `CLAUDE_CODE_ENTRYPOINT` ("cli", "sdk-cli" for `claude -p`, "claude-desktop", …) and
    /// `CLAUDE_CODE_SESSION_ATTENDED` ("1"/"0") in every hook's environment; the server uses them to
    /// tell sessions with a permission dialog of their own from headless ones.
    public static let forwardedEnv = ["TERM_PROGRAM", "TERM_SESSION_ID", "TMUX", "TMUX_PANE", "ITERM_SESSION_ID",
                                      "VSCODE_PID", "CLAUDE_PROJECT_DIR", "CODEX_HOME", "__CFBundleIdentifier",
                                      "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ATTENDED"]
}
