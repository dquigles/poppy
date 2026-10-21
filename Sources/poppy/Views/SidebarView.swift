import AppKit

/// One row of the sidebar: a session as PanelController sees it (DESIGN §7.17).
struct SidebarItem {
    var name: String
    var harness: Harness
    /// The status to tint the logo with (done only while unseen).
    var status: AgentStatus
    /// Tooltip and accessibility label: name, agent and status, so status isn't color alone.
    var label: String
    /// An empty slot where a session is about to join (a pill hovering over the panel).
    var isPlaceholder = false

    static func placeholder() -> SidebarItem {
        SidebarItem(name: "", harness: .other, status: .idle, label: "New session", isPlaceholder: true)
    }
}

/// The sessions of a pill, on the left of the expanded panel (shown with 2+ sessions):
/// status-tinted logos and names, ＋ at the bottom, scrolling when they don't fit. Its
/// right edge drags to resize it; narrower than `snapWidth` it closes to a rail showing
/// only the logos, and dragging the rail out opens it again (DESIGN §7.17).
final class SidebarView: NSView {
    /// With names: the default width, and the range a drag can set.
    static let width: CGFloat = 168
    static let minWidth: CGFloat = 120
    static let maxWidth: CGFloat = 360
    /// A drag that ends up narrower than this closes the sidebar to the rail.
    static let snapWidth: CGFloat = 96
    static let railWidth: CGFloat = 44
    static let rowHeight: CGFloat = 28
    static let rowSpacing: CGFloat = 2
    static let barHeight: CGFloat = 28
    /// Rows line up with the terminal's 8 pt inset on the left.
    static let leftInset: CGFloat = 8
    static let rightInset: CGFloat = 6

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onRestart: ((Int) -> Void)?
    /// Rename… or a double-click; PanelController decides where the name is edited.
    var onRenameRequest: ((Int) -> Void)?
    /// A name typed in a row (nil: cancelled); then the terminal takes the keyboard back.
    var onRenamed: ((Int, String?) -> Void)?
    var onNew: (() -> Void)?
    /// The ＋ menu (another agent, another folder), shown from `view`.
    var onNewMenu: ((NSView) -> Void)?
    /// The right edge dragged to `width` (not yet snapped or clamped); `ended` on mouse-up.
    var onResize: ((_ width: CGFloat, _ ended: Bool) -> Void)?
    /// A double-click on the right edge: rail ⇄ names.
    var onToggleRail: (() -> Void)?
    /// A row dragged past the 3 pt threshold: true if it may move (DESIGN §7.19). Then every
    /// mouse move, and the mouse-up; the mouse is read from `NSEvent.mouseLocation`.
    var onRowDragBegan: ((Int) -> Bool)?
    var onRowDragMoved: (() -> Void)?
    var onRowDragEnded: (() -> Void)?

    /// Logos only, names as tooltips.
    var isRail = false {
        didSet {
            guard isRail != oldValue else { return }
            rows.forEach { $0.isRail = isRail }
            moreButton.isHidden = isRail
            needsLayout = true
        }
    }

    private let scrollView = NSScrollView()
    private let documentView = SidebarDocumentView()
    private var rows: [SidebarRow] = []
    private let plusButton = FirstMouseButton()
    private let moreButton = FirstMouseButton()
    private var canClose = false
    private var renameField: RenameField?
    private let resizeHandle = SidebarResizeHandle()

    override init(frame: NSRect) {
        super.init(frame: frame)
        resizeHandle.sidebar = self
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false  // only while the rows overflow (layout)
        scrollView.verticalScrollElasticity = .none
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = documentView
        scrollView.contentView.drawsBackground = false
        addSubview(scrollView)

        Self.configure(plusButton, symbol: "plus", label: "New Session")
        plusButton.toolTip = "New Session (⌘T)"
        plusButton.target = self
        plusButton.action = #selector(plusClicked)
        addSubview(plusButton)
        Self.configure(moreButton, symbol: "chevron.down", label: "New Session with…")
        moreButton.toolTip = "New session with another agent or folder"
        moreButton.target = self
        moreButton.action = #selector(moreClicked)
        addSubview(moreButton)
        addSubview(resizeHandle)  // last: on top of the rows' right edge
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static func configure(_ button: NSButton, symbol: String, label: String) {
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.setAccessibilityLabel(label)
    }

    /// `hidden`: a row dragged out as a liquid blob, left blank in the list (DESIGN §7.19).
    func update(_ items: [SidebarItem], selected: Int, canClose: Bool, hidden: Int? = nil) {
        self.canClose = canClose
        while rows.count < items.count {
            let row = SidebarRow()
            row.sidebar = self
            row.isRail = isRail
            documentView.addSubview(row)
            rows.append(row)
        }
        while rows.count > items.count {
            rows.removeLast().removeFromSuperview()
        }
        for (index, item) in items.enumerated() {
            rows[index].index = index
            rows[index].show(item, selected: index == selected, canClose: canClose)
            rows[index].alphaValue = index == hidden ? 0 : 1
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let bar = Self.barHeight
        scrollView.frame = NSRect(x: 0, y: bar, width: bounds.width, height: max(bounds.height - bar, 0))
        let rowWidth = bounds.width - Self.leftInset - Self.rightInset
        let height = CGFloat(rows.count) * (Self.rowHeight + Self.rowSpacing)
        // Scrolling (wheel, bounce and scroller) only when the rows don't all fit.
        let overflows = height > scrollView.contentSize.height
        if overflows != scrolls {
            scrollView.hasVerticalScroller = overflows
            scrollView.verticalScrollElasticity = overflows ? .automatic : .none
            if !overflows { scrollView.contentView.scroll(to: .zero) }
        }
        documentView.frame = NSRect(x: 0, y: 0, width: scrollView.contentSize.width,
                                    height: max(height, scrollView.contentSize.height))
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: Self.leftInset, y: CGFloat(index) * (Self.rowHeight + Self.rowSpacing),
                               width: rowWidth, height: Self.rowHeight)
        }
        let button: CGFloat = 22
        let y = (bar - button) / 2
        if isRail {
            plusButton.frame = NSRect(x: Self.leftInset + (rowWidth - button) / 2, y: y, width: button, height: button)
        } else {
            plusButton.frame = NSRect(x: Self.leftInset + 3, y: y, width: button, height: button)
            moreButton.frame = NSRect(x: plusButton.frame.maxX, y: y, width: 16, height: button)
        }
        // The gap between the rows and the terminal, plus a little of the rows.
        resizeHandle.frame = NSRect(x: bounds.width - Self.rightInset - 2, y: 0,
                                    width: Self.rightInset + 2, height: bounds.height)
        if let renameField, let row = rows.first(where: { $0.isRenaming }) {
            renameField.frame = row.renameFrame
        }
    }

    /// True while the rows overflow and can be scrolled.
    var scrolls: Bool { scrollView.hasVerticalScroller }

    /// Scrolls the selected row into view (e.g. after ⌘9 or a new session).
    func reveal(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        layoutSubtreeIfNeeded()
        documentView.scrollToVisible(rows[index].frame)
    }

    // MARK: Row drag (DESIGN §7.19)

    /// The row position under a screen point while it's over the sidebar (clamped to the
    /// rows), else nil.
    func rowSlot(atScreen point: NSPoint) -> Int? {
        guard let window, !rows.isEmpty else { return nil }
        let inWindow = window.convertPoint(fromScreen: point)
        guard bounds.contains(convert(inWindow, from: nil)) else { return nil }
        let y = documentView.convert(inWindow, from: nil).y
        return min(max(Int(y / (Self.rowHeight + Self.rowSpacing)), 0), rows.count - 1)
    }

    /// What row `index` shows, and where it is on screen (for the drag image).
    func rowSnapshot(_ index: Int) -> (image: NSImage?, frame: NSRect) {
        guard rows.indices.contains(index), let window else { return (nil, .zero) }
        let row = rows[index]
        var image: NSImage?
        if let rep = row.bitmapImageRepForCachingDisplay(in: row.bounds) {
            row.cacheDisplay(in: row.bounds, to: rep)
            image = NSImage(size: row.bounds.size)
            image?.addRepresentation(rep)
        }
        return (image, window.convertToScreen(row.convert(row.bounds, to: nil)))
    }

    // MARK: Rename (DESIGN §7.17)

    /// Edits the name in the row (not in the rail, where there's no name to edit).
    @discardableResult
    func beginRename(at index: Int) -> Bool {
        guard !isRail, rows.indices.contains(index), let window else { return false }
        endRename()
        let row = rows[index]
        row.isRenaming = true
        let field = RenameField(text: row.name, fontSize: 12)
        field.frame = row.renameFrame
        field.onEnd = { [weak self, weak row] text in
            guard let self, let row else { return }
            let index = row.index
            // Removed on the next turn: this runs inside the field's own end-editing.
            DispatchQueue.main.async { [weak self] in
                self?.endRename()
                self?.onRenamed?(index, text)
            }
        }
        row.superview?.addSubview(field)
        renameField = field
        window.makeFirstResponder(field)
        return true
    }

    private func endRename() {
        renameField?.removeFromSuperview()
        renameField = nil
        rows.forEach { $0.isRenaming = false }
    }

    // MARK: Actions

    @objc private func plusClicked() { onNew?() }
    @objc private func moreClicked() { onNewMenu?(moreButton) }

    fileprivate func rowClicked(_ row: SidebarRow, event: NSEvent) {
        if event.clickCount == 2 {
            onRenameRequest?(row.index)
        } else if event.clickCount == 1 {
            onSelect?(row.index)
        }
    }

    fileprivate func closeClicked(_ row: SidebarRow) { onClose?(row.index) }

    fileprivate func showMenu(for row: SidebarRow, event: NSEvent) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, action) in [("Rename…", #selector(renameItem(_:))), ("Restart Agent", #selector(restartItem(_:))),
                                ("Close Session", #selector(closeItem(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = row.index
            item.isEnabled = action != #selector(closeItem(_:)) || canClose
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: row)
    }

    @objc private func renameItem(_ sender: NSMenuItem) { onRenameRequest?(sender.tag) }
    @objc private func restartItem(_ sender: NSMenuItem) { onRestart?(sender.tag) }
    @objc private func closeItem(_ sender: NSMenuItem) { onClose?(sender.tag) }

    override func rightMouseDown(with event: NSEvent) {}  // not the panel's menu over the sidebar's background
}

/// The sidebar's right edge: drag to resize (resize cursor), double-click for rail ⇄ names.
/// Widths come from screen coordinates, so the sidebar changing under the mouse doesn't
/// throw the drag off.
private final class SidebarResizeHandle: NSView {
    weak var sidebar: SidebarView?
    private var startMouse: CGFloat = 0
    private var startWidth: CGFloat = 0
    private var dragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            dragging = false
            sidebar?.onToggleRail?()
            return
        }
        startMouse = NSEvent.mouseLocation.x
        startWidth = sidebar?.bounds.width ?? 0
        dragging = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        NSCursor.resizeLeftRight.set()
        sidebar?.onResize?(startWidth + NSEvent.mouseLocation.x - startMouse, false)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        sidebar?.onResize?(startWidth + NSEvent.mouseLocation.x - startMouse, true)
    }

    override func rightMouseDown(with event: NSEvent) {}
}

private final class SidebarDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// A session row: logo tinted by status, name, × on hover; highlighted when selected.
private final class SidebarRow: NSView {
    weak var sidebar: SidebarView?
    var index = 0
    var isRail = false {
        didSet { applyLayout() }
    }
    var isRenaming = false {
        didSet { label.isHidden = isRenaming || isRail }
    }
    private(set) var name = ""
    private let logo = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let closeButton = FirstMouseButton()
    private var isSelected = false
    private var isHovering = false
    private var canClose = false

    static let logoSize: CGFloat = 16

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.unregisterDraggedTypes()
        addSubview(logo)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        addSubview(label)
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Session")
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "Close Session (⌘W)"
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = true
        addSubview(closeButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ item: SidebarItem, selected: Bool, canClose: Bool) {
        name = item.name
        label.stringValue = item.name
        isPlaceholder = item.isPlaceholder
        logo.isHidden = item.isPlaceholder
        logo.image = HarnessLogo.image(for: item.harness, points: Self.logoSize)
        logo.contentTintColor = item.status.tint ?? .labelColor
        toolTip = item.label
        setAccessibilityLabel(item.label)
        setAccessibilitySelected(selected)
        isSelected = selected
        self.canClose = canClose
        label.textColor = selected ? .labelColor : .secondaryLabelColor
        updateCloseButton()
        needsDisplay = true
    }

    /// Where the rename field goes, in the document view's coordinates.
    var renameFrame: NSRect {
        NSRect(x: frame.minX + label.frame.minX - 3, y: frame.minY + (frame.height - 20) / 2,
               width: frame.width - label.frame.minX - 2, height: 20)
    }

    override func layout() {
        super.layout()
        applyLayout()
    }

    private func applyLayout() {
        let size = Self.logoSize
        let y = (bounds.height - size) / 2
        logo.frame = NSRect(x: isRail ? (bounds.width - size) / 2 : 8, y: y, width: size, height: size)
        let close: CGFloat = 18
        closeButton.frame = NSRect(x: bounds.width - close - 4, y: (bounds.height - close) / 2, width: close, height: close)
        let labelX = logo.frame.maxX + 7
        label.sizeToFit()
        let labelHeight = label.frame.height
        label.frame = NSRect(x: labelX, y: (bounds.height - labelHeight) / 2,
                             width: max(closeButton.frame.minX - 2 - labelX, 0), height: labelHeight)
        label.isHidden = isRail || isRenaming
        updateCloseButton()
    }

    private func updateCloseButton() {
        closeButton.isHidden = !(isHovering && canClose && !isRail)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        let alpha: CGFloat = isPlaceholder ? 0.06 : isSelected ? 0.12 : isHovering ? 0.05 : 0
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
        layer?.borderWidth = isPlaceholder ? 1 : 0
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.25).cgColor
    }

    /// An empty slot (see `SidebarItem.isPlaceholder`): an outline, no logo or name.
    private var isPlaceholder = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateCloseButton()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateCloseButton()
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        if !closeButton.isHidden, closeButton.frame.contains(convert(point, from: superview)) { return closeButton }
        return self
    }

    /// Where a single click went down; a move past 3 pt from there drags the row.
    private var dragStart: NSPoint?
    private var dragging = false

    override func mouseDown(with event: NSEvent) {
        dragging = false
        dragStart = event.clickCount == 1 ? NSEvent.mouseLocation : nil
        sidebar?.rowClicked(self, event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let sidebar else { return }
        if !dragging {
            let mouse = NSEvent.mouseLocation
            guard hypot(mouse.x - start.x, mouse.y - start.y) > 3 else { return }
            guard sidebar.onRowDragBegan?(index) == true else {
                dragStart = nil
                return
            }
            dragging = true
        }
        sidebar.onRowDragMoved?()
    }

    override func mouseUp(with event: NSEvent) {
        let ended = dragging
        dragging = false
        dragStart = nil
        if ended { sidebar?.onRowDragEnded?() }
    }

    override func rightMouseDown(with event: NSEvent) { sidebar?.showMenu(for: self, event: event) }
    override func accessibilityPerformPress() -> Bool {
        sidebar?.onSelect?(index)
        return true
    }

    @objc private func closeClicked() { sidebar?.closeClicked(self) }
}

/// An inline name editor (a sidebar row or the header): Return commits, Esc cancels, and
/// clicking elsewhere commits, as in Finder. `onEnd` gets the text, or nil if cancelled.
final class RenameField: NSTextField, NSTextFieldDelegate {
    var onEnd: ((String?) -> Void)?
    private var ended = false

    init(text: String, fontSize: CGFloat) {
        super.init(frame: .zero)
        stringValue = text
        font = .systemFont(ofSize: fontSize)
        isBordered = true
        isBezeled = true
        bezelStyle = .roundedBezel
        controlSize = .small
        isEditable = true
        isSelectable = true
        usesSingleLineMode = true
        cell?.isScrollable = true
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            end(nil)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            end(stringValue)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        end(stringValue)
    }

    private func end(_ text: String?) {
        guard !ended else { return }
        ended = true
        onEnd?(text)
    }
}
