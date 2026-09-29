import AppKit
import Carbon

/// Owns the global hotkey, the current combo, and the "Set Hotkey" recorder
/// (DESIGN §11, §11.2). Owned by AppDelegate.
final class HotKeyManager {
    enum RecordResult {
        case saved
        /// Registered and active, but config.json couldn't be updated.
        case notSaved
        case failed(String)
    }

    private let hotKey: GlobalHotKey?
    /// The combo the user chose. Registered whenever the recorder isn't open
    /// (unless registration failed at launch).
    private(set) var current: HotKeyCombo?
    private var recorder: HotKeyRecorder?
    /// True while the "Set Hotkey" window is open (auto-open waits, DESIGN §7.15).
    var isRecording: Bool { recorder != nil }
    /// Called after the recorder closes via Esc or a save (not when the user clicked
    /// elsewhere); PanelController refocuses the terminal if expanded.
    var onRecorderClosed: (() -> Void)?

    init(spec: String, action: @escaping @MainActor () -> Void) {
        hotKey = GlobalHotKey(action: action)
        var combo = HotKeyCombo(spec: spec)
        if combo == nil {
            appLog("invalid hotkey \"\(spec)\", using \(Config.defaultHotkey)")
            combo = HotKeyCombo(spec: Config.defaultHotkey)
        }
        if let hotKey, let combo, hotKey.register(combo) == noErr {
            current = combo
        }
    }

    /// False only if the Carbon event handler couldn't be installed.
    var canRecord: Bool { hotKey != nil }

    /// Opens the recorder (or brings it forward). The current hotkey is suspended
    /// while it's open so pressing it can be recorded instead of toggling the panel.
    func beginRecording() {
        guard let hotKey else { return }
        if let recorder {
            recorder.show()
            return
        }
        hotKey.unregister()
        let recorder = HotKeyRecorder(
            current: current,
            onRecord: { [weak self] combo in self?.record(combo) ?? .failed("Hotkeys are unavailable.") },
            onClose: { [weak self] refocus in self?.recorderClosed(refocus: refocus) })
        self.recorder = recorder
        recorder.show()
    }

    private func record(_ combo: HotKeyCombo) -> RecordResult {
        guard let hotKey else { return .failed("Hotkeys are unavailable.") }
        let status = hotKey.register(combo)
        guard status == noErr else {
            return .failed("\(combo.displayString) couldn't be registered (OSStatus \(status)). Try another.")
        }
        current = combo
        if Config.saveHotkey(combo.spec) { return .saved }
        // The recorder stays open to show the error; keep the hotkey suspended until it
        // closes (recorderClosed registers `current`).
        hotKey.unregister()
        return .notSaved
    }

    /// Restores the current combo if the recorder closed without registering it
    /// (cancelled, or the last attempt failed).
    private func recorderClosed(refocus: Bool) {
        recorder = nil
        if let hotKey, let current, hotKey.registered != current,
           hotKey.register(current) != noErr {
            self.current = nil  // don't show a hotkey in the menu that doesn't work
        }
        if refocus { onRecorderClosed?() }
    }
}
