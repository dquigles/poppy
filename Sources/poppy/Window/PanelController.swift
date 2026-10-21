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

    /// Pill diameter presets, on the settings page (DESIGN §7.14).
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
    /// Recent working directories, newest first (DESIGN §9.8).
    private var recentDirectories: [String]
    static let maxRecentDirectories = 8
    /// The pill's sessions in sidebar order, and the one shown (DESIGN §7.17). Never empty.
    private var sessions: [TerminalSession] = []
    private var selectedIndex = 0
    private var session: TerminalSession { sessions[selectedIndex] }
    /// The selected session's folder (absolute, DESIGN §9.8).
    private var workingDirectory: String { session.workingDirectory }
    /// The sidebar shows only logos, or names at `sidebarWidth` (per pill, DESIGN §7.17).
    private var sidebarRail = false
    private var sidebarWidth = SidebarView.width
    /// A sidebar drag's terminal reflow is coalesced, like a live resize (DESIGN §7.13).
    private var sidebarUpdatePending = false
    /// Run once the current expand has finished (Rename Session… from the pill).
    private var afterExpand: (() -> Void)?
    /// The session whose name is being edited.
    private var renamingSession: UUID?

    static func directoryName(_ path: String) -> String {
        let short = Config.abbreviate(path)
        return short == "~" || short == "/" ? short : (path as NSString).lastPathComponent
    }
    /// The profiles in the menu as last built; menu items refer to them by `tag`.
    private var menuAgents: [AgentProfile] = []
    private let glass: GlassBackgroundView
    private let pillView: PillView
    private let expandedView: ExpandedView

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
    /// The session that auto-opened it; only that one's answer collapses it again.
    private var autoOpenedSession: UUID?
    /// An auto-open that had to wait (animating, resizing, a mouse button down); retried
    /// when that ends if the status is still the same (DESIGN §7.15).
    private var pendingAutoOpen: AgentStatus?
    private var pendingAutoOpenSession: UUID?
    static let autoOpenKeyGuard: TimeInterval = 0.4
    /// The system hid the panel (e.g. a Space swipe) and it animates in when shown again
    /// (DESIGN §7.16). Meanwhile the glass is transparent and the shadow is off.
    private var awaitingReveal = false
    /// Re-checks visibility while waiting, in case a "visible" notification is missed.
    private var revealWatchdog: Timer?
    /// Bumped by every arm and reveal; a reveal's completion acts only if it's still current.
    private var revealGeneration = 0
    /// While the glass scales in, the shadow (which draws the rim) is recomputed every
    /// frame so the rim follows the glass; stopped at `revealShadowUntil`.
    private var revealShadowLink: CADisplayLink?
    private var revealShadowUntil: CFTimeInterval = 0
    static let revealScale: CGFloat = 0.86
    static let revealFadeDuration: TimeInterval = 0.18
    static let revealWatchdogInterval: TimeInterval = 0.5
    /// The watchdog gives up after this many ticks (screen lock, display sleep).
    static let revealWatchdogMaxTicks = 20
    private var revealWatchdogTicks = 0
    /// The settings page is shown in place of the terminal (DESIGN §7.9).
    private(set) var settingsShown = false
    /// Settings… from the pill: the expand is still running (auto-opens leave the page alone).
    private var openingSettings = false
    /// Set by AppDelegate; the settings page shows and records the hotkey through it (DESIGN §7.9).
    weak var hotKeys: HotKeyManager? {
        didSet { hotKeys?.onComboChanged = { [weak self] in self?.refreshSettings() } }
    }

    /// `config`'s `command` and `cwd` are the first session's, and the defaults for new ones.
    init(config: Config) {
        self.config = config
        agents = AgentCatalog(launchCommand: config.command)
        usage = UsageMonitor(command: config.command, enabled: config.showUsage)
        let saved = PanelState.load()
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
        expandedView = ExpandedView(title: "", size: expandedSize)
        expandedView.isHidden = true
        expandedView.alphaValue = 0
        super.init()

        pillView.controller = self
        expandedView.header.controller = self
        expandedView.usageBar.controller = self
        glass.contentView.addSubview(pillView)
        glass.contentView.addSubview(expandedView)

        let first = makeSession(command: config.command, directory: Config.normalize(config.resolvedWorkingDirectory))
        sessions = [first]
        first.attach(to: expandedView.contentHost)
        wireSessionControls()

        panel.contentView = glass
        panel.allowsKey = false
        panel.isShowingSettings = { [weak self] in self?.settingsShown == true }
        panel.onCloseSettings = { [weak self] in self?.closeSettings() }
        panel.onToggleSettings = { [weak self] in self?.toggleSettings() }
        let settings = expandedView.settingsView
        settings.onPillPreset = { [weak self] index in
            guard let self, Self.pillPresets.indices.contains(index) else { return }
            setPillDiameter(Self.pillPresets[index].diameter)
            refreshSettings()
        }
        settings.onAgent = { [weak self] index in
            guard let self, menuAgents.indices.contains(index) else { return }
            switchAgent(to: menuAgents[index])
        }
        settings.onDirectory = { [weak self] path in self?.openDirectory(path, show: false) }
        settings.onChooseFolder = { [weak self] in
            self?.pickFolder { [weak self] path in self?.openDirectory(path, show: false) }
        }
        settings.onStatusHooks = { [weak self] on in
            self?.setStatusHooks(on)
            self?.refreshSettings()
        }
        settings.onEditConfig = { NSWorkspace.shared.open(ConfigPaths.config) }
        settings.hotkeyField.onBegin = { [weak self] in self?.hotKeys?.beginRecording() ?? false }
        settings.hotkeyField.onRecord = { [weak self] combo in
            self?.hotKeys?.record(combo) ?? .failed("Hotkeys are unavailable.")
        }
        settings.hotkeyField.onEnd = { [weak self] in self?.hotKeys?.endRecording() }
        expandedView.header.onDone = { [weak self] in self?.closeSettings() }
        settings.onAutoOpen = { [weak self] key, on in
            self?.setAutoOpen(key, on)
            self?.refreshSettings()
        }
        settings.onShowUsage = { [weak self] on in
            self?.setShowUsage(on)
            self?.refreshSettings()
        }

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
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelOcclusionDidChange),
            name: NSWindow.didChangeOcclusionStateNotification, object: panel)

        selectionChanged()
        panel.orderFrontRegardless()
        panel.refreshShadow()
        agents.refreshIfNeeded(agents.profiles(for: agentConfig))
        usage.onChange = { [weak self] report, reason in self?.usageChanged(report, reason: reason) }
        usage.start()
    }

    /// Footer (both windows) and pill ring (the 5-hour one; Antigravity's model group), DESIGN §9.7, §9.12.
    private func usageChanged(_ report: UsageReport?, reason: String?) {
        expandedView.setUsageVisible(usage.isActive)
        expandedView.usageBar.show(report, reason: reason)
        pillView.setUsage(report?.ring)
    }

    private var focusTarget: NSView? {
        expandedView.confirmView ?? (settingsShown ? expandedView.settingsView : session.focusView)
    }

    /// Typing goes to the selected terminal again, e.g. after Restart Agent swaps its view,
    /// a rename, or the close confirmation.
    private func refocus() {
        guard state == .expanded, expandedView.confirmView == nil, let focusTarget else { return }
        panel.makeFirstResponder(focusTarget)
    }

    /// `config` with the selected session's command: the agent lists check the running one.
    private var agentConfig: Config {
        var current = config
        current.command = session.command
        return current
    }

    // MARK: - Expand / collapse (DESIGN §6.1, §7.7)

    /// `focus: false` (an auto-open with "Focus the Panel" off, DESIGN §7.15) shows the
    /// panel without taking the keyboard; clicking into it (or the hotkey) focuses it.
    func expand(focus: Bool = true) {
        revealIfArmed()
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
                if autoOpenedFor == .waiting, let opener = sessions.first(where: { $0.id == autoOpenedSession }),
                   opener.status != .waiting {
                    autoOpenedFor = nil
                    if opener.status == .working, opener === session { collapse() }
                }
            }
        }
    }

    func collapse() {
        revealIfArmed()
        guard state == .expanded, !isAnimating, !panel.inLiveResize else { return }
        closeSettings(animated: false, markSeen: false)  // the next expand shows the terminal
        expandedView.confirmView?.end(false)  // a click outside cancels closing a session
        afterExpand = nil
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

    private func statusChanged(_ changed: TerminalSession, _ status: AgentStatus) {
        sessionsChanged()  // only the pill and the rows show status; the menu bar icon never changes
        if pendingAutoOpenSession == changed.id, pendingAutoOpen != status { pendingAutoOpen = nil }
        // A waiting auto-open collapses only on the first status after it, and only if
        // that's "working" (the user answered). Anything else (e.g. a denied prompt ending
        // the turn) disarms it, so a later prompt never collapses the panel. Only the
        // session that opened it counts, and only while it's still the one shown.
        let opener = autoOpenedSession == changed.id
        let answered = opener && autoOpenedFor == .waiting && status == .working && changed === session
        if opener, status != .waiting, autoOpenedFor == .waiting { autoOpenedFor = nil }
        switch status {
        case .working:
            // Not after a "done" auto-open: the user is typing the next prompt in the panel.
            if answered, state == .expanded, !isAnimating { collapse() }
        case .waiting:
            if config.autoOpenOnInput { autoOpen(changed, for: .waiting) } else { appLog("auto-open: off for input") }
        case .done:
            usage.refresh(.event, command: changed.command)  // a turn just used some
            if changed === session, state == .expanded, panel.isKeyWindow, !settingsShown {
                changed.markDoneSeen()  // the user is looking at it
            } else if config.autoOpenOnDone {
                autoOpen(changed, for: .done)
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
        if !settingsShown { session.markDoneSeen() }  // not seen under the settings page
        // During an expand the fade completion installs it; this covers an unfocused
        // auto-open that the user clicks into later.
        if state == .expanded, !isAnimating { installClickOutsideMonitor() }  // idempotent
    }

    /// Retries an auto-open that had to wait, if the agent is still in that status.
    private func retryPendingAutoOpen() {
        guard let reason = pendingAutoOpen else { return }
        pendingAutoOpen = nil
        if let waiting = sessions.first(where: { $0.id == pendingAutoOpenSession }), waiting.status == reason {
            autoOpen(waiting, for: reason)
        }
    }

    /// Expands (collapsed) or refocuses (expanded, not key), briefly ignoring keys so
    /// typing meant for the previous app doesn't reach the agent, and shows `opener`. Not
    /// while the user is busy in this panel with another session: then only its row, the
    /// pill color and the badge change (DESIGN §7.15).
    private func autoOpen(_ opener: TerminalSession, for reason: AgentStatus) {
        // Also not during a pill drag or with any button down: the drag would keep moving
        // the now-expanded window and save its frame as the pill's.
        guard !isAnimating, !panel.inLiveResize, NSEvent.pressedMouseButtons == 0 else {
            appLog("auto-open: waiting (animating, resizing or mouse down)")
            pendingAutoOpen = reason
            pendingAutoOpenSession = opener.id
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
        if expandedView.confirmView != nil || (state == .expanded && panel.isKeyWindow && opener !== session) {
            appLog("auto-open: skipped (busy in another session)")
            return
        }
        // The agent needs the user: the settings page gives way to the terminal (not while
        // Settings… is still opening from the pill). DESIGN §7.15.
        let closesSettings = settingsShown && state == .expanded && !openingSettings
        appLog("auto-open: \(state == .collapsed ? "expanding" : closesSettings ? "closed settings" : panel.isKeyWindow ? "already focused" : "focusing")\(opener === session ? "" : ", selecting \(opener.name)")")
        if let index = sessions.firstIndex(where: { $0 === opener }) { select(index) }
        if closesSettings { closeSettings(markSeen: panel.isKeyWindow) }
        switch state {
        case .collapsed:
            expand(focus: config.autoOpenFocus)
            autoOpenedFor = reason  // the key guard starts when the expand makes it key
            autoOpenedSession = opener.id
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

    // MARK: - Sessions (DESIGN §7.17)

    /// A session with its default name; its agent starts when it's first attached.
    private func makeSession(command: String, directory: String) -> TerminalSession {
        var sessionConfig = config
        sessionConfig.command = command
        sessionConfig.cwd = Config.abbreviate(directory)
        let new = TerminalSession(config: sessionConfig)
        new.defaultName = uniqueName(Self.directoryName(new.workingDirectory), for: new)
        new.onViewReplaced = { [weak self, weak new] in
            if let self, new === session { refocus() }
        }
        new.onStatusChange = { [weak self, weak new] status in
            if let self, let new { statusChanged(new, status) }
        }
        new.onModelChange = { [weak self, weak new] model in
            if let self, new === session { usage.setAgentModel(model) }
        }
        return new
    }

    /// `base`, or "base 2", "base 3"… (the lowest free number) if another session has it.
    private func uniqueName(_ base: String, for named: TerminalSession) -> String {
        let taken = Set(sessions.filter { $0 !== named }.map(\.name))
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    private func wireSessionControls() {
        let sidebar = expandedView.sidebar
        sidebar.onSelect = { [weak self] index in self?.sessionClicked(index) }
        sidebar.onClose = { [weak self] index in
            guard let self, sessions.indices.contains(index) else { return }
            closeSession(sessions[index])
        }
        sidebar.onRestart = { [weak self] index in
            guard let self, sessions.indices.contains(index) else { return }
            sessions[index].restart()
        }
        sidebar.onRenameRequest = { [weak self] index in self?.beginRename(index) }
        sidebar.onRenamed = { [weak self] _, text in self?.renameEnded(text) }
        sidebar.onNew = { [weak self] in self?.newSession() }
        sidebar.onNewMenu = { [weak self] view in self?.showNewSessionMenu(from: view) }
        sidebar.onToggleRail = { [weak self] in self?.toggleSidebarRail() }
        sidebar.onResize = { [weak self] width, ended in self?.sidebarDragged(to: width, ended: ended) }
        panel.onNewSession = { [weak self] in
            guard let self, !sessionKeysBlocked else { return }
            newSession()
        }
        panel.onCloseSession = { [weak self] in
            guard let self, !sessionKeysBlocked, expandedView.confirmView == nil else { return }
            closeSession(session)
        }
        panel.onSelectSession = { [weak self] index in
            guard let self, !sessionKeysBlocked, sessions.indices.contains(index) else { return }
            select(index)
        }
    }

    /// ⌘T, ⌘W and ⌘1–9 don't apply over the settings page. During the close question,
    /// ⌘T and ⌘1–9 cancel it (moving away from the session); ⌘W is ignored.
    private var sessionKeysBlocked: Bool {
        settingsShown || isAnimating
    }

    /// The last session stays until pills can go away (M25).
    private var canCloseSession: Bool { sessions.count > 1 }

    /// Ends every agent (quitting, DESIGN §4).
    func terminateAll() {
        sessions.forEach { $0.terminateChild() }
    }

    /// ＋, ⌘T, New Session: a new session in this pill, selected and shown; by default with
    /// the selected one's agent and folder.
    private func newSession(command: String? = nil, directory: String? = nil) {
        let new = makeSession(command: command ?? session.command, directory: directory ?? workingDirectory)
        sessions.append(new)
        appLog("session: new \"\(new.name)\" (\(sessions.count) sessions)")
        sessionsChanged()  // the sidebar first, so the new agent starts at its final width
        select(sessions.count - 1)  // starts its agent
        guard !isAnimating else { return }  // an expand in progress shows it anyway
        closeSettings()
        if state == .collapsed {
            expand()
        } else {
            panel.makeKeyAndOrderFront(nil)
            if let focusTarget { panel.makeFirstResponder(focusTarget) }
        }
    }

    /// Shows session `index` in the terminal area; the others keep running unseen. Looking
    /// at it (the panel key) marks its "done" seen.
    private func select(_ index: Int) {
        guard sessions.indices.contains(index), index != selectedIndex else { return }
        expandedView.confirmView?.end(false)  // moving to another session cancels the question
        session.detach()
        selectedIndex = index
        session.attach(to: expandedView.contentHost)
        appLog("session: selected \"\(session.name)\"")
        selectionChanged()
        expandedView.sidebar.reveal(index)
        guard state == .expanded else { return }
        if !settingsShown, expandedView.confirmView == nil, let view = session.focusView { panel.makeFirstResponder(view) }
        if panel.isKeyWindow, !settingsShown { session.markDoneSeen() }
    }

    /// A row click: the user wants that agent, so the settings page gives way.
    private func sessionClicked(_ index: Int) {
        guard !isAnimating else { return }
        closeSettings()
        select(index)
    }

    /// The pill's logo, the header and the usage meter follow the selected session.
    private func selectionChanged() {
        pillView.update(harness: Harness(command: session.command), title: agentConfig.pillTitle)
        expandedView.header.setPath(Config.abbreviate(workingDirectory))
        usage.setCommand(session.command)
        usage.setAgentModel(session.agentModel)
        if settingsShown { refreshSettings() }
        sessionsChanged()
    }

    /// The pill's color (the most urgent status), badge and label, the sidebar (shown with
    /// 2+ sessions) and the header title (DESIGN §7.11, §7.17).
    private func sessionsChanged() {
        let multiple = sessions.count > 1
        let urgent = sessions.map(\.status).max { Self.urgency($0) < Self.urgency($1) } ?? .idle
        let needYou = sessions.filter { $0.status == .waiting || $0.status == .done }.count
        pillView.setStatus(urgent, sessionName: multiple ? session.name : nil, selected: session.status, needYou: needYou)
        expandedView.header.setTitle(session.name)
        expandedView.sidebar.isRail = sidebarRail
        // A panel resized smaller since the drag still leaves the terminal its room.
        let names = min(sidebarWidth, max(SidebarView.minWidth, expandedView.bounds.width - Self.minTerminalWidth))
        expandedView.setSidebarWidth(multiple ? (sidebarRail ? SidebarView.railWidth : names) : 0)
        expandedView.sidebar.update(sessions.map { each in
            SidebarItem(name: each.name, harness: Harness(command: each.command), status: each.status,
                        label: Self.label(for: each))
        }, selected: selectedIndex, canClose: canCloseSession)
    }

    /// waiting > working > done (unseen; seen is idle) > idle.
    private static func urgency(_ status: AgentStatus) -> Int {
        switch status {
        case .idle: 0
        case .done: 1
        case .working: 2
        case .waiting: 3
        }
    }

    /// "api 2 — Claude Code (working)", for a row's tooltip and accessibility label.
    private static func label(for session: TerminalSession) -> String {
        let harness = Harness(command: session.command)
        var current = Config()
        current.command = session.command
        let agent = harness == .other ? current.pillTitle : harness.displayName
        return "\(session.name) — \(agent)" + PillView.statusSuffix(session.status)
    }

    private func toggleSidebarRail() {
        sidebarRail.toggle()
        appLog("sidebar: \(sidebarRail ? "logos only" : "names")")
        sessionsChanged()
    }

    /// The sidebar's edge dragged to `proposed`: narrower than `snapWidth` it closes to the
    /// rail, otherwise it shows names at that width (kept within its range, and leaving the
    /// terminal at least `minTerminalWidth`). The terminal follows at most every
    /// `liveResizeInterval` while dragging, and exactly on mouse-up.
    private func sidebarDragged(to proposed: CGFloat, ended: Bool) {
        let room = expandedView.bounds.width - Self.minTerminalWidth
        if proposed < SidebarView.snapWidth {
            sidebarRail = true
        } else {
            sidebarRail = false
            sidebarWidth = max(SidebarView.minWidth, min(proposed, SidebarView.maxWidth, room)).rounded()
        }
        if ended {
            sessionsChanged()
            appLog("sidebar: \(sidebarRail ? "logos only" : "names, \(Int(sidebarWidth)) pt")")
            return
        }
        guard !sidebarUpdatePending else { return }
        sidebarUpdatePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.liveResizeInterval) { [weak self] in
            self?.sidebarUpdatePending = false
            self?.sessionsChanged()
        }
    }

    /// What a wide sidebar must leave for the terminal.
    static let minTerminalWidth: CGFloat = 240

    /// × , ⌘W, Close Session: ends the agent and removes the row. A working or waiting
    /// agent asks first, over the panel (expanding it if needed).
    private func closeSession(_ closing: TerminalSession) {
        guard canCloseSession, !isAnimating, expandedView.confirmView == nil,
              sessions.contains(where: { $0 === closing }) else { return }
        guard closing.status == .working || closing.status == .waiting else {
            removeSession(closing)
            return
        }
        appLog("session: asking before closing \"\(closing.name)\"")
        closeSettings(animated: false, markSeen: false)
        // The question shows a still image of the terminal, faded; the live one is out
        // from under it (SwiftTerm follows the mouse window-wide) and put back afterwards
        // (same size, no reflow), or replaced by the next session.
        if closing !== session, let index = sessions.firstIndex(where: { $0 === closing }) { select(index) }
        let still = session.focusView.flatMap(Self.stillImage)
        session.detach()
        let what = closing.status == .waiting ? "is waiting for your answer" : "is still working"
        expandedView.showConfirm(terminal: still, icon: HarnessLogo.image(for: Harness(command: closing.command), points: 40),
                                 tint: closing.status.tint,
                                 title: "Close “\(closing.name)”?",
                                 message: "Its agent \(what). Closing the session ends it.",
                                 onClose: { [weak self, weak closing] in
                                     if let closing { self?.removeSession(closing) }
                                     self?.confirmEnded()
                                 },
                                 onCancel: { [weak self] in self?.confirmEnded() })
        if state == .collapsed {
            expand()
        } else {
            panel.makeKeyAndOrderFront(nil)
            if let focusTarget { panel.makeFirstResponder(focusTarget) }
        }
    }

    /// What `view` shows now, as an image.
    private static func stillImage(of view: NSView) -> NSImage? {
        guard view.bounds.width > 0, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// The selected terminal back in the panel, with the keyboard.
    private func confirmEnded() {
        if !session.isShown { session.attach(to: expandedView.contentHost) }
        refocus()
    }

    /// Ends the agent and removes the session; the next one (or the previous, if it was
    /// last) is selected.
    private func removeSession(_ closing: TerminalSession) {
        guard sessions.count > 1, let index = sessions.firstIndex(where: { $0 === closing }) else { return }
        appLog("session: closed \"\(closing.name)\"")
        closing.onStatusChange = nil
        closing.onModelChange = nil
        closing.onViewReplaced = nil
        closing.terminateChild(reap: true)
        closing.detach()
        if autoOpenedSession == closing.id { autoOpenedFor = nil }
        if pendingAutoOpenSession == closing.id { pendingAutoOpen = nil }
        let wasSelected = index == selectedIndex
        sessions.remove(at: index)
        if index < selectedIndex { selectedIndex -= 1 }
        guard wasSelected else {
            sessionsChanged()
            return
        }
        selectedIndex = min(index, sessions.count - 1)
        session.attach(to: expandedView.contentHost)
        selectionChanged()
        guard state == .expanded else { return }
        refocus()
        if panel.isKeyWindow, !settingsShown { session.markDoneSeen() }
    }

    /// Rename… or a double-click: edited in the row, or in the header while the sidebar is
    /// hidden (one session) or only logos.
    private func beginRename(_ index: Int) {
        guard sessions.indices.contains(index), state == .expanded, !isAnimating,
              expandedView.confirmView == nil else { return }
        closeSettings()
        panel.makeKeyAndOrderFront(nil)
        renamingSession = sessions[index].id
        if sessions.count > 1, !sidebarRail {
            expandedView.sidebar.beginRename(at: index)
        } else {
            select(index)
            expandedView.header.beginRename { [weak self] text in self?.renameEnded(text) }
        }
    }

    /// `text` nil: cancelled. Empty: back to the default (folder) name.
    private func renameEnded(_ text: String?) {
        defer {
            renamingSession = nil
            refocus()
        }
        guard let text, let renamed = sessions.first(where: { $0.id == renamingSession }) else { return }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            renamed.customName = nil
            renamed.defaultName = uniqueName(Self.directoryName(renamed.workingDirectory), for: renamed)
        } else {
            renamed.customName = name
        }
        appLog("session: renamed to \"\(renamed.name)\"")
        sessionsChanged()
    }

    @objc private func newSessionFromMenu() {
        newSession()
    }

    @objc private func closeSessionFromMenu() {
        closeSession(session)
    }

    @objc private func renameSessionFromMenu() {
        let index = selectedIndex
        if state == .collapsed {
            afterExpand = { [weak self] in self?.beginRename(index) }
            expand()
        } else {
            beginRename(index)
        }
    }

    /// ＋'s menu: a new session with another agent (in the selected one's folder), or in
    /// another folder (with the selected one's agent).
    private func showNewSessionMenu(from view: NSView) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "New Session in \(Self.directoryName(workingDirectory))"))
        menuAgents = agents.profiles(for: agentConfig)
        agents.refreshIfNeeded(menuAgents)
        for (index, profile) in menuAgents.enumerated() {
            let installed = agents.isInstalled(profile) ?? true
            let item = NSMenuItem(title: installed ? profile.name : "\(profile.name) (not installed)",
                                  action: #selector(newSessionWithAgent(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.image = HarnessLogo.image(for: Harness(command: profile.command), points: 16)
            item.isEnabled = installed
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let folder = NSMenuItem(title: "New Session in Folder…", action: #selector(newSessionInFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.height + 4 : -4), in: view)
    }

    @objc private func newSessionWithAgent(_ sender: NSMenuItem) {
        guard menuAgents.indices.contains(sender.tag) else { return }
        newSession(command: menuAgents[sender.tag].command)
    }

    @objc private func newSessionInFolder() {
        pickFolder { [weak self] path in
            guard let self else { return }
            let path = Config.normalize(path)
            recentDirectories = Array(([path] + recentDirectories.filter { $0 != path }).prefix(Self.maxRecentDirectories))
            saveState()
            newSession(directory: path)
        }
    }

    // MARK: - Debug hook (Poppy Dev only, DESIGN §12.2)

    /// A stand-in window that takes key status, so a test can have the panel expanded but
    /// not key without anyone clicking another app.
    private var debugBlurPanel: GlassPanel?

    /// Runs one scripted action through the same code as the UI; an error message if it
    /// couldn't. Keys (⌘T, ⌘W, ⌘n) go through GlassPanel's callbacks, as typed.
    func debugRun(_ command: DebugHook.Command) -> String? {
        let index = command.index ?? -1
        let valid = sessions.indices.contains(index)
        switch command.op {
        case "state": break
        case "new": newSession(command: command.command, directory: command.directory)
        case "click": guard valid else { return "no session \(index)" }; sessionClicked(index)
        case "cmdT": panel.onNewSession?()
        case "cmdW": panel.onCloseSession?()
        case "cmdN": panel.onSelectSession?(index)
        case "close": guard valid else { return "no session \(index)" }; closeSession(sessions[index])
        case "confirm":
            guard let confirm = expandedView.confirmView else { return "no confirmation shown" }
            confirm.end(command.value ?? true)
        case "rename":
            guard valid else { return "no session \(index)" }
            renamingSession = sessions[index].id
            renameEnded(command.name)
        case "restart": guard valid else { return "no session \(index)" }; sessions[index].restart()
        case "rail": toggleSidebarRail()
        case "dragSidebar":
            guard let width = command.width else { return "needs width" }
            sidebarDragged(to: CGFloat(width), ended: true)
        case "expand": expand(focus: command.value ?? true)
        case "collapse": collapse()
        case "focus":
            debugBlurPanel?.orderOut(nil)
            guard state == .expanded else { return "not expanded" }
            panel.makeKeyAndOrderFront(nil)
            if let focusTarget { panel.makeFirstResponder(focusTarget) }
        case "blur":
            let blur = debugBlurPanel ?? GlassPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1))
            blur.allowsKey = true
            blur.alphaValue = 0
            blur.makeKeyAndOrderFront(nil)
            debugBlurPanel = blur
        case "autoOpen":
            guard let key = command.key, let value = command.value else { return "needs key and value" }
            setAutoOpen(key, value)
        case "settings": if command.value ?? true { openSettings() } else { closeSettings() }
        case "snapshot":
            guard let path = command.directory else { return "needs a path (directory)" }
            let view = glass.contentView
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return "no bitmap" }
            view.cacheDisplay(in: view.bounds, to: rep)
            // Over the window color (the glass isn't drawn), in the panel's appearance.
            let image = NSImage(size: view.bounds.size, flipped: false) { rect in
                view.effectiveAppearance.performAsCurrentDrawingAppearance {
                    NSColor.windowBackgroundColor.setFill()
                    rect.fill()
                }
                rep.draw(in: rect)
                return true
            }
            guard let tiff = image.tiffRepresentation, let flat = NSBitmapImageRep(data: tiff),
                  let png = flat.representation(using: .png, properties: [:]) else { return "no png" }
            do { try png.write(to: URL(fileURLWithPath: path)) } catch { return "\(error)" }
        default: return "unknown op \(command.op)"
        }
        return nil
    }

    func debugState() -> [String: Any] {
        [
            "state": state == .expanded ? "expanded" : "collapsed",
            "animating": isAnimating,
            "key": panel.isKeyWindow,
            "settings": settingsShown,
            "confirm": expandedView.confirmView != nil,
            // The question is centered on the terminal's area, not shifted.
            "confirmAligned": expandedView.confirmView.map {
                $0.convert($0.terminalFrame, to: expandedView) == expandedView.contentHost.frame
            } ?? true,
            "sidebarWidth": Double(expandedView.sidebarWidth),
            "terminalWidth": Double(expandedView.contentHost.frame.width),
            "rail": sidebarRail,
            "sidebarScrolls": { expandedView.sidebar.layoutSubtreeIfNeeded(); return expandedView.sidebar.scrolls }(),
            "selected": selectedIndex,
            "header": expandedView.header.shownTitle,
            "pill": ["status": pillView.shownStatus.rawValue, "badge": pillView.badgeCount,
                     "label": pillView.toolTip ?? ""],
            "autoOpenedFor": autoOpenedFor?.rawValue ?? "",
            "sessions": sessions.map { each -> [String: Any] in
                [
                    "id": each.id.uuidString,
                    "name": each.name,
                    "custom": each.customName != nil,
                    "command": each.command,
                    "directory": each.workingDirectory,
                    "status": each.status.rawValue,
                    "statusFile": each.statusFilePath ?? "",
                    "pid": Int(each.agentPid ?? 0),
                    "exited": each.exited,
                    "shown": each.isShown,
                ]
            },
        ]
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
        // A report that arrived during Settings…' own expand leaves the page open; later
        // ones close it.
        retryPendingAutoOpen()
        openingSettings = false
        if state == .expanded, let afterExpand {
            self.afterExpand = nil
            afterExpand()
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
        revealIfArmed()
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
        sessionsChanged()  // the sidebar's width may have to give way
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
        if awaitingReveal, panel.occlusionState.contains(.visible) { reveal() }
    }

    // MARK: - Reappearing after a Space swipe (DESIGN §7.16)

    /// The system hides the panel for a whole Space swipe; it only animates back in. Reads
    /// the current state, so a very fast swipe handled late may not animate (never stuck).
    @objc private func panelOcclusionDidChange(_ notification: Notification) {
        if panel.occlusionState.contains(.visible) {
            if awaitingReveal { reveal() }
        } else if panel.isVisible, !awaitingReveal {
            // Not after a real orderOut (isVisible false); Poppy never keeps it ordered out.
            armReveal()
        }
    }

    /// While hidden, make the glass transparent so the first frame shown again is too.
    /// Not the window alpha: a window at alpha 0 never counts as visible again.
    private func armReveal() {
        awaitingReveal = true
        revealGeneration += 1
        glass.layer?.removeAnimation(forKey: "reveal")
        glass.layer?.removeAnimation(forKey: "revealFade")
        stopRevealShadowTracking()
        panel.hasShadow = false  // the shadow draws the rim and can't scale with the glass
        glass.alphaValue = 0

        revealWatchdogTicks = 0
        let timer = Timer(timeInterval: Self.revealWatchdogInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.revealWatchdogTick() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)  // also while a menu is tracking
        revealWatchdog = timer
        appLog("reveal: armed")
    }

    private func revealWatchdogTick() {
        revealWatchdogTicks += 1
        if panel.occlusionState.contains(.visible) {
            if awaitingReveal { reveal() }
        } else if revealWatchdogTicks >= Self.revealWatchdogMaxTicks {
            // Long hidden (lock, sleep): the notification, a Space change or a user action reveals it.
            revealWatchdog?.invalidate()
            revealWatchdog = nil
        }
    }

    /// Expand, collapse and the hotkey play the reveal first, so they never work on a
    /// transparent panel. Fade only: the window is about to change size, which would
    /// throw the scale's pivot off center.
    private func revealIfArmed() {
        if awaitingReveal { reveal(scale: false) }
    }

    /// Fade the glass in while it scales up from `revealScale` about its center.
    private func reveal(scale: Bool = true) {
        awaitingReveal = false
        revealGeneration += 1
        let generation = revealGeneration
        revealWatchdog?.invalidate()
        revealWatchdog = nil
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let scales = scale && !reduceMotion
        var springDuration: TimeInterval = 0

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.restoreShadowAfterReveal(generation) }
        }
        glass.alphaValue = 1
        if let layer = glass.layer {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = Self.revealFadeDuration
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: "revealFade")

            if scales {
                // Critically damped: never past full size, which the window would clip.
                let spring = CASpringAnimation(keyPath: "transform")
                spring.mass = 1
                spring.stiffness = 320
                spring.damping = 36
                spring.initialVelocity = 0
                spring.duration = spring.settlingDuration
                springDuration = spring.duration
                // AppKit picks the anchor point, so pivot on the center explicitly.
                let size = layer.bounds.size
                let dx = size.width * (0.5 - layer.anchorPoint.x)
                let dy = size.height * (0.5 - layer.anchorPoint.y)
                let from = CATransform3DConcat(
                    CATransform3DConcat(CATransform3DMakeTranslation(-dx, -dy, 0),
                                        CATransform3DMakeScale(Self.revealScale, Self.revealScale, 1)),
                    CATransform3DMakeTranslation(dx, dy, 0))
                spring.fromValue = NSValue(caTransform3D: from)
                spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                layer.add(spring, forKey: "reveal")
            }
        }
        CATransaction.commit()

        if scales {
            // The rim is the window shadow: keep it on and let it follow the glass as it
            // fades and scales, instead of popping in when the spring settles.
            panel.hasShadow = true
            revealShadowUntil = CACurrentMediaTime() + springDuration
            let link = glass.displayLink(target: self, selector: #selector(revealShadowFrame))
            link.add(to: .main, forMode: .common)
            revealShadowLink = link
        }

        // Backup in case the animations are dropped without completing (e.g. a style-mask
        // change or orderOut in the same turn, when revealed from expand/collapse).
        let backup = max(Self.revealFadeDuration, springDuration) + 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + backup) { [weak self] in
            self?.restoreShadowAfterReveal(generation)
        }
        appLog(scales ? "reveal: play" : reduceMotion ? "reveal: play (reduce motion)" : "reveal: play (fade only)")
    }

    @objc private func revealShadowFrame(_ link: CADisplayLink) {
        guard link.timestamp < revealShadowUntil else {
            stopRevealShadowTracking()
            panel.refreshShadow()
            return
        }
        panel.invalidateShadow()
    }

    private func stopRevealShadowTracking() {
        revealShadowLink?.invalidate()
        revealShadowLink = nil
    }

    private func restoreShadowAfterReveal(_ generation: Int) {
        guard generation == revealGeneration, !awaitingReveal, !panel.hasShadow else { return }
        panel.hasShadow = true
        panel.refreshShadow()
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

        // Sessions (DESIGN §7.17). The ⌘ hints are handled by GlassPanel (§6.2).
        for (title, action, key) in [("New Session", #selector(newSessionFromMenu), "t"),
                                     ("Rename Session…", #selector(renameSessionFromMenu), ""),
                                     ("Close Session", #selector(closeSessionFromMenu), "w")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = .command
            item.target = self
            item.isEnabled = !isAnimating && (action != #selector(closeSessionFromMenu) || canCloseSession)
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // Agent and folder apply to the selected session.
        let agentItem = NSMenuItem(title: "Agent", action: nil, keyEquivalent: "")
        agentItem.submenu = makeAgentMenu()
        menu.addItem(agentItem)

        let directoryItem = NSMenuItem(title: "Working Directory", action: nil, keyEquivalent: "")
        directoryItem.submenu = makeDirectoryMenu()
        menu.addItem(directoryItem)

        menu.addItem(.separator())

        // Pill size, Auto-Open, usage and the hotkey live on the settings page (DESIGN §7.9).
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = .command  // a hint; GlassPanel handles ⌘, (§6.2)
        settingsItem.target = self
        settingsItem.isEnabled = !isAnimating
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let restart = NSMenuItem(title: "Restart Agent", action: #selector(restartAgent), keyEquivalent: "")
        restart.target = self
        menu.addItem(restart)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit \(AppVariant.name)", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }

    /// One item per profile, with its logo; the running one is checked (DESIGN §9.5).
    private func makeAgentMenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        menuAgents = agents.profiles(for: agentConfig)
        agents.refreshIfNeeded(menuAgents)
        for (index, profile) in menuAgents.enumerated() {
            let installed = agents.isInstalled(profile) ?? true
            let title = installed ? profile.name : "\(profile.name) (not installed)"
            let item = NSMenuItem(title: title, action: #selector(selectAgent(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.image = HarnessLogo.image(for: Harness(command: profile.command), points: 16)
            let current = AgentCatalog.same(profile.command, session.command)
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
        pickFolder { [weak self] path in self?.openDirectory(path, show: true) }
    }

    /// From the settings page, the page stays and gets the keyboard back afterwards.
    private func pickFolder(_ chosen: @escaping (String) -> Void) {
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
                if let url = picker.url, response == .OK { chosen(url.path) }
                self?.refocusSettings()
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
        if let showUsage = request.showUsage { setShowUsage(showUsage) }

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
        changeAgent(command: request.command ?? session.command, directory: directory)
        refreshSettings()

        guard request.show, !isAnimating else { return }
        closeSettings()  // the user wants the agent
        if state == .collapsed {
            expand()
        } else {
            panel.makeKeyAndOrderFront(nil)
            if let focusTarget { panel.makeFirstResponder(focusTarget) }
        }
    }

    /// Runs `command` in `directory` in the selected session: one restart if either
    /// changed, none otherwise; both are saved (`command`, `cwd`) as the defaults for the
    /// next launch and new sessions (DESIGN §9.5, §9.8).
    private func changeAgent(command: String, directory: String) {
        let commandChanged = !AgentCatalog.same(command, session.command)
        let directoryChanged = directory != workingDirectory
        guard commandChanged || directoryChanged else { return }
        if commandChanged {
            appLog("agent: \(command)")
            config.command = command
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
            config.cwd = Config.abbreviate(directory)
            _ = Config.saveValue(config.cwd, forKey: "cwd")
        }
        session.switchTo(command: command, directory: Config.abbreviate(directory))
        if directoryChanged { session.defaultName = uniqueName(Self.directoryName(directory), for: session) }
        selectionChanged()  // logo, title, usage
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
        guard !AgentCatalog.same(profile.command, session.command) else { return }
        appLog("switching agent to \(profile.name)")
        changeAgent(command: profile.command, directory: workingDirectory)
        refreshSettings()
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

    private func setShowUsage(_ on: Bool) {
        guard on != config.showUsage else { return }
        config.showUsage = on
        appLog("usage: showUsage = \(config.showUsage)")
        usage.setEnabled(config.showUsage)
        if !Config.saveValue(config.showUsage, forKey: "showUsage") {
            appLog("usage: showUsage not saved; it applies until Poppy quits")
        }
    }

    // MARK: - Settings page (DESIGN §7.9)

    @objc private func openSettingsFromMenu() {
        openSettings()
    }

    /// ⌘, in the panel.
    private func toggleSettings() {
        guard !isAnimating else {
            NSSound.beep()
            return
        }
        if settingsShown { closeSettings() } else { openSettings() }
    }

    /// From the pill: the pill grows into the page. From the open panel: the terminal
    /// crossfades to it.
    private func openSettings() {
        revealIfArmed()
        guard !isAnimating else { return }
        expandedView.confirmView?.end(false)
        refreshSettings()
        if settingsShown {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(expandedView.settingsView)
            return
        }
        settingsShown = true
        appLog("settings: shown")
        if state == .collapsed {
            expandedView.setSettingsVisible(true, animated: false)
            openingSettings = true
            expand()
        } else {
            expandedView.setSettingsVisible(true, animated: true)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(expandedView.settingsView)
        }
    }

    /// Back to the terminal, which gets the first responder back (ready for when the panel
    /// is key). `markSeen: false` when collapsing: the user never looked at the agent.
    private func closeSettings(animated: Bool = true, markSeen: Bool = true) {
        guard settingsShown else { return }
        expandedView.settingsView.hotkeyField.cancel()
        settingsShown = false
        expandedView.setSettingsVisible(false, animated: animated && state == .expanded)
        appLog("settings: closed")
        guard state == .expanded else { return }
        if let focusTarget { panel.makeFirstResponder(focusTarget) }
        if markSeen, panel.isKeyWindow { session.markDoneSeen() }
    }

    /// After the folder picker gives activation back, the page takes the keyboard again.
    private func refocusSettings() {
        guard settingsShown, state == .expanded, !isAnimating else { return }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(expandedView.settingsView)
    }

    /// The page's controls from the current settings (also after a change was refused).
    /// The agent and directory lists are the same as the menu's (DESIGN §9.5, §9.8).
    private func refreshSettings() {
        menuAgents = agents.profiles(for: agentConfig)
        agents.refreshIfNeeded(menuAgents)
        let agentChoices = menuAgents.map { profile in
            let installed = agents.isInstalled(profile) ?? true
            let current = AgentCatalog.same(profile.command, session.command)
            return SettingsModel.Agent(title: installed ? profile.name : "\(profile.name) (not installed)",
                                       image: HarnessLogo.image(for: Harness(command: profile.command), points: 16),
                                       enabled: installed || current)
        }
        let directories = ([workingDirectory] + recentDirectories.filter { $0 != workingDirectory })
            .filter { Self.isDirectory($0) }
            .prefix(Self.maxRecentDirectories)
        let preset = Self.pillPresets.firstIndex { $0.diameter == pillDiameter } ?? 0
        expandedView.settingsView.update(SettingsModel(
            agents: agentChoices,
            currentAgent: menuAgents.firstIndex { AgentCatalog.same($0.command, session.command) },
            directories: Array(directories),
            pillPresets: Self.pillPresets.map(\.name), pillPreset: preset,
            showUsage: config.showUsage, statusHooks: config.statusHooks,
            autoOpenOnInput: config.autoOpenOnInput, autoOpenOnDone: config.autoOpenOnDone,
            autoOpenFocus: config.autoOpenFocus,
            hotkey: hotKeys?.current?.displayString, canRecordHotkey: hotKeys?.canRecord == true))
    }

    /// Saves `statusHooks`; the running agent keeps its hooks until it restarts (DESIGN §9.6).
    private func setStatusHooks(_ on: Bool) {
        guard on != config.statusHooks else { return }
        config.statusHooks = on
        sessions.forEach { $0.setStatusHooks(on) }
        appLog("status hooks: statusHooks = \(on) (from the next agent start)")
        if !Config.saveValue(on, forKey: "statusHooks") {
            appLog("status hooks: statusHooks not saved; it applies until Poppy quits")
        }
    }

    // MARK: - Attachments (DESIGN §9.10)

    var canAcceptDrop: Bool { !isAnimating }

    /// A drop on the pill: files and images become paths, text is pasted as is; then the
    /// panel opens on it.
    func dropped(_ pasteboard: NSPasteboard) -> Bool {
        guard canAcceptDrop else { return false }
        let deliver: @MainActor (String) -> Void = { [weak self] text in self?.sendToAgent(text) }
        if Attachments.text(from: pasteboard, completion: deliver) { return true }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return false }
        deliver(text)
        return true
    }

    /// Pastes `text` into the agent and shows it, focused. Not while the agent is asking
    /// for input: the characters could answer its prompt, so it's only shown (DESIGN §9.10).
    private func sendToAgent(_ text: String) {
        if session.status == .waiting {
            appLog("attachments: not pasted, the agent is waiting for an answer")
        } else {
            session.paste(text)
        }
        guard !isAnimating else { return }
        closeSettings()  // show the agent it went to
        if state == .collapsed {
            expand()
        } else if !panel.isKeyWindow {
            panel.makeKeyAndOrderFront(nil)
            if let focusTarget { panel.makeFirstResponder(focusTarget) }
        }
    }

    @objc private func restartAgent() {
        session.restart()
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
