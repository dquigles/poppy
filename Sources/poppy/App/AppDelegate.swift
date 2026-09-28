import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: PanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appLog("Poppy started (pid \(ProcessInfo.processInfo.processIdentifier))")
        controller = PanelController()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appLog("Poppy terminating")
    }
}
