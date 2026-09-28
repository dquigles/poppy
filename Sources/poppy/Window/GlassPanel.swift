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
        animationBehavior = .none
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

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
