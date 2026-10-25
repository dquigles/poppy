import Foundation

/// Everything needed to spawn the agent; computed once per session (DESIGN §9.2).
nonisolated struct LaunchSpec: Sendable {
    var executable: String
    var args: [String]
    var environment: [String]
    var currentDirectory: String
}

nonisolated enum ShellEnvironment {
    /// Runs `command` through the user's login + interactive shell so PATH, aliases
    /// and functions from their dotfiles apply (no `exec`, so aliases work).
    static func launchSpec(for config: Config) -> LaunchSpec {
        let env = ProcessInfo.processInfo.environment
        let executable = resolveShell(env["SHELL"])
        return LaunchSpec(
            executable: executable,
            args: ["-l", "-i", "-c", config.command],
            environment: childEnvironment(from: env, shell: executable),
            currentDirectory: config.resolvedWorkingDirectory
        )
    }

    /// Same shell, flags and environment as the agent, running `script` instead
    /// (used to check which agent CLIs are installed, DESIGN §9.5).
    static func probeSpec(script: String) -> LaunchSpec {
        let env = ProcessInfo.processInfo.environment
        let executable = resolveShell(env["SHELL"])
        return LaunchSpec(
            executable: executable,
            args: ["-l", "-i", "-c", script],
            environment: childEnvironment(from: env, shell: executable),
            currentDirectory: NSHomeDirectory()
        )
    }

    /// A plain terminal: the user's login shell, inside the usual `-l -i -c` one.
    static var terminalCommand: String {
        resolveShell(ProcessInfo.processInfo.environment["SHELL"]) + " -l"
    }

    private static func resolveShell(_ shell: String?) -> String {
        if let shell, shell.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: shell) {
            return shell
        }
        return "/bin/zsh"
    }

    private static func childEnvironment(from parent: [String: String], shell: String) -> [String] {
        var env = parent
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Poppy"
        env["SHELL"] = shell
        if env["LANG"]?.isEmpty ?? true {
            env["LANG"] = "en_US.UTF-8"
        }
        let defaults = ["HOME": NSHomeDirectory(), "USER": NSUserName(), "LOGNAME": NSUserName()]
        for (key, value) in defaults where env[key]?.isEmpty ?? true {
            env[key] = value
        }
        // Don't leak the launching terminal's identity or a parent Claude Code session (Poppy
        // Dev started from a session in Poppy: its agents ran as that session's children and
        // reported their status to the other Poppy's pill, whose POPPY_STATUS_FILE came first;
        // TerminalSession adds this session's own). Settings like CLAUDE_CODE_USE_BEDROCK stay.
        for key in ["POPPY_COMMAND", "POPPY_STATUS_FILE", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT",
                    "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ATTENDED",
                    "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_EXECPATH",
                    "CLAUDE_PID", "CLAUDE_EFFORT"] {
            env[key] = nil
        }
        return env.map { "\($0.key)=\($0.value)" }
    }
}
