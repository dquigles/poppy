import Foundation
import Testing
@testable import poppy

/// config.json, state.json and paths (DESIGN §8).
struct ConfigTests {
    private func decode(_ text: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(text.utf8))
    }

    @Test func emptyFileGivesDefaults() throws {
        let config = try decode("{}")
        #expect(config.command == "claude")
        #expect(config.cwd == "~")
        #expect(config.statusHooks)
        #expect(!config.autoOpenOnInput && !config.autoOpenOnDone && config.autoOpenFocus)
        #expect(!config.foldOnPrompt)
        #expect(config.showUsage)
        #expect(config.hotkeyTarget == .recent)
        #expect(config.foldOnClickOutside && !config.fadeWhenInactive && !config.hidePill)
        #expect(config.inactiveOpacity == 0.5)
        #expect(config.terminalFont == nil && config.terminalFontSize == 13 && config.terminalOpacity == 0.8)
        #expect(config.terminalTheme == .dark && config.cursorStyle == .block && config.cursorBlink)
        #expect(!config.copyOnSelect && config.confirmQuit)
        #expect(config.actHotkey == "" && !config.actEnabled && config.actCleanup == .next)
        #expect(!config.introShown)
        #expect(config.agents == nil)
    }

    @Test func wrongTypesFallBackInsteadOfFailingTheFile() throws {
        let config = try decode("""
        {"command": "codex", "statusHooks": "yes", "foldOnPrompt": 1, "hotkeyTarget": "sideways",
         "terminalTheme": 3, "cursorStyle": "triangle", "actCleanup": "never", "terminalFont": ""}
        """)
        #expect(config.command == "codex")
        #expect(config.statusHooks)
        #expect(!config.foldOnPrompt)
        #expect(config.hotkeyTarget == .recent)
        #expect(config.terminalTheme == .dark)
        #expect(config.cursorStyle == .block)
        #expect(config.actCleanup == .next)
        #expect(config.terminalFont == nil)
    }

    @Test func numbersAreClampedAndRounded() throws {
        let low = try decode(#"{"inactiveOpacity": 0, "terminalFontSize": 2, "terminalOpacity": 0}"#)
        #expect(low.inactiveOpacity == 0.2 && low.terminalFontSize == 9 && low.terminalOpacity == 0.3)
        let high = try decode(#"{"inactiveOpacity": 5, "terminalFontSize": 99, "terminalOpacity": 2}"#)
        #expect(high.inactiveOpacity == 0.9 && high.terminalFontSize == 24 && high.terminalOpacity == 1)
        #expect(try decode(#"{"terminalFontSize": 14.4}"#).terminalFontSize == 14)
    }

    @Test func settingsWrittenByTheSettingsPageDecode() throws {
        let config = try decode("""
        {"foldOnPrompt": true, "autoOpenOnDone": true, "autoOpenFocus": false, "hotkeyTarget": "cycle",
         "terminalTheme": "system", "cursorStyle": "bar", "actCleanup": "keep", "hidePill": true}
        """)
        #expect(config.foldOnPrompt && config.autoOpenOnDone && !config.autoOpenFocus && config.hidePill)
        #expect(config.hotkeyTarget == .cycle && config.terminalTheme == .system)
        #expect(config.cursorStyle == .bar && config.actCleanup == .keep)
    }

    /// An existing Act on Selection hotkey keeps working after M29 added the on/off setting.
    @Test func actEnabledDefaultsToWhetherAHotkeyIsSet() throws {
        #expect(try decode(#"{"actHotkey": "ctrl+opt+a"}"#).actEnabled)
        #expect(try !decode(#"{"actHotkey": "ctrl+opt+a", "actEnabled": false}"#).actEnabled)
        #expect(try decode(#"{"actEnabled": true}"#).actEnabled)
    }

    @Test func badAgentsAreDroppedWithoutLosingTheFile() throws {
        let bad = try decode(#"{"command": "codex", "agents": [{"name": "x"}]}"#)
        #expect(bad.command == "codex" && bad.agents == nil)
        let blank = try decode(#"{"agents": [{"name": " ", "command": "a"}, {"name": "Aider", "command": "aider"}, {"name": "b", "command": ""}]}"#)
        #expect(blank.agents == [AgentProfile(name: "Aider", command: "aider")])
    }

    @Test func roundTripsThroughJSON() throws {
        var config = Config(command: "codex", cwd: "~/src")
        config.foldOnPrompt = true
        config.terminalTheme = .light
        let again = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        #expect(again.command == "codex" && again.cwd == "~/src" && again.foldOnPrompt && again.terminalTheme == .light)
    }

    @Test(arguments: [("claude", "claude"), ("/usr/local/bin/claude --x", "claude"), ("FOO=1 codex", "codex")])
    func pillTitleIsTheFirstWordsName(command: String, title: String) {
        #expect(Config(command: command).pillTitle == title)
    }

    @Test func normalizeGivesOneSpellingPerFolder() {
        #expect(Config.normalize("/tmp/a/../b/") == "/tmp/b")
        #expect(Config.normalize("/tmp/./x") == "/tmp/x")
    }

    @Test func abbreviateWritesHomeAsTilde() {
        let home = NSHomeDirectory()
        #expect(Config.abbreviate(home) == "~")
        #expect(Config.abbreviate(home + "/src/poppy") == "~/src/poppy")
        #expect(Config.abbreviate(home + "x/y") == home + "x/y")  // not inside home
        #expect(Config.abbreviate("/tmp") == "/tmp")
    }

    @Test func resolvedWorkingDirectoryExpandsAndFallsBackToHome() {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(Config(cwd: "~").resolvedWorkingDirectory == NSHomeDirectory())
        #expect(Config(cwd: folder.path).resolvedWorkingDirectory == folder.path)
        #expect(Config(cwd: folder.path + "/gone").resolvedWorkingDirectory == NSHomeDirectory())
        let file = folder.appendingPathComponent("file")
        try? Data().write(to: file)
        #expect(Config(cwd: file.path).resolvedWorkingDirectory == NSHomeDirectory())
    }

    @Test func clamped() {
        #expect(Config.clamped(5, to: 0...1) == 1)
        #expect(Config.clamped(-5, to: 0...1) == 0)
        #expect(Config.clamped(0.5, to: 0...1) == 0.5)
    }

    // MARK: state.json (DESIGN §8.2, §9.16)

    @Test func savedSessionKeepsItsConversation() throws {
        let session = SavedSession(command: "claude", cwd: "~/src", name: nil, conversation: "abc-123")
        let data = try JSONEncoder().encode(session)
        let again = try JSONDecoder().decode(SavedSession.self, from: data)
        #expect(again.conversation == "abc-123" && again.command == "claude" && again.cwd == "~/src" && again.name == nil)
    }

    @Test func stateFromBeforeConversationsStillLoads() throws {
        let text = #"{"pills": [{"sessions": [{"command": "claude", "cwd": "~", "name": "api"}], "selected": 0}], "pillDiameter": 44}"#
        let state = try JSONDecoder().decode(PanelState.self, from: Data(text.utf8))
        let session = try #require(state.pills?.first?.sessions.first)
        #expect(session.conversation == nil && session.name == "api")
    }

    @Test func stateFromBeforeSeveralPillsStillLoads() throws {
        let text = #"{"pillOrigin": {"x": 1200, "y": 16}, "pillDiameter": 44, "expandedSize": {"width": 760, "height": 480}}"#
        let state = try JSONDecoder().decode(PanelState.self, from: Data(text.utf8))
        #expect(state.pills == nil)
        #expect(state.pillOrigin?.x == 1200 && state.expandedSize?.width == 760)
    }
}

/// Agents: detection, the profile list and the installed check's word (DESIGN §7.11, §9.5).
struct AgentTests {
    @Test(arguments: [
        ("claude", Harness.claude), ("/usr/local/bin/claude --x", .claude), ("FOO=1 claude", .claude),
        ("CLAUDE", .claude), ("codex", .codex), ("CODEX_HOME=~/x codex", .codex), ("agy", .antigravity),
        ("antigravity", .other), ("opencode", .opencode), ("zsh -l", .shell), ("/bin/bash -l", .shell),
        ("fish", .shell), ("npx claude", .other), ("aider", .other), ("", .other),
    ])
    func harnessFromCommand(command: String, harness: Harness) {
        #expect(Harness(command: command) == harness)
    }

    @Test(arguments: [("FOO=1", true), ("_X=", true), ("A1=b", true), ("=x", false), ("1A=b", false),
                      ("A-B=c", false), ("claude", false)])
    func assignments(word: String, isAssignment: Bool) {
        #expect(AgentProfile.isAssignment(word) == isAssignment)
    }

    @Test func probeWord() {
        #expect(AgentProfile(name: "", command: "claude --x").probeWord == "claude")
        #expect(AgentProfile(name: "", command: "A=1 B=2 codex").probeWord == "codex")
        #expect(AgentProfile(name: "", command: "~/bin/agent").probeWord == NSHomeDirectory() + "/bin/agent")
        #expect(AgentProfile(name: "", command: "").probeWord == nil)
        #expect(AgentProfile(name: "", command: "A=1").probeWord == nil)
        for odd in ["'my agent'", "\"x\"", "$AGENT", "`which x`", "a\\ b"] {
            #expect(AgentProfile(name: "", command: odd).probeWord == nil)
        }
    }

    @Test func builtIns() {
        #expect(AgentCatalog.builtIns.map(\.command) == ["claude", "codex", "agy", "opencode"])
    }

    @Test func profilesListTheRunningAndLaunchCommandsFirst() {
        var config = Config(command: "aider --x")
        config.agents = [AgentProfile(name: "Codex again", command: " codex "), AgentProfile(name: "Goose", command: "goose")]
        let profiles = AgentCatalog(launchCommand: "/opt/llm").profiles(for: config)
        #expect(profiles.map(\.command) == ["aider --x", "/opt/llm", "claude", "codex", "agy", "opencode", "goose"])
        #expect(profiles[0].name == "aider" && profiles[1].name == "llm")
    }

    @Test func profilesDontRepeatABuiltIn() {
        let profiles = AgentCatalog(launchCommand: "claude").profiles(for: Config(command: "codex"))
        #expect(profiles.map(\.command) == ["claude", "codex", "agy", "opencode"])
    }

    @Test func notProbedYetCountsAsUnknown() {
        let catalog = AgentCatalog(launchCommand: "claude")
        #expect(catalog.isInstalled(AgentProfile(name: "", command: "claude")) == nil)
    }

    @Test func same() {
        #expect(AgentCatalog.same(" claude ", "claude"))
        #expect(!AgentCatalog.same("claude", "claude --x"))
    }

    @Test func displayNames() {
        #expect(Harness.claude.displayName == "Claude Code" && Harness.shell.displayName == "Terminal")
    }
}

/// The agent's shell and environment (DESIGN §9.2).
struct ShellEnvironmentTests {
    @Test func runsTheCommandInAnInteractiveLoginShell() {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let spec = ShellEnvironment.launchSpec(for: Config(command: "claude --x", cwd: folder.path))
        #expect(spec.args == ["-l", "-i", "-c", "claude --x"])
        #expect(spec.executable.hasPrefix("/"))
        #expect(spec.currentDirectory == folder.path)
    }

    @Test func environmentSetsTerminalAndDropsParentSessions() {
        let leaked = ["POPPY_STATUS_FILE", "POPPY_COMMAND", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID",
                      "TERM_SESSION_ID", "CLAUDE_PID"]
        for key in leaked { setenv(key, "1", 1) }
        setenv("CLAUDE_CODE_USE_BEDROCK", "1", 1)
        defer { for key in leaked + ["CLAUDE_CODE_USE_BEDROCK"] { unsetenv(key) } }
        let env = Dictionary(ShellEnvironment.probeSpec(script: "true").environment.map { line -> (String, String) in
            let parts = line.split(separator: "=", maxSplits: 1)
            return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
        }, uniquingKeysWith: { a, _ in a })
        #expect(env["TERM"] == "xterm-256color" && env["COLORTERM"] == "truecolor" && env["TERM_PROGRAM"] == "Poppy")
        for key in leaked { #expect(env[key] == nil, "\(key) leaked into the agent") }
        #expect(env["CLAUDE_CODE_USE_BEDROCK"] == "1")
        #expect(env["HOME"]?.isEmpty == false && env["LANG"]?.isEmpty == false)
    }

    @Test func terminalCommandIsALoginShell() {
        #expect(ShellEnvironment.terminalCommand.hasSuffix(" -l"))
        #expect(Harness(command: ShellEnvironment.terminalCommand) == .shell)
    }
}
