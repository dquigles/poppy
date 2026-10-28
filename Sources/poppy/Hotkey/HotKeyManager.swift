import AppKit
import Carbon

/// Owns a global hotkey and its current combo; the settings page's shortcut field
/// records a new one through it (DESIGN §11, §11.2). Owned by AppDelegate: one for the
/// panel hotkey, one for Act on Selection (§9.14), one for Send Selection (§9.17), each saved
/// under its own config key.
final class HotKeyManager {
    enum RecordResult {
        case saved
        /// Registered and active, but config.json couldn't be updated.
        case notSaved
        case failed(String)
    }

    private let hotKey: GlobalHotKey?
    /// config.json's key for the combo ("hotkey", "actHotkey" or "sendHotkey").
    private let configKey: String
    /// The combo the user chose. Registered whenever no recording is in progress
    /// (unless registration failed at launch).
    private(set) var current: HotKeyCombo?
    /// True while the shortcut field is recording (auto-open waits, DESIGN §7.15).
    private(set) var isRecording = false
    /// Off (Act on Selection turned off, DESIGN §9.14), the combo is kept but not registered.
    private(set) var isActive: Bool
    /// Called after every recording ends, so the settings page shows the current combo.
    var onComboChanged: (() -> Void)?

    init(spec: String, id: UInt32 = 1, configKey: String = "hotkey", defaultSpec: String = Config.defaultHotkey,
         active: Bool = true, action: @escaping @MainActor () -> Void) {
        hotKey = GlobalHotKey(id: id, action: action)
        self.configKey = configKey
        isActive = active
        // An empty spec means no hotkey (Poppy Dev's default, DESIGN §12.1); one can still be recorded.
        guard !spec.trimmingCharacters(in: .whitespaces).isEmpty else {
            appLog("no \(configKey) set")
            return
        }
        var combo = HotKeyCombo(spec: spec)
        if combo == nil {
            appLog("invalid \(configKey) \"\(spec)\", using \(defaultSpec.isEmpty ? "none" : defaultSpec)")
            combo = HotKeyCombo(spec: defaultSpec)
        }
        if !active {
            current = combo
            appLog("\(configKey) not registered (turned off)")
        } else if let hotKey, let combo, hotKey.register(combo) == noErr {
            current = combo
        }
    }

    /// Registers the combo (on) or only keeps it (off).
    func setActive(_ on: Bool) {
        guard on != isActive else { return }
        isActive = on
        guard let hotKey, !isRecording else { return }
        if !on {
            hotKey.unregister()
        } else if let current, hotKey.register(current) != noErr {
            self.current = nil  // don't show a hotkey that doesn't work
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
        if Config.saveValue(combo.spec, forKey: configKey) {
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
        if isActive, let hotKey, let current, hotKey.registered != current,
           hotKey.register(current) != noErr {
            self.current = nil  // don't show a hotkey that doesn't work
        }
        onComboChanged?()
    }
}
