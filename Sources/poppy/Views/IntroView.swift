import AppKit

/// The intro's pages, in order (DESIGN §9.15). Permissions shows only with Act on Selection on.
enum IntroPage: String, CaseIterable {
    case welcome, agent, hotkeys, permissions, finish
}

/// What the intro shows, built by PanelController from the real current state, re-read
/// every second while it shows (DESIGN §9.15).
struct IntroModel {
    struct Agent {
        /// Nil until the installed-CLI probe has answered.
        var installed: Bool?
        /// Nil when it can't be told.
        var signedIn: Bool?
        var isCurrent: Bool
    }

    /// The `poppy` shell command (DESIGN §9.9).
    enum Command { case checking, ready, notOnPath, missing }

    /// AgentCatalog.builtIns, in order.
    var agents: [Agent]
    var hotkey: String?
    var canRecordHotkey: Bool
    var actEnabled: Bool
    var actHotkey: String?
    var canRecordActHotkey: Bool
    var sendEnabled: Bool
    var sendHotkey: String?
    var canRecordSendHotkey: Bool
    var accessibility: Bool
    var screenRecording: Bool
    /// Asked once already: the button opens System Settings instead.
    var askedAccessibility: Bool
    var askedScreenRecording: Bool
    var canRestart: Bool
    var claudeInstalled: Bool?
    var actFolderTrusted: Bool
    var command: Command
    var launchAtLogin: LaunchAtLogin.State
    var statusHooks: Bool
    var autoOpenOnInput: Bool
    var autoOpenOnDone: Bool
    var showUsage: Bool
}

/// The first-run intro and setup (DESIGN §9.15), on the settings page in place of the
/// settings: a few pages of rows like the settings', each showing the real state, with
/// Back and Next under them. Every page can be skipped (the header's Skip).
final class IntroView: NSView {
    static let barHeight: CGFloat = 48
    /// Restart Poppy (after allowing Screen Recording) relaunches it with this, and the
    /// intro opens on the permissions page again.
    static let relaunchFlag = "--intro-permissions"
    private static let installPages = [
        "claude": "https://docs.claude.com/en/docs/claude-code",
        "codex": "https://github.com/openai/codex",
        "agy": "https://antigravity.google",
        "opencode": "https://opencode.ai",
    ]

    var onAgent: ((Int) -> Void)?
    var onActEnabled: ((Bool) -> Void)?
    var onSendEnabled: ((Bool) -> Void)?
    var onAllowAccessibility: (() -> Void)?
    var onAllowScreenRecording: (() -> Void)?
    var onRestart: (() -> Void)?
    var onStatusHooks: ((Bool) -> Void)?
    var onShowUsage: ((Bool) -> Void)?
    var onAutoOpen: ((_ key: String, _ on: Bool) -> Void)?
    /// Launch at login and Open Login Items, as on the settings page.
    var onChange: ((SettingsChange) -> Void)?
    var onPageChanged: ((IntroPage) -> Void)?
    /// Done on the last page.
    var onFinish: (() -> Void)?

    let hotkeyField = HotkeyField()
    let actHotkeyField = HotkeyField()
    let sendHotkeyField = HotkeyField()
    private(set) var page = IntroPage.welcome
    /// Only this page, with no Back and Next (Check Permissions… in Settings).
    private(set) var single = false
    private var actEnabled = false
    private var sendEnabled = false

    private let scrollView = NSScrollView()
    private var documents: [IntroPage: NSView] = [:]
    private var pageKeyViews: [IntroPage: [NSView]] = [:]
    private let bar = NSView()
    private let backButton = FirstMouseButton(title: "Back", target: nil, action: nil)
    private let nextButton = FirstMouseButton(title: "Next", target: nil, action: nil)
    private let dots = NSTextField(labelWithString: "")
    // Agent
    private var agentRows: [(radio: NSButton, get: NSButton, note: SettingsLabel)] = []
    // Hotkeys
    private let actSwitch = FirstMouseSwitch()
    private var actHotkeyTitle: NSTextField!
    private let sendSwitch = FirstMouseSwitch()
    private var sendHotkeyTitle: NSTextField!
    // Permissions
    private let accessibilityBadge = StatusBadge()
    private let accessibilityButton = FirstMouseButton(title: "Allow…", target: nil, action: nil)
    private let screenBadge = StatusBadge()
    private let screenButton = FirstMouseButton(title: "Allow…", target: nil, action: nil)
    private let restartButton = FirstMouseButton(title: "Restart \(AppVariant.name)", target: nil, action: nil)
    private let trustBadge = StatusBadge()
    // Finish
    private let commandBadge = StatusBadge()
    private let commandNote = SettingsLabel.description("")
    private let copyButton = FirstMouseButton(title: "Copy", target: nil, action: nil)
    private let loginSwitch = FirstMouseSwitch()
    private let loginNote = SettingsLabel.description("")
    private let loginItemsButton = FirstMouseButton(title: "Open Login Items", target: nil, action: nil)
    private let hooksSwitch = FirstMouseSwitch()
    private let onInputSwitch = FirstMouseSwitch()
    private let onDoneSwitch = FirstMouseSwitch()
    private let usageSwitch = FirstMouseSwitch()
    private var loginTitle: NSTextField!
    private var onInputTitle: NSTextField!
    private var onDoneTitle: NSTextField!

    override init(frame: NSRect) {
        super.init(frame: frame)
        for button in [backButton, nextButton] {
            button.bezelStyle = .push
            button.target = self
        }
        backButton.action = #selector(back)
        nextButton.action = #selector(next)
        nextButton.keyEquivalent = "\r"  // drawn as the default button; GlassPanel sends Return here
        dots.font = .systemFont(ofSize: 9)
        dots.textColor = .tertiaryLabelColor
        for button in [accessibilityButton, screenButton, restartButton, copyButton, loginItemsButton] {
            button.bezelStyle = .push
            button.controlSize = .small
            button.target = self
            button.action = #selector(buttonClicked(_:))
        }
        for control in [actSwitch, sendSwitch, loginSwitch, hooksSwitch, onInputSwitch, onDoneSwitch, usageSwitch] {
            control.controlSize = .small
            control.target = self
            control.action = #selector(switchChanged(_:))
        }
        hotkeyField.setAccessibilityLabel("Hotkey")
        actHotkeyField.setAccessibilityLabel("Act on Selection hotkey")
        actSwitch.setAccessibilityLabel("Use Act on Selection")
        sendHotkeyField.setAccessibilityLabel("Send Selection hotkey")
        sendSwitch.setAccessibilityLabel("Use Send Selection")

        documents[.welcome] = document(welcomeContent(), top: 28)
        documents[.agent] = document(sections(agentSections()))
        documents[.hotkeys] = document(sections(hotkeySections()))
        documents[.permissions] = document(sections(permissionSections()))
        documents[.finish] = document(sections(finishSections()))
        pageKeyViews = [
            .welcome: [],
            .agent: agentRows.flatMap { [$0.get, $0.radio] },
            .hotkeys: [hotkeyField, actSwitch, actHotkeyField, sendSwitch, sendHotkeyField],
            .permissions: [accessibilityButton, screenButton, restartButton],
            .finish: [copyButton, loginItemsButton, loginSwitch, hooksSwitch, onInputSwitch, onDoneSwitch, usageSwitch],
        ]

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
        bar.autoresizingMask = [.width, .maxYMargin]
        addSubview(bar)
        let barContent = NSView()
        barContent.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(barContent)
        for view in [backButton, dots, nextButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            barContent.addSubview(view)
        }
        let fill = barContent.widthAnchor.constraint(equalTo: bar.widthAnchor, constant: -2 * SettingsView.inset)
        fill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            barContent.topAnchor.constraint(equalTo: bar.topAnchor),
            barContent.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            barContent.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            barContent.widthAnchor.constraint(lessThanOrEqualToConstant: SettingsView.maxContentWidth),
            fill,
            backButton.leadingAnchor.constraint(equalTo: barContent.leadingAnchor),
            backButton.centerYAnchor.constraint(equalTo: barContent.centerYAnchor),
            nextButton.trailingAnchor.constraint(equalTo: barContent.trailingAnchor),
            nextButton.centerYAnchor.constraint(equalTo: barContent.centerYAnchor),
            nextButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            backButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            dots.centerXAnchor.constraint(equalTo: barContent.centerXAnchor),
            dots.centerYAnchor.constraint(equalTo: barContent.centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Intro")
        show(.welcome)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutParts()
    }

    private func layoutParts() {
        let barHeight = single ? 0 : Self.barHeight
        bar.isHidden = single
        bar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.barHeight)
        scrollView.frame = NSRect(x: 0, y: barHeight, width: bounds.width, height: max(bounds.height - barHeight, 0))
    }

    // MARK: Pages

    private func welcomeContent() -> NSView {
        let logo = NSImageView(image: HarnessLogo.menuBar(points: 64))
        logo.contentTintColor = .labelColor
        let title = NSTextField(labelWithString: "Welcome to \(AppVariant.name)")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.alignment = .center
        let paragraphs = [
            "\(AppVariant.name) keeps a coding agent in a small glass pill that floats over everything, on every "
                + "Space. Click it or press its hotkey and it opens into a terminal running your agent; click "
                + "outside and it folds back, without taking you out of the app you're in.",
            "Sessions and several pills, colors when the agent needs you, usage meters, and Act on Selection: "
                + "select something in any app and the agent deals with it there.",
            "The next pages set up your agent, the hotkeys and the permissions. Each step can be skipped, and "
                + "Settings › General › Show Intro… brings this back.",
        ].map { text in
            let label = SettingsLabel(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: 13)
            label.textColor = .secondaryLabelColor  // left-aligned: centered, it measured a line short
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return label
        }
        let stack = NSStackView(views: [logo, title] + paragraphs)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(16, after: logo)
        stack.setCustomSpacing(16, after: title)
        for label in paragraphs {
            label.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -60).isActive = true
        }
        return stack
    }

    private func agentSections() -> [(NSView?, NSView)] {
        let rows = AgentCatalog.builtIns.enumerated().map { index, profile in
            let radio = FirstMouseButton(radioButtonWithTitle: "Use", target: self, action: #selector(agentChosen(_:)))
            radio.tag = index
            radio.setAccessibilityLabel("Use \(profile.name)")
            let get = FirstMouseButton(title: "Get It…", target: self, action: #selector(getAgent(_:)))
            get.bezelStyle = .push
            get.controlSize = .small
            get.tag = index
            get.setAccessibilityLabel("Get \(profile.name)")
            let note = SettingsLabel.description("Checking…")
            agentRows.append((radio, get, note))
            let controls = Self.trailing([get, radio], spacing: 12)
            return SettingsView.row(profile.name, note, controls,
                                    image: HarnessLogo.image(for: Harness(command: profile.command), points: 18)).view
        }
        return [(SettingsView.sectionHeader("Your agent", SettingsLabel.description(
            "\(AppVariant.name) runs a coding agent's command-line tool. Pick the one sessions start with; the "
                + "menu's Agent list switches any time. Install one in your terminal, and it shows here.")),
                 SettingsView.group(rows))]
    }

    private func hotkeySections() -> [(NSView?, NSView)] {
        let actHotkey = SettingsView.row("Hotkey", actHotkeyField.messageLabel, actHotkeyField)
        actHotkeyTitle = actHotkey.title
        let sendHotkey = SettingsView.row("Hotkey", sendHotkeyField.messageLabel, sendHotkeyField)
        sendHotkeyTitle = sendHotkey.title
        return [
            (SettingsView.sectionHeader("Hotkey", SettingsLabel.description(
                "Opens and folds the panel from anywhere, also over fullscreen apps.")),
             SettingsView.group([SettingsView.row("Panel hotkey", hotkeyField.messageLabel, hotkeyField).view])),
            (SettingsView.sectionHeader("Act on Selection", SettingsLabel.description(
                "Select something in any app (a question, a form, some code) and press its hotkey: a Claude Code "
                    + "session in the pill answers it or fills it in, in that app, without opening the panel. "
                    + "With nothing selected, you drag over part of the screen instead. It needs two permissions, "
                    + "set up next.")),
             SettingsView.group([SettingsView.row("Use Act on Selection", nil as String?, actSwitch).view,
                                 actHotkey.view])),
            (SettingsView.sectionHeader("Send Selection", SettingsLabel.description(
                "The simple version: select something in any app and press its hotkey, and it's pasted into the "
                    + "session you used last, which opens so you can add your question. With nothing selected, "
                    + "you drag over part of the screen instead. It needs the same permissions.")),
             SettingsView.group([SettingsView.row("Use Send Selection", nil as String?, sendSwitch).view,
                                 sendHotkey.view])),
        ]
    }

    private func permissionSections() -> [(NSView?, NSView)] {
        let accessibility = Self.trailing([accessibilityBadge, accessibilityButton])
        let screen = Self.trailing([screenBadge, restartButton, screenButton])
        return [(SettingsView.sectionHeader("Permissions", SettingsLabel.description(
            "For Act on Selection and Send Selection. macOS asks once; the status here updates by itself.")),
                 SettingsView.group([
                    SettingsView.row("Accessibility", "Reads the selection and the window's buttons and fields, "
                                     + "and presses or fills them in.", accessibility).view,
                    SettingsView.row("Screen Recording", "For the screenshot when nothing is selected. macOS may "
                                     + "need \(AppVariant.name) to restart after you allow it.", screen).view,
                    SettingsView.row("Claude Code trusts the act folder", "Claude Code asks once whether to trust "
                                     + Config.abbreviate(ActController.folder.path) + ", where act sessions run. "
                                     + "The first one opens the panel so you can answer.", trustBadge).view,
                 ]))]
    }

    private func finishSections() -> [(NSView?, NSView)] {
        let command = Self.trailing([commandBadge, copyButton])
        let loginControls = NSStackView(views: [loginItemsButton, loginSwitch])
        loginControls.spacing = 10
        let login = SettingsView.row("Launch at login", loginNote, loginControls)
        loginTitle = login.title
        let onInput = SettingsView.row("Open when the agent needs input", nil as String?, onInputSwitch)
        let onDone = SettingsView.row("Open when the agent is done", nil as String?, onDoneSwitch)
        onInputTitle = onInput.title
        onDoneTitle = onDone.title
        return [
            (SettingsView.sectionHeader("The poppy command", SettingsLabel.description(
                "Opens \(AppVariant.name) on a folder from your terminal, like poppy ~/code/app.")),
             SettingsView.group([SettingsView.row("Shell command", commandNote, command).view])),
            (SettingsView.sectionHeader("Options", SettingsLabel.description("All of these are in Settings too.")),
             SettingsView.group([
                login.view,
                SettingsView.row("Agent status", "Colors the pill while the agent works, needs input or is done.",
                                 hooksSwitch).view,
                onInput.view,
                onDone.view,
                SettingsView.row("Usage meters", "Limits left and reset times in the footer and around the pill.",
                                 usageSwitch).view,
             ])),
            (SettingsView.sectionHeader("Good to know"),
             SettingsView.group([SettingsView.row("Folder access prompts", "Agents run inside \(AppVariant.name), "
                 + "so the first time one opens your Desktop, Documents or Downloads folder, macOS asks whether "
                 + "\(AppVariant.name) may. That's expected: allow it if you want agents to work there. macOS "
                 + "can't be asked ahead of time.", NSView()).view])),
        ]
    }

    /// A row's controls kept against its right edge: the row can stretch the stack, and a
    /// hidden button would otherwise leave a gap right of a status.
    private static func trailing(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
        let stack = NSStackView()
        stack.spacing = spacing
        stack.setViews(views, in: .trailing)
        return stack
    }

    /// Section headers and their cards, spaced like the settings page.
    private func sections(_ parts: [(NSView?, NSView)]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        for (header, body) in parts {
            if let header {
                stack.addArrangedSubview(header)
                stack.setCustomSpacing(8, after: header)
            }
            stack.addArrangedSubview(body)
        }
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    /// A scroll view document for `content`, at most as wide as the settings and centered.
    private func document(_ content: NSView, top: CGFloat = 12) -> NSView {
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        let fill = content.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -2 * SettingsView.inset)
        fill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: top),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -SettingsView.inset),
            content.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: SettingsView.maxContentWidth),
            fill,
        ])
        return document
    }

    // MARK: Navigation

    /// The pages Back and Next go through.
    private var pages: [IntroPage] {
        single ? [page] : IntroPage.allCases.filter { $0 != .permissions || actEnabled || sendEnabled }
    }

    func show(_ page: IntroPage, single: Bool = false) {
        self.single = single
        go(to: page)
    }

    private func go(to page: IntroPage) {
        cancelRecording()
        self.page = page
        guard let document = documents[page] else { return }
        scrollView.documentView = document
        let clip = scrollView.contentView
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: clip.widthAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
        ])
        clip.scroll(to: .zero)
        scrollView.reflectScrolledClipView(clip)
        layoutParts()
        updateBar()
        linkKeyLoop()
        onPageChanged?(page)
    }

    @objc func next() {
        guard let index = pages.firstIndex(of: page), index + 1 < pages.count else {
            onFinish?()
            return
        }
        go(to: pages[index + 1])
    }

    @objc private func back() {
        guard let index = pages.firstIndex(of: page), index > 0 else { return }
        go(to: pages[index - 1])
    }

    private func updateBar() {
        let index = pages.firstIndex(of: page) ?? 0
        backButton.isHidden = index == 0
        nextButton.title = index + 1 < pages.count ? "Next" : "Done"
        dots.stringValue = pages.map { $0 == page ? "●" : "○" }.joined(separator: "  ")
    }

    func cancelRecording() {
        hotkeyField.cancel()
        actHotkeyField.cancel()
        sendHotkeyField.cancel()
    }

    // MARK: Keyboard

    /// The page's first control (Tab from the settings page's own first responder).
    private(set) var firstKeyView: NSView?

    private func linkKeyLoop() {
        let loop = (pageKeyViews[page] ?? []) + (single ? [] : [backButton, nextButton])
        firstKeyView = loop.first
        for (view, next) in zip(loop, loop.dropFirst()) { view.nextKeyView = next }
        loop.last?.nextKeyView = superview
    }

    // MARK: Model

    func update(_ model: IntroModel) {
        let pagesChanged = actEnabled != model.actEnabled || sendEnabled != model.sendEnabled
        actEnabled = model.actEnabled
        sendEnabled = model.sendEnabled
        for (row, agent) in zip(agentRows, model.agents) {
            row.radio.state = agent.isCurrent ? .on : .off
            row.radio.isEnabled = agent.installed != false || agent.isCurrent
            row.get.isHidden = agent.installed != false
            row.note.stringValue = switch (agent.installed, agent.signedIn) {
            case (nil, _): "Checking…"
            case (false?, _): "Not installed."
            case (true?, false?): "Installed, not signed in yet: it asks you to when it starts."
            case (true?, true?): "Installed and signed in."
            case (true?, nil): "Installed."
            }
        }

        hotkeyField.show(model.hotkey, enabled: model.canRecordHotkey)
        actSwitch.state = model.actEnabled ? .on : .off
        actHotkeyField.show(model.actHotkey, enabled: model.canRecordActHotkey && model.actEnabled,
                            note: model.canRecordActHotkey ? "Turn on Act on Selection to set it." : nil)
        actHotkeyTitle.textColor = model.actEnabled ? .labelColor : .tertiaryLabelColor
        sendSwitch.state = model.sendEnabled ? .on : .off
        sendHotkeyField.show(model.sendHotkey, enabled: model.canRecordSendHotkey && model.sendEnabled,
                             note: model.canRecordSendHotkey ? "Turn on Send Selection to set it." : nil)
        sendHotkeyTitle.textColor = model.sendEnabled ? .labelColor : .tertiaryLabelColor

        accessibilityBadge.show(model.accessibility ? .ok : .needed, model.accessibility ? "Allowed" : "Not allowed")
        accessibilityButton.isHidden = model.accessibility
        accessibilityButton.title = model.askedAccessibility ? "Open Settings" : "Allow…"
        screenBadge.show(model.screenRecording ? .ok : .needed, model.screenRecording ? "Allowed" : "Not allowed")
        screenButton.isHidden = model.screenRecording
        screenButton.title = model.askedScreenRecording ? "Open Settings" : "Allow…"
        restartButton.isHidden = model.screenRecording || !model.askedScreenRecording || !model.canRestart
        if model.claudeInstalled == false {
            trustBadge.show(.pending, "Needs Claude Code")
        } else {
            trustBadge.show(model.actFolderTrusted ? .ok : .pending, model.actFolderTrusted ? "Trusted" : "Not yet")
        }

        copyButton.isHidden = true
        switch model.command {
        case .checking:
            commandBadge.show(.pending, "Checking…")
            commandNote.stringValue = "Looking at your login shell's PATH."
        case .ready:
            commandBadge.show(.ok, "Ready")
            commandNote.stringValue = "poppy is on your PATH."
        case .notOnPath:
            let (file, line) = Self.pathLine
            commandBadge.show(.needed, "Not on PATH")
            commandNote.stringValue = "It's in ~/.local/bin, which your shell's PATH leaves out. Add this line to "
                + "\(file), then open a new terminal:\n\(line)"
            copyButton.isHidden = false
        case .missing:
            commandBadge.show(.needed, "Not installed")
            commandNote.stringValue = "scripts/install.sh puts it in ~/.local/bin."
        }

        let login = model.launchAtLogin
        loginSwitch.state = login.isOn ? .on : .off
        loginSwitch.isEnabled = login.canChange
        loginTitle.textColor = login.canChange ? .labelColor : .tertiaryLabelColor
        loginNote.stringValue = login.note ?? ""
        loginNote.isHidden = login.note == nil
        loginItemsButton.isHidden = login != .requiresApproval
        hooksSwitch.state = model.statusHooks ? .on : .off
        onInputSwitch.state = model.autoOpenOnInput ? .on : .off
        onDoneSwitch.state = model.autoOpenOnDone ? .on : .off
        for (control, title) in [(onInputSwitch, onInputTitle), (onDoneSwitch, onDoneTitle)] {
            control.isEnabled = model.statusHooks
            title?.textColor = model.statusHooks ? .labelColor : .tertiaryLabelColor
        }
        usageSwitch.state = model.showUsage ? .on : .off
        if pagesChanged { updateBar() }
    }

    /// The startup file and line that put ~/.local/bin on the login shell's PATH.
    private static var pathLine: (file: String, line: String) {
        switch URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "zsh").lastPathComponent {
        case "bash": ("~/.bash_profile", "export PATH=\"$HOME/.local/bin:$PATH\"")
        case "fish": ("~/.config/fish/config.fish", "fish_add_path ~/.local/bin")
        default: ("~/.zshrc", "export PATH=\"$HOME/.local/bin:$PATH\"")
        }
    }

    // MARK: Actions

    @objc private func agentChosen(_ sender: NSButton) { onAgent?(sender.tag) }

    @objc private func getAgent(_ sender: NSButton) {
        guard AgentCatalog.builtIns.indices.contains(sender.tag),
              let page = Self.installPages[AgentCatalog.builtIns[sender.tag].command],
              let url = URL(string: page) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func switchChanged(_ sender: NSSwitch) {
        let on = sender.state == .on
        switch sender {
        case actSwitch: onActEnabled?(on)
        case sendSwitch: onSendEnabled?(on)
        case loginSwitch: onChange?(.launchAtLogin(on))
        case hooksSwitch: onStatusHooks?(on)
        case onInputSwitch: onAutoOpen?("autoOpenOnInput", on)
        case onDoneSwitch: onAutoOpen?("autoOpenOnDone", on)
        default: onShowUsage?(on)
        }
    }

    @objc private func buttonClicked(_ sender: NSButton) {
        switch sender {
        case accessibilityButton: onAllowAccessibility?()
        case screenButton: onAllowScreenRecording?()
        case restartButton: onRestart?()
        case loginItemsButton: onChange?(.openLoginItems)
        default:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Self.pathLine.line, forType: .string)
            copyButton.title = "Copied"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.copyButton.title = "Copy" }
        }
    }
}

/// The intro's checks besides the permissions (DESIGN §9.15): signed in to each agent, and
/// the login shell's PATH. `readSlow` runs processes, so it's called off the main thread.
nonisolated enum IntroChecks {
    struct Slow: Sendable {
        /// The login shell's PATH entries; nil if the shell didn't answer.
        var path: [String]?
        var agySignedIn: Bool
    }

    static func readSlow() -> Slow {
        var path: [String]?
        let spec = ShellEnvironment.probeSpec(script: "printf 'POPPY_PATH:%s\\n' \"$PATH\"")
        if let result = ChildProcess.run(spec, label: "PATH probe", timeout: 5), result.exitedNormally {
            for line in String(decoding: result.output, as: UTF8.self).split(separator: "\n")
            where line.hasPrefix("POPPY_PATH:") {
                path = line.dropFirst("POPPY_PATH:".count).split(separator: ":").map(String.init)
            }
        }
        return Slow(path: path, agySignedIn: AntigravityUsage.isSignedIn())
    }

    /// From each agent's own login file, only checked for existence or read (Claude Code's
    /// `~/.claude.json`, never written). Nil when it can't be told.
    static func isSignedIn(_ command: String, agy: Bool?) -> Bool? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        switch command {
        case "claude":
            guard let data = try? Data(contentsOf: home.appendingPathComponent(".claude.json")),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return object["oauthAccount"] != nil || object["primaryApiKey"] != nil
        case "codex":
            return FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/auth.json").path)
        case "opencode":
            return FileManager.default.fileExists(
                atPath: home.appendingPathComponent(".local/share/opencode/auth.json").path)
        case "agy":
            return agy
        default:
            return nil
        }
    }

    /// Whether a `poppy` is on `path`, else whether install.sh's is in ~/.local/bin.
    static func command(path: [String]?) -> IntroModel.Command {
        guard let path else { return .checking }
        let manager = FileManager.default
        if path.contains(where: { manager.isExecutableFile(atPath: ($0 as NSString).expandingTildeInPath + "/poppy") }) {
            return .ready
        }
        return manager.isExecutableFile(atPath: NSHomeDirectory() + "/.local/bin/poppy") ? .notOnPath : .missing
    }
}

/// A status in a row: a colored symbol and a word, as one label (a stack of the two
/// stretched inside a row, leaving a gap between them).
private final class StatusBadge: NSTextField {
    enum Kind { case ok, needed, pending }

    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ kind: Kind, _ text: String) {
        let (symbol, color): (String, NSColor) = switch kind {
        case .ok: ("checkmark.circle.fill", .systemGreen)
        case .needed: ("exclamationmark.circle.fill", .systemOrange)
        case .pending: ("circle.dotted", .tertiaryLabelColor)
        }
        let font = NSFont.systemFont(ofSize: 12)
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: kind == .pending ? [color] : [.white, color]))
        let string = NSMutableAttributedString()
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: (font.capHeight - image.size.height) / 2,
                                       width: image.size.width, height: image.size.height)
            string.append(NSAttributedString(attachment: attachment))
        }
        string.append(NSAttributedString(string: " " + text, attributes: [
            .font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        attributedStringValue = string
        setAccessibilityLabel(text)
    }
}
