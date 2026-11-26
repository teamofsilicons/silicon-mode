import Testing
import Foundation
@testable import SiliconModeKit

@Suite struct CoreHookInstallerTests {
    /// A user's settings.json as Claude Code writes it (2-space JSON.stringify), with their own hooks.
    static let userSettings = """
    {
      "model": "opus",
      "permissions": {
        "allow": [
          "Bash(npm test:*)"
        ]
      },
      "hooks": {
        "Stop": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "say done"
              }
            ]
          }
        ],
        "PreToolUse": [
          {
            "matcher": "Bash",
            "hooks": [
              {
                "type": "command",
                "command": "~/bin/audit.sh"
              }
            ]
          }
        ]
      },
      "statusLine": {
        "type": "command",
        "command": "~/bin/status.sh",
        "padding": 0
      },
      "theme": "dark"
    }

    """

    func home(withClaude settings: String?, codex: Bool = true) throws -> String {
        let home = CoreFixtures.tempDir("home")
        try FileManager.default.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
        if let settings { try Data(settings.utf8).write(to: URL(fileURLWithPath: home + "/.claude/settings.json")) }
        if codex { try FileManager.default.createDirectory(atPath: home + "/.codex", withIntermediateDirectories: true) }
        return home
    }

    func target(_ id: String, _ home: String) -> HookInstaller.Target {
        HookInstaller.targets(home: home).first { $0.id == id }!
    }

    func helper(_ home: String) -> String { home + "/.silicon-mode/bin/silicon-mode-hook" }

    func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

    @Test func installMergesUninstallRestores() throws {
        let home = try home(withClaude: Self.userSettings)
        let t = target("claude-code", home)
        #expect(HookInstaller.status(t, helperPath: helper(home)) == .notInstalled)

        try HookInstaller.install(t, helperPath: helper(home))
        #expect(HookInstaller.status(t, helperPath: helper(home)) == .installed)
        let installed = read(t.configPath)
        let obj = try #require(CoreJSON.object(installed))
        // User settings untouched, in their original order.
        #expect(obj.str("model") == "opus")
        #expect(obj.obj("statusLine")?.str("command") == "~/bin/status.sh")
        let keys = ["\"model\"", "\"permissions\"", "\"hooks\"", "\"statusLine\"", "\"theme\""].map { installed.range(of: $0)!.lowerBound }
        #expect(keys == keys.sorted())
        // User hooks kept; ours appended.
        let hooks = try #require(obj.obj("hooks"))
        let stop = hooks.objs("Stop")
        #expect(stop.count == 2)
        #expect(stop[0].objs("hooks").first?.str("command") == "say done")
        let ours = try #require(stop[1].objs("hooks").first)
        #expect(ours.str("command") == "[ -x ~/.silicon-mode/bin/silicon-mode-hook ] && exec ~/.silicon-mode/bin/silicon-mode-hook claude-code Stop; exit 0")
        #expect(ours.bool("async") == true)
        #expect(hooks.objs("PreToolUse").count == 1) // we don't hook PreToolUse
        let perm = try #require(hooks.objs("PermissionRequest").first?.objs("hooks").first)
        #expect(perm.int("timeout") == 86_400)
        #expect(perm["async"] == nil)
        #expect(perm.str("command")?.hasSuffix("silicon-mode-hook claude-code PermissionRequest; exit 0") == true)
        for e in ["UserPromptSubmit", "Notification", "SubagentStop", "SessionStart", "SessionEnd"] { #expect(hooks.objs(e).count == 1) }
        // Formatting kept (2-space indent, trailing newline).
        #expect(installed.hasPrefix("{\n  \"model\": \"opus\",\n  \"permissions\": {\n    \"allow\": [\n      \"Bash(npm test:*)\"\n"))
        #expect(installed.hasSuffix("}\n"))

        // Backup of the original.
        #expect(read(t.configPath + ".silicon-mode-backup") == Self.userSettings)

        // Idempotent.
        try HookInstaller.install(t, helperPath: helper(home))
        #expect(read(t.configPath) == installed)

        // Uninstall restores the original bytes exactly.
        try HookInstaller.uninstall(t)
        #expect(read(t.configPath) == Self.userSettings)
        #expect(HookInstaller.status(t, helperPath: helper(home)) == .notInstalled)
        // The backup is never overwritten.
        try HookInstaller.install(t, helperPath: helper(home))
        #expect(read(t.configPath + ".silicon-mode-backup") == Self.userSettings)
    }

    @Test func createsSettingsWhenMissingAndRemovesEmptyHooks() throws {
        let home = try home(withClaude: nil)
        let t = target("claude-code", home)
        try HookInstaller.install(t, helperPath: helper(home))
        #expect(HookInstaller.status(t, helperPath: helper(home)) == .installed)
        #expect(!FileManager.default.fileExists(atPath: t.configPath + ".silicon-mode-backup"))
        try HookInstaller.uninstall(t)
        #expect(read(t.configPath) == "{}\n")
    }

    @Test func detectsOutdatedEntries() throws {
        let home = try home(withClaude: Self.userSettings)
        let t = target("claude-code", home)
        try HookInstaller.install(t, helperPath: home + "/old/silicon-mode-hook")
        #expect(HookInstaller.status(t, helperPath: helper(home)) == .needsUpdate)
        try HookInstaller.install(t, helperPath: helper(home))
        #expect(HookInstaller.status(t, helperPath: helper(home)) == .installed)
        let all = read(t.configPath)
        #expect(!all.contains("/old/"))
    }

    @Test func refusesInvalidJSONAndMissingAgents() throws {
        let home = try home(withClaude: "{ \"model\": \"opus\", oops }", codex: false)
        let t = target("claude-code", home)
        #expect(throws: HookInstaller.InstallError.self) { try HookInstaller.install(t, helperPath: helper(home)) }
        #expect(read(t.configPath) == "{ \"model\": \"opus\", oops }")
        let c = target("codex", home)
        #expect(HookInstaller.status(c) == .agentMissing)
        #expect(throws: HookInstaller.InstallError.self) { try HookInstaller.install(c, helperPath: helper(home)) }
    }

    @Test func codexHooksFile() throws {
        let home = try home(withClaude: nil)
        let c = target("codex", home)
        #expect(c.configPath == home + "/.codex/hooks.json")
        #expect(c.note != nil)
        try HookInstaller.install(c, helperPath: helper(home))
        let obj = try #require(CoreJSON.object(read(c.configPath)))
        let hooks = try #require(obj.obj("hooks"))
        #expect(Set(hooks.keys) == ["PermissionRequest", "UserPromptSubmit", "Stop"])
        let perm = try #require(hooks.objs("PermissionRequest").first?.objs("hooks").first)
        #expect(perm.str("command") == "[ -x ~/.silicon-mode/bin/silicon-mode-hook ] && exec ~/.silicon-mode/bin/silicon-mode-hook codex PermissionRequest; exit 0")
        #expect(perm["async"] == nil) // Codex hooks have no async flag
        #expect(HookInstaller.status(c, helperPath: helper(home)) == .installed)
        try HookInstaller.uninstall(c)
        #expect(HookInstaller.status(c, helperPath: helper(home)) == .notInstalled)
    }

    @Test func commandQuotingForUnusualPaths() {
        #expect(HookInstaller.command(agent: "claude-code", event: "Stop", helperPath: "/opt/sm/silicon-mode-hook", home: "/Users/x")
                == "[ -x /opt/sm/silicon-mode-hook ] && exec /opt/sm/silicon-mode-hook claude-code Stop; exit 0")
        #expect(HookInstaller.command(agent: "codex", event: "Stop", helperPath: "/Users/x/My Apps/silicon-mode-hook", home: "/Users/x")
                == "[ -x '/Users/x/My Apps/silicon-mode-hook' ] && exec '/Users/x/My Apps/silicon-mode-hook' codex Stop; exit 0")
    }

    @Test func installsHelperAtomically() throws {
        let dir = CoreFixtures.tempDir("helper")
        let src = dir + "/bundled-hook"
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: src))
        let dst = dir + "/home/.silicon-mode/bin/silicon-mode-hook"
        try HookInstaller.installHelper(from: URL(fileURLWithPath: src), to: dst)
        #expect(FileManager.default.isExecutableFile(atPath: dst))
        #expect(FileManager.default.contents(atPath: dst) == FileManager.default.contents(atPath: src))
        // Unchanged → not rewritten (same inode).
        let ino1 = CoreFS.stat(dst)?.inode
        try HookInstaller.installHelper(from: URL(fileURLWithPath: src), to: dst)
        #expect(CoreFS.stat(dst)?.inode == ino1)
        // Changed → replaced.
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: URL(fileURLWithPath: src))
        try HookInstaller.installHelper(from: URL(fileURLWithPath: src), to: dst)
        #expect(FileManager.default.contents(atPath: dst) == Data("#!/bin/sh\nexit 1\n".utf8))
        #expect(throws: HookInstaller.InstallError.self) {
            try HookInstaller.installHelper(from: URL(fileURLWithPath: dir + "/missing"), to: dst)
        }
    }

    @Test func orderedJSONRoundTrips() throws {
        let src = "{\n    \"b\": 1.50,\n    \"a\": [true, null, \"\\u00e9\"],\n    \"c\": {}\n}"
        let v = try OrderedJSON.parse(Data(src.utf8))
        #expect(v.members.map(\.0) == ["b", "a", "c"])
        let out = v.serialized(.detect(Data(src.utf8)))
        #expect(out.contains("\"b\": 1.50"))         // number text preserved
        #expect(out.contains("\"\\u00e9\""))          // escapes preserved
        #expect(out.hasPrefix("{\n    \"b\""))         // 4-space indent detected
        #expect(!out.hasSuffix("\n"))
        #expect(throws: (any Error).self) { try OrderedJSON.parse(Data("{\"a\":}".utf8)) }
    }
}
