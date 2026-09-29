import AppKit

/// Owns the panel and its views: state machine, frames, animation, observers,
/// Poppy menu (DESIGN §5–7).
final class PanelController: NSObject {
    enum State { case collapsed, expanded }

    /// Screen corner the panel grows from; fixed at the start of each expand (DESIGN §7.5).
    struct Anchor {
        var right: Bool
        var top: Bool
    }

    static let pillSize = NSSize(width: 168, height: 44)
    static let pillCornerRadius: CGFloat = 22
    static let expandedCornerRadius: CGFloat = 20
    static let margin: CGFloat = 16
    static let clampInset: CGFloat = 8
    static let frameDuration: TimeInterval = 0.30
    static let fadeDuration: TimeInterval = 0.12

    let panel: GlassPanel
    private let config: Config
    private let session: TerminalSession?
    private let glass: GlassBackgroundView
    private let pillView: PillView
    private let expandedView: ExpandedView
    /// Pre-M5 stand-in for the terminal, used to test focus behavior.
    private var placeholderField: NSTextField?

    private(set) var state = State.collapsed
    private(set) var isAnimating = false
    private var needsReclamp = false
    private(set) var pillFrame: NSRect
    private var anchor = Anchor(right: true, top: false)
    /// Global mouse-down monitor, installed only while fully expanded (DESIGN §6.3).
    private var clickOutsideMonitor: Any?

    init(config: Config, session: TerminalSession?) {
        self.config = config
        self.session = session
        pillFrame = Self.initialPillFrame(from: PanelState.load())
        panel = GlassPanel(contentRect: pillFrame)

        glass = GlassBackgroundView(frame: NSRect(origin: .zero, size: Self.pillSize),
                                    cornerRadius: Self.pillCornerRadius)
        glass.autoresizingMask = [.width, .height]
        pillView = PillView(frame: glass.contentView.bounds, title: config.pillTitle)
        pillView.autoresizingMask = [.width, .height]
        expandedView = ExpandedView(title: config.pillTitle)
        expandedView.isHidden = true
        expandedView.alphaValue = 0
        super.init()

        pillView.controller = self
        expandedView.header.controller = self
        glass.contentView.addSubview(pillView)
        glass.contentView.addSubview(expandedView)

        let host = expandedView.contentHost
        if let session {
            session.attach(to: host)
            session.onViewReplaced = { [weak self] in self?.refocusAfterRestart() }
        } else {
            let field = NSTextField(frame: NSRect(x: 0, y: host.bounds.height - 24, width: host.bounds.width, height: 24))
            field.placeholderString = "Type here to test focus"
            field.autoresizingMask = [.width, .minYMargin]
            host.addSubview(field)
            placeholderField = field
        }

        panel.contentView = glass
        panel.allowsKey = false

        // Selector-based observers are removed automatically when self deallocates.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeSpaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        panel.orderFrontRegardless()
        panel.refreshShadow()
    }

    private var focusTarget: NSView? { session?.focusView ?? placeholderField }

    /// After Restart Agent swaps the terminal view, keep typing going to the new one.
    private func refocusAfterRestart() {
        guard state == .expanded, let focusTarget else { return }
        panel.makeFirstResponder(focusTarget)
    }

    // MARK: - Expand / collapse (DESIGN §6.1, §7.7)

    func expand() {
        guard state == .collapsed, !isAnimating else { return }
        isAnimating = true
        state = .expanded

        pillFrame = panel.frame
        anchor = Self.anchor(for: pillFrame)
        let target = Self.clamp(expandedFrame(fromPill: pillFrame), in: Self.screen(for: pillFrame))

        glass.cornerRadius = Self.expandedCornerRadius
        panel.setTitledChrome(true)
        pillView.alphaValue = 0
        pillView.isHidden = true
        pinExpandedView(containerSize: glass.contentView.bounds.size)
        expandedView.alphaValue = 0
        expandedView.isHidden = false
        panel.allowsKey = true

        animateFrame(to: target) { [weak self] in
            guard let self else { return }
            panel.refreshShadow()
            panel.makeKeyAndOrderFront(nil)
            if let focusTarget { panel.makeFirstResponder(focusTarget) }
            fade(expandedView, to: 1) { [weak self] in
                self?.panel.refreshShadow()
                self?.installClickOutsideMonitor()
                self?.finishAnimation()
            }
        }
    }

    func collapse() {
        guard state == .expanded, !isAnimating else { return }
        isAnimating = true
        state = .collapsed
        removeClickOutsideMonitor()

        // Drop key status so the underlying app's window gets keyboard input again.
        panel.makeFirstResponder(nil)
        panel.allowsKey = false
        panel.orderOut(nil)
        panel.orderFrontRegardless()

        pillFrame = pillFrame(fromExpanded: panel.frame)
        expandedView.alphaValue = 0
        expandedView.isHidden = true

        animateFrame(to: pillFrame) { [weak self] in
            guard let self else { return }
            glass.cornerRadius = Self.pillCornerRadius
            panel.setTitledChrome(false)  // also refreshes the shadow
            pillView.isHidden = false
            fade(pillView, to: 1) { [weak self] in
                self?.panel.refreshShadow()
                self?.finishAnimation()
            }
        }
    }

    // MARK: - Click outside (DESIGN §6.3)

    /// Global monitors see only events delivered to other apps (other windows, the
    /// desktop, other menu bar items), never clicks on Poppy's own panel or menu bar item.
    /// Mouse events need no Accessibility permission. Left clicks collapse on mouse-up,
    /// and not when released over the panel, so dragging a file in from Finder works.
    private func installClickOutsideMonitor() {
        guard clickOutsideMonitor == nil else { return }
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseUp, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedOutside() }
        }
    }

    private func removeClickOutsideMonitor() {
        if let clickOutsideMonitor { NSEvent.removeMonitor(clickOutsideMonitor) }
        clickOutsideMonitor = nil
    }

    private func clickedOutside() {
        guard state == .expanded, !isAnimating,
              !NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) else { return }
        collapse()
    }

    private func finishAnimation() {
        isAnimating = false
        if needsReclamp {
            needsReclamp = false
            reclamp()
        }
    }

    private func animateFrame(to target: NSRect, completion: @escaping @MainActor () -> Void) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.frameDuration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.2, 1.0)
            panel.animator().setFrame(target, display: true)
        }, completionHandler: {
            MainActor.assumeIsolated { completion() }
        })
    }

    private func fade(_ view: NSView, to alpha: CGFloat, completion: @escaping @MainActor () -> Void) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.fadeDuration
            view.animator().alphaValue = alpha
        }, completionHandler: {
            MainActor.assumeIsolated { completion() }
        })
    }

    /// Place the fixed-size ExpandedView at the anchor corner of the container and
    /// keep it pinned there while the window grows or shrinks.
    private func pinExpandedView(containerSize: NSSize) {
        let size = ExpandedView.size
        let x = anchor.right ? containerSize.width - size.width : 0
        let y = anchor.top ? containerSize.height - size.height : 0
        expandedView.frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        var mask: NSView.AutoresizingMask = []
        mask.insert(anchor.right ? .minXMargin : .maxXMargin)
        mask.insert(anchor.top ? .minYMargin : .maxYMargin)
        expandedView.autoresizingMask = mask
    }

    // MARK: - Hotkey (DESIGN §11)

    func hotkeyPressed() {
        guard !isAnimating else { return }
        switch state {
        case .collapsed:
            // Follow the user: if the mouse is on another display, jump there first.
            let mouseScreen = Self.screenWithMouse()
            if Self.screenNumber(mouseScreen) != Self.screenNumber(Self.screen(for: pillFrame)) {
                pillFrame = NSRect(origin: Self.defaultPillOrigin(on: mouseScreen), size: Self.pillSize)
                panel.setFrame(pillFrame, display: true)
                saveState()
            }
            expand()
        case .expanded:
            if panel.isKeyWindow {
                collapse()
            } else {
                panel.makeKeyAndOrderFront(nil)
                if let focusTarget { panel.makeFirstResponder(focusTarget) }
            }
        }
    }

    // MARK: - Pill / header interaction

    func pillClicked() {
        expand()
    }

    func pillDragEnded() {
        guard state == .collapsed, !isAnimating else { return }
        let frame = Self.clamp(panel.frame, in: Self.screen(for: panel.frame))
        panel.setFrame(frame, display: true)
        panel.refreshShadow()
        pillFrame = frame
        saveState()
    }

    func headerDragEnded() {
        guard state == .expanded, !isAnimating else { return }
        let frame = Self.clamp(panel.frame, in: Self.screen(for: panel.frame))
        panel.setFrame(frame, display: true)
        panel.refreshShadow()
        pillFrame = pillFrame(fromExpanded: frame)
        saveState()
    }

    // MARK: - Observers

    @objc private func activeSpaceDidChange(_ notification: Notification) {
        panel.orderFrontRegardless()
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        reclamp()
    }

    /// Keep the panel on-screen after a display change (DESIGN §7.4).
    private func reclamp() {
        guard !isAnimating else {
            needsReclamp = true
            return
        }
        let current = panel.frame
        let clamped = Self.clamp(current, in: Self.screen(for: current))
        guard clamped != current else { return }
        panel.setFrame(clamped, display: true)
        panel.refreshShadow()
        pillFrame = state == .expanded ? pillFrame(fromExpanded: clamped) : clamped
        saveState()
    }

    private func saveState() {
        PanelState(pillOrigin: SavedPoint(x: pillFrame.minX, y: pillFrame.minY)).save()
    }

    // MARK: - Poppy menu (DESIGN §7.10)

    func showContextMenu(event: NSEvent, in view: NSView) {
        NSMenu.popUpContextMenu(makeMenu(), with: event, for: view)
    }

    /// Poppy's menu, shared by the right-click context menu and the menu bar item.
    /// The controller is its delegate, so a long-lived menu (the menu bar's) is
    /// rebuilt each time it opens and never shows stale items.
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        populateMenu(menu)
        return menu
    }

    private func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let restart = NSMenuItem(title: "Restart Agent", action: #selector(restartAgent), keyEquivalent: "")
        restart.target = self
        restart.isEnabled = session != nil
        menu.addItem(restart)

        let collapse = NSMenuItem(title: "Collapse", action: #selector(collapseFromMenu), keyEquivalent: "")
        collapse.target = self
        collapse.isEnabled = state == .expanded && !isAnimating
        menu.addItem(collapse)

        let quit = NSMenuItem(title: "Quit Poppy", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func collapseFromMenu() {
        collapse()
    }

    @objc private func restartAgent() {
        session?.restart()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Frame math (DESIGN §7.3–7.6)

    private func expandedFrame(fromPill pill: NSRect) -> NSRect {
        let size = ExpandedView.size
        let x = anchor.right ? pill.maxX - size.width : pill.minX
        let y = anchor.top ? pill.maxY - size.height : pill.minY
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    private func pillFrame(fromExpanded expanded: NSRect) -> NSRect {
        let size = Self.pillSize
        let x = anchor.right ? expanded.maxX - size.width : expanded.minX
        let y = anchor.top ? expanded.maxY - size.height : expanded.minY
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    private static func anchor(for pill: NSRect) -> Anchor {
        let visible = screen(for: pill).visibleFrame
        return Anchor(right: pill.midX > visible.midX, top: pill.midY > visible.midY)
    }

    /// Saved origin if it's still on some screen (clamped), else the default position.
    private static func initialPillFrame(from state: PanelState) -> NSRect {
        if let saved = state.pillOrigin {
            let rect = NSRect(x: saved.x, y: saved.y, width: pillSize.width, height: pillSize.height)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) {
                return clamp(rect, in: screen(for: rect))
            }
        }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        return NSRect(origin: defaultPillOrigin(on: screen), size: pillSize)
    }

    static func defaultPillOrigin(on screen: NSScreen) -> NSPoint {
        let visible = screen.visibleFrame
        return NSPoint(x: visible.maxX - margin - pillSize.width, y: visible.minY + margin)
    }

    /// Screen containing the rect's center, else largest intersection, else main, else first.
    static func screen(for rect: NSRect) -> NSScreen {
        let screens = NSScreen.screens
        let center = NSPoint(x: rect.midX, y: rect.midY)
        if let hit = screens.first(where: { $0.frame.contains(center) }) {
            return hit
        }
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for screen in screens {
            let overlap = screen.frame.intersection(rect)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > bestArea {
                best = screen
                bestArea = area
            }
        }
        return best ?? NSScreen.main ?? screens[0]
    }

    /// Screen under the mouse pointer, edges included (else main).
    static func screenWithMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Stable identity for comparing screens (NSScreen objects can be recreated).
    static func screenNumber(_ screen: NSScreen) -> NSNumber? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }

    /// Shift `frame` inside the inset visible area, never shrinking it. An axis that
    /// doesn't fit is aligned to the area's left (x) or top (y) edge.
    static func clamp(_ frame: NSRect, in screen: NSScreen) -> NSRect {
        let area = screen.visibleFrame.insetBy(dx: clampInset, dy: clampInset)
        var result = frame
        if frame.width > area.width {
            result.origin.x = area.minX
        } else {
            result.origin.x = min(max(frame.minX, area.minX), area.maxX - frame.width)
        }
        if frame.height > area.height {
            result.origin.y = area.maxY - frame.height
        } else {
            result.origin.y = min(max(frame.minY, area.minY), area.maxY - frame.height)
        }
        return result
    }
}

extension PanelController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        populateMenu(menu)
    }
}
