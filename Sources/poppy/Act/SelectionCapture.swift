import AppKit
import ApplicationServices
import Carbon

/// One control of the front window, as the agent sees it (DESIGN §9.14).
nonisolated struct ActControl: Sendable {
    var id: String
    /// "text field", "checkbox", …
    var kind: String
    var label: String
    /// Text content, or "checked"/"unchecked"; empty if none.
    var value: String
    var enabled: Bool
    var focused: Bool
    /// Inside a web page (a browser or Electron app): text goes in by pasting.
    var inWeb: Bool
    var isText: Bool
}

/// What the hotkey found in the front app: the selection, the window's controls and the
/// elements to act on later. AXUIElement isn't Sendable, but it's a thread-safe CF handle.
nonisolated struct ActCapture: @unchecked Sendable {
    var pid: pid_t
    var appName: String
    var windowTitle: String
    var selection: String
    var controls: [ActControl]
    var elements: [String: AXUIElement]
    /// A region screenshot, when nothing was selected.
    var imagePath: String?
    /// A Firefox-based app (it ships Gecko's XUL library): its reported text values can lag
    /// in the background (DESIGN §9.14).
    var isGecko = false
}

/// Reads the front app through Accessibility (DESIGN §9.14). Runs off the main thread:
/// a big web page takes a moment, and a hung app is cut off by the messaging timeout.
nonisolated enum SelectionCapture {
    static let maxControls = 250
    static let maxNodes = 6000
    static let maxDepth = 80
    static let maxSelection = 20_000

    static func isTrusted(prompt: Bool) -> Bool {
        let key = "AXTrustedCheckOptionPrompt"  // kAXTrustedCheckOptionPrompt, a non-Sendable global var
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// `anchor` (the mouse, in Accessibility's top-left coordinates) picks the nearest
    /// controls when the window has more than `maxControls`.
    static func capture(pid: pid_t, appName: String, anchor: CGPoint) -> ActCapture {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.5)
        // Chromium (Chrome, Edge, Arc, Electron) builds its page tree only when asked.
        // Others refuse the attribute, which is fine.
        let manual = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        appLog("act: \(appName) AXManualAccessibility: \(manual == .success ? "on" : "refused (\(manual.rawValue))")")

        let focused: AXUIElement? = element(app, kAXFocusedUIElementAttribute)
        var selection = focused.flatMap { string($0, kAXSelectedTextAttribute) } ?? ""
        if selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Static text in a web page has no AXSelectedText: copy it instead.
            selection = KeyInput.copySelection() ?? ""
        }
        selection = String(selection.prefix(maxSelection))

        let window: AXUIElement? = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute)
        var found: [(ActControl, AXUIElement, CGRect)] = []
        var visited = 0
        if let window {
            collect(window, depth: 0, inWeb: false, focused: focused, visited: &visited, into: &found)
            // Firefox-based browsers, and Chrome versions that refuse AXManualAccessibility,
            // build their page tree only for an assistive app, which they recognize by
            // AXEnhancedUserInterface (VoiceOver sets it). Set only when no page content showed
            // up, and put back after: it can slow other apps' window animations.
            var enhanced = false
            if manual != .success, !found.contains(where: { $0.0.inWeb }),
               AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) == .success {
                enhanced = true
                appLog("act: \(appName) AXEnhancedUserInterface: on")
            }
            // A tree just switched on isn't built at once, and Chrome builds its own a moment
            // after it notices an Accessibility client. If a walk finds no more than the one
            // before (a native app), stop there.
            do {
                var previous = visited
                for delay in [0.5, 0.8] where !found.contains(where: { $0.0.inWeb }) {
                    Thread.sleep(forTimeInterval: delay)
                    var again: [(ActControl, AXUIElement, CGRect)] = []
                    visited = 0
                    collect(window, depth: 0, inWeb: false, focused: focused, visited: &visited, into: &again)
                    found = again
                    if visited <= previous { break }
                    previous = visited
                }
            }
            if enhanced {
                AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
            }
        }
        appLog("act: window \(window == nil ? "not found" : "walked"), \(visited) elements, \(found.count) controls")
        // The same link repeated (a calendar's event in every cell) only costs the agent time.
        var seenLinks = Set<String>()
        found.removeAll { entry in
            entry.0.kind == "link" && !seenLinks.insert(entry.0.label).inserted
        }
        if found.count > maxControls {
            found.sort { distance($0.2, anchor) < distance($1.2, anchor) }
            found = Array(found.prefix(maxControls))
        }
        // Reading order, then ids in that order.
        found.sort { ($0.2.minY, $0.2.minX) < ($1.2.minY, $1.2.minX) }
        var controls: [ActControl] = []
        var elements: [String: AXUIElement] = [:]
        for (index, entry) in found.enumerated() {
            var control = entry.0
            control.id = "e\(index + 1)"
            controls.append(control)
            elements[control.id] = entry.1
        }
        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleURL
        let isGecko = bundle.map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/MacOS/XUL").path)
        } ?? false
        return ActCapture(pid: pid, appName: appName,
                          windowTitle: window.flatMap { string($0, kAXTitleAttribute) } ?? "",
                          selection: selection, controls: controls, elements: elements, isGecko: isGecko)
    }

    // MARK: Walking the tree

    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
    private static let kinds: [String: String] = [
        "AXTextField": "text field", "AXTextArea": "text area", "AXComboBox": "combo box",
        "AXCheckBox": "checkbox", "AXRadioButton": "radio button", "AXButton": "button",
        "AXPopUpButton": "pop-up button", "AXMenuButton": "menu button", "AXLink": "link",
    ]
    private static let windowButtons: Set<String> = [
        "AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton",
    ]
    private static let attributes: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
        kAXEnabledAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute,
        kAXPlaceholderValueAttribute, kAXHelpAttribute,
    ]

    private static func collect(_ node: AXUIElement, depth: Int, inWeb: Bool, focused: AXUIElement?,
                                visited: inout Int, into found: inout [(ActControl, AXUIElement, CGRect)]) {
        guard depth < maxDepth, visited < maxNodes else { return }
        visited += 1
        let values = attributeValues(node)
        guard values.count == attributes.count else { return }
        func text(_ i: Int) -> String? { (values[i] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let role = text(0) ?? ""
        let web = inWeb || role == "AXWebArea"

        // The window's own close, minimize, zoom and full-screen buttons aren't the page's.
        if let subrole = text(1), windowButtons.contains(subrole) { return }
        if let kind = kinds[role] {
            let isSwitch = text(1) == "AXSwitch"
            let isText = textRoles.contains(role)
            let frame = CGRect(origin: point(values[6]) ?? .zero, size: size(values[7]) ?? .zero)
            if frame.width > 0, frame.height > 0 {
                var value = ""
                if isText {
                    let full = values[4] as? String ?? ""
                    let isFocused = focused.map { CFEqual($0, node) } ?? false
                    value = String(full.prefix(isFocused ? 4000 : 300))
                } else if role == "AXCheckBox" || role == "AXRadioButton" {
                    value = (values[4] as? NSNumber)?.intValue == 1 ? "checked" : "unchecked"
                } else if role == "AXPopUpButton" {
                    value = values[4] as? String ?? ""
                }
                var label = text(2) ?? text(3) ?? titleElementText(node) ?? text(9) ?? text(10) ?? ""
                if label.isEmpty, !isText { label = childText(node, depth: 0) }
                found.append((ActControl(id: "", kind: isSwitch ? "switch" : kind,
                                         label: String(label.prefix(160)), value: value,
                                         enabled: (values[5] as? Bool) ?? true,
                                         focused: focused.map { CFEqual($0, node) } ?? false,
                                         inWeb: web, isText: isText), node, frame))
            }
            // A control's own children (a button's text) aren't controls.
            if !isText, role != "AXComboBox" { return }
        }
        guard let children = values[8] as? [AnyObject] else { return }
        for child in children {
            guard CFGetTypeID(child) == AXUIElementGetTypeID() else { continue }
            collect(child as! AXUIElement, depth: depth + 1, inWeb: web, focused: focused, visited: &visited,
                    into: &found)
        }
    }

    /// `attributes` in one call; one by one where that call fails (Firefox-based browsers).
    /// A missing attribute is NSNull (or an AXValue error from the batched call).
    private static func attributeValues(_ node: AXUIElement) -> [AnyObject] {
        var raw: CFArray?
        if AXUIElementCopyMultipleAttributeValues(node, attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0),
                                                  &raw) == .success,
           let values = raw as? [AnyObject], values.count == attributes.count {
            return values
        }
        return attributes.map { attribute in
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, attribute as CFString, &value) == .success, let value else {
                return NSNull()
            }
            return value as AnyObject
        }
    }

    /// The label element a control names (a native form's "Name:" text).
    private static func titleElementText(_ node: AXUIElement) -> String? {
        guard let title: AXUIElement = element(node, kAXTitleUIElementAttribute) else { return nil }
        return string(title, kAXValueAttribute) ?? string(title, kAXTitleAttribute)
    }

    /// The text inside a control with no title (a web button's or option's text).
    private static func childText(_ node: AXUIElement, depth: Int) -> String {
        guard depth < 4, let children: [AnyObject] = copy(node, kAXChildrenAttribute) else { return "" }
        var parts: [String] = []
        for child in children.prefix(12) where CFGetTypeID(child) == AXUIElementGetTypeID() {
            let element = child as! AXUIElement
            if let value = string(element, kAXValueAttribute) ?? string(element, kAXTitleAttribute)
                ?? string(element, kAXDescriptionAttribute) {
                parts.append(value)
            } else {
                parts.append(childText(element, depth: depth + 1))
            }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func distance(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    // MARK: Accessibility helpers

    static func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        let value: String? = copy(element, attribute)
        return value?.isEmpty == false ? value : nil
    }

    private static func point(_ value: AnyObject) -> CGPoint? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func size(_ value: AnyObject) -> CGSize? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }
}

/// Synthetic keys for copying the selection and pasting text (DESIGN §9.14). Posting
/// events needs the Accessibility permission, which Act on Selection asks for anyway.
nonisolated enum KeyInput {
    /// Waits (up to 1.5 s) until no modifier key is held, so the hotkey's own ⌃⌥… don't
    /// combine with the keys posted next.
    static func waitForModifiersUp() {
        let held: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        let deadline = Date().addingTimeInterval(1.5)
        while !CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.03)
        }
    }

    static func press(_ key: Int, flags: CGEventFlags = .maskCommand) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    /// ⌘C in the front app; its text, with the clipboard put back. Nil if nothing was
    /// copied (no selection).
    static func copySelection() -> String? {
        let pasteboard = NSPasteboard.general
        let saved = ClipboardSnapshot(pasteboard)
        let before = pasteboard.changeCount
        waitForModifiersUp()
        press(kVK_ANSI_C)
        let deadline = Date().addingTimeInterval(0.6)
        while pasteboard.changeCount == before, Date() < deadline { Thread.sleep(forTimeInterval: 0.03) }
        guard pasteboard.changeCount != before else { return nil }
        let text = pasteboard.string(forType: .string)
        saved.restore(pasteboard)
        return text
    }

    /// ⌘A then ⌘V of `text` into the focused control, with the clipboard put back.
    static func replaceFocusedText(with text: String) {
        let pasteboard = NSPasteboard.general
        let saved = ClipboardSnapshot(pasteboard)
        waitForModifiersUp()
        press(kVK_ANSI_A)
        Thread.sleep(forTimeInterval: 0.08)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ours = pasteboard.changeCount
        press(kVK_ANSI_V)
        // The app reads the clipboard when it handles the event: give it time first.
        Thread.sleep(forTimeInterval: 0.4)
        if pasteboard.changeCount == ours { saved.restore(pasteboard) }
    }
}

/// The clipboard's items, to put back after borrowing it.
nonisolated struct ClipboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            var types: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { types[type] = data } }
            return types
        }
    }

    func restore(_ pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}
