import AppKit

/// Shared with the `poppy` command's `--pill` (DESIGN §7.14, §9.9).
nonisolated enum PanelSizes {
    static let pillPresets: [(name: String, diameter: CGFloat)] = [("Small", 36), ("Medium", 44), ("Large", 56)]
}

/// One pill: owns its panel and views, its sessions, state machine, frames, animation,
/// observers and Poppy menu (DESIGN §5–7). `PillManager` owns the pills and what they
/// share (DESIGN §7.18).
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
    unowned let manager: PillManager
    /// The global settings, shared by every pill (DESIGN §8.1).
    private var config: Config {
        get { manager.config }
        set { manager.config = newValue }
    }
    private var agents: AgentCatalog { manager.agents }
    /// The selected session's agent's subscription usage (DESIGN §9.7).
    private let usage: UsageMonitor
    /// Recent working directories, newest first, shared by every pill (DESIGN §9.8).
    private var recentDirectories: [String] {
        get { manager.recentDirectories }
        set { manager.recentDirectories = newValue }
    }
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
    /// Pinned: a click outside never folds this panel (DESIGN §6.3). Saved with the layout.
    private var pinned = false
    /// Hide pill when collapsed: ordered out until it opens again (DESIGN §7.21).
    private(set) var isPillHidden = false

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
    /// The pill is a glass circle holding the logo; its diameter is a preset, the same
    /// for every pill (DESIGN §7.14).
    private var pillDiameter: CGFloat { manager.pillDiameter }
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
    /// The settings page shows and records the hotkey through it (DESIGN §7.9).
    private var hotKeys: HotKeyManager? { manager.hotKeys }

    /// A pill with `saved`'s sessions (never empty), each started fresh, at `frame`; or with
    /// `adopting`'s running sessions instead (a row dragged out, DESIGN §7.19).
    init(manager: PillManager, saved: SavedPill, frame: NSRect, adopting: [TerminalSession] = []) {
        self.manager = manager
        let first = adopting.first?.command ?? saved.sessions[0].command
        usage = UsageMonitor(command: first, enabled: manager.config.showUsage)
        expandedSize = saved.expandedSize.map {
            NSSize(width: max($0.width, ExpandedView.minSize.width), height: max($0.height, ExpandedView.minSize.height))
        } ?? ExpandedView.defaultSize
        sidebarRail = saved.sidebarCollapsed ?? false
        pinned = saved.pinned ?? false
        if let width = saved.sidebarWidth {
            sidebarWidth = max(SidebarView.minWidth, min(CGFloat(width), SidebarView.maxWidth))
        }
        let pillSize = frame.size
        pillFrame = frame
        panel = GlassPanel(contentRect: pillFrame)

        glass = GlassBackgroundView(frame: NSRect(origin: .zero, size: pillSize),
                                    cornerRadius: pillSize.width / 2)
        glass.autoresizingMask = [.width, .height]
        var firstConfig = manager.config
        firstConfig.command = first
        pillView = PillView(frame: glass.contentView.bounds, harness: Harness(command: first),
                            title: firstConfig.pillTitle)
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

        for each in adopting {
            wire(each)
            sessions.append(each)
        }
        for each in adopting.isEmpty ? saved.sessions : [] {
            // A folder that's gone falls back to the home folder (logged), as `cwd` does.
            var resolved = manager.config
            resolved.cwd = each.cwd
            let name = each.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            sessions.append(makeSession(command: each.command, directory: Config.normalize(resolved.resolvedWorkingDirectory),
                                        name: name?.isEmpty == false ? name : nil, conversation: each.conversation))
        }
        selectedIndex = min(max(saved.selected ?? 0, 0), sessions.count - 1)
        sessionsChanged()  // the sidebar first, so the agents start at their final width
        // Every agent starts now, as at any launch; only the selected one stays in the panel.
        for (index, each) in sessions.enumerated() where index != selectedIndex && adopting.isEmpty {
            each.attach(to: expandedView.contentHost)
            each.detach()
        }
        session.attach(to: expandedView.contentHost)
        wireSessionControls()

        panel.contentView = glass
        panel.allowsKey = false
        panel.isShowingSettings = { [weak self] in self?.settingsShown == true }
        panel.onCloseSettings = { [weak self] returnKey in
            guard let self else { return }
            if returnKey, introShown { expandedView.settingsView.intro.next() } else { settingsDone() }
        }
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
        settings.actHotkeyField.onBegin = { [weak self] in self?.manager.actHotKeys?.beginRecording() ?? false }
        settings.actHotkeyField.onRecord = { [weak self] combo in
            self?.manager.actHotKeys?.record(combo) ?? .failed("Hotkeys are unavailable.")
        }
        settings.actHotkeyField.onEnd = { [weak self] in self?.manager.actHotKeys?.endRecording() }
        settings.sendHotkeyField.onBegin = { [weak self] in self?.manager.sendHotKeys?.beginRecording() ?? false }
        settings.sendHotkeyField.onRecord = { [weak self] combo in
            self?.manager.sendHotKeys?.record(combo) ?? .failed("Hotkeys are unavailable.")
        }
        settings.sendHotkeyField.onEnd = { [weak self] in self?.manager.sendHotKeys?.endRecording() }
        expandedView.header.onDone = { [weak self] in self?.settingsDone() }
        expandedView.header.onNew = { [weak self] in self?.newSession() }
        expandedView.header.onNewMenu = { [weak self] view in self?.showNewSessionMenu(from: view) }
        expandedView.header.onPin = { [weak self] in self?.togglePin() }
        expandedView.header.onFold = { [weak self] in self?.collapse() }
        expandedView.header.onTitleClick = { [weak self] view in self?.showDirectoryMenu(from: view) }
        settings.onChange = { [weak self] change in self?.manager.applySetting(change) }
        panel.onZoom = { [weak self] step in self?.manager.zoomTerminal(step) }
        glass.onHoverChange = { [weak self] in self?.updateFade() }
        settings.onAutoOpen = { [weak self] key, on in
            self?.setAutoOpen(key, on)
            self?.refreshSettings()
        }
        settings.onShowUsage = { [weak self] on in
            self?.setShowUsage(on)
            self?.refreshSettings()
        }
        settings.onHotkeyTarget = { [weak self] index in
            guard let self, HotkeyTarget.allCases.indices.contains(index) else { return }
            manager.setHotkeyTarget(HotkeyTarget.allCases[index])
            refreshSettings()
        }
        settings.onActEnabled = { [weak self] on in self?.manager.setActEnabled(on) }
        settings.onSendEnabled = { [weak self] on in self?.manager.setSendEnabled(on) }
        settings.onShowIntro = { [weak self] in self?.openIntro() }
        settings.onCheckPermissions = { [weak self] in self?.openIntro(at: .permissions, single: true) }
        wireIntro()

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
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelDidResignKey),
            name: NSWindow.didResignKeyNotification, object: panel)

        selectionChanged()
        updatePinButton()
        if manager.config.hidePill, adopting.isEmpty {
            isPillHidden = true  // shown when it opens (DESIGN §7.21)
        } else {
            panel.orderFrontRegardless()
        }
        panel.refreshShadow()
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
        // Only one pill is open at a time: the other folds first (DESIGN §7.18).
        guard manager.willExpand(self) else {
            appLog("expand: another pill can't fold right now")
            return
        }
        showHiddenPill()
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
                    if opener.status == .working, opener === session, !pinned { collapse() }
                }
            }
        }
    }

    func collapse() {
        revealIfArmed()
        guard state == .expanded, !isAnimating, !panel.inLiveResize else { return }
        // The next expand shows the terminal; the intro stays for it (DESIGN §9.15).
        if introShown {
            expandedView.settingsView.intro.cancelRecording()
        } else {
            closeSettings(animated: false, markSeen: false)
        }
        expandedView.confirmView?.end(false)  // a click outside cancels closing a session
        afterExpand = nil
        isAnimating = true
        state = .collapsed
        autoOpenedFor = nil
        removeClickOutsideMonitor()
        panel.setResizable(false)
        updateFade()  // the pill never fades

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
            if config.hidePill {
                // Gone instead of the pill (DESIGN §7.21).
                pillView.alphaValue = 1
                hidePill()
                finishAnimation()
                return
            }
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
            // Pinned means "leave it open" (DESIGN §7.15).
            if answered, state == .expanded, !isAnimating, !pinned {
                collapse()
            } else if config.foldOnPrompt, changed === session, state == .expanded, !isAnimating, !pinned,
                      panel.isKeyWindow, !settingsShown {
                // The user just sent a prompt (or answered) in the panel (DESIGN §7.15).
                appLog("auto-open: folding, the agent is working")
                collapse()
            }
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
        refreshIntro()  // e.g. back from System Settings
        // During an expand the fade completion installs it; this covers an unfocused
        // auto-open that the user clicks into later.
        if state == .expanded, !isAnimating { installClickOutsideMonitor() }  // idempotent
        updateFade()
    }

    @objc private func panelDidResignKey(_ notification: Notification) {
        updateFade()
    }

    /// Retries an auto-open that had to wait, if the agent is still in that status.
    func retryPendingAutoOpen() {
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
        guard !manager.isAnimating, !panel.inLiveResize, NSEvent.pressedMouseButtons == 0 else {
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
        if hotKeys?.isRecording == true || manager.actHotKeys?.isRecording == true
            || manager.sendHotKeys?.isRecording == true {
            appLog("auto-open: skipped (recording a hotkey)")
            return
        }
        if expandedView.confirmView != nil || (state == .expanded && panel.isKeyWindow && opener !== session) {
            appLog("auto-open: skipped (busy in another session)")
            return
        }
        if manager.otherPillIsKey(than: self) {
            appLog("auto-open: skipped (busy in another pill)")
            return
        }
        // The agent needs the user: the settings page gives way to the terminal (not while
        // Settings… is still opening from the pill). DESIGN §7.15.
        let closesSettings = settingsShown && state == .expanded && !openingSettings && !introShown
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

    /// A session with its default name (or `name`); its agent starts when it's first attached.
    private func makeSession(command: String, directory: String, name: String? = nil,
                             startCommand: String? = nil, conversation: String? = nil) -> TerminalSession {
        var sessionConfig = config
        sessionConfig.command = command
        sessionConfig.cwd = Config.abbreviate(directory)
        let new = TerminalSession(config: sessionConfig, startCommand: startCommand, conversationID: conversation)
        new.customName = name
        new.defaultName = uniqueName(Self.directoryName(new.workingDirectory), for: new)
        wire(new)
        return new
    }

    /// The session's callbacks go to this pill (also when one moves here, DESIGN §7.19).
    private func wire(_ wired: TerminalSession) {
        wired.onViewReplaced = { [weak self, weak wired] in
            if let self, wired === session { refocus() }
        }
        wired.onStatusChange = { [weak self, weak wired] status in
            if let self, let wired { statusChanged(wired, status) }
        }
        wired.onModelChange = { [weak self, weak wired] model in
            if let self, wired === session { usage.setAgentModel(model) }
        }
        wired.onConversationChange = { [weak self] in self?.manager.saveLayout() }
    }

    /// `base`, or "base 2", "base 3"… (the lowest free number) if another session anywhere
    /// in Poppy has it. (This pill's own sessions are listed too: while it's being built,
    /// it isn't among the manager's pills yet.)
    private func uniqueName(_ base: String, for named: TerminalSession) -> String {
        let taken = Set((manager.allSessions + sessions).filter { $0 !== named }.map(\.name))
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
        sidebar.onToggleRail = { [weak self] in self?.toggleSidebarRail() }
        sidebar.onResize = { [weak self] width, ended in self?.sidebarDragged(to: width, ended: ended) }
        sidebar.onRowDragBegan = { [weak self] index in self?.rowDragBegan(index) ?? false }
        sidebar.onRowDragMoved = { [weak self] in self?.rowDragMoved() }
        sidebar.onRowDragEnded = { [weak self] in self?.rowDragEnded() }
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

    /// Any session can be closed; closing a pill's last one removes the pill (DESIGN §7.18).
    private var canCloseSession: Bool { true }

    /// Ends every agent (quitting, DESIGN §4).
    func terminateAll() {
        sessions.forEach { $0.terminateChild() }
    }

    var sessionCount: Int { sessions.count }
    /// Torn down (its last session closed); nothing should touch its views any more.
    private(set) var isRemoved = false
    var allSessions: [TerminalSession] { sessions }
    var selectedSessionIndex: Int { selectedIndex }

    /// This pill in the saved layout (DESIGN §8.2).
    var savedPill: SavedPill {
        SavedPill(origin: SavedPoint(x: pillFrame.minX, y: pillFrame.minY),
                  expandedSize: SavedSize(width: expandedSize.width, height: expandedSize.height),
                  sidebarCollapsed: sidebarRail, sidebarWidth: Double(sidebarWidth),
                  selected: savedSelection,
                  pinned: pinned ? true : nil,
                  sessions: savedSessions.map {
                      SavedSession(command: $0.command, cwd: Config.abbreviate($0.workingDirectory), name: $0.customName,
                                   conversation: $0.conversationID)
                  })
    }

    /// Act on Selection's sessions aren't saved (DESIGN §9.14); a pill with only those is
    /// dropped at the next launch.
    private var savedSessions: [TerminalSession] { sessions.filter { !$0.isTransient } }

    /// The selected session among `savedSessions`. Not through `session`: a closing session
    /// saves the layout before the next one is selected, when `selectedIndex` can be past the end.
    private var savedSelection: Int {
        guard sessions.indices.contains(selectedIndex) else { return 0 }
        let selected = sessions[selectedIndex]
        return savedSessions.firstIndex { $0 === selected } ?? 0
    }

    /// The menu bar's pill list: the selected session's name and the pill's most urgent
    /// status, with the selected agent's logo (DESIGN §7.12).
    var menuTitle: String {
        let count = sessions.count > 1 ? " · \(sessions.count) sessions" : ""
        return session.name + PillView.statusSuffix(urgentStatus) + count
    }

    var menuImage: NSImage {
        HarnessLogo.image(for: Harness(command: session.command), points: 16)
    }

    private var urgentStatus: AgentStatus {
        sessions.map(\.status).max { Self.urgency($0) < Self.urgency($1) } ?? .idle
    }

    /// The pill is going away (its last session closed): end every agent, take it off screen.
    func tearDown() {
        isRemoved = true
        removeClickOutsideMonitor()
        stopRevealShadowTracking()
        revealWatchdog?.invalidate()
        revealWatchdog = nil
        introTimer?.invalidate()
        expandedView.settingsView.intro.cancelRecording()
        expandedView.settingsView.hotkeyField.cancel()
        expandedView.settingsView.actHotkeyField.cancel()
        expandedView.settingsView.sendHotkeyField.cancel()
        for each in sessions {
            each.onStatusChange = nil
            each.onModelChange = nil
            each.onConversationChange = nil
            each.onViewReplaced = nil
            each.terminateChild(reap: true)
            each.detach()
        }
        if state == .expanded {
            panel.makeFirstResponder(nil)
            panel.allowsKey = false  // the keyboard goes back to the app underneath
        }
        panel.orderOut(nil)
        debugBlurPanel?.orderOut(nil)
    }

    /// Opens this pill on its selected session, focused: the menu bar's pill list, New Pill.
    func open() {
        manager.used(self)
        guard !isAnimating else { return }
        closeSettings()
        showFocused()
    }

    /// Collapsed: expand (folding any other pill). Expanded: take the keyboard.
    private func showFocused() {
        if state == .collapsed {
            expand()
        } else {
            panel.makeKeyAndOrderFront(nil)
            if let focusTarget { panel.makeFirstResponder(focusTarget) }
        }
    }

    /// The user is typing in this panel (so a background change mustn't switch sessions).
    private var userBusyHere: Bool { state == .expanded && panel.isKeyWindow }

    /// `poppy` in a folder that already has this session: select it and, with `show`, open
    /// the pill on it. Without `show` (`-b`) it's only selected, and not while the user is
    /// busy in this panel. Never restarts it (DESIGN §9.9).
    func reveal(_ revealed: TerminalSession, show: Bool) {
        guard let index = sessions.firstIndex(where: { $0 === revealed }) else { return }
        guard show else {
            if !userBusyHere { select(index) }
            return
        }
        manager.used(self)
        guard !isAnimating else {
            select(index)
            return
        }
        closeSettings()
        select(index)
        showFocused()
    }

    /// `poppy` with a folder no session has (or `--new`): a new session here; without
    /// `show` it's only added (and selected unless the user is busy in this panel).
    func addSession(command: String, directory: String, show: Bool) {
        if show {
            manager.used(self)
            newSession(command: command, directory: directory)
        } else {
            newSession(command: command, directory: directory, show: false, select: !userBusyHere)
        }
    }

    /// Closes `closing` without asking (a finished Act on Selection session, DESIGN §9.14).
    func closeFinished(_ closing: TerminalSession) {
        removeSession(closing)
    }

    /// An Act on Selection session (DESIGN §9.14) in `directory`: added without showing the
    /// panel (unless `show`), selected unless the user is busy in this panel, never saved;
    /// `startCommand` the first time, `command` after a restart.
    func addActSession(command: String, startCommand: String, directory: String, name: String, show: Bool) {
        if show { manager.used(self) }
        newSession(command: command, directory: directory, show: show, select: show || !userBusyHere,
                   name: name, startCommand: startCommand, transient: true)
    }

    /// The hotkey's "most urgent" target: the pill opens on `wanted` (and, if it's already
    /// showing it with the keyboard, collapses as usual).
    func hotkeyPressed(showing wanted: TerminalSession) {
        guard !isAnimating, let index = sessions.firstIndex(where: { $0 === wanted }) else { return }
        if state == .expanded, panel.isKeyWindow, index == selectedIndex {
            hotkeyPressed()
            return
        }
        closeSettings()
        select(index)
        if state == .expanded, panel.isKeyWindow { return }
        hotkeyPressed()
    }

    /// ＋, ⌘T, New Session: a new session in this pill, selected and shown; by default with
    /// the selected one's agent and folder. `show: false` only adds it (selected or not).
    private func newSession(command: String? = nil, directory: String? = nil, show: Bool = true, select selects: Bool = true,
                            name: String? = nil, startCommand: String? = nil, transient: Bool = false) {
        let new = makeSession(command: command ?? session.command, directory: directory ?? workingDirectory,
                              name: name, startCommand: startCommand)
        new.isTransient = transient
        sessions.append(new)
        appLog("session: new \"\(new.name)\" (\(sessions.count) sessions)")
        sessionsChanged()  // the sidebar first, so the new agent starts at its final width
        if selects {
            select(sessions.count - 1)  // starts its agent
        } else {
            new.attach(to: expandedView.contentHost)  // starts its agent, unseen
            new.detach()
        }
        saveState()
        guard show, !isAnimating else { return }  // an expand in progress shows it anyway
        closeSettings()
        showFocused()
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
        saveState()
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
        let urgent = urgentStatus
        let needYou = sessions.filter { $0.status == .waiting || $0.status == .done }.count
        pillView.setStatus(urgent, sessionName: multiple ? session.name : nil, selected: session.status, needYou: needYou)
        expandedView.header.setTitle(session.name)
        expandedView.sidebar.isRail = sidebarRail
        // While a pill hovers over a panel with one session, the sidebar is only a preview
        // (`previewSidebar`); its real width comes with the drop.
        if multiple || dropPreviewCount == 0 {
            expandedView.setSidebarWidth(multiple ? shownSidebarWidth : 0)
        }
        expandedView.sidebar.update(sessions.map { each in
            SidebarItem(name: each.name, harness: Harness(command: each.command), status: each.status,
                        label: Self.label(for: each))
        } + Array(repeating: SidebarItem.placeholder(), count: dropPreviewCount),
           selected: selectedIndex, canClose: canCloseSession,
           hidden: hiddenRowSession.flatMap { hidden in sessions.firstIndex { $0 === hidden } })
        manager.updateMenuBarIcon()
    }

    /// The sidebar's width when it shows: the rail, or names at `sidebarWidth` (a panel
    /// resized smaller since the drag still leaves the terminal its room).
    private var shownSidebarWidth: CGFloat {
        sidebarRail ? SidebarView.railWidth
            : min(sidebarWidth, max(SidebarView.minWidth, expandedView.bounds.width - Self.minTerminalWidth))
    }

    /// Empty slots at the end of the sidebar for sessions about to join: a pill hovering
    /// over this open panel (DESIGN §7.19). With one session the sidebar slides in for them.
    private var dropPreviewCount = 0

    func setDropPreview(_ count: Int) {
        let count = state == .expanded ? count : 0
        guard count != dropPreviewCount else { return }
        dropPreviewCount = count
        if sessions.count == 1 { expandedView.previewSidebar(count > 0 ? shownSidebarWidth : 0) }
        sessionsChanged()
    }

    /// Where the first empty slot is on screen (where a dropped pill's content goes).
    var dropSlotFrame: NSRect {
        expandedView.sidebar.rowSnapshot(sessions.count).frame
    }

    /// waiting > working > done (unseen; seen is idle) > idle.
    static func urgency(_ status: AgentStatus) -> Int {
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
        saveState()
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
            saveState()
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
        guard !isAnimating, expandedView.confirmView == nil,
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
        guard !isRemoved else { return }
        if !session.isShown { session.attach(to: expandedView.contentHost) }
        refocus()
    }

    /// Ends the agent and removes the session; the next one (or the previous, if it was
    /// last) is selected. The pill's last session takes the pill with it.
    private func removeSession(_ closing: TerminalSession) {
        guard let index = sessions.firstIndex(where: { $0 === closing }) else { return }
        appLog("session: closed \"\(closing.name)\"")
        guard sessions.count > 1 else {
            manager.remove(self)  // ends the agent too
            return
        }
        release(closing, at: index, ending: true)
    }

    /// Takes `leaving` out of this pill: its callbacks unhooked, its view detached (and its
    /// agent ended if `ending`); the next session (or the previous) is selected if it was.
    /// Never the last one.
    private func release(_ leaving: TerminalSession, at index: Int, ending: Bool) {
        leaving.onStatusChange = nil
        leaving.onModelChange = nil
        leaving.onConversationChange = nil
        leaving.onViewReplaced = nil
        if ending { leaving.terminateChild(reap: true) }
        leaving.detach()
        if autoOpenedSession == leaving.id { autoOpenedFor = nil }
        if pendingAutoOpenSession == leaving.id { pendingAutoOpen = nil }
        if hiddenRowSession === leaving { hiddenRowSession = nil }
        let wasSelected = index == selectedIndex
        sessions.remove(at: index)
        if index < selectedIndex { selectedIndex -= 1 }
        saveState()
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
        saveState()
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
        // Shells are the Terminal item below, not listed as agents (e.g. a selected terminal).
        menuAgents = agents.profiles(for: agentConfig).filter { Harness(command: $0.command) != .shell }
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
        let terminal = NSMenuItem(title: "Terminal", action: #selector(newTerminalSession), keyEquivalent: "")
        terminal.target = self
        terminal.image = HarnessLogo.image(for: .shell, points: 16)
        menu.addItem(terminal)
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

    @objc private func newTerminalSession() {
        newSession(command: ShellEnvironment.terminalCommand)
    }

    @objc private func newSessionInFolder() {
        pickFolder { [weak self] path in
            guard let self else { return }
            let path = Config.normalize(path)
            manager.addRecentDirectory(path)
            newSession(directory: path)
        }
    }

    // MARK: - Dragging between pills (DESIGN §7.19)

    /// The session whose row is being dragged.
    private var draggedSession: TerminalSession?

    /// A row may be dragged with 2+ sessions, not while animating, renaming or asking.
    private func rowDragBegan(_ index: Int) -> Bool {
        guard sessions.count > 1, sessions.indices.contains(index), state == .expanded, !isAnimating,
              expandedView.confirmView == nil, renamingSession == nil else { return false }
        draggedSession = sessions[index]
        let snapshot = expandedView.sidebar.rowSnapshot(index)
        manager.rowDragBegan(sessions[index], from: self, image: snapshot.image, frame: snapshot.frame)
        return true
    }

    /// Over the sidebar the row moves to the slot under the mouse; elsewhere its image
    /// follows the mouse, and a pill under it is highlighted.
    private func rowDragMoved() {
        guard let dragged = draggedSession else { return }
        let slot = expandedView.sidebar.rowSlot(atScreen: DragPointer.location)
        if let slot { moveSession(dragged, to: slot) }
        manager.rowDragMoved(from: self, overSidebar: slot != nil, rowFrame: rowScreenFrame(of: dragged))
    }

    private func rowDragEnded() {
        guard let dragged = draggedSession else { return }
        draggedSession = nil
        let overPanel = NSMouseInRect(DragPointer.location, panel.frame, false)
        manager.rowDragEnded(dragged, from: self, overPanel: overPanel)
    }

    /// Reorders the sidebar; the selected session stays selected.
    private func moveSession(_ moving: TerminalSession, to slot: Int) {
        guard let from = sessions.firstIndex(where: { $0 === moving }), from != slot,
              sessions.indices.contains(slot) else { return }
        let selected = session
        sessions.remove(at: from)
        sessions.insert(moving, at: slot)
        selectedIndex = sessions.firstIndex { $0 === selected } ?? 0
        appLog("session: moved \"\(moving.name)\" to row \(slot + 1)")
        sessionsChanged()
    }

    /// `leaving` goes to another pill: out of this one with its agent still running.
    func giveAway(_ leaving: TerminalSession) {
        guard sessions.count > 1, let index = sessions.firstIndex(where: { $0 === leaving }) else { return }
        release(leaving, at: index, ending: false)
    }

    /// This pill is dropped onto another: all its sessions leave, running; the manager
    /// removes the pill right after.
    func giveAwayAll() -> [TerminalSession] {
        let leaving = sessions
        for each in leaving {
            each.onStatusChange = nil
            each.onModelChange = nil
            each.onConversationChange = nil
            each.onViewReplaced = nil
            each.detach()
        }
        autoOpenedFor = nil
        pendingAutoOpen = nil
        sessions = []
        return leaving
    }

    /// Sessions from another pill join the end of the sidebar, still running, with their
    /// id, name, status and unseen done. The selected session and the position stay.
    func adopt(_ moved: [TerminalSession]) {
        dropPreviewCount = 0  // the slots become the rows
        for each in moved {
            wire(each)
            sessions.append(each)
        }
        appLog("session: \(moved.count == 1 ? "\"\(moved[0].name)\"" : "\(moved.count) sessions") joined (\(sessions.count) sessions)")
        sessionsChanged()
    }

    /// The session whose row is out of the sidebar as a liquid blob (its row is blank).
    private var hiddenRowSession: TerminalSession?

    func setDraggedRowHidden(_ hidden: TerminalSession?) {
        guard hidden !== hiddenRowSession else { return }
        hiddenRowSession = hidden
        sessionsChanged()
    }

    /// Where `session`'s row is on screen now.
    func rowScreenFrame(of shown: TerminalSession) -> NSRect {
        guard let index = sessions.firstIndex(where: { $0 === shown }) else { return .zero }
        return expandedView.sidebar.rowSnapshot(index).frame
    }

    /// The glass's corner radius now (pill or panel), for the liquid overlay's copy of it.
    var glassRadius: CGFloat { state == .expanded ? Self.expandedCornerRadius : pillCornerRadius }

    /// The glass can be lent (see `GlassBackgroundView.canHideGlass`).
    var canLendGlass: Bool { glass.canHideGlass }

    /// The liquid overlay draws this pill's glass (and its rim, through its shadow) for a
    /// while; the content stays here, above it (DESIGN §7.19).
    func lendGlass() {
        glass.isGlassHidden = true
        panel.hasShadow = false
    }

    /// The pill's content (logo, usage ring, badge, DEV tag) fades while it's dragged onto
    /// another, so only the target's shows as their glass merges.
    func setContentAlpha(_ alpha: CGFloat) {
        glass.contentView.alphaValue = alpha
    }

    func takeGlassBack() {
        glass.isGlassHidden = false
        panel.hasShadow = true
        panel.refreshShadow()
    }

    /// The highlight while something dragged is over this (collapsed) pill.
    func setDropHighlight(_ on: Bool) {
        pillView.setDropHighlight(on)
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
        case "type":
            // `name` pasted into session `index`'s terminal (if any), then Return unless value is
            // false; or `key` (up, down, left, right, escape) pressed instead.
            guard valid else { return "no session \(index)" }
            if let key = command.key {
                return sessions[index].pressKey(key) ? nil : "unknown key \(key)"
            }
            if let text = command.name, !text.isEmpty { sessions[index].paste(text) }
            if command.value ?? true {
                let typed = sessions[index]
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { typed.pressReturn() }  // after the paste lands
            }
        case "rail": toggleSidebarRail()
        case "drag":
            // A scripted mouse drag, step by step (key: rowBegin, rowMove, rowEnd, pillMove,
            // pillEnd), at x, y; the steps run the same code as the mouse's.
            let point = NSPoint(x: command.x ?? 0, y: command.y ?? 0)
            switch command.key {
            case "rowBegin":
                guard valid else { return "no session \(index)" }
                let frame = expandedView.sidebar.rowSnapshot(index).frame
                DragPointer.scripted = NSPoint(x: frame.midX, y: frame.midY)
                guard rowDragBegan(index) else { DragPointer.scripted = nil; return "can't drag that row" }
            case "rowMove":
                DragPointer.scripted = point
                rowDragMoved()
            case "rowEnd":
                DragPointer.scripted = point
                rowDragEnded()
                DragPointer.scripted = nil
            case "pillMove":
                DragPointer.scripted = point
                panel.setFrameOrigin(NSPoint(x: point.x - pillFrame.width / 2, y: point.y - pillFrame.height / 2))
                pillDragMoved()
            case "pillEnd":
                DragPointer.scripted = point
                pillDragEnded()
                DragPointer.scripted = nil
            default: return "unknown drag step"
            }
        case "moveRow":
            guard valid, let target = command.target, sessions.indices.contains(target) else { return "needs index and target" }
            moveSession(sessions[index], to: target)
            saveState()
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
        case "intro":
            // key: the page; value false ends it like Skip.
            if command.value ?? true {
                openIntro(at: command.key.flatMap(IntroPage.init(rawValue:)) ?? .welcome)
            } else {
                settingsDone()
            }
        case "pin": togglePin()
        case "setting":
            // The Panel/Terminal/General cards: key, with value (switches) or width (numbers).
            let on = command.value ?? false, number = command.width ?? 0
            let change: SettingsChange? = switch command.key {
            case "foldOnClickOutside": .foldOnClickOutside(on)
            case "fadeWhenInactive": .fadeWhenInactive(on)
            case "inactiveOpacity": .inactiveOpacity(number, done: true)
            case "hidePill": .hidePill(on)
            case "terminalFontSize": .terminalFontSize(number)
            case "terminalOpacity": .terminalOpacity(number, done: true)
            case "copyOnSelect": .copyOnSelect(on)
            case "confirmQuit": .confirmQuit(on)
            default: nil
            }
            guard let change else { return "unknown setting" }
            manager.applySetting(change)
        case "probe":
            // A fresh settings page (name "settings") or header (else) at `width`, drawn
            // offscreen over a plain window in light or dark (value: dark), to check layout.
            guard let path = command.directory else { return "needs a path (directory)" }
            let width = CGFloat(command.width ?? 480)
            let view: NSView
            if let name = command.name, name.hasPrefix("intro-"), let page = IntroPage(rawValue: String(name.dropFirst(6))) {
                // An intro page (name "intro-<page>"), bar included, `width` × 520.
                let intro = IntroView(frame: NSRect(x: 0, y: 0, width: width, height: 520))
                intro.show(page)
                intro.update(introModel)
                view = intro
            } else if command.name == "settings" {
                let page = SettingsView(frame: NSRect(x: 0, y: 0, width: width, height: 2400))
                page.update(settingsModel)
                view = page.documentView
            } else {
                let header = HeaderView(frame: NSRect(x: 0, y: 0, width: width, height: ExpandedView.headerHeight),
                                        title: session.name + " with a long name to check truncation")
                header.setPinned(pinned, shown: config.foldOnClickOutside)
                view = header
            }
            let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: width, height: 2400),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: command.value == true ? .darkAqua : .aqua)
            window.isReleasedWhenClosed = false
            let host = NSView(frame: window.contentLayoutRect)
            window.contentView = host
            host.addSubview(view)
            view.frame.size.width = width
            for _ in 0..<4 { view.layoutSubtreeIfNeeded() }  // wrapping labels take their width a pass late
            if command.name == "settings" {
                view.widthAnchor.constraint(equalToConstant: width).isActive = true
                view.layoutSubtreeIfNeeded()
                view.frame.size = NSSize(width: width, height: view.fittingSize.height)
            }
            view.frame.origin = .zero
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return "no bitmap" }
            let image = NSImage(size: view.bounds.size, flipped: false) { rect in
                window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    NSColor.windowBackgroundColor.setFill()
                    rect.fill()
                    view.cacheDisplay(in: view.bounds, to: rep)
                    rep.draw(in: rect)
                }
                return true
            }
            guard let tiff = image.tiffRepresentation, let flat = NSBitmapImageRep(data: tiff),
                  let png = flat.representation(using: .png, properties: [:]) else { return "no png" }
            do { try png.write(to: URL(fileURLWithPath: path)) } catch { return "\(error)" }
        case "snapshot":
            guard let path = command.directory else { return "needs a path (directory)" }
            // name "settings": the whole settings page, scrolled parts included.
            let view = command.name == "settings" ? expandedView.settingsView.documentView : glass.contentView
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
            "frame": [Double(panel.frame.minX), Double(panel.frame.minY), Double(panel.frame.width), Double(panel.frame.height)],
            "animating": isAnimating,
            "key": panel.isKeyWindow,
            "settings": settingsShown,
            "intro": introShown ? expandedView.settingsView.intro.page.rawValue : "",
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
            "pinned": pinned,
            "pillHidden": isPillHidden,
            "visible": panel.isVisible,
            "fade": Double(glass.fadeAlpha),
            "clickOutsideMonitor": clickOutsideMonitor != nil,
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
                    "conversation": each.conversationID ?? "",
                    "shown": each.isShown,
                    "screen": each.screenText,
                ]
            },
        ]
    }

    // MARK: - Keep open, fade, hidden pill (DESIGN §6.3, §7.20, §7.21)

    /// A click outside folds the panel: the setting is on and this pill isn't pinned.
    /// Never during the intro: the user goes to System Settings and back (DESIGN §9.15).
    private var foldsOnClickOutside: Bool { config.foldOnClickOutside && !pinned && !introShown }

    private func togglePin() {
        pinned.toggle()
        appLog("pin: \(pinned ? "on" : "off")")
        updatePinButton()
        clickOutsideChanged()
        saveState()
    }

    /// The pin is hidden while a click outside never folds anyway.
    private func updatePinButton() {
        expandedView.header.setPinned(pinned, shown: config.foldOnClickOutside)
    }

    /// The fold setting or the pin changed: the monitor follows (installed only once key,
    /// as after an unfocused auto-open).
    func clickOutsideChanged() {
        updatePinButton()
        if !foldsOnClickOutside {
            removeClickOutsideMonitor()
        } else if state == .expanded, !isAnimating, panel.isKeyWindow {
            installClickOutsideMonitor()
        }
    }

    /// Fade when not focused: the open panel, not key and not under the mouse, fades to
    /// the set opacity; everything else is at full opacity.
    func updateFade() {
        let faded = config.fadeWhenInactive && state == .expanded && !isAnimating && !panel.isKeyWindow
            && !NSMouseInRect(NSEvent.mouseLocation, panel.frame, false)
        glass.setFade(faded ? CGFloat(config.inactiveOpacity) : 1, animated: true) { [weak self] in
            self?.panel.refreshShadow()  // the rim is the shadow; it follows the glass's alpha
        }
    }

    /// Collapsed with Hide pill on: ordered out (only while collapsed and not animating).
    private func hidePill() {
        guard !isPillHidden else { return }
        isPillHidden = true
        panel.orderOut(nil)
        appLog("pill: hidden")
        manager.pillVisibilityChanged()
    }

    /// Back on screen as the pill, where it was (before opening, or the setting went off).
    private func showHiddenPill() {
        guard isPillHidden else { return }
        isPillHidden = false
        pillFrame = Self.clamp(pillFrame, in: Self.screen(for: pillFrame))
        panel.setFrame(pillFrame, display: false)
        panel.orderFrontRegardless()
        panel.refreshShadow()
        appLog("pill: shown")
        manager.pillVisibilityChanged()
    }

    /// Hide pill changed: collapsed pills go or come back now.
    func hidePillChanged() {
        guard state == .collapsed, !isAnimating else { return }  // the collapse's end checks it
        if config.hidePill { hidePill() } else { showHiddenPill() }
    }

    // MARK: - Click outside (DESIGN §6.3)

    /// Global monitors see only events delivered to other apps (other windows, the
    /// desktop, other menu bar items), never clicks on Poppy's own panel or menu bar item.
    /// Mouse events need no Accessibility permission. Left clicks collapse on mouse-up,
    /// and not when released over the panel, so dragging a file in from Finder works.
    private func installClickOutsideMonitor() {
        guard clickOutsideMonitor == nil, foldsOnClickOutside else { return }
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
        guard state == .expanded, !isAnimating, foldsOnClickOutside,
              !NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) else { return }
        collapse()
    }

    private func finishAnimation() {
        isAnimating = false
        updateFade()
        if needsReclamp {
            needsReclamp = false
            reclamp()
        }
        // A report that arrived during Settings…' own expand leaves the page open; later
        // ones close it. Other pills' waiting auto-opens may go now too.
        manager.animationFinished()
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

    /// While the pill is dragged: a pill under the mouse is highlighted, and this one dims
    /// so the highlight shows through it.
    func pillDragMoved() {
        guard state == .collapsed, !isAnimating else { return }
        panel.alphaValue = manager.pillDragMoved(self) ? 0.5 : 1
    }

    /// The pill drag stopped without a drop (an animation took over).
    func pillDragCancelled() {
        panel.alphaValue = 1
        manager.pillDragCancelled()
    }

    func pillDragEnded() {
        panel.alphaValue = 1
        guard state == .collapsed, !isAnimating else {
            manager.clearDropHighlight()
            return
        }
        if manager.pillDropped(self) { return }  // merged into the pill under it
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

    private func setPillDiameter(_ diameter: CGFloat) {
        manager.setPillDiameter(diameter)
    }

    /// The manager changed the size preset (every pill's). Collapsed, the pill grows or
    /// shrinks from its nearest screen corner; expanded, the next collapse uses it.
    func pillDiameterChanged() {
        let diameter = pillDiameter
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
    }

    // MARK: - Observers

    @objc private func activeSpaceDidChange(_ notification: Notification) {
        guard !isPillHidden else { return }  // stays hidden (DESIGN §7.21)
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

    /// The whole layout is saved, every pill (DESIGN §8.2).
    private func saveState() {
        manager.saveLayout()
    }

    // MARK: - Poppy menu (DESIGN §7.10)

    /// The menu acts on the pill it was opened from, which becomes the most recent.
    func showContextMenu(event: NSEvent, in view: NSView) {
        manager.used(self)
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

    /// This pill's items; `clear: false` appends them (the menu bar menu's pill list
    /// comes first, DESIGN §7.12).
    func populateMenu(_ menu: NSMenu, clear: Bool = true) {
        if clear { menu.removeAllItems() }

        // With keep-open, a click outside may not fold it (DESIGN §6.3).
        if state == .expanded {
            let collapseItem = NSMenuItem(title: "Collapse", action: #selector(collapseFromMenu), keyEquivalent: "")
            collapseItem.target = self
            collapseItem.isEnabled = !isAnimating
            menu.addItem(collapseItem)
            menu.addItem(.separator())
        }

        // Sessions (DESIGN §7.17). The ⌘ hints are handled by GlassPanel (§6.2).
        for (title, action, key) in [("New Session", #selector(newSessionFromMenu), "t"),
                                     ("Rename Session…", #selector(renameSessionFromMenu), ""),
                                     ("Close Session", #selector(closeSessionFromMenu), "w")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = .command
            item.target = self
            item.isEnabled = !isAnimating && (action != #selector(closeSessionFromMenu) || canCloseSession)
            menu.addItem(item)
            if action == #selector(newSessionFromMenu) { menu.addItem(manager.newPillItem()) }
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

    /// A click on the header's title: the selected session's folder, the recents, Choose
    /// Folder… (DESIGN §7.9). Not during an animation or under the close question.
    private func showDirectoryMenu(from view: NSView) {
        guard state == .expanded, !isAnimating, expandedView.confirmView == nil else { return }
        let menu = makeDirectoryMenu()
        menu.insertItem(.sectionHeader(title: "Working Directory"), at: 0)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.height + 4 : -4), in: view)
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

    /// The selected session to another folder (the menu, the picker, the settings page;
    /// DESIGN §9.8), with at most one restart, then (if `show`) expands and focuses the
    /// panel. (The `poppy` command goes through `PillManager.apply` since M25.)
    private func apply(_ request: LaunchRequest) {
        var directory = workingDirectory
        if let requested = request.directory {
            let path = Config.normalize(requested)
            if Self.isDirectory(path) {
                directory = path
                manager.addRecentDirectory(path)
                saveState()
            } else {
                appLog("working directory \(path) is not a directory; ignored")
            }
        }
        changeAgent(command: request.command ?? session.command, directory: directory)
        refreshSettings()

        guard request.show, !isAnimating else { return }
        closeSettings()  // the user wants the agent
        showFocused()
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
        saveState()
    }

    static func isDirectory(_ path: String) -> Bool {
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

    /// Global settings live in the manager, shared by every pill (DESIGN §7.18).
    private func setAutoOpen(_ key: String, _ on: Bool) {
        manager.setAutoOpen(key, on)
    }

    private func setShowUsage(_ on: Bool) {
        manager.setShowUsage(on)
    }

    /// Show Usage changed (for every pill).
    func usageEnabledChanged() {
        usage.setEnabled(config.showUsage)
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
        if settingsShown, state == .expanded {
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
        finishIntro()
        expandedView.settingsView.hotkeyField.cancel()
        expandedView.settingsView.actHotkeyField.cancel()
        expandedView.settingsView.sendHotkeyField.cancel()
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
    func refreshSettings() {
        expandedView.settingsView.update(settingsModel)
        refreshIntro()
    }

    /// Done, Esc or Skip: the intro opened from the settings page goes back to it; anything
    /// else closes the page.
    private func settingsDone() {
        if introShown, introReturnsToSettings {
            finishIntro()
            refreshSettings()
            if state == .expanded { panel.makeFirstResponder(expandedView.settingsView) }
            return
        }
        closeSettings()
    }

    private var settingsModel: SettingsModel {
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
        return SettingsModel(
            agents: agentChoices,
            currentAgent: menuAgents.firstIndex { AgentCatalog.same($0.command, session.command) },
            directories: Array(directories),
            pillPresets: Self.pillPresets.map(\.name), pillPreset: preset,
            showUsage: config.showUsage, statusHooks: config.statusHooks,
            autoOpenOnInput: config.autoOpenOnInput, autoOpenOnDone: config.autoOpenOnDone,
            autoOpenFocus: config.autoOpenFocus, foldOnPrompt: config.foldOnPrompt,
            hotkey: hotKeys?.current?.displayString, canRecordHotkey: hotKeys?.canRecord == true,
            hotkeyTargets: HotkeyTarget.allCases.map(\.title),
            hotkeyTarget: HotkeyTarget.allCases.firstIndex(of: config.hotkeyTarget) ?? 0,
            actHotkey: manager.actHotKeys?.current?.displayString,
            canRecordActHotkey: manager.actHotKeys?.canRecord == true, actEnabled: config.actEnabled,
            sendHotkey: manager.sendHotKeys?.current?.displayString,
            canRecordSendHotkey: manager.sendHotKeys?.canRecord == true, sendEnabled: config.sendEnabled,
            settings: config, launchAtLogin: LaunchAtLogin.state)
    }

    // MARK: - Intro (DESIGN §9.15)

    /// The intro shows on the settings page.
    var introShown: Bool { settingsShown && expandedView.settingsView.showsIntro }
    /// Opened from the settings page, which comes back when it ends.
    private var introReturnsToSettings = false
    /// Re-reads every row once a second while the intro shows.
    private var introTimer: Timer?
    /// The login shell's PATH and Antigravity's login, read in the background.
    private var introSlow: IntroChecks.Slow?
    private var readingIntroSlow = false

    private func wireIntro() {
        let intro = expandedView.settingsView.intro
        intro.onPageChanged = { [weak self] page in self?.introPageShown(page) }
        intro.onFinish = { [weak self] in self?.settingsDone() }
        intro.onAgent = { [weak self] index in
            guard let self, AgentCatalog.builtIns.indices.contains(index) else { return }
            useAgent(AgentCatalog.builtIns[index])
        }
        intro.onActEnabled = { [weak self] on in self?.manager.setActEnabled(on) }
        intro.onAllowAccessibility = { [weak self] in self?.manager.askForPermission(accessibility: true) }
        intro.onAllowScreenRecording = { [weak self] in self?.manager.askForPermission(accessibility: false) }
        intro.onRestart = { [weak self] in self?.manager.relaunchForIntro() }
        intro.onStatusHooks = { [weak self] on in
            self?.setStatusHooks(on)
            self?.refreshSettings()
        }
        intro.onAutoOpen = { [weak self] key, on in
            self?.setAutoOpen(key, on)
            self?.refreshSettings()
        }
        intro.onShowUsage = { [weak self] on in
            self?.setShowUsage(on)
            self?.refreshSettings()
        }
        intro.onChange = { [weak self] change in self?.manager.applySetting(change) }
        intro.hotkeyField.onBegin = { [weak self] in self?.hotKeys?.beginRecording() ?? false }
        intro.hotkeyField.onRecord = { [weak self] combo in
            self?.hotKeys?.record(combo) ?? .failed("Hotkeys are unavailable.")
        }
        intro.hotkeyField.onEnd = { [weak self] in self?.hotKeys?.endRecording() }
        intro.actHotkeyField.onBegin = { [weak self] in self?.manager.actHotKeys?.beginRecording() ?? false }
        intro.actHotkeyField.onRecord = { [weak self] combo in
            self?.manager.actHotKeys?.record(combo) ?? .failed("Hotkeys are unavailable.")
        }
        intro.actHotkeyField.onEnd = { [weak self] in self?.manager.actHotKeys?.endRecording() }
    }

    /// The default agent (`command`, for new sessions). The selected session switches too
    /// if it runs the old default (at first launch, the one agent).
    private func useAgent(_ profile: AgentProfile) {
        guard !AgentCatalog.same(profile.command, config.command) else { return }
        if AgentCatalog.same(session.command, config.command) {
            switchAgent(to: profile)
        } else {
            appLog("agent: \(profile.command) for new sessions")
            config.command = profile.command
            _ = Config.saveValue(profile.command, forKey: "command")
            refreshSettings()
        }
    }

    /// The intro from `page`; `single` shows only that page (Check Permissions…). From the
    /// pill it grows into the page, like Settings….
    func openIntro(at page: IntroPage = .welcome, single: Bool = false) {
        revealIfArmed()
        guard !isAnimating else { return }
        expandedView.confirmView?.end(false)
        if !introShown { introReturnsToSettings = settingsShown && state == .expanded }
        expandedView.settingsView.setIntroVisible(true)
        expandedView.setSettingsCoversSidebar(true)
        expandedView.settingsView.intro.show(page, single: single)
        appLog("intro: shown (\(page.rawValue)\(single ? ", alone" : ""))")
        if introTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.state == .expanded else { return }
                    self.refreshIntro()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            introTimer = timer
        }
        openSettings()
        clickOutsideChanged()
    }

    /// The intro ended (Skip, Done, or the page closing): it won't show at launch again.
    private func finishIntro() {
        guard introShown else { return }
        appLog("intro: finished on \(expandedView.settingsView.intro.page.rawValue)")
        introTimer?.invalidate()
        introTimer = nil
        expandedView.settingsView.setIntroVisible(false)
        expandedView.setSettingsCoversSidebar(false)
        expandedView.header.setSettingsTitle("Settings", button: "Done")
        manager.introFinished()
        clickOutsideChanged()
    }

    private func introPageShown(_ page: IntroPage) {
        let intro = expandedView.settingsView.intro
        expandedView.header.setSettingsTitle(intro.single ? "Permissions" : "Set Up \(AppVariant.name)",
                                             button: intro.single ? "Done" : "Skip")
        expandedView.settingsView.introPageChanged()
        if page == .agent || page == .finish { readIntroSlowChecks() }
        refreshIntro()
    }

    private func readIntroSlowChecks() {
        guard !readingIntroSlow else { return }
        readingIntroSlow = true
        Task {
            let slow = await Task.detached { IntroChecks.readSlow() }.value
            readingIntroSlow = false
            introSlow = slow
            refreshIntro()
        }
    }

    private func refreshIntro() {
        guard introShown else { return }
        let intro = expandedView.settingsView.intro
        agents.refreshIfNeeded(agents.profiles(for: agentConfig),
                               maxAge: intro.page == .agent ? 5 : AgentCatalog.reprobeInterval)
        intro.update(introModel)
    }

    /// Every row's real state (DESIGN §9.15).
    private var introModel: IntroModel {
        let introAgents = AgentCatalog.builtIns.map { profile in
            let installed = agents.isInstalled(profile)
            return IntroModel.Agent(
                installed: installed,
                signedIn: installed == true ? IntroChecks.isSignedIn(profile.command, agy: introSlow?.agySignedIn) : nil,
                isCurrent: AgentCatalog.same(profile.command, config.command))
        }
        return IntroModel(
            agents: introAgents,
            hotkey: hotKeys?.current?.displayString, canRecordHotkey: hotKeys?.canRecord == true,
            actEnabled: config.actEnabled,
            actHotkey: manager.actHotKeys?.current?.displayString,
            canRecordActHotkey: manager.actHotKeys?.canRecord == true,
            accessibility: SelectionCapture.isTrusted(prompt: false),
            screenRecording: CGPreflightScreenCaptureAccess(),
            askedAccessibility: manager.askedAccessibility, askedScreenRecording: manager.askedScreenRecording,
            canRestart: Bundle.main.bundleURL.pathExtension == "app",
            claudeInstalled: agents.isInstalled(AgentCatalog.builtIns[0]),
            actFolderTrusted: ActController.isTrusted(ActController.folder.path),
            command: IntroChecks.command(path: introSlow?.path),
            launchAtLogin: LaunchAtLogin.state,
            statusHooks: config.statusHooks, autoOpenOnInput: config.autoOpenOnInput,
            autoOpenOnDone: config.autoOpenOnDone, showUsage: config.showUsage)
    }

    private func setStatusHooks(_ on: Bool) {
        manager.setStatusHooks(on)
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
    /// Also Send Selection's paste (§9.17).
    func sendToAgent(_ text: String) {
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

    @objc private func collapseFromMenu() {
        collapse()
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
