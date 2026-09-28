import AppKit

/// Fixed-size expanded content: header + content host (DESIGN §7.7, §7.9).
/// Its size never changes, so the terminal inside is never resized by animation.
final class ExpandedView: NSView {
    static let size = NSSize(width: 760, height: 480)
    static let headerHeight: CGFloat = 28
    static let contentInset: CGFloat = 8

    let header: HeaderView
    let contentHost: NSView

    init(title: String) {
        let size = Self.size
        header = HeaderView(frame: NSRect(x: 0, y: size.height - Self.headerHeight,
                                          width: size.width, height: Self.headerHeight),
                            title: title)
        contentHost = NSView(frame: NSRect(x: Self.contentInset, y: Self.contentInset,
                                           width: size.width - 2 * Self.contentInset,
                                           height: size.height - Self.headerHeight - Self.contentInset))
        super.init(frame: NSRect(origin: .zero, size: size))

        contentHost.wantsLayer = true
        contentHost.layer?.cornerRadius = 10
        contentHost.layer?.masksToBounds = true
        addSubview(header)
        addSubview(contentHost)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// Drag area with a centered title and a trailing collapse button.
final class HeaderView: NSView {
    weak var controller: PanelController? {
        didSet { collapseButton.target = controller }
    }

    private let collapseButton = FirstMouseButton()
    private var drag = WindowDrag()

    init(frame: NSRect, title: String) {
        super.init(frame: frame)

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        let buttonSize: CGFloat = 20
        collapseButton.frame = NSRect(x: frame.width - 8 - buttonSize, y: (frame.height - buttonSize) / 2,
                                      width: buttonSize, height: buttonSize)
        collapseButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Collapse")
        collapseButton.imagePosition = .imageOnly
        collapseButton.isBordered = false
        collapseButton.contentTintColor = .secondaryLabelColor
        collapseButton.action = #selector(PanelController.collapse)
        addSubview(collapseButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The button gets its own clicks; everything else (including the title) drags.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        if let hit = super.hitTest(point), hit === collapseButton { return hit }
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
        if drag.end() {
            controller?.headerDragEnded()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.showContextMenu(event: event, in: self)
    }
}

/// Button that acts on the first click even when the panel isn't key.
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
