import AppKit

/// Collapsed content: icon + title. Click expands, drag moves (DESIGN §7.8, §7.11).
final class PillView: NSView {
    weak var controller: PanelController?

    private var startMouse = NSPoint.zero
    private var startOrigin = NSPoint.zero
    private var tracking = false
    private var dragging = false

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
        tracking = false
        guard let controller, !controller.isAnimating, let window else { return }
        startMouse = NSEvent.mouseLocation
        startOrigin = window.frame.origin
        tracking = true
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard tracking, let window else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - startMouse.x
        let dy = mouse.y - startMouse.y
        if !dragging && hypot(dx, dy) > 3 {
            dragging = true
        }
        if dragging {
            window.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard tracking else { return }
        tracking = false
        if dragging {
            controller?.pillDragEnded()
        } else {
            controller?.pillClicked()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.showContextMenu(event: event, in: self)
    }
}
