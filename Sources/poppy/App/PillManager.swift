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
    /// The menu bar item's menu, rebuilt each time it opens (DESIGN §7.12).
    private(set) lazy var statusMenu: NSMenu = {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        return menu
    }()
    /// Set while restoring, so building the pills doesn't save a half-built layout.
    private var restoring = false

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
        saveLayout()
        pills.forEach { $0.terminateAll() }
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

extension PillManager: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        populateStatusMenu(menu)
    }
}
