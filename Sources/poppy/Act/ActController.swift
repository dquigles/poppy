import AppKit

/// Act on Selection (DESIGN §9.14): the hotkey reads the front app's selection (or, with
/// nothing selected, a region screenshot) and its window's controls, then starts a Claude
/// Code session on it in the most recent pill, without opening the panel: the pill's status
/// colors show its progress. The session acts in the app through `poppy-act`, which hands
/// the actions back here (`handle`).
final class ActController {
    private weak var manager: PillManager?
    /// Captures by id, oldest first; the sessions' `poppy-act` refers to them.
    private var captures: [(id: String, capture: ActCapture)] = []
    static let maxCaptures = 20
    /// The hotkey's capture is still being read (or the screenshot taken).
    private var isCapturing = false

    /// Closes finished sessions 5 minutes after they're done, when that's the setting.
    private var cleanupTimer: Timer?

    init(manager: PillManager) {
        self.manager = manager
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let manager = self?.manager, manager.config.actCleanup == .timer else { return }
                manager.closeFinishedActSessions(age: ActCleanup.delay)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        cleanupTimer = timer
    }

    isolated deinit {
        cleanupTimer?.invalidate()
    }

    func hotkeyPressed() {
        guard !isCapturing else { return }
        guard SelectionCapture.isTrusted(prompt: true) else {
            appLog("act: no Accessibility permission")  // macOS shows its own prompt the first time
            return
        }
        guard let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current else {
            appLog("act: \(AppVariant.name) is in front, nothing to act on")
            return
        }
        isCapturing = true
        let pid = front.processIdentifier
        let name = front.localizedName ?? "the app"
        let anchor = Self.accessibilityPoint(NSEvent.mouseLocation)
        appLog("act: started in \(name)")
        Task {
            var capture = await Task.detached { SelectionCapture.capture(pid: pid, appName: name, anchor: anchor) }.value
            appLog("act: \(capture.controls.count) controls, selection \(capture.selection.count) characters")
            if capture.selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let image = await screenshot() else {
                    isCapturing = false
                    return
                }
                capture.imagePath = image
            }
            isCapturing = false
            startSession(capture)
        }
    }

    /// Nothing selected: a region screenshot instead (`screencapture -i`, the ⌘⇧4 crosshair).
    private func screenshot() async -> String? {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            appLog("act: nothing selected and no Screen Recording permission")  // macOS asks the first time
            return nil
        }
        guard Attachments.prepareDirectory() else { return nil }
        let path = Attachments.newImageURL(prefix: "act").path
        let taken = await Task.detached { Self.takeScreenshot(to: path) }.value
        if !taken { appLog("act: screenshot cancelled") }
        return taken ? path : nil
    }

    private nonisolated static func takeScreenshot(to path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", "-o", path]
        do {
            try process.run()
        } catch {
            appLog("act: screencapture failed to start: \(error)")
            return false
        }
        process.waitUntilExit()
        return FileManager.default.fileExists(atPath: path)
    }

    /// A Claude Code session on `capture` in the most recent pill, not shown. Its first
    /// message is in a file (it can be long), read by the shell when the session starts.
    private func startSession(_ capture: ActCapture) {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        guard let manager, let tool = Self.installTool(), Attachments.prepareDirectory() else {
            appLog("act: couldn't start the session")
            return
        }
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        captures.append((id, capture))
        if captures.count > Self.maxCaptures { captures.removeFirst() }
        let promptURL = Attachments.directory.appendingPathComponent("act-\(id).txt")
        do {
            try Data(ActPrompt.text(for: capture, id: id, tool: tool).utf8).write(to: promptURL)
        } catch {
            appLog("act: could not write the prompt: \(error)")
            return
        }
        // Poppy's status hooks go in after `claude` as usual (§9.6). `poppy-act` and reading
        // the screenshot are allowed up front, so the session never stops to ask for them.
        let command = "claude --add-dir \(Self.quote(Attachments.directory.path)) "
            + "--allowedTools \(Self.quote("Bash(\(tool):*),Read")) -- \"$(cat \(Self.quote(promptURL.path)))\""
        // Claude Code asks once whether to trust a folder, and no hook reports that question:
        // until the act folder is trusted, the panel opens on the session so it can be answered.
        let trusted = Self.isTrusted(Self.folder.path)
        manager.startActSession(command: command, directory: Self.folder.path, name: "\(capture.appName) (act)",
                                show: !trusted)
        appLog("act: session started for capture \(id)\(trusted ? "" : " (folder not trusted yet: shown)")")
    }

    /// The sessions' working folder: Poppy's own, empty, trusted once in Claude Code.
    static let folder = ConfigPaths.directory.appendingPathComponent("act")

    /// Claude Code's "trust this folder" answer for `path`, from `~/.claude.json` (only read:
    /// Claude Code rewrites that file all the time).
    static func isTrusted(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = object["projects"] as? [String: Any],
              let project = projects[path] as? [String: Any] else { return false }
        return project["hasTrustDialogAccepted"] as? Bool == true
    }

    /// `poppy-act` from a session (DESIGN §9.14): act on its capture, if that app is still in
    /// front, and answer with the result.
    func handle(_ url: URL) {
        let reply = ActRequest.replyURL(for: url)
        guard let data = try? Data(contentsOf: url),
              let request = try? JSONDecoder().decode(ActRequest.self, from: data) else {
            appLog("act: request \(url.lastPathComponent) is invalid")
            Self.write(.init(ok: false, message: "the request couldn't be read"), to: reply)
            return
        }
        guard let capture = captures.last(where: { $0.id == request.capture })?.capture else {
            Self.write(.init(ok: false, message: "unknown capture \(request.capture) (Poppy may have restarted)"),
                       to: reply)
            return
        }
        appLog("act: \(request.actions.map(\.op).joined(separator: " ")) for capture \(request.capture)")
        // Accessibility reaches the app in the background; only pasting needs it in front,
        // and the runner checks that itself.
        guard NSRunningApplication(processIdentifier: capture.pid) != nil else {
            Self.write(.init(ok: false, message: "\(capture.appName) isn't running any more"), to: reply)
            return
        }
        let plan = ActPlan(actions: request.actions)
        Task {
            let failures = await Task.detached { ActionRunner.run(plan, in: capture) }.value
            Self.write(failures.isEmpty ? .init(ok: true, message: "done")
                                        : .init(ok: false, message: failures.joined(separator: "; ")), to: reply)
        }
    }

    private static func write(_ reply: ActRequest.Reply, to url: URL) {
        do {
            try JSONEncoder().encode(reply).write(to: url, options: .atomic)
        } catch {
            appLog("act: could not write \(url.lastPathComponent): \(error)")
        }
    }

    /// `<config dir>/bin/poppy-act`: runs this app's binary as the `poppy-act` client. A
    /// script of its own, so the sessions' allowed-command rule names one plain path.
    private static func installTool() -> String? {
        guard let executable = Bundle.main.executablePath, Bundle.main.bundleURL.pathExtension == "app" else {
            appLog("act: needs the bundled app")
            return nil
        }
        let folder = ConfigPaths.directory.appendingPathComponent("bin")
        let url = folder.appendingPathComponent("poppy-act")
        let script = "#!/bin/sh\n# Written by \(AppVariant.name) for Act on Selection sessions.\n"
            + "exec \(quote(executable)) \(ActClient.flag) \"$@\"\n"
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if (try? String(contentsOf: url, encoding: .utf8)) != script {
                try Data(script.utf8).write(to: url, options: .atomic)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url.path
        } catch {
            appLog("act: could not write \(url.path): \(error)")
            return nil
        }
    }

    private static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Accessibility uses top-left coordinates from the main screen's top edge.
    private static func accessibilityPoint(_ point: NSPoint) -> CGPoint {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: point.x, y: height - point.y)
    }

    // MARK: - Poppy Dev (DESIGN §12.2)

    /// `actCapture`: reads the front app now (selection and controls, no screenshot).
    /// `actStart`: starts a session on the last capture, with `command` as the selection.
    /// `actRun`: runs `command` (an ActPlan's JSON) on the last capture.
    func debugRun(_ command: DebugHook.Command) -> String? {
        switch command.op {
        case "actCapture":
            guard SelectionCapture.isTrusted(prompt: false) else { return "no Accessibility permission" }
            guard let front = NSWorkspace.shared.frontmostApplication else { return "no front app" }
            let capture = SelectionCapture.capture(pid: front.processIdentifier, appName: front.localizedName ?? "",
                                                   anchor: Self.accessibilityPoint(NSEvent.mouseLocation))
            captures.append(("debug", capture))
            if captures.count > Self.maxCaptures { captures.removeFirst() }
            return nil
        case "actStart":
            guard var capture = captures.last?.capture else { return "no capture" }
            if let selection = command.command { capture.selection = selection }
            startSession(capture)
            return nil
        case "actRun":
            guard let capture = captures.last?.capture else { return "no capture" }
            guard let data = command.command?.data(using: .utf8),
                  let plan = try? JSONDecoder().decode(ActPlan.self, from: data) else { return "invalid plan" }
            let failures = ActionRunner.run(plan, in: capture)
            return failures.isEmpty ? nil : failures.joined(separator: "; ")
        default:
            return "unknown op \(command.op)"
        }
    }

    func debugState() -> [String: Any] {
        guard let last = captures.last else { return [:] }
        let capture = last.capture
        return ["act": [
            "id": last.id, "app": capture.appName, "window": capture.windowTitle, "selection": capture.selection,
            "controls": capture.controls.map { "\($0.id) \($0.kind) \"\($0.label)\" \($0.value)\($0.inWeb ? " web" : "")" },
        ]]
    }
}
