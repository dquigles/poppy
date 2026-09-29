import AppKit
import Carbon

/// Small glass window that records the next shortcut pressed (DESIGN §11.2).
/// It becomes key without activating Poppy, like the expanded panel. Esc (no
/// modifiers) or clicking elsewhere closes it.
final class HotKeyRecorder {
    static let size = NSSize(width: 340, height: 140)

    private let panel: GlassPanel
    private let comboLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let onRecord: (HotKeyCombo) -> HotKeyManager.RecordResult
    /// The argument is true when Poppy should refocus (Esc or a save), false when the
    /// user moved focus elsewhere.
    private let onClose: (Bool) -> Void
    private let idleHint: String
    private var keyMonitor: Any?
    private var closed = false

    init(current: HotKeyCombo?,
         onRecord: @escaping (HotKeyCombo) -> HotKeyManager.RecordResult,
         onClose: @escaping (Bool) -> Void) {
        self.onRecord = onRecord
        self.onClose = onClose
        idleHint = "Current: \(current?.displayString ?? "none") · Esc to cancel"

        let visible = PanelController.screenWithMouse().visibleFrame
        let frame = NSRect(x: (visible.midX - Self.size.width / 2).rounded(),
                           y: (visible.midY - Self.size.height / 2 + visible.height / 6).rounded(),
                           width: Self.size.width, height: Self.size.height)
        panel = GlassPanel(contentRect: frame)
        panel.allowsKey = true
        panel.setTitledChrome(true)  // rounded key-window outline (DESIGN §5)

        let glass = GlassBackgroundView(frame: NSRect(origin: .zero, size: Self.size), cornerRadius: 20)
        glass.autoresizingMask = [.width, .height]
        panel.contentView = glass

        let title = NSTextField(labelWithString: "Poppy hotkey")
        title.font = .systemFont(ofSize: 12)
        title.textColor = .secondaryLabelColor
        comboLabel.font = .systemFont(ofSize: 24, weight: .medium)
        comboLabel.textColor = .labelColor
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.alignment = .center
        hintLabel.preferredMaxLayoutWidth = Self.size.width - 40

        let stack = NSStackView(views: [title, comboLabel, hintLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: glass.contentView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: glass.contentView.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: glass.contentView.widthAnchor, constant: -40),
        ])
        showIdle()

        // Deferred: closing releases this panel, which must not happen inside its own resignKey.
        panel.onResignKey = { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.close(refocus: false) }
        }
    }

    func show() {
        if keyMonitor == nil {
            // A local monitor sees keys before key equivalents (GlassPanel's ⌘C/V/A routing)
            // and before the responder chain, and can swallow them. The handler isn't
            // @Sendable, so it inherits main-actor isolation (it's called on the main thread).
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                self?.handle(event) ?? event
            }
        }
        panel.makeKeyAndOrderFront(nil)
        panel.refreshShadow()
        // If it never became key, no key or click could close it, and the hotkey would
        // stay suspended; close instead of leaving it stuck (DESIGN §11.2).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !closed, !panel.isKeyWindow else { return }
            appLog("hotkey recorder did not become key; closing")
            close(refocus: false)
        }
    }

    func close(refocus: Bool) {
        guard !closed else { return }
        closed = true
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel.onResignKey = nil
        panel.allowsKey = false
        panel.orderOut(nil)
        onClose(refocus)
    }

    private func showIdle() {
        comboLabel.stringValue = "Press a shortcut"
        showHint(idleHint, error: false)
    }

    private func showHint(_ text: String, error: Bool) {
        hintLabel.stringValue = text
        hintLabel.textColor = error ? .systemRed : .secondaryLabelColor
    }

    /// Returns nil to swallow the event.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.window === panel else { return event }
        let modifiers = HotKeyCombo.carbonModifiers(event.modifierFlags)

        if event.type == .flagsChanged {
            let symbols = HotKeyCombo.modifierSymbols(modifiers)
            comboLabel.stringValue = symbols.isEmpty ? "Press a shortcut" : symbols + "…"
            return event
        }

        guard !event.isARepeat else { return nil }
        let keyCode = Int(event.keyCode)
        if keyCode == kVK_Escape && modifiers == 0 {
            close(refocus: true)
            return nil
        }
        switch HotKeyCombo.check(keyCode: keyCode, modifiers: modifiers) {
        case .unsupportedKey:
            comboLabel.stringValue = "Press a shortcut"
            showHint("That key can't be used. Esc to cancel", error: true)
            return nil
        case .needsModifier:
            comboLabel.stringValue = "Press a shortcut"
            showHint("Add ⌃, ⌥ or ⌘ (F-keys work alone). Esc to cancel", error: true)
            return nil
        case nil:
            break
        }

        let combo = HotKeyCombo(keyCode: UInt32(keyCode), modifiers: modifiers)
        comboLabel.stringValue = combo.displayString
        switch onRecord(combo) {
        case .saved:
            close(refocus: true)
        case .notSaved:
            showHint("Active now, but config.json couldn't be updated, so it resets on relaunch. Esc to close",
                     error: true)
        case .failed(let message):
            showHint(message, error: true)
        }
        return nil
    }
}
