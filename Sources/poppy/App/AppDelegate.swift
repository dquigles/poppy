import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        appLog("Poppy started (pid \(ProcessInfo.processInfo.processIdentifier))")
    }

    func applicationWillTerminate(_ notification: Notification) {
        appLog("Poppy terminating")
    }
}
