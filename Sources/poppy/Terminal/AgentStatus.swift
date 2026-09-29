import AppKit

/// What the agent is doing, as reported by its hooks (DESIGN §9.6).
nonisolated enum AgentStatus: String, Sendable {
    case idle, working, waiting, done

    /// Tint for the pill logo (not the menu bar icon); nil means the normal color.
    var tint: NSColor? {
        switch self {
        case .idle: nil
        case .working: .systemBlue
        case .waiting: .systemOrange
        case .done: .systemGreen
        }
    }
}

/// Installs the hooks that report status into `$POPPY_STATUS_FILE` (DESIGN §9.6).
/// Every hook command does nothing unless that variable is set, so entries in an
/// agent's global config are inert outside Poppy.
nonisolated enum StatusHooks {
    /// Marker used to recognize Poppy's own entries in shared config files.
    static let marker = "POPPY_STATUS_FILE"

    /// Writes only if the file exists, so a dying agent can't recreate a file Poppy removed.
    static func command(_ status: AgentStatus) -> String {
        "[ -f \"$POPPY_STATUS_FILE\" ] && printf %s \(status.rawValue) > \"$POPPY_STATUS_FILE\"; exit 0"
    }

    /// Readies status reporting for `command`'s harness and returns the command to run:
    /// Claude gets `--settings <Poppy's hooks file>` right after the executable word
    /// (nothing global is touched); Codex, Gemini and opencode get Poppy's entries merged
    /// into their global config.
    static func prepare(command: String) -> String {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        switch Harness(command: command) {
        case .claude:
            if command.contains("--settings") {
                appLog("status hooks: the command already has --settings; Poppy's may be overridden")
            }
            guard let path = writeClaudeSettings() else { return command }
            return insertAfterExecutable(command, "--settings '" + path.replacingOccurrences(of: "'", with: "'\\''") + "'")
        case .codex:
            let codexHome = directory(fromEnvironment: "CODEX_HOME") ?? home.appendingPathComponent(".codex")
            mergeHooks(into: codexHome.appendingPathComponent("hooks.json"), events: [
                ("SessionStart", .idle), ("UserPromptSubmit", .working), ("PreToolUse", .working),
                ("PostToolUse", .working), ("PermissionRequest", .waiting), ("Stop", .done),
            ])
        case .gemini:
            // Gemini matches `matcher` as a regex only for tool events; other events get no
            // matcher (which matches all), as other tools' Gemini hooks do.
            mergeHooks(into: home.appendingPathComponent(".gemini/settings.json"), events: [
                ("SessionStart", .idle), ("BeforeAgent", .working), ("BeforeTool", .working),
                ("AfterTool", .working), ("Notification", .waiting), ("AfterAgent", .done),
            ], matcherEvents: ["BeforeTool", "AfterTool"])
        case .opencode:
            let config = directory(fromEnvironment: "XDG_CONFIG_HOME") ?? home.appendingPathComponent(".config")
            writeOpencodePlugin(config.appendingPathComponent("opencode/plugins/poppy-status.ts"))
        case .other:
            break
        }
        return command
    }

    /// A directory from Poppy's own environment; empty counts as unset, and a leading `~`
    /// is expanded. (A value exported only in the shell's dotfiles isn't seen here.)
    private static func directory(fromEnvironment key: String) -> URL? {
        guard var value = ProcessInfo.processInfo.environment[key], !value.isEmpty else { return nil }
        if value == "~" || value.hasPrefix("~/") { value = NSHomeDirectory() + value.dropFirst() }
        return URL(fileURLWithPath: value)
    }

    /// Inserts `argument` after the command's executable word (after any leading
    /// `NAME=value` words), so `claude; exec zsh` or `claude -- "prompt"` still pass it
    /// to claude. Whitespace inside the rest of the command is kept as typed.
    static func insertAfterExecutable(_ command: String, _ argument: String) -> String {
        var index = command.startIndex
        func skipSpaces() { while index < command.endIndex, command[index].isWhitespace { index = command.index(after: index) } }
        func word() -> Substring {
            let start = index
            while index < command.endIndex, !command[index].isWhitespace { index = command.index(after: index) }
            return command[start..<index]
        }
        while true {
            skipSpaces()
            let w = word()
            if w.isEmpty { return command + " " + argument }
            if !AgentProfile.isAssignment(String(w)) {
                // Stop the executable word at a shell operator glued to it (e.g. "claude;").
                if let cut = w.firstIndex(where: { ";|&<>()".contains($0) }) { index = cut }
                return String(command[..<index]) + " " + argument + String(command[index...])
            }
        }
    }

    // MARK: - Claude: a --settings overlay

    /// Written on every Claude start (init, switch, restart). `Notification` is scoped to `permission_prompt`, so
    /// Claude's ~60 s idle notification never reads as "needs input".
    private static func writeClaudeSettings() -> String? {
        let entry = { (matcher: String, status: AgentStatus) -> [String: Any] in
            ["matcher": matcher, "hooks": [["type": "command", "command": command(status)]]]
        }
        let settings: [String: Any] = ["hooks": [
            // Not "compact": SessionStart also fires after auto-compaction, mid-turn.
            "SessionStart": [entry("startup|resume|clear", .idle)],
            "UserPromptSubmit": [entry(".*", .working)],
            "PreToolUse": [entry(".*", .working)],
            "PostToolUse": [entry(".*", .working)],
            "Notification": [entry("permission_prompt", .waiting)],
            "PermissionRequest": [entry(".*", .waiting)],
            "Stop": [entry(".*", .done)],
        ]]
        let url = ConfigPaths.directory.appendingPathComponent("claude-hooks.json")
        do {
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try ConfigPaths.write(data, to: url)
            return url.path
        } catch {
            appLog("status hooks: could not write \(url.path): \(error)")
            return nil
        }
    }

    // MARK: - Codex / Gemini: additive merge into a shared hooks file

    /// Appends one `{matcher: ".*", hooks: [Poppy's command]}` entry per event unless an
    /// entry for that event already contains `marker`. Never removes or reorders anything
    /// (Codex records approval per entry position), never touches other keys, and writes
    /// nothing if the file can't be read or isn't the expected shape.
    /// `matcherEvents`: events whose entry gets `"matcher": ".*"` (nil: all of them).
    private static func mergeHooks(into url: URL, events: [(String, AgentStatus)], matcherEvents: Set<String>? = nil) {
        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                appLog("status hooks: \(url.path) isn't a JSON object; not changed")
                return
            }
            root = parsed
        }
        guard var hooks = (root["hooks"] ?? [String: Any]()) as? [String: Any] else {
            appLog("status hooks: \(url.path) has an unexpected \"hooks\" value; not changed")
            return
        }
        var changed = false
        for (event, status) in events {
            guard var entries = (hooks[event] ?? [Any]()) as? [Any] else {
                appLog("status hooks: \(url.path) has an unexpected \(event) value; not changed")
                return
            }
            let present = entries.contains { entry in
                guard let data = try? JSONSerialization.data(withJSONObject: entry) else { return false }
                return String(decoding: data, as: UTF8.self).contains(marker)
            }
            if present { continue }
            var entry: [String: Any] = ["hooks": [["type": "command", "command": command(status)]]]
            if matcherEvents?.contains(event) ?? true { entry["matcher"] = ".*" }
            entries.append(entry)
            hooks[event] = entries
            changed = true
        }
        guard changed else { return }
        root["hooks"] = hooks
        // Write through a symlink (dotfile managers) and keep the file's permissions.
        let target = url.resolvingSymlinksInPath()
        let permissions = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.posixPermissions]
        do {
            let data = try JSONSerialization.data(withJSONObject: root,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            if let permissions {
                try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
            }
            appLog("status hooks: added Poppy's entries to \(target.path)")
        } catch {
            appLog("status hooks: could not write \(url.path): \(error)")
        }
    }

    // MARK: - opencode: a Poppy-owned plugin file

    private static let opencodePlugin = """
    // Managed by Poppy (DESIGN §9.6). Reports status to Poppy when running inside it;
    // a no-op for any other opencode session. Subagent (child) sessions are ignored, so a
    // finishing subagent doesn't report "done" mid-turn.
    export const PoppyStatus = async () => {
      const file = process.env.POPPY_STATUS_FILE;
      if (!file) return {};
      const fs = await import("node:fs");
      const report = (status) => {
        try { fs.writeFileSync(file, status); } catch {}
      };
      let root;
      return {
        event: async ({ event }) => {
          const props = event.properties ?? {};
          if (event.type === "session.created") {
            const info = props.info ?? {};
            if (info.parentID) return;
            root = info.id;
            report("idle");
          }
          if (event.type === "session.idle") {
            if (root && props.sessionID && props.sessionID !== root) return;
            report("done");
          }
          // Newer opencode reports permission requests as events.
          if (event.type === "permission.updated" || event.type === "permission.asked") report("waiting");
        },
        "chat.message": async () => { report("working"); },
        "tool.execute.before": async () => { report("working"); },
        "tool.execute.after": async () => { report("working"); },
        "permission.ask": async () => { report("waiting"); },
      };
    };

    """

    private static func writeOpencodePlugin(_ url: URL) {
        if (try? String(contentsOf: url, encoding: .utf8)) == opencodePlugin { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try opencodePlugin.write(to: url, atomically: true, encoding: .utf8)
            appLog("status hooks: wrote \(url.path)")
        } catch {
            appLog("status hooks: could not write \(url.path): \(error)")
        }
    }
}
