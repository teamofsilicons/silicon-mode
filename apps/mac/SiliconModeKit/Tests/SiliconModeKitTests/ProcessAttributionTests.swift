import Testing
import Foundation
@testable import SiliconModeKit

/// Who owns an agent process: an editor owns what its extensions spawn, not what a person runs in
/// its integrated terminal.
extension MoreSupportTests {
    @Test func interactiveShellsAreRecognised() {
        func p(_ args: [String], path: String? = nil, name: String = "zsh") -> ProcessEntry {
            ProcessEntry(pid: 1, ppid: 1, name: name, path: path, args: args, startTime: nil)
        }
        let vscodeBash = "/Applications/Visual Studio Code.app/Contents/Resources/app/out/vs/workbench/contrib/terminal/common/scripts/shellIntegration-bash.sh"
        #expect(p(["-zsh"]).isInteractiveShell)                                  // login shell, path unknown
        #expect(p(["/bin/zsh", "-il"], path: "/bin/zsh").isInteractiveShell)
        #expect(p(["/bin/bash", "--init-file", vscodeBash], path: "/bin/bash").isInteractiveShell)
        #expect(p(["fish", "--init-command", "source x.fish"], path: "/opt/homebrew/bin/fish").isInteractiveShell)
        #expect(p(["fish", "-C", "source x.fish"], path: "/opt/homebrew/bin/fish").isInteractiveShell)
        #expect(p(["pwsh", "-NoExit", "-Command", ". x.ps1"], path: "/usr/local/bin/pwsh").isInteractiveShell)
        #expect(p(["tmux", "new", "-s", "work"], path: "/opt/homebrew/bin/tmux").isInteractiveShell)
        // Programs spawning helpers.
        #expect(!p(["/bin/sh", "-c", "copilot-runtime --stdio"], path: "/bin/sh").isInteractiveShell)
        #expect(!p(["/bin/zsh", "-lc", "gemini"], path: "/bin/zsh").isInteractiveShell)
        #expect(!p(["/bin/bash", "/x/wrapper.sh"], path: "/bin/bash").isInteractiveShell)
        #expect(!p(["fish", "--command", "x"], path: "/opt/homebrew/bin/fish").isInteractiveShell)
        #expect(!p(["pwsh", "-Command", "x"], path: "/usr/local/bin/pwsh").isInteractiveShell)
        #expect(!p(["node", "x.js"], path: "/opt/homebrew/bin/node", name: "node").isInteractiveShell)
    }

    @Test func agentsInAnEditorTerminalAreTopLevel() async {
        let home = TempHome(), world = FakeWorld()
        let app = "/Applications/Visual Studio Code.app/Contents"
        let helper = "\(app)/Frameworks/Code Helper.app/Contents/MacOS/Code Helper"
        let plugin = "\(app)/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"
        let bashIntegration = "\(app)/Resources/app/out/vs/workbench/contrib/terminal/common/scripts/shellIntegration-bash.sh"
        let procs = [
            world.spawn(500, name: "Code", path: "\(app)/MacOS/Code", args: ["\(app)/MacOS/Code"]),
            // Integrated terminal: ptyHost → shell → agent.
            world.spawn(501, ppid: 500, name: "Code Helper", path: helper, args: [helper, "--type=utility", "--utility-sub-type=node.mojom.NodeService"]),
            world.spawn(502, ppid: 501, name: "zsh", path: "/bin/zsh", args: ["/bin/zsh", "-il"]),
            world.spawn(503, ppid: 502, name: "kimi", path: "/usr/local/bin/kimi", args: ["kimi"], cwd: "/tmp/term-proj"),
            // bash with VS Code's shell integration (its argv alone classifies as the editor).
            world.spawn(504, ppid: 501, name: "bash", path: "/bin/bash", args: ["/bin/bash", "--init-file", bashIntegration]),
            world.spawn(505, ppid: 504, name: "auggie", path: "/usr/local/bin/auggie", args: ["auggie"], cwd: "/tmp/bash-proj"),
            // Extension host spawning agent runtimes, directly or through `sh -c`: editor features.
            world.spawn(510, ppid: 500, name: "Code Helper (Plugin)", path: plugin, args: [plugin, "--type=utility"]),
            world.spawn(511, ppid: 510, name: "cline", path: "/usr/local/bin/cline", args: ["cline", "--stdio"]),
            world.spawn(512, ppid: 510, name: "sh", path: "/bin/sh", args: ["/bin/sh", "-c", "letta --headless"]),
            world.spawn(513, ppid: 512, name: "letta", path: "/usr/local/bin/letta", args: ["letta", "--headless"]),
            // A child of an agent stays attributed to it, shell or not.
            world.spawn(520, ppid: 503, name: "zsh", path: "/bin/zsh", args: ["/bin/zsh", "-i"]),
            world.spawn(521, ppid: 520, name: "cline", path: "/usr/local/bin/cline", args: ["cline"]),
        ]
        let env = world.env(home)
        let sessions = await ProcessFallbackProvider(env: env).scan(scanContext(procs))
        #expect(Set(sessions.map(\.id)) == ["kimi:pid-503", "augment:pid-505"])
        #expect(sessions.first { $0.pid == 503 }?.title == "term-proj")

        let idx = env.processCache.index(for: scanContext(procs))
        #expect(idx.isEditorHosted(511))
        #expect(idx.isEditorHosted(513))
        #expect(!idx.isEditorHosted(503))
        #expect(idx.owner(of: 521) == .agent("kimi"))
        // Opting in to editor-hosted agents.
        let hosted = LiveAgents.find(["cline", "letta"], ctx: scanContext(procs), env: env, allowIDE: true)
        #expect(hosted.map(\.pid) == [511, 513])
    }
}
