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
    var onEditConfig: (() -> Void)?

    let hotkeyField = HotkeyField()
    private let scrollView = NSScrollView()
    private let agentPopUp = FirstMousePopUpButton()
    private let directoryPopUp = FirstMousePopUpButton()
    private let pillStack = NSStackView()
    private var pillRadios: [NSButton] = []
    private let usageSwitch = FirstMouseSwitch()
    private let hooksSwitch = FirstMouseSwitch()
    private let onInputSwitch = FirstMouseSwitch()
    private let onDoneSwitch = FirstMouseSwitch()
    private let focusSwitch = FirstMouseSwitch()
    private let autoOpenNote = SettingsLabel.description("")
    private let editConfigButton = FirstMouseButton(title: "Edit config.json…", target: nil, action: nil)
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
        hotkeyField.messageLabel.stringValue = "Click, then press the new shortcut."

        let restartNote = "Changing it restarts the agent."
        let general = Self.group([
            Self.row("Agent", restartNote, agentPopUp).view,
            Self.row("Working directory", restartNote, directoryPopUp).view,
            Self.row("Hotkey", hotkeyField.messageLabel, hotkeyField).view,
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
        let advanced = Self.group([
            Self.row("Custom agents and other options", "In config.json, read when Poppy starts.",
                     editConfigButton).view,
        ])

        let content = NSStackView(views: [
            general,
            Self.sectionHeader("Pill"), pill,
            Self.sectionHeader("Auto-Open", autoOpenNote), autoOpen,
            Self.sectionHeader("Advanced"), advanced,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 20
        for header in [content.arrangedSubviews[1], content.arrangedSubviews[3], content.arrangedSubviews[5]] {
            content.setCustomSpacing(8, after: header)
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        for view in content.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        for popUp in [agentPopUp, directoryPopUp] {
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
        usageSwitch.setAccessibilityLabel("Usage meters")
        hooksSwitch.setAccessibilityLabel("Agent status")
        onInputSwitch.setAccessibilityLabel("Auto-Open when the agent needs input")
        onDoneSwitch.setAccessibilityLabel("Auto-Open when the agent is done")
        focusSwitch.setAccessibilityLabel("Auto-Open takes keyboard focus")
        hotkeyField.setAccessibilityLabel("Hotkey")
        linkKeyLoop()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Tab order with Full Keyboard Access on (rebuilt when the pill size radios change).
    private func linkKeyLoop() {
        let loop: [NSView] = [agentPopUp, directoryPopUp, hotkeyField] + pillRadios
            + [usageSwitch, hooksSwitch, onInputSwitch, onDoneSwitch, focusSwitch, editConfigButton]
        nextKeyView = loop.first
        for (view, next) in zip(loop, loop.dropFirst()) { view.nextKeyView = next }
        loop.last?.nextKeyView = self
    }

    // MARK: Building blocks

    /// A row: title (13 pt) and an optional description (11 pt, secondary) on the left,
    /// the control on the right, vertically centered.
    private static func row(_ title: String, _ description: String?, _ control: NSView)
        -> (view: NSView, title: NSTextField) {
        row(title, description.map { SettingsLabel.description($0) }, control)
    }

    private static func row(_ title: String, _ description: NSTextField?, _ control: NSView)
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

        let row = NSView()
        for view in [text, control] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        // The text fills the space left of the control, so a description wraps at that
        // width (and keeps it when its text changes) instead of shrinking to a word.
        let fillText = text.trailingAnchor.constraint(equalTo: control.leadingAnchor, constant: -16)
        fillText.priority = NSLayoutConstraint.Priority(600)
        description?.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        let hug = row.heightAnchor.constraint(equalToConstant: 0)
        hug.priority = .fittingSizeCompression
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            text.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -16),
            text.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            text.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 9),
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
    private static func group(_ rows: [NSView]) -> NSView {
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
    private static func sectionHeader(_ title: String, _ description: NSTextField? = nil) -> NSView {
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

    func show(_ hotkey: String?, enabled: Bool) {
        shown = hotkey
        isEnabled = enabled
        guard !isRecording else { return }
        title = hotkey ?? "None"
        state = .off
        if !enabled { showMessage("Hotkeys are unavailable.", error: false) }
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

/// Top-to-bottom document for the settings scroll view.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
