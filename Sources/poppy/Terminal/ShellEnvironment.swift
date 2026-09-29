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
        // Don't leak the launching terminal's identity or a parent Claude Code session.
        for key in ["POPPY_COMMAND", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"] {
            env[key] = nil
        }
        return env.map { "\($0.key)=\($0.value)" }
    }
}
