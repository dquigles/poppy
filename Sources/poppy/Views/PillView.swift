import AppKit

/// Collapsed content: icon + title. Click expands, drag moves (DESIGN §7.8, §7.11).
final class PillView: NSView {
    weak var controller: PanelController?

    private var drag = WindowDrag()

    init(frame: NSRect, title: String) {
        super.init(frame: frame)

        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let icon = NSImageView(image: NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage())
        icon.contentTintColor = .labelColor

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The whole pill handles the mouse; the icon and label never swallow clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        drag.cancel()
        guard let controller, !controller.isAnimating, let window else { return }
        drag.begin(window: window)
    }

    override func mouseDragged(with event: NSEvent) {
        // An animation started mid-drag (e.g. the hotkey) owns the frame now.
        guard let controller, !controller.isAnimating, let window else {
            drag.cancel()
            return
        }
        drag.moved(window: window)
    }

    override func mouseUp(with event: NSEvent) {
        guard drag.isTracking else { return }
        if drag.end() {
            controller?.pillDragEnded()
        } else {
            controller?.pillClicked()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.showContextMenu(event: event, in: self)
    }
}

/// Manual window drag with a 3pt click-vs-drag threshold, in screen coordinates.
struct WindowDrag {
    private var startMouse = NSPoint.zero
    private var startOrigin = NSPoint.zero
    private(set) var isTracking = false
    private var isDragging = false

    mutating func cancel() {
        isTracking = false
        isDragging = false
    }

    mutating func begin(window: NSWindow) {
        startMouse = NSEvent.mouseLocation
        startOrigin = window.frame.origin
        isTracking = true
        isDragging = false
    }

    mutating func moved(window: NSWindow) {
        guard isTracking else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - startMouse.x
        let dy = mouse.y - startMouse.y
        if !isDragging && hypot(dx, dy) > 3 {
            isDragging = true
        }
        if isDragging {
            window.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
        }
    }

    /// Ends tracking; returns true if the gesture was a drag (false for a click or no gesture).
    mutating func end() -> Bool {
        let wasDrag = isTracking && isDragging
        cancel()
        return wasDrag
    }
}
