import AppKit

/// Expanded content: header + content host (DESIGN §7.7, §7.9). It keeps its size
/// during animations and live resizes, so the terminal inside is resized only when
/// PanelController sets a new frame (during, coalesced, and at the end of a user resize,
/// DESIGN §7.13).
final class ExpandedView: NSView {
    static let defaultSize = NSSize(width: 760, height: 480)
    static let minSize = NSSize(width: 480, height: 300)
    static let headerHeight: CGFloat = 28
    static let contentInset: CGFloat = 8

    let header: HeaderView
    let contentHost: NSView

    init(title: String, size: NSSize) {
        header = HeaderView(frame: NSRect(x: 0, y: size.height - Self.headerHeight,
                                          width: size.width, height: Self.headerHeight),
                            title: title)
        contentHost = NSView(frame: NSRect(x: Self.contentInset, y: Self.contentInset,
                                           width: size.width - 2 * Self.contentInset,
                                           height: size.height - Self.headerHeight - Self.contentInset))
        super.init(frame: NSRect(origin: .zero, size: size))

        // Children follow the view's own frame when PanelController resizes it.
        header.autoresizingMask = [.width, .minYMargin]
        contentHost.autoresizingMask = [.width, .height]
        contentHost.wantsLayer = true
        contentHost.layer?.cornerRadius = 10
        contentHost.layer?.masksToBounds = true
        addSubview(header)
        addSubview(contentHost)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// Drag area with a centered title. Clicking outside the panel collapses it (DESIGN §6.3).
final class HeaderView: NSView {
    weak var controller: PanelController?

    private var drag = WindowDrag()
    private let label = NSTextField(labelWithString: "")

    init(frame: NSRect, title: String) {
        super.init(frame: frame)

        label.stringValue = title
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setTitle(_ title: String) {
        label.stringValue = title
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The whole header, including the title, drags.
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
        if drag.end() {
            controller?.headerDragEnded()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.showContextMenu(event: event, in: self)
    }
}
