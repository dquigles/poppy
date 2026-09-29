import AppKit

/// Collapsed content: the harness logo. Click expands, drag moves (DESIGN §7.8, §7.11).
final class PillView: NSView {
    weak var controller: PanelController?

    private var drag = WindowDrag()
    private let logo = NSImageView()

    static let logoSize: CGFloat = 24

    /// `title` names the CLI (DESIGN §7.11); it labels the pill when the harness isn't recognized.
    init(frame: NSRect, harness: Harness, title: String) {
        super.init(frame: frame)

        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.contentTintColor = .labelColor  // black in light mode, white in dark
        logo.translatesAutoresizingMaskIntoConstraints = false
        addSubview(logo)
        NSLayoutConstraint.activate([
            logo.centerXAnchor.constraint(equalTo: centerXAnchor),
            logo.centerYAnchor.constraint(equalTo: centerYAnchor),
            logo.widthAnchor.constraint(equalToConstant: Self.logoSize),
            logo.heightAnchor.constraint(equalToConstant: Self.logoSize),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        update(harness: harness, title: title)
    }

    /// Shows `harness`'s logo; also called when the agent is switched (DESIGN §9.5).
    func update(harness: Harness, title: String) {
        logo.image = HarnessLogo.image(for: harness, points: Self.logoSize)
        let label = harness == .other ? title : harness.displayName
        toolTip = label
        setAccessibilityLabel(label)
    }

    override func accessibilityPerformPress() -> Bool {
        guard let controller, !controller.isAnimating else { return false }
        controller.expand()
        return true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The whole pill handles the mouse; the logo never swallows clicks.
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
