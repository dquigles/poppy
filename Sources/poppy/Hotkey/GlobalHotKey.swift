import AppKit
import Carbon

/// System-wide hotkey via Carbon RegisterEventHotKey: works while any app is
/// frontmost and needs no Accessibility permission (DESIGN §11). The event handler
/// is installed once; the combo can be registered, unregistered and changed live.
/// Kept alive by its HotKeyManager for the app's lifetime.
/// Each instance has its own `id`, so several can be registered: every handler sees every
/// hotkey event and passes on the ones that aren't its own.
final class GlobalHotKey {
    nonisolated static let signature: OSType = 0x506F_7079  // 'Popy'
    /// 1: the panel hotkey, 2: Act on Selection (DESIGN §9.14), 3: Send Selection (§9.17).
    nonisolated let id: UInt32

    private let action: @MainActor () -> Void
    private var handlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    /// The combo currently registered with Carbon, if any.
    private(set) var registered: HotKeyCombo?

    /// Installs the Carbon event handler. Returns nil if that fails.
    init?(id: UInt32 = 1, action: @escaping @MainActor () -> Void) {
        self.id = id
        self.action = action
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &eventSpec,
                                         Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        appLog("hotkey handler \(id) installed: OSStatus \(status)")
        guard status == noErr else { return nil }
    }

    /// Replaces any registered combo with `combo`. On failure nothing is registered.
    @discardableResult
    func register(_ combo: HotKeyCombo) -> OSStatus {
        unregister()
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        appLog("hotkey \(combo.spec) registered: OSStatus \(status)")
        if status == noErr {
            hotKeyRef = ref
            registered = combo
        }
        return status
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        registered = nil
    }

    fileprivate func fire() {
        action()
    }
}

/// Carbon event handler. Carbon delivers hotkey events on the main thread.
private nonisolated func hotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?,
                                       _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    // Unwrap outside the closure: the raw pointer isn't Sendable, the main-actor object is.
    let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
    // Another instance's hotkey: the next handler gets it.
    guard status == noErr, id.signature == GlobalHotKey.signature, id.id == hotKey.id else {
        return OSStatus(eventNotHandledErr)
    }
    MainActor.assumeIsolated { hotKey.fire() }
    return noErr
}
