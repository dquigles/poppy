import AppKit
import Carbon

/// System-wide hotkey via Carbon RegisterEventHotKey: works while any app is
/// frontmost and needs no Accessibility permission (DESIGN §11).
/// Kept alive by AppDelegate for the app's lifetime.
final class GlobalHotKey {
    nonisolated static let signature: OSType = 0x506F_7079  // 'Popy'
    nonisolated static let hotKeyID: UInt32 = 1

    private let action: @MainActor () -> Void
    private var handlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?

    /// Parses `spec` (falling back to the default), installs the handler and registers
    /// the hotkey. Returns nil if either Carbon call fails.
    init?(spec: String, action: @escaping @MainActor () -> Void) {
        self.action = action

        var used = spec
        var parsed = Self.parse(spec)
        if parsed == nil {
            appLog("invalid hotkey \"\(spec)\", using \(Config.defaultHotkey)")
            used = Config.defaultHotkey
            parsed = Self.parse(used)
        }
        guard let (keyCode, modifiers) = parsed else { return nil }

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &eventSpec,
                                                Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        appLog("hotkey handler installed: OSStatus \(installStatus)")
        guard installStatus == noErr else { return nil }

        let id = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        let registerStatus = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        appLog("hotkey \(used) registered: OSStatus \(registerStatus)")
        guard registerStatus == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    fileprivate func fire() {
        action()
    }

    // MARK: - Parsing

    private nonisolated static let modifierTokens: [String: Int] = [
        "ctrl": controlKey, "control": controlKey,
        "opt": optionKey, "option": optionKey, "alt": optionKey,
        "cmd": cmdKey, "command": cmdKey,
        "shift": shiftKey,
    ]

    private nonisolated static let functionKeys: [String: Int] = [
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
        "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
    ]

    /// US-layout key codes for a–z, 0–9 and space.
    private nonisolated static let keyTokens: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
        "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
        "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "space": kVK_Space,
    ]

    /// "ctrl+opt+space" -> (kVK_Space, controlKey|optionKey). Exactly one key token;
    /// at least one modifier unless the key is F1–F12.
    nonisolated static func parse(_ spec: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        var modifiers: UInt32 = 0
        var key: (code: Int, isFunctionKey: Bool)?
        for token in spec.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if let modifier = modifierTokens[token] {
                modifiers |= UInt32(modifier)
            } else if let code = functionKeys[token] {
                guard key == nil else { return nil }
                key = (code, true)
            } else if let code = keyTokens[token] {
                guard key == nil else { return nil }
                key = (code, false)
            } else {
                return nil
            }
        }
        guard let key, modifiers != 0 || key.isFunctionKey else { return nil }
        return (UInt32(key.code), modifiers)
    }
}

/// Carbon event handler. Carbon delivers hotkey events on the main thread.
private nonisolated func hotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?,
                                       _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr, id.signature == GlobalHotKey.signature, id.id == GlobalHotKey.hotKeyID else {
        return OSStatus(eventNotHandledErr)
    }
    // Unwrap outside the closure: the raw pointer isn't Sendable, the main-actor object is.
    let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { hotKey.fire() }
    return noErr
}
