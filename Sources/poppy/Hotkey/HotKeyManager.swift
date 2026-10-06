import AppKit
import Carbon

/// Owns the global hotkey and the current combo; the settings page's shortcut field
/// records a new one through it (DESIGN §11, §11.2). Owned by AppDelegate.
final class HotKeyManager {
    enum RecordResult {
        case saved
        /// Registered and active, but config.json couldn't be updated.
        case notSaved
        case failed(String)
    }

    private let hotKey: GlobalHotKey?
    /// The combo the user chose. Registered whenever no recording is in progress
    /// (unless registration failed at launch).
    private(set) var current: HotKeyCombo?
    /// True while the shortcut field is recording (auto-open waits, DESIGN §7.15).
    private(set) var isRecording = false
    /// Called after every recording ends, so the settings page shows the current combo.
    var onComboChanged: (() -> Void)?

    init(spec: String, action: @escaping @MainActor () -> Void) {
        hotKey = GlobalHotKey(action: action)
        // An empty spec means no hotkey (Poppy Dev's default, DESIGN §12.1); one can still be recorded.
        guard !spec.trimmingCharacters(in: .whitespaces).isEmpty else {
            appLog("no hotkey set")
            return
        }
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

    /// Suspends the current hotkey so pressing it can be recorded instead of toggling
    /// the panel. Returns false if hotkeys are unavailable.
    func beginRecording() -> Bool {
        guard let hotKey else { return false }
        if !isRecording {
            isRecording = true
            hotKey.unregister()
        }
        return true
    }

    /// Registers and saves `combo`. On `.saved` the recording ends; otherwise it stays
    /// open so the field can show the message.
    func record(_ combo: HotKeyCombo) -> RecordResult {
        guard let hotKey else { return .failed("Hotkeys are unavailable.") }
        let status = hotKey.register(combo)
        guard status == noErr else {
            return .failed("\(combo.displayString) couldn't be registered (OSStatus \(status)). Try another.")
        }
        current = combo
        if Config.saveHotkey(combo.spec) {
            endRecording()
            return .saved
        }
        // Keep the hotkey suspended until the recording ends (endRecording registers `current`).
        hotKey.unregister()
        return .notSaved
    }

    /// Restores the current combo if it isn't registered (cancelled, or the last attempt
    /// failed).
    func endRecording() {
        guard isRecording else { return }
        isRecording = false
        if let hotKey, let current, hotKey.registered != current,
           hotKey.register(current) != noErr {
            self.current = nil  // don't show a hotkey that doesn't work
        }
        onComboChanged?()
    }
}
