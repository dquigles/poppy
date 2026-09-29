import Foundation

/// Short-lived helper processes: the installed-CLI probe (DESIGN §9.5) and Codex's usage
/// RPC (§9.7).
nonisolated enum ChildProcess {
    struct Result: Sendable {
        var output: Data
        /// The `waitpid` status if the process exited on its own; nil if `until` ended it.
        var status: Int32?

        var exitedNormally: Bool { status.map { $0 & 0x7f == 0 } ?? false }
    }

    /// Runs `spec` in its own session (setsid: no controlling terminal, so under
    /// `swift run` it can't touch the launching terminal), with stderr on /dev/null and
    /// stdin on /dev/null, or a pipe holding `input` (kept open until the end). Reads
    /// stdout until `until(output)` is true (then closes stdin, gives the process up to
    /// `graceTime` to exit on its own, and SIGKILLs the process group) or the process exits, not until EOF (a background job from the dotfiles may hold the pipe
    /// open), polling every 100 ms. After `timeout` it SIGKILLs the whole process group
    /// (interactive shells ignore SIGTERM) and returns nil. Nil on any failure.
    static let graceTime: TimeInterval = 1

    static func run(_ spec: LaunchSpec, label: String, input: Data? = nil, timeout: TimeInterval,
                    until: (Data) -> Bool = { _ in false }) -> Result? {
        var outFds: [Int32] = [0, 0]
        guard pipe(&outFds) == 0 else { return nil }
        let (readEnd, writeEnd) = (outFds[0], outFds[1])
        var inFds: [Int32] = [-1, -1]
        if input != nil, pipe(&inFds) != 0 {
            close(readEnd)
            close(writeEnd)
            return nil
        }
        // Not inherited by the agent if it's (re)started on the main thread meanwhile;
        // the spawn below still gets them through its dup2 actions.
        for fd in outFds + inFds where fd >= 0 { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        let stdinRead = inFds[0]
        var stdinWrite = inFds[1]
        defer { if stdinWrite >= 0 { close(stdinWrite) } }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if stdinRead >= 0 {
            posix_spawn_file_actions_adddup2(&actions, stdinRead, 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
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
        if stdinRead >= 0 { close(stdinRead) }
        guard spawnError == 0 else {
            close(readEnd)
            appLog("\(label) failed to start: errno \(spawnError)")
            return nil
        }
        defer { close(readEnd) }
        _ = fcntl(readEnd, F_SETFL, fcntl(readEnd, F_GETFL) | O_NONBLOCK)

        if let input, stdinWrite >= 0 {
            // Small (well under the pipe buffer), so this doesn't block. No SIGPIPE if the
            // child has already exited: the write just fails.
            _ = fcntl(stdinWrite, F_SETNOSIGPIPE, 1)
            _ = input.withUnsafeBytes { write(stdinWrite, $0.baseAddress, $0.count) }
        }

        let deadline = Date().addingTimeInterval(timeout)
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
        func killGroup() {
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        }
        var status: Int32 = 0
        /// `waitpid`, retried on EINTR; returns its result.
        func reap(_ options: Int32) -> pid_t {
            var result: pid_t
            repeat { result = waitpid(pid, &status, options) } while result == -1 && errno == EINTR
            return result
        }
        while true {
            if eof {
                usleep(50_000)
            } else {
                var pfd = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
                _ = poll(&pfd, 1, 100)
                drain()
            }
            if until(output) {
                // EOF on stdin first, so it can finish writing its own files and exit;
                // then clean up whatever is left of the group.
                if stdinWrite >= 0 {
                    close(stdinWrite)
                    stdinWrite = -1
                }
                let graceEnd = Date().addingTimeInterval(graceTime)
                var exited = false
                while Date() < graceEnd {
                    if reap(WNOHANG) == pid { exited = true; break }
                    usleep(50_000)
                }
                killGroup()
                if !exited { _ = reap(0) }
                return Result(output: output, status: nil)
            }
            if reap(WNOHANG) == pid {
                drain()  // everything it wrote before exiting
                return Result(output: output, status: status)
            }
            if Date() > deadline {
                appLog("\(label) timed out")
                killGroup()
                _ = reap(0)
                return nil
            }
        }
    }
}
