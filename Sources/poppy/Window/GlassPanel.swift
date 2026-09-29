import AppKit

/// Borderless, non-activating panel that floats above everything, including
/// other apps' fullscreen Spaces, without ever activating Poppy (DESIGN §5).
final class GlassPanel: NSPanel {
    /// Set by PanelController; true only in the expanded state (DESIGN §6.1).
    var allowsKey = false

    init(contentRect: NSRect) {
        // .nonactivatingPanel must be passed to init; setting it later is unreliable.
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        isMovable = false  // no system titlebar drag while titled; HeaderView drags manually
        // Only take effect while titled (see setTitledChrome); harmless while borderless.
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        animationBehavior = .none
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { allowsKey }

    /// No zoom: a double-click on the (hidden) titlebar area under the header would
    /// otherwise resize the panel (DESIGN §7.13).
    override func zoom(_ sender: Any?) {}
    override var canBecomeMain: Bool { false }

    /// While expanded the panel is a titled window with an invisible titlebar: macOS 26
    /// gives titled windows a real rounded window shape, so the key-window outline and
    /// shadow follow the glass. As a borderless key window it drew a square hairline
    /// around the bounds. The pill stays borderless: its shadow follows the capsule's
    /// alpha, and a titled window's corner radius wouldn't match the capsule.
    func setTitledChrome(_ titled: Bool) {
        guard styleMask.contains(.titled) != titled else { return }
        if titled {
            // .resizable is added via setResizable(true) once the expand animation ends (DESIGN §7.13).
            styleMask.formUnion([.titled, .fullSizeContentView])
        } else {
            styleMask.subtract([.titled, .fullSizeContentView, .resizable])
        }
        refreshShadow()
    }

    /// AppKit recreates the traffic-light buttons when a titled window's style mask changes
    /// (observed for .titled and .resizable), so hide them after every change, whatever
    /// made it (DESIGN §5).
    override var styleMask: NSWindow.StyleMask {
        didSet { hideStandardButtons() }
    }

    /// Edge/corner resizing while expanded (DESIGN §7.13).
    func setResizable(_ resizable: Bool) {
        if resizable {
            styleMask.insert(.resizable)
        } else {
            styleMask.remove(.resizable)
        }
    }

    private func hideStandardButtons() {
        for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
    }

    /// The window shadow also draws the bright rim around the glass, so its shape must
    /// track the rounded glass. Recompute now and again on the next pass, after the
    /// glass has rendered its current shape (otherwise it can come out square).
    func refreshShadow() {
        invalidateShadow()
        DispatchQueue.main.async { [weak self] in self?.invalidateShadow() }
    }

    // Key windows get a stronger shadow; recompute its shape on every key change.
    override func becomeKey() {
        super.becomeKey()
        refreshShadow()
    }

    /// Called after the panel stops being key (used by the hotkey recorder, DESIGN §11.2).
    var onResignKey: (() -> Void)?

    override func resignKey() {
        super.resignKey()
        refreshShadow()
        onResignKey?()
    }

    /// Poppy is never the active app and has no main menu, so menu key
    /// equivalents never fire. Route Cmd-C/V/A to the first responder (DESIGN §6.2).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .shift, .control, .option]) == [.command] else {
            return super.performKeyEquivalent(with: event)
        }
        let action: Selector
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": action = #selector(NSText.copy(_:))
        case "v": action = #selector(NSText.paste(_:))
        case "a": action = #selector(NSResponder.selectAll(_:))
        default: return super.performKeyEquivalent(with: event)
        }
        return NSApp.sendAction(action, to: nil, from: self)
    }
}
