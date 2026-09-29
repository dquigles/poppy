import AppKit
@preconcurrency import SwiftTerm

/// Owns the terminal view and its child process for the app's lifetime (DESIGN §9).
final class TerminalSession {
    private var config: Config
    private var spec: LaunchSpec
    private weak var host: NSView?
    private var currentView: PoppyTerminalView?

    /// True after the child exits; the next Enter restarts it.
    private(set) var exited = false

    /// Called after `restart()` swaps in a new view, so focus can follow it.
    var onViewReplaced: (() -> Void)?

    var focusView: NSView? { currentView }

    init(config: Config) {
        self.config = config
        spec = ShellEnvironment.launchSpec(for: config)
        logSpec()
    }

    private func logSpec() {
        appLog("agent: \(spec.executable) \(spec.args.joined(separator: " ")) in \(spec.currentDirectory)")
    }

    /// Ends the current agent and starts `command` in a fresh terminal (DESIGN §9.5).
    /// No conversation is carried over.
    func switchCommand(to command: String) {
        config.command = command
        spec = ShellEnvironment.launchSpec(for: config)
        logSpec()
        restart()
    }

    /// Adds the terminal to `host` (which has a fixed size) and starts the agent.
    func attach(to host: NSView) {
        self.host = host
        startNewView()
    }

    func restart() {
        appLog("restarting agent")
        terminateChild(reap: true)
        currentView?.removeFromSuperview()
        currentView = nil
        startNewView()
        onViewReplaced?()
    }

    /// SIGHUP the shell's process group, else the shell itself. With `-i` the agent may be
    /// in its own job group; it still gets SIGHUP when the shell (the pty's session leader) exits.
    func terminateChild(reap: Bool = false) {
        guard let process = currentView?.process, process.running else { return }
        let pid = process.shellPid
        guard pid > 0 else { return }
        if kill(-pid, SIGHUP) == -1 {
            kill(pid, SIGHUP)
        }
        if reap {
            // The old view is discarded without waiting. Reap off the main thread so the child
            // can't linger as a zombie; if it ignores SIGHUP for 1s, SIGKILL it.
            // waitpid returns -1 (ECHILD) if SwiftTerm already reaped it.
            DispatchQueue.global().async {
                var status: Int32 = 0
                for _ in 0..<20 {
                    if waitpid(pid, &status, WNOHANG) != 0 { return }
                    usleep(50_000)
                }
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
                _ = waitpid(pid, &status, 0)
            }
        }
    }

    private func startNewView() {
        guard let host else {
            appLog("terminal host is gone; not starting agent")
            return
        }
        let view = PoppyTerminalView(frame: host.bounds)
        view.autoresizingMask = [.width, .height]
        view.session = self
        view.processDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.nativeForegroundColor = NSColor(white: 0.92, alpha: 1)
        view.nativeBackgroundColor = NSColor(white: 0.05, alpha: 1)
        view.backgroundOpacity = 0.80
        // SwiftTerm's scroller is private; hide its view (trackpad scrollback still works).
        // With it hidden SwiftTerm reserves no width, and setFrameSize re-fits the columns
        // before the process starts.
        for case let scroller as NSScroller in view.subviews {
            scroller.isHidden = true
        }
        view.setFrameSize(host.bounds.size)
        host.addSubview(view)
        currentView = view
        exited = false
        view.startProcess(executable: spec.executable, args: spec.args, environment: spec.environment,
                          execName: nil, currentDirectory: spec.currentDirectory)
        appLog("agent started (pid \(view.process.shellPid))")
    }
}

extension TerminalSession: @preconcurrency LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        guard source === currentView else { return }
        appLog("terminal size \(newCols)x\(newRows)")
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard source === currentView, let view = currentView else { return }
        exited = true
        let desc = Self.describe(waitStatus: exitCode)
        appLog("agent exited (\(desc))")
        view.feed(text: "\r\n[Poppy] process exited (\(desc)). Press Enter to restart.\r\n")
    }

    /// SwiftTerm passes the raw waitpid status; decode it like WIFEXITED/WEXITSTATUS/WTERMSIG.
    private static func describe(waitStatus status: Int32?) -> String {
        guard let status else { return "signal" }
        let signal = status & 0x7f
        return signal == 0 ? "code \((status >> 8) & 0xff)" : "signal \(signal)"
    }
}

/// Terminal view that swallows input after the agent exits and restarts on Enter.
final class PoppyTerminalView: LocalProcessTerminalView {
    weak var session: TerminalSession?

    /// macOS line-editing shortcuts, as Ghostty maps them by default. SwiftTerm sends
    /// Command keys through interpretKeyEvents, which turns these into text-editing
    /// commands it ignores, so translate them to the control bytes shells and TUIs expect.
    /// (keyDown isn't overridable; Command keys reach performKeyEquivalent first.)
    private static let commandKeyBytes: [UInt16: UInt8] = [
        51: 0x15,   // ⌘⌫  -> ^U  delete to start of line
        123: 0x01,  // ⌘←  -> ^A  start of line
        124: 0x05,  // ⌘→  -> ^E  end of line
    ]

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if event.type == .keyDown, flags == [.command], window?.firstResponder === self,
           let byte = Self.commandKeyBytes[event.keyCode] {
            send(source: self, data: [byte][...])
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if let session, session.exited {
            if data.contains(13) {
                // Deferred: restart() removes this view, which is still on the stack in keyDown.
                // Re-check when it runs so a second Enter can't kill the fresh agent.
                DispatchQueue.main.async { [weak session, weak self] in
                    guard let session, let self, session.exited, session.focusView === self else { return }
                    session.restart()
                }
            }
            return
        }
        super.send(source: source, data: data)
    }
}
