import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config = Config()
    private var session: TerminalSession?
    private var controller: PanelController?
    private var hotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appLog("Poppy started (pid \(ProcessInfo.processInfo.processIdentifier))")
        config = Config.load()
        appLog("config: command=\(config.command) cwd=\(config.cwd) hotkey=\(config.hotkey)")
        let session = TerminalSession(config: config)
        self.session = session
        controller = PanelController(config: config, session: session)
        hotKey = GlobalHotKey(spec: config.hotkey) { [weak self] in
            self?.controller?.hotkeyPressed()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        appLog("Poppy terminating")
        session?.terminateChild()
    }
}
