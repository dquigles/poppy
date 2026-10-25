import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config = Config()
    private var manager: PillManager?
    private var hotKeys: HotKeyManager?
    private var actHotKeys: HotKeyManager?
    private var act: ActController?
    private var statusItem: NSStatusItem?
    /// Poppy Dev only: scripted tests (DESIGN §12.2).
    private var debugHook: DebugHook?
    /// Requests from the `poppy` shell command that arrived before launch finished, in
    /// order (DESIGN §9.9).
    private var pendingRequests: [LaunchRequest] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        appLog("\(AppVariant.name) started (pid \(ProcessInfo.processInfo.processIdentifier))")
        config = Config.load()
        LaunchRequest.removeStaleFiles()
        // With no saved layout, the first session starts with the requested agent in the
        // requested directory (the last request's, if several), and the request then reuses
        // it; both are saved like any change. Everything else is applied below.
        for request in pendingRequests {
            if let command = request.command {
                config.command = command
                _ = Config.saveValue(command, forKey: "command")
            }
            if let directory = request.directory.map(Config.normalize), Self.isDirectory(directory) {
                config.cwd = Config.abbreviate(directory)
                _ = Config.saveValue(config.cwd, forKey: "cwd")
            }
        }
        appLog("config: command=\(config.command) cwd=\(config.cwd) hotkey=\(config.hotkey)")
        let manager = PillManager(config: config)
        self.manager = manager
        let hotKeys = HotKeyManager(spec: config.hotkey) { [weak self] in
            self?.manager?.hotkeyPressed()
        }
        self.hotKeys = hotKeys
        manager.hotKeys = hotKeys
        let act = ActController(manager: manager)
        self.act = act
        let actHotKeys = HotKeyManager(spec: config.actHotkey, id: 2, configKey: "actHotkey", defaultSpec: "",
                                       active: config.actEnabled) { [weak act] in act?.hotkeyPressed() }
        self.actHotKeys = actHotKeys
        manager.actHotKeys = actHotKeys
        statusItem = makeStatusItem(menu: manager.statusMenu)
        manager.statusItem = statusItem
        if AppVariant.isDev { debugHook = DebugHook(manager: manager, act: act) }
        for request in pendingRequests { manager.apply(request) }
        pendingRequests = []
        // The intro (DESIGN §9.15): at the first launch, or back on its permissions page
        // after its Restart button. Shortly after launch: a frame animation started during
        // launch never finished (the pill stayed small, still animating).
        let introPage: IntroPage? = CommandLine.arguments.contains(IntroView.relaunchFlag) ? .permissions
            : config.introShown ? nil : .welcome
        if let introPage {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.manager?.showIntro(at: introPage)
            }
        }
    }

    /// The `poppy` shell command hands Poppy a request file (DESIGN §9.9). Nothing else
    /// opened with Poppy is accepted: any app could `open -a Poppy <folder>`, and silently
    /// restarting the agent in a folder it chose (whose project config the agent loads)
    /// isn't safe. Arrives whether Poppy was already running or is being launched by it
    /// (then before `applicationDidFinishLaunching`).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            // `poppy-act` from an Act on Selection session (DESIGN §9.14).
            if ActRequest.isRequestFile(url) {
                act?.handle(url)
                continue
            }
            guard LaunchRequest.isRequestFile(url) else {
                appLog("open request ignored (not a poppy command request): \(url.path)")
                continue
            }
            if let request = LaunchRequest.consume(url) { received(request) }
        }
    }

    private func received(_ request: LaunchRequest) {
        appLog("open request: \(request.directory ?? "-")\(request.command.map { ", agent \($0)" } ?? "")")
        if let manager {
            manager.apply(request)
        } else {
            pendingRequests.append(request)
        }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Confirm before quitting (DESIGN §4): Poppy's own Quit asks while agents are busy.
    /// Logout, restart and shutdown (a quit Apple event with a reason) never wait.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let manager, manager.config.confirmQuit, manager.busySessionCount > 0 else { return .terminateNow }
        if NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: kAEQuitReason) != nil {
            return .terminateNow
        }
        let count = manager.busySessionCount
        DispatchQueue.main.async { [weak self] in self?.askBeforeQuitting(count) }
        return .terminateLater
    }

    /// A standalone alert above the panels; Poppy is active only while it shows, as for
    /// the folder picker (DESIGN §9.8), and gives activation back if the quit is cancelled.
    private func askBeforeQuitting(_ count: Int) {
        let previous = NSWorkspace.shared.frontmostApplication
        let alert = NSAlert()
        alert.messageText = "Quit \(AppVariant.name)?"
        alert.informativeText = count == 1 ? "1 agent is still working." : "\(count) agents are still working."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.window.level = .statusBar + 1
        alert.window.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])
        appLog("quit: asking (\(count) busy)")
        NSApp.activate()
        let quit = alert.runModal() == .alertFirstButtonReturn
        appLog(quit ? "quit: confirmed" : "quit: cancelled")
        if !quit, let previous, previous != NSRunningApplication.current {
            NSApp.yieldActivation(to: previous)
            previous.activate()
        }
        NSApp.reply(toApplicationShouldTerminate: quit)
    }

    func applicationWillTerminate(_ notification: Notification) {
        appLog("Poppy terminating")
        manager?.terminateAll()
    }

    /// Menu bar icon that opens Poppy's menu (DESIGN §7.12).
    /// The icon is Poppy's own logo (whatever the harness), as a template so it follows the menu bar.
    private func makeStatusItem(menu: NSMenu) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = HarnessLogo.menuBar(points: 18)
            button.image = image
            if image.size == .zero {
                button.title = "P"  // never leave an invisible, unclickable item
                appLog("status item: logo missing, using text")
            }
            button.toolTip = AppVariant.name
        }
        item.menu = menu
        appLog("status item created")
        return item
    }
}
