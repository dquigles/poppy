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

    /// Reported by the agent's hooks through `statusFile` (DESIGN §9.6).
    private(set) var status = AgentStatus.idle
    var onStatusChange: ((AgentStatus) -> Void)?
    private var statusFile: URL?
    private var statusGeneration = 0
    private var statusTimer: Timer?
    /// Modification date of the last report acted on; a hook rewriting the same word is
    /// still a new report (e.g. "done" at the end of every turn).
    private var lastStatusDate: Date?
    static let statusPollInterval: TimeInterval = 0.25
    static let statusDirectory = ConfigPaths.directory.appendingPathComponent("run")

    var focusView: NSView? { currentView }

    init(config: Config) {
        self.config = config
        spec = Self.launchSpec(for: config)
        logSpec()
        Self.removeStaleStatusFiles()
        Attachments.removeOldFiles()
    }

    /// Pastes `text` (e.g. attachment paths) into the agent as if typed (DESIGN §9.10).
    func paste(_ text: String) {
        currentView?.pasteText(text)
    }

    /// The launch spec, with the command readied for status hooks (DESIGN §9.6).
    private static func launchSpec(for config: Config) -> LaunchSpec {
        var hooked = config
        if config.statusHooks {
            hooked.command = StatusHooks.prepare(command: config.command)
        }
        return ShellEnvironment.launchSpec(for: hooked)
    }

    private func logSpec() {
        appLog("agent: \(spec.executable) \(spec.args.joined(separator: " ")) in \(spec.currentDirectory)")
    }

    /// Ends the current agent and starts `command` in `directory`: one restart for an
    /// agent switch, a directory change, or both (DESIGN §9.5, §9.8, §9.9).
    func switchTo(command: String, directory: String) {
        config.command = command
        config.cwd = directory
        restart()  // recomputes the spec
    }

    /// Adds the terminal to `host` (which has a fixed size) and starts the agent.
    func attach(to host: NSView) {
        self.host = host
        startNewView()
    }

    func restart() {
        appLog("restarting agent")
        Attachments.removeOldFiles()
        spec = Self.launchSpec(for: config)  // re-readies the hooks (e.g. a deleted Claude hooks file)
        logSpec()
        terminateChild(reap: true)
        currentView?.removeFromSuperview()
        currentView = nil
        startNewView()
        onViewReplaced?()
    }

    /// SIGHUP the shell's process group, else the shell itself. With `-i` the agent may be
    /// in its own job group; it still gets SIGHUP when the shell (the pty's session leader) exits.
    func terminateChild(reap: Bool = false) {
        removeStatusFile()
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
        view.registerForDrops()  // files and images (DESIGN §9.10)
        host.addSubview(view)
        currentView = view
        exited = false
        // No status file or variable when status hooks are off (DESIGN §9.6).
        let statusURL = config.statusHooks ? newStatusFile() : nil
        let environment = spec.environment + (statusURL.map { ["POPPY_STATUS_FILE=\($0.path)"] } ?? [])
        view.startProcess(executable: spec.executable, args: spec.args, environment: environment,
                          execName: nil, currentDirectory: spec.currentDirectory)
        appLog("agent started (pid \(view.process.shellPid))")
    }
}

// MARK: - Status (DESIGN §9.6)

extension TerminalSession {
    /// A fresh, empty status file for a new agent start (so an old agent that's still
    /// dying can't report into it), and polling starts. Nil if it can't be created.
    fileprivate func newStatusFile() -> URL? {
        removeStatusFile()
        setStatus(.idle)  // even if the new file can't be created
        statusGeneration += 1
        let url = Self.statusDirectory.appendingPathComponent(
            "status-\(ProcessInfo.processInfo.processIdentifier)-\(statusGeneration)")
        do {
            try FileManager.default.createDirectory(at: Self.statusDirectory, withIntermediateDirectories: true)
            try Data().write(to: url)
        } catch {
            appLog("status: could not create \(url.path): \(error)")
            return nil
        }
        statusFile = url
        lastStatusDate = nil
        let timer = Timer(timeInterval: Self.statusPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollStatus() }
        }
        RunLoop.main.add(timer, forMode: .common)  // also during menus and live resize
        statusTimer = timer
        return url
    }

    fileprivate func removeStatusFile() {
        statusTimer?.invalidate()
        statusTimer = nil
        if let statusFile { try? FileManager.default.removeItem(at: statusFile) }
        statusFile = nil
    }

    /// Acts on a report only when the file changed (by modification date), so a status
    /// Poppy changed locally (markDoneSeen) isn't overwritten by an old report. The file is
    /// never truncated here, so no report can be lost between reading and clearing.
    private func pollStatus() {
        guard let statusFile,
              let date = (try? FileManager.default.attributesOfItem(atPath: statusFile.path))?[.modificationDate] as? Date,
              date != lastStatusDate,
              let data = try? Data(contentsOf: statusFile) else { return }
        let word = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let reported = AgentStatus(rawValue: word) else { return }  // empty or mid-write
        lastStatusDate = date
        setStatus(reported)
    }

    fileprivate func setStatus(_ new: AgentStatus) {
        guard new != status else { return }
        appLog("status: \(status.rawValue) -> \(new.rawValue)")
        status = new
        onStatusChange?(new)
    }

    /// The user has seen the panel: "done" goes back to idle.
    func markDoneSeen() {
        if status == .done { setStatus(.idle) }
    }

    /// Removes status files left by Poppy processes that are no longer running.
    fileprivate static func removeStaleStatusFiles() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: statusDirectory.path) else { return }
        for name in names where name.hasPrefix("status-") {
            let parts = name.split(separator: "-")
            guard parts.count == 3, let pid = pid_t(parts[1]) else { continue }
            if kill(pid, 0) != 0 && errno == ESRCH {
                try? FileManager.default.removeItem(at: statusDirectory.appendingPathComponent(name))
            }
        }
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
        // Stop polling: a report written just before exit mustn't change the status (or
        // auto-open) for a dead agent. The file stays until the next start or quit.
        statusTimer?.invalidate()
        statusTimer = nil
        setStatus(.idle)
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

    /// Pastes `text` as if typed, bracketed when the app asked for it (so an agent treats
    /// a path as one paste, e.g. Claude attaching an image, DESIGN §9.10).
    func pasteText(_ text: String) {
        let text = Attachments.sanitized(text)
        guard !text.isEmpty else { return }
        if terminal.bracketedPasteMode {
            send(data: EscapeSequences.bracketedPasteStart[0...])
            send(txt: text)
            send(data: EscapeSequences.bracketedPasteEnd[0...])
        } else {
            send(txt: text)
        }
    }

    /// ⌘V: files and images (e.g. a screenshot copied with ⌘⌃⇧4) paste as paths; text as usual.
    override func paste(_ sender: Any) {
        let pasteboard = NSPasteboard.general
        if Attachments.hasAttachment(pasteboard),
           Attachments.text(from: pasteboard, completion: { [weak self] text in self?.pasteText(text) }) {
            return
        }
        super.paste(sender)
    }

    // MARK: Drag and drop (DESIGN §9.10)

    func registerForDrops() {
        registerForDraggedTypes(Attachments.dropTypes)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Attachments.operation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { Attachments.operation(for: sender) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        Attachments.logDrag(sender, "on terminal")
        let pasteboard = sender.draggingPasteboard
        if Attachments.text(from: pasteboard, completion: { [weak self] text in self?.pasteText(text) }) {
            return true
        }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return false }
        pasteText(text)
        return true
    }

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
