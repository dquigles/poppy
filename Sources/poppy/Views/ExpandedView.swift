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
    /// The pill's sessions, left of the terminal while there are 2+ (DESIGN §7.17).
    let sidebar = SidebarView(frame: .zero)
    /// 0 while the sidebar is hidden.
    private(set) var sidebarWidth: CGFloat = 0
    /// "Close this busy session?" over the panel (DESIGN §7.17).
    private(set) var confirmView: ConfirmView?
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
        sidebar.autoresizingMask = [.height, .maxXMargin]
        sidebar.isHidden = true
        addSubview(sidebar)
    }

    /// Shows or hides the usage footer, moving the content's bottom edge (a terminal
    /// resize, so only on a harness or setting change, DESIGN §7.9).
    func setUsageVisible(_ visible: Bool) {
        guard usageBar.isHidden == visible else { return }
        usageBar.isHidden = !visible
        layoutContent()
    }

    /// Shows the sidebar at `width` (0 hides it), narrowing the terminal: one resize.
    func setSidebarWidth(_ width: CGFloat) {
        guard width != sidebarWidth else { return }
        sidebarPreview = 0
        sidebarWidth = width
        sidebar.isHidden = width == 0
        layoutContent()
    }

    /// While a pill hovers over this panel and it has no sidebar (DESIGN §7.19): the sidebar
    /// slides in at `width` and pushes the terminal right without resizing it (no reflow;
    /// its right edge goes past the panel's meanwhile). 0 slides it back. A drop commits
    /// the real layout with `setSidebarWidth`.
    private(set) var sidebarPreview: CGFloat = 0
    static let previewDuration: TimeInterval = 0.25

    func previewSidebar(_ width: CGFloat) {
        guard sidebarWidth == 0, width != sidebarPreview else { return }
        sidebarPreview = width
        let bottom = usageBar.isHidden ? Self.contentInset : UsageBar.height
        let top = bounds.height - Self.headerHeight
        if width > 0, sidebar.isHidden {
            sidebar.frame = NSRect(x: 0, y: bottom, width: 0, height: top - bottom)
            sidebar.isHidden = false
        }
        var terminal = contentHost.frame
        terminal.origin.x = width > 0 ? width : Self.contentInset
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.previewDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            sidebar.animator().frame = NSRect(x: 0, y: bottom, width: width, height: top - bottom)
            contentHost.animator().frame = terminal
            settingsView.animator().frame = terminal
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.sidebarPreview == 0, self.sidebarWidth == 0 else { return }
                self.sidebar.isHidden = true
            }
        })
    }

    /// The terminal (and the settings page over it) between the sidebar or the left inset,
    /// the header, and the footer or the bottom inset; the sidebar beside it.
    private func layoutContent() {
        let bottom = usageBar.isHidden ? Self.contentInset : UsageBar.height
        let top = bounds.height - Self.headerHeight
        let left = sidebarWidth > 0 ? sidebarWidth : Self.contentInset
        let frame = NSRect(x: left, y: bottom, width: bounds.width - left - Self.contentInset, height: top - bottom)
        contentHost.frame = frame
        settingsView.frame = frame
        if let confirmView {
            confirmView.frame = confirmFrame
            confirmView.setTerminalFrame(convert(frame, to: confirmView))
        }
        sidebar.frame = NSRect(x: 0, y: bottom, width: sidebarWidth, height: top - bottom)
    }

    /// Asks before closing a busy session; Return or Close confirms, Esc or Cancel doesn't.
    /// Over the terminal's area only (the header and sidebar stay as they are), showing
    /// `terminal`, a still image of the session's terminal, faded behind the question.
    func showConfirm(terminal: NSImage?, icon: NSImage?, tint: NSColor?, title: String, message: String,
                     onClose: @escaping () -> Void, onCancel: @escaping () -> Void) {
        dismissConfirm()
        let view = ConfirmView(frame: confirmFrame, terminal: terminal, icon: icon, tint: tint,
                               title: title, message: message)
        view.autoresizingMask = [.width, .height]
        view.onEnd = { [weak self] confirmed in
            self?.dismissConfirm()
            if confirmed { onClose() } else { onCancel() }
        }
        addSubview(view)
        // Only once it's in this view: converting to a view outside the hierarchy goes
        // through window coordinates and shifted it by the sidebar's width.
        view.setTerminalFrame(convert(contentHost.frame, to: view))
        confirmView = view
    }

    /// Everything right of the sidebar and below the header, margins and footer included.
    private var confirmFrame: NSRect {
        NSRect(x: sidebarWidth, y: 0, width: bounds.width - sidebarWidth, height: bounds.height - Self.headerHeight)
    }

    func dismissConfirm() {
        confirmView?.removeFromSuperview()
        confirmView = nil
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

/// Drag area with a centered title: the selected session's name, or "Settings" with a Done button
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
    private var renameField: RenameField?

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

    /// Edits the title in place (the selected session's name, DESIGN §7.17). `onEnd` gets
    /// the text, or nil if cancelled.
    func beginRename(_ onEnd: @escaping (String?) -> Void) {
        guard !showsSettings, let window else { return }
        endRename()
        let field = RenameField(text: directoryTitle, fontSize: 12)
        field.alignment = .center
        let width = min(240, bounds.width - 120)
        field.frame = NSRect(x: (bounds.width - width) / 2, y: (bounds.height - 20) / 2, width: width, height: 20)
        field.autoresizingMask = [.minXMargin, .maxXMargin]
        field.onEnd = { [weak self] text in
            DispatchQueue.main.async {  // this runs inside the field's own end-editing
                self?.endRename()
                onEnd(text)
            }
        }
        label.isHidden = true
        addSubview(field)
        renameField = field
        window.makeFirstResponder(field)
    }

    private func endRename() {
        renameField?.removeFromSuperview()
        renameField = nil
        label.isHidden = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// What the header shows (for Poppy Dev's debug hook).
    var shownTitle: String { label.stringValue }

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
        let local = convert(point, from: superview)
        for view in [doneButton, renameField].compactMap({ $0 }) where !view.isHidden {
            if view.frame.contains(local) { return view.hitTest(point) ?? view }
        }
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

/// Asks before closing a session whose agent is working or waiting (DESIGN §7.17), like a
/// sheet on that session: right of the sidebar and below the header, a still image of its
/// terminal faded down to the bare glass (the same as the sidebar and header behind it), and
/// centered on the terminal the question laid out
/// like a macOS alert (the agent's logo, a bold title, the message, Cancel and Close;
/// Return closes, Esc cancels). PanelController
/// takes the live terminal out meanwhile: SwiftTerm follows the mouse for the whole window,
/// so a terminal underneath would still react. Everything in this area stops here: clicks,
/// right-clicks, scrolling, drops and keys. Not an NSAlert sheet: clicking one would
/// activate Poppy, which it never does (DESIGN §4).
final class ConfirmView: NSView {
    var onEnd: ((Bool) -> Void)?
    private var ended = false
    /// The terminal's still shows this faintly, so the area reads as the panel's glass.
    static let terminalAlpha: CGFloat = 0.15

    private let still = NSImageView()
    private let content = NSView()

    init(frame: NSRect, terminal: NSImage?, icon: NSImage?, tint: NSColor?, title: String, message: String) {
        super.init(frame: frame)

        still.image = terminal
        still.wantsLayer = true
        still.layer?.cornerRadius = 10  // as the terminal's area (DESIGN §7.9)
        still.layer?.masksToBounds = true
        still.imageScaling = .scaleNone
        still.imageAlignment = .alignTopLeft
        still.unregisterDraggedTypes()
        still.alphaValue = Self.terminalAlpha
        addSubview(still)
        addSubview(content)  // the terminal's area: the question is centered in it

        let logo = NSImageView()
        logo.image = icon
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.contentTintColor = tint ?? .labelColor
        logo.unregisterDraggedTypes()
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingMiddle
        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        let cancel = FirstMouseButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let close = FirstMouseButton(title: "Close", target: self, action: #selector(closeClicked))
        close.keyEquivalent = "\r"
        close.hasDestructiveAction = true
        for button in [cancel, close] {
            button.bezelStyle = .push
            button.controlSize = .large
        }
        let buttons = NSStackView(views: [cancel, close])
        buttons.distribution = .fillEqually
        buttons.spacing = 10
        let stack = NSStackView(views: [logo, titleLabel, messageLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(12, after: logo)
        stack.setCustomSpacing(18, after: messageLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.widthAnchor.constraint(equalToConstant: 260),
            logo.widthAnchor.constraint(equalToConstant: 40),
            logo.heightAnchor.constraint(equalToConstant: 40),
            titleLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            messageLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        registerForDraggedTypes(Attachments.dropTypes)  // nothing lands under it
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(title) \(message)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Where the terminal is (in this view): its still image stays in place, and the
    /// question is centered on it.
    func setTerminalFrame(_ frame: NSRect) {
        still.frame = frame
        content.frame = frame
    }

    /// Where the question is centered (for Poppy Dev's debug hook).
    var terminalFrame: NSRect { content.frame }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Every point is the card's: its buttons, or this view (which ignores it).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        let hit = super.hitTest(point)
        return hit is NSButton ? hit : self
    }

    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func menu(for event: NSEvent) -> NSMenu? { nil }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { [] }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: end(true)   // Return, keypad Enter
        case 53: end(false)      // Esc
        default: break           // swallowed
        }
    }

    @objc private func closeClicked() { end(true) }
    @objc private func cancelClicked() { end(false) }

    func end(_ confirmed: Bool) {
        guard !ended else { return }
        ended = true
        onEnd?(confirmed)
    }
}
