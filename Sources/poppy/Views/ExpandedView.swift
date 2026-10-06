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
    /// Usage footer (DESIGN §7.9, §9.7); hidden unless the agent has usage to show.
    let usageBar: UsageBar
    /// The settings page, in place of the terminal (DESIGN §7.9).
    let settingsView: SettingsView
    /// Bumped by every `setSettingsVisible`, so a stale fade's completion does nothing.
    private var settingsGeneration = 0

    init(title: String, size: NSSize) {
        header = HeaderView(frame: NSRect(x: 0, y: size.height - Self.headerHeight,
                                          width: size.width, height: Self.headerHeight),
                            title: title)
        contentHost = NSView(frame: NSRect(x: Self.contentInset, y: Self.contentInset,
                                           width: size.width - 2 * Self.contentInset,
                                           height: size.height - Self.headerHeight - Self.contentInset))
        usageBar = UsageBar(frame: NSRect(x: 0, y: 0, width: size.width, height: UsageBar.height))
        settingsView = SettingsView(frame: contentHost.frame)
        super.init(frame: NSRect(origin: .zero, size: size))

        // Children follow the view's own frame when PanelController resizes it.
        header.autoresizingMask = [.width, .minYMargin]
        contentHost.autoresizingMask = [.width, .height]
        contentHost.wantsLayer = true
        contentHost.layer?.cornerRadius = 10
        contentHost.layer?.masksToBounds = true
        usageBar.autoresizingMask = [.width, .maxYMargin]
        usageBar.isHidden = true
        addSubview(header)
        addSubview(contentHost)
        addSubview(usageBar)
        settingsView.autoresizingMask = [.width, .height]
        settingsView.isHidden = true
        addSubview(settingsView)  // over the terminal
    }

    /// Shows or hides the usage footer, moving the content's bottom edge (a terminal
    /// resize, so only on a harness or setting change, DESIGN §7.9).
    func setUsageVisible(_ visible: Bool) {
        guard usageBar.isHidden == visible else { return }
        usageBar.isHidden = !visible
        let bottom = visible ? UsageBar.height : Self.contentInset
        var frame = contentHost.frame
        frame.size.height = frame.maxY - bottom
        frame.origin.y = bottom
        contentHost.frame = frame
        settingsView.frame = frame
    }

    /// Shows the settings page over the terminal (and "Settings" in the header), or the
    /// terminal again (DESIGN §7.9). The
    /// view that ends up shown is unhidden first, so it can take the keyboard at once; the
    /// other is hidden when the fade ends (if no newer call came meanwhile).
    func setSettingsVisible(_ visible: Bool, animated: Bool) {
        settingsGeneration += 1
        let generation = settingsGeneration
        let shown: NSView = visible ? settingsView : contentHost
        let other: NSView = visible ? contentHost : settingsView
        header.setShowsSettings(visible)
        shown.isHidden = false
        guard animated else {
            shown.alphaValue = 1
            other.alphaValue = 1
            other.isHidden = true
            return
        }
        shown.alphaValue = 0
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            shown.animator().alphaValue = 1
            other.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.settingsGeneration else { return }
                other.isHidden = true
                other.alphaValue = 1
            }
        })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// Drag area with a centered title: the directory name, or "Settings" with a Done button
/// while the settings page shows (DESIGN §7.9). Clicking outside the panel collapses it
/// (DESIGN §6.3).
final class HeaderView: NSView {
    weak var controller: PanelController?
    var onDone: (() -> Void)?

    private var drag = WindowDrag()
    private let label = NSTextField(labelWithString: "")
    private let doneButton = FirstMouseButton(title: "Done", target: nil, action: nil)
    private var directoryTitle = ""
    private var path: String?
    private var showsSettings = false

    init(frame: NSRect, title: String) {
        super.init(frame: frame)

        directoryTitle = title
        label.stringValue = title
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle  // long directories (DESIGN §9.8)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
        ])

        doneButton.bezelStyle = .push
        doneButton.controlSize = .small
        doneButton.target = self
        doneButton.action = #selector(done)
        doneButton.isHidden = true
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(doneButton)
        NSLayoutConstraint.activate([
            doneButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            doneButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setTitle(_ title: String) {
        directoryTitle = title
        if !showsSettings { label.stringValue = title }
    }

    /// The full directory, shown on hover (DESIGN §7.9).
    func setPath(_ path: String) {
        self.path = path
        if !showsSettings { toolTip = path }
    }

    /// "Settings" and Done in place of the directory while the settings page shows.
    func setShowsSettings(_ shows: Bool) {
        showsSettings = shows
        label.stringValue = shows ? "Settings" : directoryTitle
        toolTip = shows ? nil : path
        doneButton.isHidden = !shows
    }

    @objc private func done() { onDone?() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The whole header, including the title, drags; only Done takes its own clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        if !doneButton.isHidden, doneButton.frame.contains(convert(point, from: superview)) { return doneButton }
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
