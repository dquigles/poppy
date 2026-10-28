import AppKit
import Sparkle

/// Updates through Sparkle (DESIGN §12.4), only in a downloaded Poppy: release.sh adds the
/// feed and its public key to Info.plist. A build from install.sh or bundle.sh has neither
/// (and Poppy Dev never updates), so it's updated from source.
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    static var isAvailable: Bool {
        !AppVariant.isDev && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
    }

    private var controller: SPUStandardUpdaterController?
    /// A scheduled check found an update Sparkle showed in the background (Poppy never
    /// activates by itself): the menu item says so until it's handled.
    private var updateWaiting = false

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        appLog("updater: started, automatic checks \(controller?.updater.automaticallyChecksForUpdates == true ? "on" : "off")")
    }

    /// "Check for Updates…" in the Poppy menu (§7.10); "Update Available…" while one waits.
    func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: updateWaiting ? "Update Available…" : "Check for Updates…",
                              action: #selector(checkForUpdates), keyEquivalent: "")
        item.target = self
        item.isEnabled = controller?.updater.canCheckForUpdates ?? false
        return item
    }

    /// Sparkle's windows need Poppy active, as for the quit question (§4).
    @objc func checkForUpdates() {
        appLog("updater: checking")
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate

    /// Poppy is a background app (`LSUIElement`), so a scheduled check's update is shown
    /// without taking focus, and the menu item points to it.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        appLog("updater: \(update.displayVersionString) available")
        if !state.userInitiated { updateWaiting = true }
    }

    func standardUserDriverWillFinishUpdateSession() {
        updateWaiting = false
    }
}
