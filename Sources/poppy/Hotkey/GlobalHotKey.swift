import AppKit
import Carbon

/// System-wide hotkey via Carbon RegisterEventHotKey: works while any app is
/// frontmost and needs no Accessibility permission (DESIGN §11). The event handler
/// is installed once; the combo can be registered, unregistered and changed live.
/// Kept alive by HotKeyManager for the app's lifetime.
final class GlobalHotKey {
    nonisolated static let signature: OSType = 0x506F_7079  // 'Popy'
    nonisolated static let hotKeyID: UInt32 = 1

    private let action: @MainActor () -> Void
    private var handlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    /// The combo currently registered with Carbon, if any.
    private(set) var registered: HotKeyCombo?

    /// Installs the Carbon event handler. Returns nil if that fails.
    init?(action: @escaping @MainActor () -> Void) {
        self.action = action
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &eventSpec,
                                         Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        appLog("hotkey handler installed: OSStatus \(status)")
        guard status == noErr else { return nil }
    }

    /// Replaces any registered combo with `combo`. On failure nothing is registered.
    @discardableResult
    func register(_ combo: HotKeyCombo) -> OSStatus {
        unregister()
        let id = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
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
    guard status == noErr, id.signature == GlobalHotKey.signature, id.id == GlobalHotKey.hotKeyID else {
        return OSStatus(eventNotHandledErr)
    }
    // Unwrap outside the closure: the raw pointer isn't Sendable, the main-actor object is.
    let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { hotKey.fire() }
    return noErr
}
