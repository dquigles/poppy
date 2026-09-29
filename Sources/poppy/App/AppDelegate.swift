import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config = Config()
    private var session: TerminalSession?
    private var controller: PanelController?
    private var hotKeys: HotKeyManager?
    private var statusItem: NSStatusItem?
    /// Requests from the `poppy` shell command that arrived before launch finished, in
    /// order (DESIGN §9.9).
    private var pendingRequests: [LaunchRequest] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        appLog("Poppy started (pid \(ProcessInfo.processInfo.processIdentifier))")
        config = Config.load()
        LaunchRequest.removeStaleFiles()
        // Start the requested agent in the requested directory (the last request's, if
        // several), instead of starting and restarting; both are saved like any change.
        // Everything else is applied below.
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
        let session = TerminalSession(config: config)
        self.session = session
        let controller = PanelController(config: config, session: session)
        self.controller = controller
        let hotKeys = HotKeyManager(spec: config.hotkey) { [weak self] in
            self?.controller?.hotkeyPressed()
        }
        self.hotKeys = hotKeys
        controller.hotKeys = hotKeys
        statusItem = makeStatusItem(menu: controller.makeMenu())
        for request in pendingRequests { controller.apply(request) }
        pendingRequests = []
    }

    /// The `poppy` shell command hands Poppy a request file (DESIGN §9.9). Nothing else
    /// opened with Poppy is accepted: any app could `open -a Poppy <folder>`, and silently
    /// restarting the agent in a folder it chose (whose project config the agent loads)
    /// isn't safe. Arrives whether Poppy was already running or is being launched by it
    /// (then before `applicationDidFinishLaunching`).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard LaunchRequest.isRequestFile(url) else {
                appLog("open request ignored (not a poppy command request): \(url.path)")
                continue
            }
            if let request = LaunchRequest.consume(url) { received(request) }
        }
    }

    private func received(_ request: LaunchRequest) {
        appLog("open request: \(request.directory ?? "-")\(request.command.map { ", agent \($0)" } ?? "")")
        if let controller {
            controller.apply(request)
        } else {
            pendingRequests.append(request)
        }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    func applicationWillTerminate(_ notification: Notification) {
        appLog("Poppy terminating")
        session?.terminateChild()
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
            button.toolTip = "Poppy"
        }
        item.menu = menu
        appLog("status item created")
        return item
    }
}
