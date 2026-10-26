import AppKit

/// Owns the pills (DESIGN §7.18): their order, the most recent one, the one-expanded-at-a-
/// time rule, the hotkey's target, the `poppy` command's routing, the menu bar menu, the
/// global settings every pill shares, and saving the layout.
final class PillManager: NSObject {
    /// Global settings; each pill reads and changes this one copy (DESIGN §8.1).
    var config: Config
    let agents: AgentCatalog
    /// Recent working directories, newest first (DESIGN §9.8).
    var recentDirectories: [String]
    /// Pill size is global (DESIGN §7.14).
    private(set) var pillDiameter: CGFloat
    /// In creation order (the hotkey's cycle order and the menu bar's list).
    private(set) var pills: [PanelController] = []
    /// The pill used last: expanded, or picked in a menu. The menu bar menu, the hotkey
    /// (most recent) and the `poppy` command act on it.
    private(set) weak var recent: PanelController?
    weak var hotKeys: HotKeyManager? {
        didSet { hotKeys?.onComboChanged = { [weak self] in self?.pills.forEach { $0.refreshSettings() } } }
    }
    /// Act on Selection's hotkey (DESIGN §9.14), recorded on the same settings page.
    weak var actHotKeys: HotKeyManager? {
        didSet { actHotKeys?.onComboChanged = { [weak self] in self?.pills.forEach { $0.refreshSettings() } } }
    }
    /// The menu bar item's menu, rebuilt each time it opens (DESIGN §7.12).
    private(set) lazy var statusMenu: NSMenu = {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        return menu
    }()
    /// Set while restoring, so building the pills doesn't save a half-built layout.
    private var restoring = false
    /// The menu bar item, colored by status while pills are hidden (DESIGN §7.21).
    weak var statusItem: NSStatusItem? {
        didSet { updateMenuBarIcon() }
    }
    /// Follow system: the terminals switch with macOS's appearance (DESIGN §9.1).
    private var appearanceObservation: NSKeyValueObservation?
    /// Held while every pill is hidden, so App Nap doesn't slow status polling (DESIGN §7.21).
    private var napActivity: NSObjectProtocol?

    /// Restores the saved layout, or one pill from `config`'s `command` and `cwd` (a first
    /// launch, or a state.json from before M25).
    init(config: Config) {
        self.config = config
        agents = AgentCatalog(launchCommand: config.command)
        let saved = PanelState.load()
        recentDirectories = saved.recentDirectories ?? []
        if let diameter = saved.pillDiameter.map({ CGFloat($0) }),
           PanelController.pillPresets.contains(where: { $0.diameter == diameter }) {
            pillDiameter = diameter
        } else {
            pillDiameter = PanelController.defaultPillDiameter
        }
        super.init()

        restoring = true
        var layout = (saved.pills ?? []).filter { !$0.sessions.isEmpty }  // a pill with no sessions is dropped
        if layout.isEmpty {
            if saved.pills != nil { appLog("pills: none saved, starting one") }
            layout = [SavedPill(origin: saved.pillOrigin, expandedSize: saved.expandedSize,
                                sessions: [SavedSession(command: config.command, cwd: config.cwd)])]
        }
        for pill in layout { addPill(pill) }
        recent = pills.first
        restoring = false
        appLog("pills: \(pills.count) restored (\(pills.map { "\($0.sessionCount)" }.joined(separator: ", ")) sessions)")
        saveLayout()
        pillVisibilityChanged()  // Hide pill: they start hidden
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.allSessions.forEach { $0.appearanceChanged() } }
        }
        agents.refreshIfNeeded(agents.profiles(for: config))
    }

    /// Every session in Poppy, pill by pill (names are unique across all of them).
    var allSessions: [TerminalSession] { pills.flatMap(\.allSessions) }

    var isAnimating: Bool { pills.contains { $0.isAnimating } }

    /// The user is typing in `pill`'s panel, or in another one's (DESIGN §7.15).
    func otherPillIsKey(than pill: PanelController) -> Bool {
        pills.contains { $0 !== pill && $0.state == .expanded && $0.panel.isKeyWindow }
    }

    // MARK: - Pills

    /// A pill from `saved` (its origin if still on a screen, else a free spot).
    @discardableResult
    private func addPill(_ saved: SavedPill) -> PanelController {
        let size = NSSize(width: pillDiameter, height: pillDiameter)
        var frame: NSRect?
        if let origin = saved.origin {
            let rect = NSRect(x: origin.x, y: origin.y, width: size.width, height: size.height)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) {
                frame = PanelController.clamp(rect, in: PanelController.screen(for: rect))
            }
        }
        let pill = PanelController(manager: self, saved: saved,
                                   frame: frame ?? freeFrame(on: NSScreen.main ?? NSScreen.screens[0]))
        pills.append(pill)
        return pill
    }

    /// The default position (DESIGN §7.3), moved left (then up a row) past existing pills.
    private func freeFrame(on screen: NSScreen) -> NSRect {
        let size = NSSize(width: pillDiameter, height: pillDiameter)
        let start = PanelController.defaultPillOrigin(on: screen, size: size)
        let area = screen.visibleFrame.insetBy(dx: PanelController.clampInset, dy: PanelController.clampInset)
        let step = pillDiameter + Self.pillSpacing
        var frame = NSRect(origin: start, size: size)
        let taken = pills.map { $0.pillFrame.insetBy(dx: -Self.pillSpacing / 2, dy: -Self.pillSpacing / 2) }
        while taken.contains(where: { $0.intersects(frame) }) {
            frame.origin.x -= step
            if frame.minX < area.minX {
                frame.origin.x = start.x
                frame.origin.y += step
                if frame.maxY > area.maxY { return NSRect(origin: start, size: size) }  // full: overlap
            }
        }
        return frame
    }

    static let pillSpacing: CGFloat = 12

    /// New Pill, `--new-pill`, or anything that needs a pill when there is none: one
    /// session, placed clear of the others, expanded and focused if `show`.
    @discardableResult
    func newPill(command: String? = nil, directory: String? = nil, show: Bool = true) -> PanelController {
        let session = SavedSession(command: command ?? config.command,
                                   cwd: Config.abbreviate(directory ?? Config.normalize(config.resolvedWorkingDirectory)))
        let pill = addPill(SavedPill(sessions: [session]))
        appLog("pills: new (\(pills.count) pills)")
        saveLayout()
        if show { pill.open() } else { recent = recent ?? pill }
        return pill
    }

    /// Closing a pill's last session removes it. With none left, Poppy stays in the menu
    /// bar; New Pill, New Session, the hotkey or `poppy` bring one back.
    func remove(_ pill: PanelController) {
        guard let index = pills.firstIndex(where: { $0 === pill }) else { return }
        pill.tearDown()
        pills.remove(at: index)
        if recent === pill { recent = pills.last }
        appLog("pills: closed one (\(pills.count) left)")
        saveLayout()
        pillVisibilityChanged()
    }

    /// Expanding `pill` first folds the one that's open. False (nothing expands) if that
    /// one can't fold right now (mid-animation or being resized).
    func willExpand(_ pill: PanelController) -> Bool {
        for other in pills where other !== pill && other.state == .expanded {
            guard !other.isAnimating, !other.panel.inLiveResize else { return false }
            other.collapse()
        }
        recent = pill
        return true
    }

    func used(_ pill: PanelController) {
        recent = pill
    }

    /// Any pill finished animating: auto-opens that waited for it may go now.
    func animationFinished() {
        for pill in pills where !pill.isAnimating { pill.retryPendingAutoOpen() }
    }

    func terminateAll() {
        endNapActivity()
        saveLayout()
        pills.forEach { $0.terminateAll() }
    }

    // MARK: - Dragging between pills (DESIGN §7.19)

    /// The Liquid Glass side of dragging (made on first use; nil without Liquid Glass, where
    /// the drag image and the accent highlight below are used instead).
    private var liquidStorage: AnyObject?

    @available(macOS 26, *)
    private var liquid: LiquidDrag? {
        // Off if the glass can't be hidden apart from its content (a later macOS).
        guard GlassBackgroundView.isLiquid, pills.first?.canLendGlass ?? true else { return nil }
        if let made = liquidStorage as? LiquidDrag { return made }
        let made = LiquidDrag(manager: self)
        liquidStorage = made
        return made
    }

    /// The dragged row's image, above every pill; made once and reused.
    private var dragImage: DragImageWindow?
    /// Where the row was grabbed, from its bottom-left corner.
    private var dragOffset = NSPoint.zero
    private weak var highlighted: PanelController?

    /// A collapsed pill other than `excluded` under `mouse`: where a drop goes. With
    /// `expanded`, an open panel under it too (a pill dropped onto it); a collapsed pill
    /// over that panel comes first.
    func dropTarget(at mouse: NSPoint, excluding excluded: PanelController, expanded: Bool = false) -> PanelController? {
        let under = pills.filter {
            $0 !== excluded && !$0.isAnimating && !$0.isPillHidden && NSMouseInRect(mouse, $0.panel.frame, false)
        }
        return under.first { $0.state == .collapsed }
            ?? (expanded ? under.first { $0.state == .expanded && !$0.panel.inLiveResize } : nil)
    }

    /// Highlights the pill a drop would go to; true if there is one.
    @discardableResult
    func highlightDropTarget(excluding excluded: PanelController) -> Bool {
        let target = dropTarget(at: DragPointer.location, excluding: excluded)
        if target !== highlighted {
            highlighted?.setDropHighlight(false)
            target?.setDropHighlight(true)
            highlighted = target
        }
        return target != nil
    }

    func clearDropHighlight() {
        highlighted?.setDropHighlight(false)
        highlighted = nil
    }

    func rowDragBegan(_ session: TerminalSession, from source: PanelController, image: NSImage?, frame: NSRect) {
        if #available(macOS 26, *), let liquid {
            liquid.rowDragBegan(session, from: source, frame: frame)
            return
        }
        let mouse = DragPointer.location
        dragOffset = NSPoint(x: mouse.x - frame.minX, y: mouse.y - frame.minY)
        let window = dragImage ?? DragImageWindow()
        dragImage = window
        window.show(image, size: frame.size)
    }

    /// Over the source's sidebar the row itself moves (no image); elsewhere the image
    /// follows the mouse.
    func rowDragMoved(from source: PanelController, overSidebar: Bool, rowFrame: NSRect) {
        if #available(macOS 26, *), let liquid {
            liquid.rowDragMoved(overSidebar: overSidebar, rowFrame: rowFrame)
            return
        }
        let mouse = DragPointer.location
        if overSidebar {
            dragImage?.orderOut(nil)
        } else if let dragImage {
            dragImage.setFrameOrigin(NSPoint(x: mouse.x - dragOffset.x, y: mouse.y - dragOffset.y))
            dragImage.orderFrontRegardless()
        }
        highlightDropTarget(excluding: source)
    }

    /// Dropped over its own panel: the reorder (already done) stays. Over another pill: it
    /// joins that pill. Anywhere else: a new collapsed pill there. Its agent keeps running.
    func rowDragEnded(_ session: TerminalSession, from source: PanelController, overPanel: Bool) {
        if #available(macOS 26, *), let liquid {
            if !liquid.rowDragEnded(overPanel: overPanel) { saveLayout() }  // only reordered
            return
        }
        dragImage?.orderOut(nil)
        let mouse = DragPointer.location
        let target = overPanel ? nil : dropTarget(at: mouse, excluding: source)
        clearDropHighlight()
        if overPanel {
            saveLayout()
            return
        }
        move(session, from: source, to: target, newPillAt: mouse)
    }

    /// `session` leaves `source` (never its last) for `target`, or for a new collapsed pill
    /// centered on `point` (clamped to that screen), which is returned.
    @discardableResult
    func move(_ session: TerminalSession, from source: PanelController, to target: PanelController?,
              newPillAt point: NSPoint = .zero) -> PanelController? {
        source.giveAway(session)
        if let target {
            appLog("pills: \"\(session.name)\" dropped onto another pill")
            target.adopt([session])
        } else {
            let diameter = pillDiameter
            let rect = NSRect(x: point.x - diameter / 2, y: point.y - diameter / 2, width: diameter, height: diameter)
            let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? PanelController.screen(for: rect)
            var saved = source.savedPill  // the same expanded size and sidebar
            saved.origin = nil
            saved.pinned = nil
            saved.selected = 0
            saved.sessions = []
            let pill = PanelController(manager: self, saved: saved, frame: PanelController.clamp(rect, in: screen),
                                       adopting: [session])
            pills.append(pill)
            appLog("pills: \"\(session.name)\" dragged out to a new pill (\(pills.count) pills)")
            saveLayout()
            return pill
        }
        saveLayout()
        return nil
    }

    /// A pill is dragged: true if it should dim (the plain highlight shows a pill under it).
    func pillDragMoved(_ pill: PanelController) -> Bool {
        if #available(macOS 26, *), let liquid {
            liquid.pillDragMoved(pill)
            return false
        }
        return highlightDropTarget(excluding: pill)
    }

    func pillDragCancelled() {
        if #available(macOS 26, *), let liquid { liquid.cancel() }
        clearDropHighlight()
    }

    /// A pill dropped onto another: all its sessions join the end of that one's sidebar,
    /// which keeps its position, selection and collapsed state; the dropped pill goes.
    /// False if it wasn't over a pill.
    func pillDropped(_ pill: PanelController) -> Bool {
        if #available(macOS 26, *), let liquid {
            return liquid.pillDropped(pill) { [weak self] target in self?.merge(pill, into: target) }
        }
        let target = dropTarget(at: DragPointer.location, excluding: pill, expanded: true)
        clearDropHighlight()
        guard let target else { return false }
        merge(pill, into: target)
        return true
    }

    private func merge(_ pill: PanelController, into target: PanelController) {
        appLog("pills: merged a pill of \(pill.sessionCount) into one of \(target.sessionCount)")
        target.adopt(pill.giveAwayAll())
        remove(pill)
        if recent == nil || recent === pill { recent = target }
    }

    // MARK: - Global settings (DESIGN §7.9)

    func setPillDiameter(_ diameter: CGFloat) {
        guard diameter != pillDiameter, !isAnimating else { return }
        pillDiameter = diameter
        pills.forEach { $0.pillDiameterChanged() }
        saveLayout()
    }

    func setAutoOpen(_ key: String, _ on: Bool) {
        switch key {
        case "autoOpenOnInput": config.autoOpenOnInput = on
        case "autoOpenOnDone": config.autoOpenOnDone = on
        case "autoOpenFocus": config.autoOpenFocus = on
        case "foldOnPrompt": config.foldOnPrompt = on
        default: return
        }
        appLog("auto-open: \(key) = \(on)")
        if !Config.saveValue(on, forKey: key) {
            appLog("auto-open: \(key) not saved; it applies until Poppy quits")
        }
    }

    func setShowUsage(_ on: Bool) {
        guard on != config.showUsage else { return }
        config.showUsage = on
        appLog("usage: showUsage = \(on)")
        pills.forEach { $0.usageEnabledChanged() }
        if !Config.saveValue(on, forKey: "showUsage") {
            appLog("usage: showUsage not saved; it applies until Poppy quits")
        }
    }

    /// Saves `statusHooks`; running agents keep their hooks until they restart (DESIGN §9.6).
    func setStatusHooks(_ on: Bool) {
        guard on != config.statusHooks else { return }
        config.statusHooks = on
        allSessions.forEach { $0.setStatusHooks(on) }
        appLog("status hooks: statusHooks = \(on) (from the next agent start)")
        if !Config.saveValue(on, forKey: "statusHooks") {
            appLog("status hooks: statusHooks not saved; it applies until Poppy quits")
        }
    }

    /// Act on Selection on or off (DESIGN §9.14): its hotkey is registered only while on.
    func setActEnabled(_ on: Bool) {
        guard on != config.actEnabled else { return }
        config.actEnabled = on
        actHotKeys?.setActive(on)
        appLog("act: \(on ? "on" : "off")")
        save(on, "actEnabled")
        pills.forEach { $0.refreshSettings() }
    }

    // MARK: - Intro (DESIGN §9.15)

    /// The permission was asked for once this run: the intro's button opens System Settings.
    private(set) var askedAccessibility = false
    private(set) var askedScreenRecording = false

    /// The intro in the most recent pill (a new one if there's none).
    func showIntro(at page: IntroPage = .welcome) {
        (recent ?? newPill(show: false)).openIntro(at: page)
    }

    /// The first time, macOS's own question (it also lists Poppy in System Settings);
    /// after that, the Privacy & Security pane.
    func askForPermission(accessibility: Bool) {
        if accessibility ? askedAccessibility : askedScreenRecording {
            applySetting(.openPrivacySettings(accessibility ? "Accessibility" : "ScreenCapture"))
        } else if accessibility {
            askedAccessibility = true
            _ = SelectionCapture.isTrusted(prompt: true)
        } else {
            askedScreenRecording = true
            CGRequestScreenCaptureAccess()
        }
        appLog("intro: asked for \(accessibility ? "Accessibility" : "Screen Recording")")
        pills.forEach { $0.refreshSettings() }
    }

    func introFinished() {
        guard !config.introShown else { return }
        config.introShown = true
        save(true, "introShown")
    }

    /// Restart Poppy (macOS may only see a new Screen Recording grant after one): a shell
    /// opens it again a second after it quits, on the intro's permissions page.
    func relaunchForIntro() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open -a \"$0\" --args \(IntroView.relaunchFlag)",
                             Bundle.main.bundlePath]
        do {
            try process.run()
        } catch {
            appLog("intro: couldn't relaunch: \(error)")
            return
        }
        appLog("intro: relaunching")
        NSApp.terminate(nil)
    }

    /// The Panel, Terminal and General cards (DESIGN §7.9): applied at once to every pill
    /// and session, saved to config.json, and every settings page refreshed.
    func applySetting(_ change: SettingsChange) {
        var refresh = true
        switch change {
        case .foldOnClickOutside(let on):
            config.foldOnClickOutside = on
            save(on, "foldOnClickOutside")
            pills.forEach { $0.clickOutsideChanged() }
        case .fadeWhenInactive(let on):
            config.fadeWhenInactive = on
            save(on, "fadeWhenInactive")
            pills.forEach { $0.updateFade() }
        case .inactiveOpacity(let value, let done):
            config.inactiveOpacity = Config.clamped(value, to: Config.inactiveOpacityRange)
            if done { save(config.inactiveOpacity, "inactiveOpacity") }
            refresh = done
            pills.forEach { $0.updateFade() }
        case .hidePill(let on):
            config.hidePill = on
            save(on, "hidePill")
            pills.forEach { $0.hidePillChanged() }
            pillVisibilityChanged()
        case .terminalFont(let name):
            config.terminalFont = name
            save(name ?? NSNull(), "terminalFont")
            lookChanged()
        case .terminalFontSize(let size):
            setTerminalFontSize(size)
        case .terminalTheme(let theme):
            config.terminalTheme = theme
            save(theme.rawValue, "terminalTheme")
            lookChanged()
        case .terminalOpacity(let value, let done):
            config.terminalOpacity = Config.clamped(value, to: Config.terminalOpacityRange)
            if done { save(config.terminalOpacity, "terminalOpacity") }
            refresh = done
            lookChanged()
        case .cursorStyle(let shape):
            config.cursorStyle = shape
            save(shape.rawValue, "cursorStyle")
            lookChanged()
        case .cursorBlink(let on):
            config.cursorBlink = on
            save(on, "cursorBlink")
            lookChanged()
        case .copyOnSelect(let on):
            config.copyOnSelect = on
            save(on, "copyOnSelect")
            lookChanged()
        case .confirmQuit(let on):
            config.confirmQuit = on
            save(on, "confirmQuit")
        case .actCleanup(let cleanup):
            config.actCleanup = cleanup
            save(cleanup.rawValue, "actCleanup")
        case .openPrivacySettings(let pane):
            let url = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_" + pane
            if let url = URL(string: url) { NSWorkspace.shared.open(url) }
        case .launchAtLogin(let on):
            LaunchAtLogin.set(on)
        case .openLoginItems:
            LaunchAtLogin.openSystemSettings()
        }
        if refresh { pills.forEach { $0.refreshSettings() } }
    }

    /// ⌘+ / ⌘– (`step` ±1) and ⌘0 (0: back to 13 pt) in a terminal: the one size for all.
    func zoomTerminal(_ step: Int) {
        let size = step == 0 ? Config().terminalFontSize : config.terminalFontSize + Double(step)
        setTerminalFontSize(size)
        pills.forEach { $0.refreshSettings() }
    }

    private func setTerminalFontSize(_ size: Double) {
        let size = Config.clamped(size, to: Config.fontSizeRange).rounded()
        guard size != config.terminalFontSize else { return }
        config.terminalFontSize = size
        save(size, "terminalFontSize")
        lookChanged()
    }

    /// Every session's terminal gets the new look now (new ones get it at creation).
    private func lookChanged() {
        allSessions.forEach { $0.setLook(from: config) }
    }

    private func save(_ value: Any, _ key: String) {
        appLog("settings: \(key) = \(value)")
        if !Config.saveValue(value, forKey: key) {
            appLog("settings: \(key) not saved; it applies until Poppy quits")
        }
    }

    // MARK: - Hidden pills (DESIGN §7.21)

    private var allHidden: Bool { !pills.isEmpty && pills.allSatisfy(\.isPillHidden) }

    /// An Act on Selection session (DESIGN §9.14) in the most recent pill (a new pill if
    /// there's none), opened only if `show`. After a restart it's a plain `claude`.
    func startActSession(command: String, directory: String, name: String, show: Bool) {
        if config.actCleanup == .next { closeFinishedActSessions() }
        let pill = recent ?? newPill(show: false)
        pill.addActSession(command: "claude", startCommand: command, directory: directory, name: name, show: show)
        saveLayout()
    }

    /// Act on Selection sessions that are done and were never looked at (DESIGN §9.14), done
    /// at least `age` ago; working, waiting or opened ones are never closed.
    func closeFinishedActSessions(age: TimeInterval = 0) {
        for pill in pills {
            for session in pill.allSessions where session.isTransient && !session.wasSeen && session.status == .done {
                guard let doneAt = session.doneAt, Date().timeIntervalSince(doneAt) >= age else { continue }
                appLog("act: closing finished \"\(session.name)\"")
                pill.closeFinished(session)
            }
        }
    }

    /// A pill hid or showed: the menu bar icon, and App Nap held off while all are hidden.
    func pillVisibilityChanged() {
        if allHidden, napActivity == nil {
            napActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Poppy watches its agents' status while its pills are hidden")
            appLog("pills: all hidden")
        } else if !allHidden {
            endNapActivity()
        }
        updateMenuBarIcon()
    }

    private func endNapActivity() {
        guard let napActivity else { return }
        ProcessInfo.processInfo.endActivity(napActivity)
        self.napActivity = nil
    }

    /// With Hide pill on, the menu bar icon takes the most urgent status color and its
    /// tooltip lists the sessions that need you; otherwise it's never colored (M14).
    func updateMenuBarIcon() {
        guard let button = statusItem?.button else { return }
        guard config.hidePill else {
            button.contentTintColor = nil
            button.toolTip = AppVariant.name
            return
        }
        let sessions = allSessions
        let urgent = sessions.map(\.status).max { PanelController.urgency($0) < PanelController.urgency($1) } ?? .idle
        if button.contentTintColor != urgent.tint { button.contentTintColor = urgent.tint }
        let needYou = sessions.filter { $0.status == .waiting || $0.status == .done }
        button.toolTip = needYou.isEmpty ? AppVariant.name
            : ([AppVariant.name] + needYou.map { "\($0.name)\(PillView.statusSuffix($0.status))" }).joined(separator: "\n")
    }

    @objc private func showRecentFromMenu() {
        recent?.open()
    }

    // MARK: - Quitting (DESIGN §4)

    /// Agents still working or waiting, for Confirm before quitting.
    var busySessionCount: Int {
        allSessions.filter { $0.status == .working || $0.status == .waiting }.count
    }

    func setHotkeyTarget(_ target: HotkeyTarget) {
        guard target != config.hotkeyTarget else { return }
        config.hotkeyTarget = target
        appLog("hotkey: opens \(target.rawValue)")
        if !Config.saveValue(target.rawValue, forKey: "hotkeyTarget") {
            appLog("hotkey: hotkeyTarget not saved; it applies until Poppy quits")
        }
    }

    func addRecentDirectory(_ path: String) {
        recentDirectories = Array(([path] + recentDirectories.filter { $0 != path }).prefix(PanelController.maxRecentDirectories))
    }

    // MARK: - Hotkey (DESIGN §11)

    func hotkeyPressed() {
        guard !isAnimating else { return }
        guard let recent else {
            newPill()
            return
        }
        switch config.hotkeyTarget {
        case .recent:
            recent.hotkeyPressed()
        case .urgent:
            guard let (pill, session) = mostUrgent() else {
                recent.hotkeyPressed()
                return
            }
            pill.hotkeyPressed(showing: session)
        case .cycle:
            guard let open = pills.first(where: { $0.state == .expanded && $0.panel.isKeyWindow }), pills.count > 1 else {
                recent.hotkeyPressed()
                return
            }
            let index = pills.firstIndex { $0 === open } ?? 0
            let next = pills[(index + 1) % pills.count]
            open.collapse()
            next.hotkeyPressed()  // collapsed: moves to the mouse's screen if needed, then expands
        }
    }

    /// The session that needs the user most (waiting, then unseen done), preferring the
    /// most recent pill, then pill order.
    private func mostUrgent() -> (PanelController, TerminalSession)? {
        let ordered = (recent.map { [$0] } ?? []) + pills.filter { $0 !== recent }
        for wanted in [AgentStatus.waiting, .done] {
            for pill in ordered {
                if let session = pill.allSessions.first(where: { $0.status == wanted }) { return (pill, session) }
            }
        }
        return nil
    }

    // MARK: - The `poppy` command (DESIGN §9.9)

    /// Settings first; then the session: the first one already in that folder (with that
    /// agent, if one was asked for), else a new one in the most recent pill (or a new
    /// pill). Never restarts a running agent.
    func apply(_ request: LaunchRequest) {
        if let diameter = request.pillDiameter.map({ CGFloat($0) }),
           PanelController.pillPresets.contains(where: { $0.diameter == diameter }) {
            setPillDiameter(diameter)  // only the presets, whoever wrote the request (DESIGN §7.14)
        }
        for (key, value) in [("autoOpenOnInput", request.autoOpenOnInput), ("autoOpenOnDone", request.autoOpenOnDone),
                             ("autoOpenFocus", request.autoOpenFocus)] {
            if let value { setAutoOpen(key, value) }
        }
        if let showUsage = request.showUsage { setShowUsage(showUsage) }

        var directory = Config.normalize(config.resolvedWorkingDirectory)
        if let requested = request.directory.map(Config.normalize) {
            if PanelController.isDirectory(requested) {
                directory = requested
                addRecentDirectory(requested)
            } else {
                appLog("working directory \(requested) is not a directory; ignored")
            }
        }
        if let command = request.command, !AgentCatalog.same(command, config.command) {
            config.command = command  // the default for the next new session, as an agent change saves it
            _ = Config.saveValue(command, forKey: "command")
        }
        let command = request.command ?? config.command
        pills.forEach { $0.refreshSettings() }

        if request.newPill == true {
            appLog("poppy: new pill in \(directory)")
            newPill(command: command, directory: directory, show: request.show)
        } else if request.new != true, let (pill, session) = existingSession(in: directory, command: request.command) {
            appLog("poppy: reusing \"\(session.name)\"")
            pill.reveal(session, show: request.show)
        } else if let recent {
            appLog("poppy: new session in \(directory)")
            recent.addSession(command: command, directory: directory, show: request.show)
        } else {
            newPill(command: command, directory: directory, show: request.show)
        }
        saveLayout()
    }

    /// The first session in `directory` (and running `command`, if given), most recent pill first.
    private func existingSession(in directory: String, command: String?) -> (PanelController, TerminalSession)? {
        let ordered = (recent.map { [$0] } ?? []) + pills.filter { $0 !== recent }
        for pill in ordered {
            if let session = pill.allSessions.first(where: { session in
                session.workingDirectory == directory && (command.map { AgentCatalog.same($0, session.command) } ?? true)
            }) { return (pill, session) }
        }
        return nil
    }

    // MARK: - Layout (DESIGN §8.2)

    func saveLayout() {
        guard !restoring else { return }
        let layout = pills.map(\.savedPill)
        let first = layout.first
        PanelState(pills: layout,
                   pillOrigin: first?.origin,
                   pillDiameter: pillDiameter,
                   expandedSize: first?.expandedSize,
                   recentDirectories: recentDirectories).save()
    }

    // MARK: - Menu bar menu (DESIGN §7.10, §7.12)

    @objc private func newPillFromMenu() {
        newPill()
    }

    @objc private func openPillFromMenu(_ sender: NSMenuItem) {
        guard pills.indices.contains(sender.tag) else { return }
        pills[sender.tag].open()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// The "New Pill" item, in every pill's menu too.
    func newPillItem() -> NSMenuItem {
        let item = NSMenuItem(title: "New Pill", action: #selector(newPillFromMenu), keyEquivalent: "")
        item.target = self
        item.isEnabled = !isAnimating
        return item
    }

    /// With 2+ pills, one item per pill to open it (its selected session and most urgent
    /// status); then the most recent pill's menu. With none, only New Pill and Quit.
    private func populateStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let recent else {
            menu.addItem(newPillItem())
            let session = NSMenuItem(title: "New Session", action: #selector(newPillFromMenu), keyEquivalent: "")
            session.target = self
            menu.addItem(session)
            menu.addItem(.separator())
            let quit = NSMenuItem(title: "Quit \(AppVariant.name)", action: #selector(quit), keyEquivalent: "")
            quit.target = self
            menu.addItem(quit)
            return
        }
        if config.hidePill, recent.isPillHidden {
            let show = NSMenuItem(title: "Show", action: #selector(showRecentFromMenu), keyEquivalent: "")
            show.target = self
            show.isEnabled = !isAnimating
            menu.addItem(show)
            menu.addItem(.separator())
        }
        if pills.count > 1 {
            menu.addItem(.sectionHeader(title: "Pills"))
            for (index, pill) in pills.enumerated() {
                let item = NSMenuItem(title: pill.menuTitle, action: #selector(openPillFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                item.image = pill.menuImage
                item.state = pill === recent ? .on : .off
                item.isEnabled = !isAnimating
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        recent.populateMenu(menu, clear: false)
    }

    // MARK: - Debug hook (Poppy Dev only, DESIGN §12.2)

    /// Pill-level ops here; the rest go to `command.pill` (default: the most recent).
    func debugRun(_ command: DebugHook.Command) -> String? {
        switch command.op {
        case "newPill":
            newPill(command: command.command, directory: command.directory, show: command.value ?? true)
            return nil
        case "hotkey":
            hotkeyPressed()
            return nil
        case "hotkeyTarget":
            guard let target = command.key.flatMap(HotkeyTarget.init(rawValue:)) else { return "needs key" }
            setHotkeyTarget(target)
            return nil
        case "apply":
            var request = LaunchRequest(directory: command.directory, command: command.command, show: command.value ?? true)
            request.new = command.new
            request.newPill = command.newPill
            apply(request)
            return nil
        case "openPill":
            guard let index = command.pill, pills.indices.contains(index) else { return "no pill" }
            pills[index].open()
            return nil
        case "statusMenu":
            populateStatusMenu(statusMenu)
            return nil
        case "dropRow":
            // A row of `pill` dropped onto pill `target`, or (no target) out at x, y.
            guard let source = debugPill(command), source.sessionCount > 1,
                  let index = command.index, source.allSessions.indices.contains(index) else { return "needs pill and index (2+ sessions)" }
            let target = command.target.flatMap { pills.indices.contains($0) ? pills[$0] : nil }
            guard target !== source else { return "target is the source" }
            move(source.allSessions[index], from: source, to: target,
                 newPillAt: NSPoint(x: command.x ?? 400, y: command.y ?? 400))
            saveLayout()
            return nil
        case "dropPill":
            guard let source = debugPill(command), let index = command.target, pills.indices.contains(index),
                  pills[index] !== source else { return "needs pill and another target" }
            merge(source, into: pills[index])
            return nil
        case "liquidHold":
            guard let pill = debugPill(command) else { return "no pill" }
            if #available(macOS 26, *), let liquid { liquid.debugHold(pill, command.value ?? true) } else { return "no liquid glass" }
            return nil
        case "reloadLayout":
            // What a relaunch would restore, without restarting Poppy: the saved file's pills.
            let saved = PanelState.load().pills ?? []
            return "\(saved.count) pills: " + saved.map { "\($0.sessions.count)" }.joined(separator: ",")
        default:
            guard let pill = debugPill(command) else { return command.op == "state" ? nil : "no pill" }
            return pill.debugRun(command)
        }
    }

    private func debugPill(_ command: DebugHook.Command) -> PanelController? {
        if let index = command.pill { return pills.indices.contains(index) ? pills[index] : nil }
        return recent ?? pills.first
    }

    func debugState(for command: DebugHook.Command?) -> [String: Any] {
        var state: [String: Any] = ["animating": isAnimating, "state": "none", "sessions": [Any]()]
        if let command, let pill = debugPill(command) {
            state.merge(pill.debugState()) { $1 }
            state["pill#"] = pills.firstIndex { $0 === pill } ?? -1
        }
        state["recent"] = pills.firstIndex { $0 === recent } ?? -1
        state["hotkeyTarget"] = config.hotkeyTarget.rawValue
        state["menuPills"] = statusMenu.items.filter { $0.action == #selector(openPillFromMenu(_:)) }.map(\.title)
        state["pills"] = pills.map { pill -> [String: Any] in
            [
                "state": pill.state == .expanded ? "expanded" : "collapsed",
                "key": pill.panel.isKeyWindow,
                "x": Double(pill.pillFrame.minX), "y": Double(pill.pillFrame.minY),
                "selected": pill.selectedSessionIndex,
                "sessions": pill.allSessions.map { ["id": $0.id.uuidString, "name": $0.name, "status": $0.status.rawValue,
                                                    "directory": $0.workingDirectory, "command": $0.command,
                                                    "pid": Int($0.agentPid ?? 0)] as [String: Any] },
            ]
        }
        return state
    }
}

/// The dragged sidebar row, floating under the mouse above every pill on every Space
/// (DESIGN §7.19). It never takes the mouse or the keyboard.
private final class DragImageWindow: NSPanel {
    private let imageView = NSImageView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 160, height: 28),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        animationBehavior = .none
        isReleasedWhenClosed = false
        let glass = GlassBackgroundView(frame: NSRect(x: 0, y: 0, width: 160, height: 28), cornerRadius: 8)
        glass.autoresizingMask = [.width, .height]
        imageView.frame = glass.contentView.bounds
        imageView.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleNone
        imageView.unregisterDraggedTypes()
        glass.contentView.addSubview(imageView)
        contentView = glass
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Sized like the row; shown at the first move outside the sidebar.
    func show(_ image: NSImage?, size: NSSize) {
        imageView.image = image
        setContentSize(size)
    }
}

extension PillManager: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        populateStatusMenu(menu)
    }
}
