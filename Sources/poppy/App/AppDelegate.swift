import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config = Config()
    private var session: TerminalSession?
    private var controller: PanelController?
    private var hotKeys: HotKeyManager?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appLog("Poppy started (pid \(ProcessInfo.processInfo.processIdentifier))")
        config = Config.load()
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
            let image = HarnessLogo.poppy(points: 18)
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
