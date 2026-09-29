import AppKit

/// Shared with the `poppy` command's `--pill` (DESIGN §7.14, §9.9).
nonisolated enum PanelSizes {
    static let pillPresets: [(name: String, diameter: CGFloat)] = [("Small", 36), ("Medium", 44), ("Large", 56)]
}

/// Owns the panel and its views: state machine, frames, animation, observers,
/// Poppy menu (DESIGN §5–7).
final class PanelController: NSObject {
    enum State { case collapsed, expanded }

    /// Screen corner the panel grows from; fixed at the start of each expand (DESIGN §7.5).
    struct Anchor {
        var right: Bool
        var top: Bool
    }

    /// Pill diameter presets, in the Pill Size menu (DESIGN §7.14).
    static let pillPresets = PanelSizes.pillPresets
    static let defaultPillDiameter: CGFloat = 44
    static let expandedCornerRadius: CGFloat = 20
    static let margin: CGFloat = 16
    static let clampInset: CGFloat = 8
    static let frameDuration: TimeInterval = 0.30
    static let fadeDuration: TimeInterval = 0.12

    let panel: GlassPanel
    private var config: Config
    private let agents: AgentCatalog
    /// The running agent's subscription usage (DESIGN §9.7).
    private let usage: UsageMonitor
    /// The agent's working directory (absolute) and recent ones, newest first (DESIGN §9.8).
    private var workingDirectory: String
    private var recentDirectories: [String]
    static let maxRecentDirectories = 8
    /// The working directory's name ("~" for home), DESIGN §7.9.
    private var headerTitle: String { Self.directoryName(workingDirectory) }

    static func directoryName(_ path: String) -> String {
        let short = Config.abbreviate(path)
        return short == "~" || short == "/" ? short : (path as NSString).lastPathComponent
    }
    /// The profiles in the menu as last built; menu items refer to them by `tag`.
    private var menuAgents: [AgentProfile] = []
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
    /// The pill is a glass circle holding the logo; its diameter is a preset (DESIGN §7.14).
    private var pillDiameter: CGFloat
    private var pillSize: NSSize { NSSize(width: pillDiameter, height: pillDiameter) }
    private var pillCornerRadius: CGFloat { pillDiameter / 2 }
    /// The expanded size the user chose by resizing (DESIGN §7.13).
    private var expandedSize: NSSize
    /// A terminal resize is scheduled during a live resize (coalesced, DESIGN §7.13).
    private var liveResizeUpdatePending = false
    static let liveResizeInterval: TimeInterval = 0.05
    /// Global mouse-down monitor, installed only while fully expanded (DESIGN §6.3).
    private var clickOutsideMonitor: Any?
    /// Why the panel is open, if it opened itself (DESIGN §7.15). After a `.waiting`
    /// auto-open it collapses again once the agent is working; any manual expand or
    /// collapse clears it.
    private var autoOpenedFor: AgentStatus?
    /// An auto-open that had to wait (animating, resizing, a mouse button down); retried
    /// when that ends if the status is still the same (DESIGN §7.15).
    private var pendingAutoOpen: AgentStatus?
    static let autoOpenKeyGuard: TimeInterval = 0.4
    /// Set by AppDelegate; the menu shows and changes the hotkey through it (DESIGN §7.10).
    weak var hotKeys: HotKeyManager? {
        didSet { hotKeys?.onRecorderClosed = { [weak self] in self?.refocusIfExpanded() } }
    }

    init(config: Config, session: TerminalSession?) {
        self.config = config
        agents = AgentCatalog(launchCommand: config.command)
        usage = UsageMonitor(command: config.command, enabled: config.showUsage)
        self.session = session
        let saved = PanelState.load()
        workingDirectory = Config.normalize(config.resolvedWorkingDirectory)
        recentDirectories = saved.recentDirectories ?? []
        if let diameter = saved.pillDiameter.map({ CGFloat($0) }),
           Self.pillPresets.contains(where: { $0.diameter == diameter }) {
            pillDiameter = diameter
        } else {
            pillDiameter = Self.defaultPillDiameter
        }
        expandedSize = saved.expandedSize.map {
            NSSize(width: max($0.width, ExpandedView.minSize.width), height: max($0.height, ExpandedView.minSize.height))
        } ?? ExpandedView.defaultSize
        let pillSize = NSSize(width: pillDiameter, height: pillDiameter)
        pillFrame = Self.initialPillFrame(from: saved, size: pillSize)
        panel = GlassPanel(contentRect: pillFrame)

        glass = GlassBackgroundView(frame: NSRect(origin: .zero, size: pillSize),
                                    cornerRadius: pillDiameter / 2)
        glass.autoresizingMask = [.width, .height]
        pillView = PillView(frame: glass.contentView.bounds, harness: Harness(command: config.command),
                            title: config.pillTitle)
        pillView.autoresizingMask = [.width, .height]
        expandedView = ExpandedView(title: Self.directoryName(workingDirectory), size: expandedSize)
        expandedView.header.setPath(Config.abbreviate(workingDirectory))
        expandedView.isHidden = true
        expandedView.alphaValue = 0
        super.init()

        pillView.controller = self
        expandedView.header.controller = self
        expandedView.usageBar.controller = self
        glass.contentView.addSubview(pillView)
        glass.contentView.addSubview(expandedView)

        let host = expandedView.contentHost
        if let session {
            session.attach(to: host)
            session.onViewReplaced = { [weak self] in self?.refocusAfterRestart() }
            session.onStatusChange = { [weak self] status in self?.statusChanged(status) }
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(liveResizeWillStart),
            name: NSWindow.willStartLiveResizeNotification, object: panel)
        NotificationCenter.default.addObserver(
            self, selector: #selector(liveResizeDidEnd),
            name: NSWindow.didEndLiveResizeNotification, object: panel)
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelDidResize),
            name: NSWindow.didResizeNotification, object: panel)
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification, object: panel)

        panel.orderFrontRegardless()
        panel.refreshShadow()
        agents.refreshIfNeeded(agents.profiles(for: config))
        usage.onChange = { [weak self] report, reason in self?.usageChanged(report, reason: reason) }
        usage.start()
    }

    /// Footer (both windows) and pill ring (the 5-hour one), DESIGN §9.7.
    private func usageChanged(_ report: UsageReport?, reason: String?) {
        expandedView.setUsageVisible(usage.isActive)
        expandedView.usageBar.show(report, reason: reason)
        pillView.setUsage(report?.short)
    }

    private var focusTarget: NSView? { session?.focusView ?? placeholderField }

    /// After the hotkey recorder closes over the expanded panel, give the terminal key back.
    private func refocusIfExpanded() {
        guard state == .expanded, !isAnimating else { return }
        panel.makeKeyAndOrderFront(nil)
        if let focusTarget { panel.makeFirstResponder(focusTarget) }
    }

    /// After Restart Agent swaps the terminal view, keep typing going to the new one.
    private func refocusAfterRestart() {
        guard state == .expanded, let focusTarget else { return }
        panel.makeFirstResponder(focusTarget)
    }

    // MARK: - Expand / collapse (DESIGN §6.1, §7.7)

    /// `focus: false` (an auto-open with "Focus the Panel" off, DESIGN §7.15) shows the
    /// panel without taking the keyboard; clicking into it (or the hotkey) focuses it.
    func expand(focus: Bool = true) {
        guard state == .collapsed, !isAnimating else { return }
        isAnimating = true
        state = .expanded
        autoOpenedFor = nil
        usage.refresh(.event)

        pillFrame = panel.frame
        anchor = Self.anchor(for: pillFrame)
        let screen = Self.screen(for: pillFrame)
        // A saved size larger than this screen shrinks to fit (while hidden, before animating).
        let area = screen.visibleFrame.insetBy(dx: Self.clampInset, dy: Self.clampInset)
        let fitted = NSSize(width: max(min(expandedSize.width, area.width), ExpandedView.minSize.width),
                            height: max(min(expandedSize.height, area.height), ExpandedView.minSize.height))
        if expandedView.frame.size != fitted {
            expandedView.setFrameSize(fitted)
        }
        let target = Self.clamp(expandedFrame(fromPill: pillFrame), in: screen)

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
            // Resizable only once fully grown, so an edge drag can't fight the animation.
            // (contentMinSize limits user resizes only; code-driven frames ignore it.)
            panel.setResizable(true)
            panel.contentMinSize = ExpandedView.minSize
            panel.refreshShadow()
            if let focusTarget { panel.makeFirstResponder(focusTarget) }  // ready for when it's key
            if focus {
                panel.makeKeyAndOrderFront(nil)
                // Auto-opened: the guard starts when the panel actually takes the keyboard.
                if autoOpenedFor != nil { panel.ignoreKeys(for: Self.autoOpenKeyGuard) }
            } else {
                panel.orderFrontRegardless()
            }
            fade(expandedView, to: 1) { [weak self] in
                guard let self else { return }
                panel.refreshShadow()
                // Unfocused, a click in the user's own app would collapse it at once; the
                // monitor starts when the panel first becomes key instead.
                if panel.isKeyWindow { installClickOutsideMonitor() }
                finishAnimation()
                // The status moved on while it was still opening: a waiting open collapses
                // if the user already answered, and is disarmed by anything else.
                if autoOpenedFor == .waiting, let status = session?.status, status != .waiting {
                    autoOpenedFor = nil
                    if status == .working { collapse() }
                }
            }
        }
    }

    func collapse() {
        guard state == .expanded, !isAnimating, !panel.inLiveResize else { return }
        isAnimating = true
        state = .collapsed
        autoOpenedFor = nil
        removeClickOutsideMonitor()
        panel.setResizable(false)

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
            glass.cornerRadius = pillCornerRadius
            panel.setTitledChrome(false)  // also refreshes the shadow
            pillView.isHidden = false
            fade(pillView, to: 1) { [weak self] in
                self?.panel.refreshShadow()
                self?.finishAnimation()
            }
        }
    }

    // MARK: - Agent status and auto-open (DESIGN §9.6, §7.15)

    private func statusChanged(_ status: AgentStatus) {
        pillView.setStatus(status)  // only the pill shows status; the menu bar icon never changes
        if pendingAutoOpen != status { pendingAutoOpen = nil }
        // A waiting auto-open collapses only on the first status after it, and only if
        // that's "working" (the user answered). Anything else (e.g. a denied prompt ending
        // the turn) disarms it, so a later prompt never collapses the panel.
        let answered = autoOpenedFor == .waiting && status == .working
        if status != .waiting, autoOpenedFor == .waiting { autoOpenedFor = nil }
        switch status {
        case .working:
            // Not after a "done" auto-open: the user is typing the next prompt in the panel.
            if answered, state == .expanded, !isAnimating { collapse() }
        case .waiting:
            if config.autoOpenOnInput { autoOpen(for: .waiting) } else { appLog("auto-open: off for input") }
        case .done:
            usage.refresh(.event)  // a turn just used some
            if state == .expanded, panel.isKeyWindow {
                session?.markDoneSeen()  // the user is looking at it
            } else if config.autoOpenOnDone {
                autoOpen(for: .done)
            } else {
                appLog("auto-open: off for done")
            }
        case .idle:
            break
        }
    }

    /// "done" goes back to idle whenever the panel takes the keyboard: expand, the hotkey,
    /// an auto-open, or a click into it.
    @objc private func panelDidBecomeKey(_ notification: Notification) {
        session?.markDoneSeen()
        // During an expand the fade completion installs it; this covers an unfocused
        // auto-open that the user clicks into later.
        if state == .expanded, !isAnimating { installClickOutsideMonitor() }  // idempotent
    }

    /// Retries an auto-open that had to wait, if the agent is still in that status.
    private func retryPendingAutoOpen() {
        guard let reason = pendingAutoOpen else { return }
        pendingAutoOpen = nil
        if session?.status == reason { autoOpen(for: reason) }
    }

    /// Expands (collapsed) or refocuses (expanded, not key), briefly ignoring keys so
    /// typing meant for the previous app doesn't reach the agent.
    private func autoOpen(for reason: AgentStatus) {
        // Also not during a pill drag or with any button down: the drag would keep moving
        // the now-expanded window and save its frame as the pill's.
        guard !isAnimating, !panel.inLiveResize, NSEvent.pressedMouseButtons == 0 else {
            appLog("auto-open: waiting (animating, resizing or mouse down)")
            pendingAutoOpen = reason
            if NSEvent.pressedMouseButtons != 0 {
                // No event marks the end of a press elsewhere; check again shortly.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.retryPendingAutoOpen()
                }
            }
            return
        }
        if hotKeys?.isRecording == true {
            appLog("auto-open: skipped (recording a hotkey)")
            return
        }
        appLog("auto-open: \(state == .collapsed ? "expanding" : panel.isKeyWindow ? "already focused" : "focusing")")
        switch state {
        case .collapsed:
            expand(focus: config.autoOpenFocus)
            autoOpenedFor = reason  // the key guard starts when the expand makes it key
        case .expanded where !panel.isKeyWindow:
            guard config.autoOpenFocus else {
                panel.orderFrontRegardless()  // already showing; leave the keyboard alone
                break
            }
            panel.ignoreKeys(for: Self.autoOpenKeyGuard)
            panel.makeKeyAndOrderFront(nil)
            if let focusTarget { panel.makeFirstResponder(focusTarget) }
        case .expanded:
            break
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
        defer { retryPendingAutoOpen() }
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

    /// Place the ExpandedView at the anchor corner of the container and keep it pinned
    /// there, at its own size, while the window grows or shrinks.
    private func pinExpandedView(containerSize: NSSize) {
        let size = expandedView.frame.size
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
                pillFrame = NSRect(origin: Self.defaultPillOrigin(on: mouseScreen, size: pillSize), size: pillSize)
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

    // MARK: - Resizing (DESIGN §7.13, §7.14)

    /// During a user resize the ExpandedView is pinned top-left (the header stays put) and
    /// follows the window at most every `liveResizeInterval`, so the terminal reflows live
    /// without a resize (and agent redraw) on every mouse move.
    @objc private func liveResizeWillStart(_ notification: Notification) {
        guard state == .expanded, !isAnimating else { return }
        expandedView.autoresizingMask = [.maxXMargin, .minYMargin]
    }

    @objc private func panelDidResize(_ notification: Notification) {
        guard state == .expanded, !isAnimating else { return }
        guard panel.inLiveResize else {
            // Resized some other way (e.g. a window-tiling command): apply it at once.
            if expandedView.frame.size != glass.contentView.bounds.size { applyUserResize() }
            return
        }
        guard !liveResizeUpdatePending else { return }
        liveResizeUpdatePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.liveResizeInterval) { [weak self] in
            guard let self else { return }
            liveResizeUpdatePending = false
            guard state == .expanded, panel.inLiveResize else { return }
            let size = glass.contentView.bounds.size
            if expandedView.frame.size != size {
                expandedView.frame = NSRect(origin: .zero, size: size)
            }
        }
    }

    @objc private func liveResizeDidEnd(_ notification: Notification) {
        guard state == .expanded, !isAnimating else { return }
        applyUserResize()
    }

    /// Final resize of the ExpandedView (and so the terminal) to the new size; save it.
    private func applyUserResize() {
        let frame = Self.clamp(panel.frame, in: Self.screen(for: panel.frame))
        if frame != panel.frame {
            panel.setFrame(frame, display: true)
        }
        let size = glass.contentView.bounds.size
        expandedSize = size
        expandedView.setFrameSize(size)
        pinExpandedView(containerSize: size)
        panel.refreshShadow()
        pillFrame = pillFrame(fromExpanded: panel.frame)
        saveState()
        appLog("expanded size \(Int(size.width))x\(Int(size.height))")
        retryPendingAutoOpen()
    }

    /// Applies a pill size preset. Collapsed, the pill grows or shrinks from its nearest
    /// screen corner; expanded, the next collapse uses it.
    private func setPillDiameter(_ diameter: CGFloat) {
        guard diameter != pillDiameter, !isAnimating else { return }
        pillDiameter = diameter
        pillView.setDiameter(diameter)
        if state == .collapsed {
            let corner = Self.anchor(for: pillFrame)
            let x = corner.right ? pillFrame.maxX - diameter : pillFrame.minX
            let y = corner.top ? pillFrame.maxY - diameter : pillFrame.minY
            let frame = Self.clamp(NSRect(x: x, y: y, width: diameter, height: diameter),
                                   in: Self.screen(for: pillFrame))
            panel.setFrame(frame, display: true)
            glass.cornerRadius = pillCornerRadius
            panel.refreshShadow()
            pillFrame = frame
        } else {
            pillFrame = pillFrame(fromExpanded: panel.frame)  // saved origin matches the new size
        }
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
        PanelState(pillOrigin: SavedPoint(x: pillFrame.minX, y: pillFrame.minY),
                   pillDiameter: pillDiameter,
                   expandedSize: SavedSize(width: expandedSize.width, height: expandedSize.height),
                   recentDirectories: recentDirectories).save()
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

        let agentItem = NSMenuItem(title: "Agent", action: nil, keyEquivalent: "")
        agentItem.submenu = makeAgentMenu()
        agentItem.isEnabled = session != nil
        menu.addItem(agentItem)

        let directoryItem = NSMenuItem(title: "Working Directory", action: nil, keyEquivalent: "")
        directoryItem.submenu = makeDirectoryMenu()
        directoryItem.isEnabled = session != nil
        menu.addItem(directoryItem)

        // One line for both: "Set Hotkey (⌃⌥Space)", or just "Set Hotkey" when none is registered.
        var setTitle = "Set Hotkey"
        if let combo = hotKeys?.current { setTitle += " (\(combo.displayString))" }
        let pillSizeItem = NSMenuItem(title: "Pill Size", action: nil, keyEquivalent: "")
        let pillSizeMenu = NSMenu()
        pillSizeMenu.autoenablesItems = false
        for preset in Self.pillPresets {
            let item = NSMenuItem(title: preset.name, action: #selector(selectPillSize(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(preset.diameter)
            item.state = preset.diameter == pillDiameter ? .on : .off
            item.isEnabled = !isAnimating
            pillSizeMenu.addItem(item)
        }
        pillSizeItem.submenu = pillSizeMenu
        menu.addItem(pillSizeItem)

        let autoOpenItem = NSMenuItem(title: "Auto-Open", action: nil, keyEquivalent: "")
        let autoOpenMenu = NSMenu()
        autoOpenMenu.autoenablesItems = false
        for (title, key, on) in [("When Input Is Needed", "autoOpenOnInput", config.autoOpenOnInput),
                                 ("When Done", "autoOpenOnDone", config.autoOpenOnDone)] {
            let item = NSMenuItem(title: title, action: #selector(toggleAutoOpen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
            item.state = on ? .on : .off
            item.isEnabled = session != nil && config.statusHooks
            autoOpenMenu.addItem(item)
        }
        autoOpenMenu.addItem(.separator())
        let focusItem = NSMenuItem(title: "Focus the Panel", action: #selector(toggleAutoOpen(_:)), keyEquivalent: "")
        focusItem.target = self
        focusItem.representedObject = "autoOpenFocus"
        focusItem.state = config.autoOpenFocus ? .on : .off
        focusItem.isEnabled = session != nil && config.statusHooks
        autoOpenMenu.addItem(focusItem)
        autoOpenItem.submenu = autoOpenMenu
        menu.addItem(autoOpenItem)

        let usageItem = NSMenuItem(title: "Show Usage", action: #selector(toggleShowUsage), keyEquivalent: "")
        usageItem.target = self
        usageItem.state = config.showUsage ? .on : .off
        menu.addItem(usageItem)

        let setHotKey = NSMenuItem(title: setTitle, action: #selector(setHotKey), keyEquivalent: "")
        setHotKey.target = self
        setHotKey.isEnabled = hotKeys?.canRecord == true
        menu.addItem(setHotKey)

        menu.addItem(.separator())

        let restart = NSMenuItem(title: "Restart Agent", action: #selector(restartAgent), keyEquivalent: "")
        restart.target = self
        restart.isEnabled = session != nil
        menu.addItem(restart)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Poppy", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }

    /// One item per profile, with its logo; the running one is checked (DESIGN §9.5).
    private func makeAgentMenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        menuAgents = agents.profiles(for: config)
        agents.refreshIfNeeded(menuAgents)
        for (index, profile) in menuAgents.enumerated() {
            let installed = agents.isInstalled(profile) ?? true
            let title = installed ? profile.name : "\(profile.name) (not installed)"
            let item = NSMenuItem(title: title, action: #selector(selectAgent(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.image = HarnessLogo.image(for: Harness(command: profile.command), points: 16)
            let current = AgentCatalog.same(profile.command, config.command)
            item.state = current ? .on : .off
            item.isEnabled = installed || current
            submenu.addItem(item)
        }
        return submenu
    }

    /// Recent directories (the current one checked), then Choose Folder… (DESIGN §9.8).
    private func makeDirectoryMenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        var paths = [workingDirectory] + recentDirectories.filter { $0 != workingDirectory }
        paths = paths.filter { Self.isDirectory($0) }
        for path in paths.prefix(Self.maxRecentDirectories) {
            let item = NSMenuItem(title: Config.abbreviate(path), action: #selector(selectDirectory(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = path
            item.state = path == workingDirectory ? .on : .off
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let choose = NSMenuItem(title: "Choose Folder…", action: #selector(chooseFolder), keyEquivalent: "")
        choose.target = self
        submenu.addItem(choose)
        return submenu
    }

    @objc private func selectDirectory(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        openDirectory(path, show: false)
    }

    /// The system folder picker. Poppy is activated only while it's open (it can't take
    /// keyboard input otherwise), then the previous app is activated again (DESIGN §9.8).
    @objc private func chooseFolder() {
        let previous = NSWorkspace.shared.frontmostApplication
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.canCreateDirectories = true
        picker.prompt = "Open"
        picker.message = "Choose the agent's working directory"
        picker.directoryURL = URL(fileURLWithPath: workingDirectory)
        // Over a fullscreen app, open on its Space instead of switching away from it.
        picker.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])
        picker.level = .statusBar + 1  // above the expanded panel
        NSApp.activate()
        picker.begin { [weak self] response in
            MainActor.assumeIsolated {
                if let previous, previous != NSRunningApplication.current {
                    NSApp.yieldActivation(to: previous)
                    previous.activate()
                }
                guard response == .OK, let url = picker.url else { return }
                self?.openDirectory(url.path, show: true)
            }
        }
    }

    /// A directory from the menu or the folder picker (DESIGN §9.8).
    func openDirectory(_ path: String, show: Bool) {
        apply(LaunchRequest(directory: path, show: show))
    }

    /// Applies a request from the `poppy` command or a folder handed to Poppy (DESIGN §9.9):
    /// settings first, then the agent and directory with at most one restart, then (if
    /// `show`) expands and focuses the panel. Everything is saved like the menu's changes.
    func apply(_ request: LaunchRequest) {
        // Only the presets, whoever wrote the request (DESIGN §7.14).
        if let diameter = request.pillDiameter.map({ CGFloat($0) }),
           Self.pillPresets.contains(where: { $0.diameter == diameter }) {
            setPillDiameter(diameter)
        }
        for (key, value) in [("autoOpenOnInput", request.autoOpenOnInput), ("autoOpenOnDone", request.autoOpenOnDone),
                             ("autoOpenFocus", request.autoOpenFocus)] {
            if let value { setAutoOpen(key, value) }
        }
        if let showUsage = request.showUsage, showUsage != config.showUsage {
            toggleShowUsage()
        }

        var directory = workingDirectory
        if let requested = request.directory {
            let path = Config.normalize(requested)
            if Self.isDirectory(path) {
                directory = path
                recentDirectories = Array(([path] + recentDirectories.filter { $0 != path })
                    .prefix(Self.maxRecentDirectories))
                saveState()
            } else {
                appLog("working directory \(path) is not a directory; ignored")
            }
        }
        changeAgent(command: request.command ?? config.command, directory: directory)

        guard request.show, !isAnimating else { return }
        if state == .collapsed {
            expand()
        } else {
            panel.makeKeyAndOrderFront(nil)
            if let focusTarget { panel.makeFirstResponder(focusTarget) }
        }
    }

    /// Runs `command` in `directory`: one restart if either changed, none otherwise; both
    /// are saved (`command`, `cwd`) for the next launch (DESIGN §9.5, §9.8).
    private func changeAgent(command: String, directory: String) {
        let commandChanged = !AgentCatalog.same(command, config.command)
        let directoryChanged = directory != workingDirectory
        guard commandChanged || directoryChanged, let session else { return }
        if commandChanged {
            appLog("agent: \(command)")
            config.command = command
            pillView.update(harness: Harness(command: command), title: config.pillTitle)
            _ = Config.saveValue(command, forKey: "command")
        }
        if directoryChanged {
            appLog("working directory: \(directory)")
            // Keep the one being left in the recents too (e.g. the one Poppy launched in).
            if !recentDirectories.contains(workingDirectory) {
                recentDirectories = Array(([directory, workingDirectory]
                    + recentDirectories.filter { $0 != directory }).prefix(Self.maxRecentDirectories))
                saveState()
            }
            workingDirectory = directory
            config.cwd = Config.abbreviate(directory)
            expandedView.header.setTitle(headerTitle)
            expandedView.header.setPath(config.cwd)
            _ = Config.saveValue(config.cwd, forKey: "cwd")
        }
        session.switchTo(command: config.command, directory: config.cwd)
        if commandChanged { usage.setCommand(command) }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    @objc private func selectAgent(_ sender: NSMenuItem) {
        guard menuAgents.indices.contains(sender.tag) else { return }
        switchAgent(to: menuAgents[sender.tag])
    }

    /// Starts `profile` in a fresh terminal, updates the logo, and saves it as the command
    /// for the next launch (DESIGN §9.5). Picking the running agent does nothing.
    private func switchAgent(to profile: AgentProfile) {
        guard session != nil, !AgentCatalog.same(profile.command, config.command) else { return }
        appLog("switching agent to \(profile.name)")
        changeAgent(command: profile.command, directory: workingDirectory)
    }

    @objc private func toggleAutoOpen(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        setAutoOpen(key, sender.state != .on)
    }

    /// Sets and saves one Auto-Open flag (DESIGN §7.15).
    private func setAutoOpen(_ key: String, _ on: Bool) {
        switch key {
        case "autoOpenOnInput": config.autoOpenOnInput = on
        case "autoOpenOnDone": config.autoOpenOnDone = on
        case "autoOpenFocus": config.autoOpenFocus = on
        default: return
        }
        appLog("auto-open: \(key) = \(on)")
        if !Config.saveValue(on, forKey: key) {
            appLog("auto-open: \(key) not saved; it applies until Poppy quits")
        }
    }

    @objc private func toggleShowUsage() {
        config.showUsage.toggle()
        appLog("usage: showUsage = \(config.showUsage)")
        usage.setEnabled(config.showUsage)
        if !Config.saveValue(config.showUsage, forKey: "showUsage") {
            appLog("usage: showUsage not saved; it applies until Poppy quits")
        }
    }

    @objc private func selectPillSize(_ sender: NSMenuItem) {
        setPillDiameter(CGFloat(sender.tag))
    }

    @objc private func setHotKey() {
        hotKeys?.beginRecording()
    }

    @objc private func restartAgent() {
        session?.restart()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Frame math (DESIGN §7.3–7.6)

    private func expandedFrame(fromPill pill: NSRect) -> NSRect {
        let size = expandedView.frame.size
        let x = anchor.right ? pill.maxX - size.width : pill.minX
        let y = anchor.top ? pill.maxY - size.height : pill.minY
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    private func pillFrame(fromExpanded expanded: NSRect) -> NSRect {
        let size = pillSize
        let x = anchor.right ? expanded.maxX - size.width : expanded.minX
        let y = anchor.top ? expanded.maxY - size.height : expanded.minY
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    private static func anchor(for pill: NSRect) -> Anchor {
        let visible = screen(for: pill).visibleFrame
        return Anchor(right: pill.midX > visible.midX, top: pill.midY > visible.midY)
    }

    /// Saved origin if it's still on some screen (clamped), else the default position.
    private static func initialPillFrame(from state: PanelState, size pillSize: NSSize) -> NSRect {
        if let saved = state.pillOrigin {
            let rect = NSRect(x: saved.x, y: saved.y, width: pillSize.width, height: pillSize.height)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) {
                return clamp(rect, in: screen(for: rect))
            }
        }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        return NSRect(origin: defaultPillOrigin(on: screen, size: pillSize), size: pillSize)
    }

    static func defaultPillOrigin(on screen: NSScreen, size pillSize: NSSize) -> NSPoint {
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
