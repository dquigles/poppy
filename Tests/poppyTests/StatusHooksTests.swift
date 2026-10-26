import Foundation
import Testing
@testable import poppy

/// Hook commands, argument insertion and resuming (DESIGN §9.6, §9.16).
struct StatusHooksTests {
    // MARK: Arguments after the executable word

    @Test(arguments: [
        ("claude", "claude X"),
        ("claude --model opus", "claude X --model opus"),
        ("FOO=1 claude", "FOO=1 claude X"),
        ("A=1 B=2 claude -c", "A=1 B=2 claude X -c"),
        ("claude; exec zsh", "claude X; exec zsh"),
        ("claude|tee log", "claude X|tee log"),
        ("claude -- \"prompt\"", "claude X -- \"prompt\""),
        ("claude # note", "claude X # note"),
        ("/usr/local/bin/claude", "/usr/local/bin/claude X"),
    ])
    func insertsAfterExecutable(command: String, expected: String) {
        #expect(StatusHooks.insertAfterExecutable(command, "X") == expected)
    }

    @Test func executablePrefixKeepsAssignments() {
        #expect(StatusHooks.executablePrefix("CODEX_HOME=~/x codex --foo") == "CODEX_HOME=~/x codex")
        #expect(StatusHooks.executablePrefix("  claude  ") == "claude")
        #expect(StatusHooks.executablePrefix("codex;ls") == "codex")
    }

    // MARK: Resuming (DESIGN §9.16)

    @Test(arguments: [
        ("claude", "claude --resume abc-123"),
        ("claude --model opus", "claude --resume abc-123 --model opus"),
        ("codex", "codex resume abc-123"),
        ("agy", "agy --conversation abc-123"),
        ("opencode", "opencode --session abc-123"),
        ("FOO=1 /opt/bin/claude", "FOO=1 /opt/bin/claude --resume abc-123"),
    ])
    func resumes(command: String, expected: String) {
        #expect(StatusHooks.resuming(command, conversation: "abc-123") == expected)
    }

    @Test func opencodeIdsWithUnderscoresResume() {
        #expect(StatusHooks.resuming("opencode", conversation: "ses_9fA2") == "opencode --session ses_9fA2")
    }

    @Test(arguments: ["zsh -l", "cat", "npx something"])
    func doesNotResumeOtherCommands(command: String) {
        #expect(StatusHooks.resuming(command, conversation: "abc") == nil)
    }

    @Test(arguments: ["", "a b", "a;rm -rf ~", "$(id)", "a'b", "é"])
    func rejectsUnsafeIds(id: String) {
        #expect(StatusHooks.resuming("claude", conversation: id) == nil)
    }

    /// Codex's `--no-daemon` (added by `prepare`) must come before the `resume` subcommand.
    @Test func codexNoDaemonGoesBeforeResume() {
        let resumed = StatusHooks.resuming("codex", conversation: "id1")!
        #expect(StatusHooks.insertAfterExecutable(resumed, "--no-daemon") == "codex --no-daemon resume id1")
    }

    // MARK: Claude's settings overlay

    @Test func claudeSettingsReportStatusAndConversation() {
        let hooks = StatusHooks.claudeSettings["hooks"] as! [String: [[String: Any]]]
        #expect(Set(hooks.keys) == ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                                    "Notification", "PermissionRequest", "Stop"])
        #expect(hooks["SessionStart"]![0]["matcher"] as? String == "startup|resume|clear")
        #expect(hooks["Notification"]![0]["matcher"] as? String == "permission_prompt")
        let prompt = hooks["UserPromptSubmit"]![0]["hooks"] as! [[String: String]]
        #expect(prompt.map { $0["command"]! } == [StatusHooks.command(.working), StatusHooks.conversationCommand])
        let stop = hooks["Stop"]![0]["hooks"] as! [[String: String]]
        #expect(stop[0]["command"] == StatusHooks.command(.done))
    }

    // MARK: Codex's merged hooks file

    private func codexEntries() -> [(event: String, command: String, marker: String)] {
        [("UserPromptSubmit", StatusHooks.command(.working), StatusHooks.marker),
         ("Stop", StatusHooks.command(.done), StatusHooks.marker),
         ("UserPromptSubmit", StatusHooks.conversationCommand, StatusHooks.conversationMarker)]
    }

    private func commands(_ file: URL, _ event: String) -> [String] {
        let hooks = json(read(file)!)["hooks"] as! [String: [[String: Any]]]
        return (hooks[event] ?? []).flatMap { ($0["hooks"] as! [[String: String]]).map { $0["command"]! } }
    }

    @Test func mergeIntoNewFile() {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("sub/hooks.json")
        StatusHooks.mergeHooks(into: file, entries: codexEntries())
        #expect(commands(file, "UserPromptSubmit") == [StatusHooks.command(.working), StatusHooks.conversationCommand])
        #expect(commands(file, "Stop") == [StatusHooks.command(.done)])
    }

    /// An install from before §9.16 gains only the conversation entry, after the user's and Poppy's.
    @Test func mergeAddsOnlyWhatIsMissingAndKeepsTheRest() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("hooks.json")
        let old: [String: Any] = [
            "other": ["kept": true],
            "hooks": [
                "UserPromptSubmit": [
                    ["matcher": ".*", "hooks": [["type": "command", "command": "echo mine"]]],
                    ["matcher": ".*", "hooks": [["type": "command", "command": StatusHooks.command(.working)]]],
                ],
                "Stop": [["matcher": ".*", "hooks": [["type": "command", "command": StatusHooks.command(.done)]]]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: old).write(to: file)
        StatusHooks.mergeHooks(into: file, entries: codexEntries())
        #expect(commands(file, "UserPromptSubmit") == ["echo mine", StatusHooks.command(.working), StatusHooks.conversationCommand])
        #expect(commands(file, "Stop") == [StatusHooks.command(.done)])
        #expect((json(read(file)!)["other"] as? [String: Bool]) == ["kept": true])

        let once = read(file)
        StatusHooks.mergeHooks(into: file, entries: codexEntries())
        #expect(read(file) == once)  // idempotent
    }

    @Test(arguments: ["not json", "[1, 2]", "{\"hooks\": 3}", "{\"hooks\": {\"Stop\": {}}}"])
    func mergeLeavesUnexpectedFilesAlone(text: String) throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("hooks.json")
        try text.write(to: file, atomically: true, encoding: .utf8)
        StatusHooks.mergeHooks(into: file, entries: codexEntries())
        #expect(read(file) == text)
    }

    @Test func mergeWritesThroughSymlinks() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("dotfiles-hooks.json")
        try "{}".write(to: target, atomically: true, encoding: .utf8)
        let link = folder.appendingPathComponent("hooks.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        StatusHooks.mergeHooks(into: link, entries: codexEntries())
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
        #expect(commands(target, "Stop") == [StatusHooks.command(.done)])
    }

    @Test func opencodePluginRecordsTheRootSession() {
        #expect(StatusHooks.opencodePlugin.contains(#"fs.writeFileSync(file + ".conversation", info.id)"#))
        #expect(StatusHooks.opencodePlugin.contains("if (info.parentID) return;"))
    }

    // MARK: The hook commands, run through a real shell

    @Test(arguments: [AgentStatus.idle, .working, .waiting, .done])
    func statusCommandWritesItsWord(status: AgentStatus) throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("status")
        try Data().write(to: file)
        #expect(runShell(StatusHooks.command(status), environment: ["POPPY_STATUS_FILE": file.path]) == 0)
        #expect(read(file) == status.rawValue)
    }

    @Test func statusCommandNeverRecreatesARemovedFile() {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("status")
        #expect(runShell(StatusHooks.command(.done), environment: ["POPPY_STATUS_FILE": file.path]) == 0)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(runShell(StatusHooks.command(.done)) == 0)  // outside Poppy: a no-op
    }

    @Test(arguments: [
        #"{"session_id":"abc-123","transcript_path":"/x","prompt":"say \"hi\""}"#,
        #"{"hook_event_name": "UserPromptSubmit", "session_id" : "abc-123", "cwd": "/"}"#,
        "{\n  \"session_id\": \"abc-123\",\n  \"turn_id\": \"t1\"\n}",
    ])
    func conversationCommandRecordsTheSessionId(input: String) throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("status")
        try Data().write(to: file)
        #expect(runShell(StatusHooks.conversationCommand, stdin: input, environment: ["POPPY_STATUS_FILE": file.path]) == 0)
        #expect(read(folder.appendingPathComponent("status.conversation")) == "abc-123")
        #expect(read(file) == "")  // the status itself is untouched
    }

    @Test func conversationCommandWithoutAnIdOrOutsidePoppyWritesNothing() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("status")
        let conversation = folder.appendingPathComponent("status.conversation")
        try Data().write(to: file)
        #expect(runShell(StatusHooks.conversationCommand, stdin: #"{"cwd":"/"}"#,
                         environment: ["POPPY_STATUS_FILE": file.path]) == 0)
        #expect(!FileManager.default.fileExists(atPath: conversation.path))
        try FileManager.default.removeItem(at: file)
        #expect(runShell(StatusHooks.conversationCommand, stdin: #"{"session_id":"x"}"#,
                         environment: ["POPPY_STATUS_FILE": file.path]) == 0)
        #expect(!FileManager.default.fileExists(atPath: conversation.path))
    }

    @Test func antigravityInvocationRecordsWorkingModelAndConversation() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("status")
        try Data().write(to: file)
        let input = #"{"conversationId":"c-42","modelName":"gemini-3-pro","step":1}"#
        #expect(runShell(StatusHooks.antigravityInvocationCommand, stdin: input,
                         environment: ["POPPY_STATUS_FILE": file.path]) == 0)
        #expect(read(file) == "working")
        #expect(read(folder.appendingPathComponent("status.model")) == "gemini-3-pro")
        #expect(read(folder.appendingPathComponent("status.conversation")) == "c-42")
    }

    @Test func antigravityInvocationWithoutIdsOnlyReportsWorking() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("status")
        try Data().write(to: file)
        #expect(runShell(StatusHooks.antigravityInvocationCommand, stdin: "{}",
                         environment: ["POPPY_STATUS_FILE": file.path]) == 0)
        #expect(read(file) == "working")
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("status.model").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("status.conversation").path))
    }
}
