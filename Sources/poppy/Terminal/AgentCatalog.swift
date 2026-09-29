import Foundation

/// A switchable agent: a display name and the shell command that runs it (DESIGN §9.5).
nonisolated struct AgentProfile: Codable, Sendable, Equatable {
    var name: String
    var command: String

    /// The word to check with `command -v`: the command's first word after any leading
    /// `NAME=value` assignments, with a leading `~/` expanded. Nil (can't tell; treated as
    /// installed) for an empty command or a word with quotes, `$`, backticks or backslashes.
    var probeWord: String? {
        let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard var word = words.first(where: { !Self.isAssignment($0) }) else { return nil }
        if word.contains(where: { "'\"`$\\".contains($0) }) { return nil }
        if word.hasPrefix("~/") { word = NSHomeDirectory() + "/" + word.dropFirst(2) }
        return word
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let eq = word.firstIndex(of: "="), eq != word.startIndex else { return false }
        let name = word[..<eq]
        return name.first.map { $0 == "_" || $0.isLetter } == true
            && name.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }
}

/// The agents offered in the menu, and which of their CLIs are installed (DESIGN §9.5).
final class AgentCatalog {
    static let builtIns = [
        AgentProfile(name: "Claude Code", command: "claude"),
        AgentProfile(name: "Codex", command: "codex"),
        AgentProfile(name: "Gemini CLI", command: "gemini"),
        AgentProfile(name: "opencode", command: "opencode"),
    ]
    private nonisolated static let probeTimeout: TimeInterval = 5
    private static let reprobeInterval: TimeInterval = 60

    /// The command Poppy launched with, kept in the list after switching away from it.
    private let launchCommand: String

    /// Words found on the login shell's PATH (aliases and functions count). Nil until a
    /// probe succeeds; a failed probe leaves the last result unchanged.
    private var installed: Set<String>?
    private var probedWords: Set<String> = []
    private var lastProbe: Date?
    private var probing = false

    init(launchCommand: String) {
        self.launchCommand = launchCommand
    }

    /// Built-ins, then `config.agents` (skipping duplicate commands). The launch command and
    /// the current command, if not among them, are listed first under their `pillTitle`s,
    /// so the running agent is always checked and the launch one can be switched back to.
    func profiles(for config: Config) -> [AgentProfile] {
        var list = Self.builtIns
        for agent in config.agents ?? [] where !list.contains(where: { Self.same($0.command, agent.command) }) {
            list.append(agent)
        }
        for command in [config.command, launchCommand].reversed()
        where !list.contains(where: { Self.same($0.command, command) }) {
            var named = config
            named.command = command
            list.insert(AgentProfile(name: named.pillTitle, command: command), at: 0)
        }
        return list
    }

    static func same(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces) == b.trimmingCharacters(in: .whitespaces)
    }

    /// True/false once probed; nil if unknown (treated as installed).
    func isInstalled(_ profile: AgentProfile) -> Bool? {
        guard let word = profile.probeWord, let installed, probedWords.contains(word) else { return nil }
        return installed.contains(word)
    }

    /// Probes in the background if none has run, the last is over a minute old, or the
    /// list has words not yet probed. The result shows the next time the menu opens.
    func refreshIfNeeded(_ profiles: [AgentProfile]) {
        let words = Set(profiles.compactMap(\.probeWord))
        let stale = lastProbe.map { Date().timeIntervalSince($0) > Self.reprobeInterval } ?? true
        guard !probing, !words.isEmpty, stale || !words.isSubset(of: probedWords) else { return }
        probing = true
        let spec = ShellEnvironment.probeSpec(script: Self.probeScript(for: words))
        DispatchQueue.global().async { [weak self] in
            let found = Self.runProbe(spec)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.probeFinished(found: found, words: words) }
            }
        }
    }

    private func probeFinished(found: Set<String>?, words: Set<String>) {
        probing = false
        lastProbe = Date()
        guard let found else { return }
        installed = found
        probedWords = words
        appLog("agents installed: \(found.sorted().joined(separator: ", "))")
    }

    /// `command -v` each word; found ones are echoed with a marker, so anything the user's
    /// dotfiles print is ignored.
    private static func probeScript(for words: Set<String>) -> String {
        let quoted = words.sorted().map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return "for c in \(quoted.joined(separator: " ")); do "
            + "command -v \"$c\" >/dev/null 2>&1 && printf 'POPPY_AGENT:%s\\n' \"$c\"; done"
    }

    /// Runs the probe shell in its own session (setsid: no controlling terminal, so under
    /// `swift run` it can't touch the launching terminal), with stdin/stderr on /dev/null.
    /// Reads until the shell exits, not until EOF (a background job from the dotfiles may
    /// hold the pipe open), polling every 100 ms. After `probeTimeout` it SIGKILLs the
    /// whole process group (interactive shells ignore SIGTERM) and returns nil. Nil on
    /// any failure.
    private nonisolated static func runProbe(_ spec: LaunchSpec) -> Set<String>? {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        let (readEnd, writeEnd) = (fds[0], fds[1])

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addchdir_np(&actions, spec.currentDirectory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // New session; close every descriptor not set up above (e.g. the agent's pty).
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = ([spec.executable] + spec.args).map { strdup($0) } + [nil]
        let envp = spec.environment.map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        let spawnError = posix_spawn(&pid, spec.executable, &actions, &attributes, argv, envp)
        close(writeEnd)
        guard spawnError == 0 else {
            close(readEnd)
            appLog("agent probe failed to start: errno \(spawnError)")
            return nil
        }
        defer { close(readEnd) }
        _ = fcntl(readEnd, F_SETFL, fcntl(readEnd, F_GETFL) | O_NONBLOCK)

        let deadline = Date().addingTimeInterval(probeTimeout)
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var eof = false
        /// Reads whatever is available now; sets `eof` when the pipe closes.
        func drain() {
            while !eof {
                let n = read(readEnd, &buffer, buffer.count)
                if n > 0 { output.append(contentsOf: buffer[0..<n]) } else { eof = n == 0; return }
            }
        }
        var status: Int32 = 0
        while true {
            if eof {
                usleep(50_000)
            } else {
                var pfd = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
                _ = poll(&pfd, 1, 100)
                drain()
            }
            if waitpid(pid, &status, WNOHANG) == pid {
                drain()  // everything the shell wrote before exiting
                break
            }
            if Date() > deadline {
                appLog("agent probe timed out")
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
                waitpid(pid, &status, 0)
                return nil
            }
        }
        guard status & 0x7f == 0 else { return nil }  // killed by a signal

        var found = Set<String>()
        for line in String(decoding: output, as: UTF8.self).split(separator: "\n")
        where line.hasPrefix("POPPY_AGENT:") {
            found.insert(String(line.dropFirst("POPPY_AGENT:".count)))
        }
        return found
    }
}
