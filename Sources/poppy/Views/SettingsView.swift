import AppKit
import Carbon

/// What the settings page shows, built by PanelController from current state (DESIGN §7.9).
struct SettingsModel {
    struct Agent {
        var title: String
        var image: NSImage?
        var enabled: Bool
    }

    var agents: [Agent]
    var currentAgent: Int?
    /// Absolute paths, the current one first.
    var directories: [String]
    var pillPresets: [String]
    var pillPreset: Int
    var showUsage: Bool
    var statusHooks: Bool
    var autoOpenOnInput: Bool
    var autoOpenOnDone: Bool
    var autoOpenFocus: Bool
    /// The hotkey's display string; nil when none is registered.
    var hotkey: String?
    var canRecordHotkey: Bool
    /// "Hotkey opens" (DESIGN §11): the choices' titles and the current one.
    var hotkeyTargets: [String]
    var hotkeyTarget: Int
    /// Act on Selection's hotkey (DESIGN §9.14); nil when none is registered.
    var actHotkey: String?
    var canRecordActHotkey: Bool
    var actEnabled: Bool
    /// Panel, Terminal and General (M27): the global settings as saved.
    var settings: Config
    var launchAtLogin: LaunchAtLogin.State
}

/// A change on the Panel, Terminal or General cards (DESIGN §7.9). `done` is false while a
/// slider is still being dragged (applied live, saved at the end).
enum SettingsChange {
    case foldOnClickOutside(Bool)
    case fadeWhenInactive(Bool)
    case inactiveOpacity(Double, done: Bool)
    case hidePill(Bool)
    case terminalFont(String?)
    case terminalFontSize(Double)
    case terminalTheme(TerminalTheme)
    case terminalOpacity(Double, done: Bool)
    case cursorStyle(CursorShape)
    case cursorBlink(Bool)
    case copyOnSelect(Bool)
    case confirmQuit(Bool)
    /// "Accessibility" or "ScreenCapture": that Privacy & Security pane.
    case openPrivacySettings(String)
    case actCleanup(ActCleanup)
    case launchAtLogin(Bool)
    case openLoginItems
}

/// The settings page inside the expanded panel, in place of the terminal (DESIGN §7.9),
/// laid out like System Settings: rounded groups of rows, each with its title (and a
/// description) on the left and its control on the right, hairlines between rows, and
/// bold section headers. The header shows its title and Done. It takes the keyboard
/// itself so nothing reaches the hidden terminal; GlassPanel turns Esc and Return into Done.
final class SettingsView: NSView {
    static let inset: CGFloat = 20
    static let maxContentWidth: CGFloat = 620

    var onAgent: ((Int) -> Void)?
    var onDirectory: ((String) -> Void)?
    var onChooseFolder: (() -> Void)?
    var onPillPreset: ((Int) -> Void)?
    var onShowUsage: ((Bool) -> Void)?
    var onStatusHooks: ((Bool) -> Void)?
    var onAutoOpen: ((_ key: String, _ on: Bool) -> Void)?
    var onHotkeyTarget: ((Int) -> Void)?
    var onEditConfig: (() -> Void)?
    var onChange: ((SettingsChange) -> Void)?
    var onActEnabled: ((Bool) -> Void)?
    /// The intro (DESIGN §9.15), from its first page or only its permissions page.
    var onShowIntro: (() -> Void)?
    var onCheckPermissions: (() -> Void)?

    let hotkeyField = HotkeyField()
    let actHotkeyField = HotkeyField()
    /// The intro's pages, shown here in place of the settings (DESIGN §9.15).
    let intro = IntroView()
    private let scrollView = NSScrollView()
    private let agentPopUp = FirstMousePopUpButton()
    private let directoryPopUp = FirstMousePopUpButton()
    private let hotkeyTargetPopUp = FirstMousePopUpButton()
    private let pillStack = NSStackView()
    private var pillRadios: [NSButton] = []
    private let usageSwitch = FirstMouseSwitch()
    private let hooksSwitch = FirstMouseSwitch()
    private let onInputSwitch = FirstMouseSwitch()
    private let onDoneSwitch = FirstMouseSwitch()
    private let focusSwitch = FirstMouseSwitch()
    private let autoOpenNote = SettingsLabel.description("")
    private let editConfigButton = FirstMouseButton(title: "Edit config.json…", target: nil, action: nil)
    // Panel
    private let foldSwitch = FirstMouseSwitch()
    private let fadeSwitch = FirstMouseSwitch()
    private let fadeSlider = PercentSlider(range: Config.inactiveOpacityRange)
    private let hidePillSwitch = FirstMouseSwitch()
    private var fadeSliderTitle: NSTextField!
    // Terminal
    private let fontPopUp = FirstMousePopUpButton()
    private let sizeStepper = FirstMouseStepper()
    private let sizeLabel = NSTextField(labelWithString: "")
    private let themePopUp = FirstMousePopUpButton()
    private let opacitySlider = PercentSlider(range: Config.terminalOpacityRange)
    private let cursorPopUp = FirstMousePopUpButton()
    private let blinkCheckbox = FirstMouseButton(checkboxWithTitle: "Blink", target: nil, action: nil)
    private let copySwitch = FirstMouseSwitch()
    // General
    private let loginSwitch = FirstMouseSwitch()
    private let loginNote = SettingsLabel.description("")
    private let loginItemsButton = FirstMouseButton(title: "Open Login Items", target: nil, action: nil)
    private let confirmQuitSwitch = FirstMouseSwitch()
    // Act on Selection
    private let actSwitch = FirstMouseSwitch()
    private let actCleanupPopUp = FirstMousePopUpButton()
    private let permissionsButton = FirstMouseButton(title: "Check Permissions…", target: nil, action: nil)
    private let introButton = FirstMouseButton(title: "Show Intro…", target: nil, action: nil)
    private var actHotkeyTitle: NSTextField!
    private var actCleanupTitle: NSTextField!
    private var loginTitle: NSTextField!
    /// Titles of rows whose control can be disabled, dimmed with it.
    private var onInputTitle: NSTextField!
    private var onDoneTitle: NSTextField!
    private var focusTitle: NSTextField!
    private var directories: [String] = []

    override init(frame: NSRect) {
        super.init(frame: frame)

        agentPopUp.target = self
        agentPopUp.action = #selector(agentChosen)
        directoryPopUp.target = self
        directoryPopUp.action = #selector(directoryChosen)
        hotkeyTargetPopUp.target = self
        hotkeyTargetPopUp.action = #selector(hotkeyTargetChosen)
        pillStack.orientation = .horizontal
        pillStack.spacing = 14
        for (control, selector) in [(usageSwitch, #selector(usageChanged)), (hooksSwitch, #selector(hooksChanged)),
                                    (onInputSwitch, #selector(autoOpenChanged(_:))),
                                    (onDoneSwitch, #selector(autoOpenChanged(_:))),
                                    (focusSwitch, #selector(autoOpenChanged(_:)))] {
            control.controlSize = .small
            control.target = self
            control.action = selector
        }
        editConfigButton.bezelStyle = .push
        editConfigButton.target = self
        editConfigButton.action = #selector(editConfig)
        for control in [foldSwitch, fadeSwitch, hidePillSwitch, copySwitch, loginSwitch, confirmQuitSwitch] {
            control.controlSize = .small
            control.target = self
            control.action = #selector(switchChanged(_:))
        }
        for slider in [fadeSlider, opacitySlider] {
            slider.slider.target = self
            slider.slider.action = #selector(sliderChanged(_:))
        }
        fontPopUp.target = self
        fontPopUp.action = #selector(fontChosen)
        fontPopUp.autoenablesItems = false
        sizeStepper.minValue = Config.fontSizeRange.lowerBound
        sizeStepper.maxValue = Config.fontSizeRange.upperBound
        sizeStepper.increment = 1
        sizeStepper.valueWraps = false
        sizeStepper.target = self
        sizeStepper.action = #selector(sizeChanged)
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        sizeLabel.alignment = .right
        sizeLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true
        themePopUp.addItems(withTitles: TerminalTheme.allCases.map(\.title))
        themePopUp.target = self
        themePopUp.action = #selector(themeChosen)
        cursorPopUp.addItems(withTitles: CursorShape.allCases.map(\.title))
        cursorPopUp.target = self
        cursorPopUp.action = #selector(cursorChosen)
        blinkCheckbox.setContentHuggingPriority(.required, for: .horizontal)
        cursorPopUp.setContentHuggingPriority(.required, for: .horizontal)
        blinkCheckbox.target = self
        blinkCheckbox.action = #selector(blinkChanged)
        loginItemsButton.bezelStyle = .push
        loginItemsButton.controlSize = .small
        loginItemsButton.target = self
        loginItemsButton.action = #selector(openLoginItems)
        hotkeyField.messageLabel.stringValue = "Click, then press the new shortcut."
        actCleanupPopUp.addItems(withTitles: ActCleanup.allCases.map(\.title))
        actCleanupPopUp.target = self
        actCleanupPopUp.action = #selector(actCleanupChosen)
        actSwitch.controlSize = .small
        actSwitch.target = self
        actSwitch.action = #selector(actChanged)
        for button in [permissionsButton, introButton] {
            button.bezelStyle = .push
            button.target = self
            button.action = #selector(introButtonClicked(_:))
        }

        let restartNote = "Changing it restarts the agent."
        let general = Self.group([
            Self.row("Agent", restartNote, agentPopUp).view,
            Self.row("Working directory", restartNote, directoryPopUp).view,
            Self.row("Hotkey", hotkeyField.messageLabel, hotkeyField).view,
            Self.row("Hotkey opens", "Which pill, when there are several.", hotkeyTargetPopUp).view,
        ])
        let pill = Self.group([
            Self.row("Pill size", nil as String?, pillStack).view,
            Self.row("Usage meters", "Limits left and reset times in the footer and around the pill.", usageSwitch).view,
            Self.row("Agent status", "Colors the pill while the agent works, needs input or is done. "
                     + "Applies the next time the agent starts.", hooksSwitch).view,
        ])
        let onInput = Self.row("When the agent needs input", nil as String?, onInputSwitch)
        let onDone = Self.row("When the agent is done", nil as String?, onDoneSwitch)
        let focus = Self.row("Take keyboard focus", "With this off, the panel shows without taking your typing.",
                             focusSwitch)
        onInputTitle = onInput.title
        onDoneTitle = onDone.title
        focusTitle = focus.title
        let autoOpen = Self.group([onInput.view, onDone.view, focus.view])
        let fadeOpacity = Self.row("Faded opacity", nil as String?, fadeSlider)
        fadeSliderTitle = fadeOpacity.title
        let panelGroup = Self.group([
            Self.row("Fold when clicking outside", "Off, the panel stays open until you fold it. "
                     + "Each panel's pin keeps it open too.", foldSwitch).view,
            Self.row("Fade when not focused", "While you're in another app; full again on hover.", fadeSwitch).view,
            fadeOpacity.view,
            Self.row("Hide pill when collapsed", "Open it from the menu bar, the hotkey or Auto-Open.",
                     hidePillSwitch).view,
        ])
        let size = NSStackView(views: [sizeLabel, sizeStepper])
        size.spacing = 4
        let cursor = NSStackView(views: [cursorPopUp, blinkCheckbox])
        cursor.spacing = 12
        let terminalGroup = Self.group([
            Self.row("Font", nil as String?, fontPopUp).view,
            Self.row("Size", "⌘+ and ⌘– in the terminal, ⌘0 to reset.", size).view,
            Self.row("Theme", nil as String?, themePopUp).view,
            Self.row("Background", "Behind the text. At 100 % it's solid.", opacitySlider).view,
            Self.row("Cursor", "Agents can change it.", cursor).view,
            Self.row("Copy on select", "Selecting text with the mouse copies it.", copySwitch).view,
        ])
        let loginControls = NSStackView(views: [loginItemsButton, loginSwitch])
        loginControls.spacing = 10
        let login = Self.row("Launch at login", loginNote, loginControls)
        loginTitle = login.title
        let generalGroup = Self.group([
            login.view,
            Self.row("Confirm before quitting", "Asks while an agent is working or waiting.", confirmQuitSwitch).view,
            Self.row("Intro", "What Poppy is, and setting up the agent, hotkeys and permissions.", introButton).view,
        ])
        let actHotkey = Self.row("Hotkey", actHotkeyField.messageLabel, actHotkeyField)
        let actCleanup = Self.row("Close finished sessions", "Done ones you haven't opened. Working ones and ones you "
                                  + "opened stay.", actCleanupPopUp)
        actHotkeyTitle = actHotkey.title
        actCleanupTitle = actCleanup.title
        let actGroup = Self.group([
            Self.row("Act on Selection", "Off, its hotkey does nothing.", actSwitch).view,
            actHotkey.view,
            actCleanup.view,
            Self.row("Permissions", "Accessibility reads and acts in apps; Screen Recording takes the screenshot.",
                     permissionsButton).view,
        ])
        let advanced = Self.group([
            Self.row("Custom agents and other options", "In config.json, read when Poppy starts.",
                     editConfigButton).view,
        ])

        let headers = [
            Self.sectionHeader("Pill"), Self.sectionHeader("Auto-Open", autoOpenNote), Self.sectionHeader("Panel"),
            Self.sectionHeader("Terminal"),
            Self.sectionHeader("Act on Selection", SettingsLabel.description(
                "Select something in any app and press the hotkey: a Claude Code session in the pill deals with "
                + "it there, or explains it. With nothing selected, drag over a region to screenshot instead.")),
            Self.sectionHeader("General"), Self.sectionHeader("Advanced"),
        ]
        let groups = [pill, autoOpen, panelGroup, terminalGroup, actGroup, generalGroup, advanced]
        let content = NSStackView(views: [general] + zip(headers, groups).flatMap { [$0, $1] })
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 20
        for header in headers {
            content.setCustomSpacing(8, after: header)
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        for view in content.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        for popUp in [agentPopUp, directoryPopUp, hotkeyTargetPopUp, fontPopUp, actCleanupPopUp] {
            popUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
            popUp.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
        }

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = document
        scrollView.autoresizingMask = [.width, .height]
        scrollView.frame = bounds
        addSubview(scrollView)
        intro.frame = bounds
        intro.autoresizingMask = [.width, .height]
        intro.isHidden = true
        addSubview(intro)
        let fill = content.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -2 * Self.inset)
        fill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -Self.inset),
            content.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxContentWidth),
            fill,
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Settings")
        agentPopUp.setAccessibilityLabel("Agent")
        directoryPopUp.setAccessibilityLabel("Working directory")
        hotkeyTargetPopUp.setAccessibilityLabel("Hotkey opens")
        usageSwitch.setAccessibilityLabel("Usage meters")
        hooksSwitch.setAccessibilityLabel("Agent status")
        onInputSwitch.setAccessibilityLabel("Auto-Open when the agent needs input")
        onDoneSwitch.setAccessibilityLabel("Auto-Open when the agent is done")
        focusSwitch.setAccessibilityLabel("Auto-Open takes keyboard focus")
        hotkeyField.setAccessibilityLabel("Hotkey")
        actHotkeyField.setAccessibilityLabel("Act on Selection hotkey")
        actSwitch.setAccessibilityLabel("Act on Selection")
        actCleanupPopUp.setAccessibilityLabel("Close finished Act on Selection sessions")
        for (control, label) in [(foldSwitch, "Fold when clicking outside"), (fadeSwitch, "Fade when not focused"),
                                 (fadeSlider.slider, "Faded opacity"), (hidePillSwitch, "Hide pill when collapsed"),
                                 (fontPopUp, "Terminal font"), (sizeStepper, "Terminal font size"),
                                 (themePopUp, "Terminal theme"), (opacitySlider.slider, "Terminal background opacity"),
                                 (cursorPopUp, "Cursor"), (copySwitch, "Copy on select"),
                                 (loginSwitch, "Launch at login"), (confirmQuitSwitch, "Confirm before quitting")] as [(NSView, String)] {
            control.setAccessibilityLabel(label)
        }
        linkKeyLoop()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The page's scrolled content (Poppy Dev's snapshot, DESIGN §12.2).
    var documentView: NSView { scrollView.documentView ?? scrollView }

    private var settingsKeyView: NSView?

    /// The intro's pages are showing in place of the settings.
    var showsIntro: Bool { !intro.isHidden }

    /// The intro (DESIGN §9.15) or the settings, in place of each other; Tab goes through
    /// the shown one's controls.
    func setIntroVisible(_ visible: Bool) {
        intro.isHidden = !visible
        scrollView.isHidden = visible
        if !visible { intro.cancelRecording() }
        nextKeyView = visible ? intro.firstKeyView : settingsKeyView
    }

    /// The intro's page changed: Tab starts at its first control.
    func introPageChanged() {
        if showsIntro { nextKeyView = intro.firstKeyView }
    }

    /// Tab order with Full Keyboard Access on (rebuilt when the pill size radios change).
    private func linkKeyLoop() {
        let loop: [NSView] = [agentPopUp, directoryPopUp, hotkeyField, hotkeyTargetPopUp] + pillRadios
            + [usageSwitch, hooksSwitch, onInputSwitch, onDoneSwitch, focusSwitch,
               foldSwitch, fadeSwitch, fadeSlider.slider, hidePillSwitch,
               fontPopUp, sizeStepper, themePopUp, opacitySlider.slider, cursorPopUp, blinkCheckbox, copySwitch,
               actSwitch, actHotkeyField, actCleanupPopUp, permissionsButton,
               loginItemsButton, loginSwitch, confirmQuitSwitch, introButton, editConfigButton]
        settingsKeyView = loop.first
        nextKeyView = showsIntro ? intro.firstKeyView : loop.first
        for (view, next) in zip(loop, loop.dropFirst()) { view.nextKeyView = next }
        loop.last?.nextKeyView = self
    }

    // MARK: Building blocks

    /// A row: title (13 pt) and an optional description (11 pt, secondary) on the left,
    /// the control on the right, vertically centered.
    static func row(_ title: String, _ description: String?, _ control: NSView, image: NSImage? = nil)
        -> (view: NSView, title: NSTextField) {
        row(title, description.map { SettingsLabel.description($0) }, control, image: image)
    }

    /// `image` (an agent's logo) goes left of the title.
    static func row(_ title: String, _ description: NSTextField?, _ control: NSView, image: NSImage? = nil)
        -> (view: NSView, title: NSTextField) {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView(views: [titleLabel] + (description.map { [$0] } ?? []))
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        var leading: NSView = text
        if let image {
            let imageView = NSImageView(image: image)
            imageView.contentTintColor = .labelColor
            imageView.setContentHuggingPriority(.required, for: .horizontal)
            let stack = NSStackView(views: [imageView, text])
            stack.spacing = 8
            stack.alignment = .centerY
            leading = stack
        }

        let row = NSView()
        for view in [leading, control] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        (control as? NSStackView)?.setHuggingPriority(.required, for: .horizontal)  // its own, not the view's
        // The text fills the space left of the control, so a description wraps at that
        // width (and keeps it when its text changes) instead of shrinking to a word.
        let fillText = leading.trailingAnchor.constraint(equalTo: control.leadingAnchor, constant: -16)
        fillText.priority = NSLayoutConstraint.Priority(600)
        description?.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        let hug = row.heightAnchor.constraint(equalToConstant: 0)
        hug.priority = .fittingSizeCompression
        NSLayoutConstraint.activate([
            leading.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            leading.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -16),
            leading.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            leading.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 9),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 6),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 38),
            fillText,
            hug,
        ])
        return (row, titleLabel)
    }

    /// Rows on a rounded card, with inset hairlines between them.
    static func group(_ rows: [NSView]) -> NSView {
        var views: [NSView] = []
        for (index, row) in rows.enumerated() {
            if index > 0 { views.append(SeparatorLine()) }
            views.append(row)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        let card = SettingsCard()
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -2),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        for view in views {
            if view is SeparatorLine {
                view.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 10).isActive = true
                view.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -10).isActive = true
            } else {
                view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        return card
    }

    /// A bold 13 pt section title over a group, aligned with the rows' text, with an
    /// optional description under it.
    static func sectionHeader(_ title: String, _ description: NSTextField? = nil) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .bold)
        label.textColor = .labelColor
        let stack = NSStackView(views: [label] + (description.map { [$0] } ?? []))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        // A wrapping label in a stack has no width of its own: give it the header's.
        description?.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        return stack
    }

    // MARK: Model

    func update(_ model: SettingsModel) {
        agentPopUp.autoenablesItems = false
        agentPopUp.removeAllItems()
        for agent in model.agents {
            agentPopUp.addItem(withTitle: agent.title)
            agentPopUp.lastItem?.image = agent.image
            agentPopUp.lastItem?.isEnabled = agent.enabled
        }
        if let current = model.currentAgent { agentPopUp.selectItem(at: current) }

        directories = model.directories
        directoryPopUp.removeAllItems()
        for path in model.directories {
            directoryPopUp.addItem(withTitle: Config.abbreviate(path))
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = NSSize(width: 16, height: 16)
            directoryPopUp.lastItem?.image = icon
            directoryPopUp.lastItem?.toolTip = path
        }
        directoryPopUp.menu?.addItem(.separator())
        directoryPopUp.addItem(withTitle: "Choose Folder…")
        directoryPopUp.selectItem(at: 0)

        if pillRadios.map(\.title) != model.pillPresets {
            pillRadios.forEach { $0.removeFromSuperview() }
            pillRadios = model.pillPresets.enumerated().map { index, name in
                let radio = FirstMouseButton(radioButtonWithTitle: name, target: self, action: #selector(pillChanged(_:)))
                radio.tag = index
                return radio
            }
            pillRadios.forEach { pillStack.addArrangedSubview($0) }
            linkKeyLoop()
        }
        for radio in pillRadios { radio.state = radio.tag == model.pillPreset ? .on : .off }

        usageSwitch.state = model.showUsage ? .on : .off
        hooksSwitch.state = model.statusHooks ? .on : .off
        onInputSwitch.state = model.autoOpenOnInput ? .on : .off
        onDoneSwitch.state = model.autoOpenOnDone ? .on : .off
        focusSwitch.state = model.autoOpenFocus ? .on : .off
        let focusEnabled = model.statusHooks && (model.autoOpenOnInput || model.autoOpenOnDone)
        for (control, title, enabled) in [(onInputSwitch, onInputTitle, model.statusHooks),
                                          (onDoneSwitch, onDoneTitle, model.statusHooks),
                                          (focusSwitch, focusTitle, focusEnabled)] {
            control.isEnabled = enabled
            title?.textColor = enabled ? .labelColor : .tertiaryLabelColor
        }
        autoOpenNote.stringValue = model.statusHooks
            ? "Opens the panel by itself when the agent needs you."
            : "Needs Agent status, above."
        hotkeyField.show(model.hotkey, enabled: model.canRecordHotkey)
        if hotkeyTargetPopUp.itemTitles != model.hotkeyTargets {
            hotkeyTargetPopUp.removeAllItems()
            hotkeyTargetPopUp.addItems(withTitles: model.hotkeyTargets)
        }
        hotkeyTargetPopUp.selectItem(at: model.hotkeyTarget)
        actSwitch.state = model.actEnabled ? .on : .off
        actHotkeyField.show(model.actHotkey, enabled: model.canRecordActHotkey && model.actEnabled,
                            note: model.canRecordActHotkey ? "Turn on Act on Selection to set it." : nil)
        actCleanupPopUp.isEnabled = model.actEnabled
        for title in [actHotkeyTitle, actCleanupTitle] {
            title?.textColor = model.actEnabled ? .labelColor : .tertiaryLabelColor
        }

        let settings = model.settings
        foldSwitch.state = settings.foldOnClickOutside ? .on : .off
        fadeSwitch.state = settings.fadeWhenInactive ? .on : .off
        fadeSlider.value = settings.inactiveOpacity
        fadeSlider.isEnabled = settings.fadeWhenInactive
        fadeSliderTitle.textColor = settings.fadeWhenInactive ? .labelColor : .tertiaryLabelColor
        hidePillSwitch.state = settings.hidePill ? .on : .off
        updateFonts(selected: settings.terminalFont)
        sizeStepper.doubleValue = settings.terminalFontSize
        sizeLabel.stringValue = "\(Int(settings.terminalFontSize)) pt"
        themePopUp.selectItem(at: TerminalTheme.allCases.firstIndex(of: settings.terminalTheme) ?? 0)
        opacitySlider.value = settings.terminalOpacity
        cursorPopUp.selectItem(at: CursorShape.allCases.firstIndex(of: settings.cursorStyle) ?? 0)
        blinkCheckbox.state = settings.cursorBlink ? .on : .off
        copySwitch.state = settings.copyOnSelect ? .on : .off
        confirmQuitSwitch.state = settings.confirmQuit ? .on : .off
        actCleanupPopUp.selectItem(at: ActCleanup.allCases.firstIndex(of: settings.actCleanup) ?? 0)

        let login = model.launchAtLogin
        loginSwitch.state = login.isOn ? .on : .off
        loginSwitch.isEnabled = login.canChange
        loginTitle.textColor = login.canChange ? .labelColor : .tertiaryLabelColor
        loginNote.stringValue = login.note ?? ""
        loginNote.isHidden = login.note == nil
        loginItemsButton.isHidden = login != .requiresApproval
    }

    /// System Mono, then the installed fixed-pitch fonts by family (DESIGN §9.1). A saved
    /// font that isn't in the list (gone, or not fixed-pitch) shows as System Mono, which
    /// is what the terminal falls back to if it's gone.
    private func updateFonts(selected: String?) {
        let fonts = Self.fixedPitchFonts()
        if fontNames != fonts.flatMap({ $0.faces.map(\.name) }) {
            fontNames = fonts.flatMap { $0.faces.map(\.name) }
            fontPopUp.removeAllItems()
            fontPopUp.addItem(withTitle: "System Mono")
            for family in fonts {
                fontPopUp.menu?.addItem(.sectionHeader(title: family.family))
                for face in family.faces {
                    let item = NSMenuItem(title: face.title, action: nil, keyEquivalent: "")
                    item.representedObject = face.name
                    item.indentationLevel = 1
                    fontPopUp.menu?.addItem(item)
                }
            }
        }
        let index = selected.map { fontPopUp.indexOfItem(withRepresentedObject: $0) } ?? 0
        fontPopUp.selectItem(at: index >= 0 ? index : 0)
    }

    private var fontNames: [String]?

    /// Families with their fixed-pitch faces: (PostScript name, "Family Face"), "Regular"
    /// shown as the family alone.
    private static func fixedPitchFonts() -> [(family: String, faces: [(name: String, title: String)])] {
        if let cachedFonts { return cachedFonts }
        let fonts = scanFixedPitchFonts()
        cachedFonts = fonts
        return fonts
    }

    /// Scanned once (fonts installed later show after a relaunch).
    private static var cachedFonts: [(family: String, faces: [(name: String, title: String)])]?

    private static func scanFixedPitchFonts() -> [(family: String, faces: [(name: String, title: String)])] {
        let manager = NSFontManager.shared
        let fixed = Set(manager.availableFontNames(with: .fixedPitchFontMask) ?? [])
        var result: [(family: String, faces: [(name: String, title: String)])] = []
        for family in manager.availableFontFamilies.sorted() where !family.hasPrefix(".") {
            var faces: [(name: String, title: String)] = []
            for member in manager.availableMembers(ofFontFamily: family) ?? [] {
                guard let name = member.first as? String, fixed.contains(name) else { continue }
                let face = member.count > 1 ? member[1] as? String ?? "" : ""
                faces.append((name, face.isEmpty || face == "Regular" ? family : "\(family) \(face)"))
            }
            if !faces.isEmpty { result.append((family, faces)) }
        }
        return result
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool { true }

    /// Tab moves through the controls; every other key stops here (never reaches the
    /// terminal underneath). Esc and Return are handled by GlassPanel.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 {
            if event.modifierFlags.contains(.shift) {
                window?.selectPreviousKeyView(self)
            } else {
                window?.selectNextKeyView(self)
            }
        }
    }

    // MARK: Actions

    @objc private func agentChosen() { onAgent?(agentPopUp.indexOfSelectedItem) }
    @objc private func pillChanged(_ sender: NSButton) { onPillPreset?(sender.tag) }
    @objc private func usageChanged() { onShowUsage?(usageSwitch.state == .on) }
    @objc private func hooksChanged() { onStatusHooks?(hooksSwitch.state == .on) }
    @objc private func editConfig() { onEditConfig?() }

    @objc private func directoryChosen() {
        let index = directoryPopUp.indexOfSelectedItem
        directoryPopUp.selectItem(at: 0)  // the current one, until the change lands
        if directories.indices.contains(index) {
            onDirectory?(directories[index])
        } else {
            onChooseFolder?()
        }
    }

    @objc private func hotkeyTargetChosen() {
        onHotkeyTarget?(hotkeyTargetPopUp.indexOfSelectedItem)
    }

    @objc private func switchChanged(_ sender: NSSwitch) {
        let on = sender.state == .on
        switch sender {
        case foldSwitch: onChange?(.foldOnClickOutside(on))
        case fadeSwitch: onChange?(.fadeWhenInactive(on))
        case hidePillSwitch: onChange?(.hidePill(on))
        case copySwitch: onChange?(.copyOnSelect(on))
        case loginSwitch: onChange?(.launchAtLogin(on))
        default: onChange?(.confirmQuit(on))
        }
    }

    /// Applied while dragging; `done` (saved) once the mouse is up or the keyboard moved it.
    @objc private func sliderChanged(_ sender: NSSlider) {
        let type = NSApp.currentEvent?.type
        let done = type != .leftMouseDragged && type != .leftMouseDown
        fadeSlider.showValue()
        opacitySlider.showValue()
        if sender === fadeSlider.slider {
            onChange?(.inactiveOpacity(fadeSlider.value, done: done))
        } else {
            onChange?(.terminalOpacity(opacitySlider.value, done: done))
        }
    }

    @objc private func fontChosen() {
        onChange?(.terminalFont(fontPopUp.selectedItem?.representedObject as? String))
    }

    @objc private func sizeChanged() {
        sizeLabel.stringValue = "\(Int(sizeStepper.doubleValue)) pt"
        onChange?(.terminalFontSize(sizeStepper.doubleValue))
    }

    @objc private func themeChosen() {
        onChange?(.terminalTheme(TerminalTheme.allCases[max(themePopUp.indexOfSelectedItem, 0)]))
    }

    @objc private func cursorChosen() {
        onChange?(.cursorStyle(CursorShape.allCases[max(cursorPopUp.indexOfSelectedItem, 0)]))
    }

    @objc private func actCleanupChosen() {
        onChange?(.actCleanup(ActCleanup.allCases[max(actCleanupPopUp.indexOfSelectedItem, 0)]))
    }

    @objc private func actChanged() { onActEnabled?(actSwitch.state == .on) }

    @objc private func introButtonClicked(_ sender: NSButton) {
        if sender === permissionsButton { onCheckPermissions?() } else { onShowIntro?() }
    }

    @objc private func blinkChanged() { onChange?(.cursorBlink(blinkCheckbox.state == .on)) }
    @objc private func openLoginItems() { onChange?(.openLoginItems) }

    @objc private func autoOpenChanged(_ sender: NSSwitch) {
        let key = switch sender {
        case onInputSwitch: "autoOpenOnInput"
        case onDoneSwitch: "autoOpenOnDone"
        default: "autoOpenFocus"
        }
        onAutoOpen?(key, sender.state == .on)
    }
}

/// A wrapping label that wraps at its laid-out width (Auto Layout gives it no width of
/// its own otherwise).
final class SettingsLabel: NSTextField {
    /// 11 pt secondary text under a row's title.
    static func description(_ text: String) -> SettingsLabel {
        let label = SettingsLabel(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    override func layout() {
        if preferredMaxLayoutWidth != bounds.width {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
        super.layout()
    }
}

/// The rounded card behind a group of rows: a faint fill over the glass, like System
/// Settings' grouped form, redrawn for light and dark.
private final class SettingsCard: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        }
        layer?.borderWidth = 0.5
    }
}

/// A one-pixel hairline between rows.
private final class SeparatorLine: NSBox {
    init() {
        super.init(frame: .zero)
        boxType = .separator
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}


/// The hotkey as a button; clicking it records the next shortcut pressed, like System
/// Settings' shortcut fields (DESIGN §11.2). Esc cancels. A local key monitor sees the
/// keys before GlassPanel's key equivalents, so ⌘ shortcuts and Esc can be recorded or
/// cancel instead of acting on the panel.
final class HotkeyField: NSButton {
    /// Recording starts; return false to refuse (hotkeys unavailable).
    var onBegin: (() -> Bool)?
    var onRecord: ((HotKeyCombo) -> HotKeyManager.RecordResult)?
    var onEnd: (() -> Void)?

    /// Hints and errors, shown under the field.
    let messageLabel = SettingsLabel.description("Click, then press the new shortcut.")
    private var keyMonitor: Any?
    private var shown: String?
    var isRecording: Bool { keyMonitor != nil }

    init() {
        super.init(frame: .zero)
        bezelStyle = .push
        setButtonType(.pushOnPushOff)
        font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        target = self
        action = #selector(clicked)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// `note` says why it's disabled (default: hotkeys are unavailable).
    func show(_ hotkey: String?, enabled: Bool, note: String? = nil) {
        let wasEnabled = isEnabled
        shown = hotkey
        isEnabled = enabled
        guard !isRecording else { return }
        title = hotkey ?? "None"
        state = .off
        if !enabled {
            showMessage(note ?? "Hotkeys are unavailable.", error: false)
        } else if !wasEnabled {
            showMessage("Click, then press the new shortcut.", error: false)
        }
    }

    @objc private func clicked() {
        if isRecording {
            cancel()
        } else if onBegin?() == true {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                self?.handle(event) ?? event
            }
            state = .on
            title = "Press a shortcut"
            showMessage("Esc to cancel.", error: false)
        } else {
            state = .off
        }
    }

    /// Ends a recording without a new combo (Esc, a second click, the page closing).
    func cancel() {
        guard isRecording else { return }
        stop()
        showMessage("Click, then press the new shortcut.", error: false)
    }

    private func stop() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        state = .off
        title = shown ?? "None"
        onEnd?()  // refreshes the page, which calls show(_:enabled:)
    }

    private func showMessage(_ text: String, error: Bool) {
        messageLabel.stringValue = text
        messageLabel.textColor = error ? .systemRed : .secondaryLabelColor
    }

    /// Returns nil to swallow the event.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.window === window else { return event }
        let modifiers = HotKeyCombo.carbonModifiers(event.modifierFlags)
        if event.type == .flagsChanged {
            let symbols = HotKeyCombo.modifierSymbols(modifiers)
            title = symbols.isEmpty ? "Press a shortcut" : symbols + "…"
            return nil
        }
        guard !event.isARepeat else { return nil }
        let keyCode = Int(event.keyCode)
        if keyCode == kVK_Escape && modifiers == 0 {
            cancel()
            return nil
        }
        switch HotKeyCombo.check(keyCode: keyCode, modifiers: modifiers) {
        case .unsupportedKey:
            title = "Press a shortcut"
            showMessage("That key can't be used. Esc to cancel.", error: true)
            return nil
        case .needsModifier:
            title = "Press a shortcut"
            showMessage("Add ⌃, ⌥ or ⌘ (F-keys work alone). Esc to cancel.", error: true)
            return nil
        case nil:
            break
        }
        let combo = HotKeyCombo(keyCode: UInt32(keyCode), modifiers: modifiers)
        title = combo.displayString
        switch onRecord?(combo) ?? .failed("Hotkeys are unavailable.") {
        case .saved:
            shown = combo.displayString
            stop()
            showMessage("Click, then press the new shortcut.", error: false)
        case .notSaved:
            shown = combo.displayString
            stop()
            showMessage("Active now, but config.json couldn't be updated, so it resets when Poppy restarts.",
                        error: true)
        case .failed(let message):
            showMessage(message, error: true)
        }
        return nil
    }
}

/// One click works even while the panel isn't key.
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class FirstMouseSegmentedControl: NSSegmentedControl {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class FirstMousePopUpButton: NSPopUpButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class FirstMouseSwitch: NSSwitch {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class FirstMouseStepper: NSStepper {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class FirstMouseSlider: NSSlider {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A slider with its value as a percentage beside it, in 5 % steps.
final class PercentSlider: NSStackView {
    let slider = FirstMouseSlider()
    private let label = NSTextField(labelWithString: "")

    init(range: ClosedRange<Double>) {
        super.init(frame: .zero)
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.isContinuous = true
        slider.controlSize = .small
        slider.widthAnchor.constraint(equalToConstant: 100).isActive = true
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 38).isActive = true
        addArrangedSubview(slider)
        addArrangedSubview(label)
        spacing = 6
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var value: Double {
        get { (slider.doubleValue * 20).rounded() / 20 }
        set {
            slider.doubleValue = newValue
            label.stringValue = "\(Int((newValue * 100).rounded())) %"
        }
    }

    var isEnabled: Bool {
        get { slider.isEnabled }
        set {
            slider.isEnabled = newValue
            label.textColor = newValue ? .secondaryLabelColor : .tertiaryLabelColor
        }
    }

    /// The label follows while dragging (the page isn't refreshed until the drag ends).
    func showValue() { label.stringValue = "\(Int((value * 100).rounded())) %" }
}

/// Top-to-bottom document for the settings scroll view.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
