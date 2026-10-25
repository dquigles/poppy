import AppKit
import ApplicationServices

/// Carries out an `ActPlan` in the captured app (DESIGN §9.14): presses with AXPress and
/// enters text by setting AXValue, which both work while the app is in the background
/// (Chrome and Firefox-based browsers fire the page's input events for it); where a set
/// value doesn't stick (Safari, some editors), by focusing the control and pasting, which
/// needs the app in front. Runs off the main thread.
nonisolated enum ActionRunner {
    /// Failures, as short messages; empty if every action worked.
    static func run(_ plan: ActPlan, in capture: ActCapture) -> [String] {
        var failures: [String] = []
        let app = AXUIElementCreateApplication(capture.pid)
        AXUIElementSetMessagingTimeout(app, 1.5)
        for (index, action) in plan.actions.enumerated() {
            if index > 0 { Thread.sleep(forTimeInterval: 0.12) }
            guard let element = capture.elements[action.id],
                  let control = capture.controls.first(where: { $0.id == action.id }) else {
                failures.append("no control \(action.id)")
                continue
            }
            switch action.op {
            case "press":
                let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
                if result != .success { failures.append("couldn't press \"\(control.label)\" (\(result.rawValue))") }
                appLog("act: press \(action.id) \(control.kind): \(result.rawValue)")
            case "enterText":
                if let failure = enterText(action.text, into: element, control: control, capture: capture, app: app) {
                    failures.append(failure)
                }
            default:
                failures.append("unknown action \(action.op)")
            }
        }
        return failures
    }

    private static func enterText(_ text: String, into element: AXUIElement, control: ActControl,
                                  capture: ActCapture, app: AXUIElement) -> String? {
        guard control.isText else { return "\"\(control.label)\" isn't a text control" }
        // A set value, read back: it can be accepted and still ignored (Safari's pages).
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
            // Browsers report it a moment later (Chrome 0.1 s, Zen up to 0.9 s, measured).
            for attempt in 0..<15 {
                if attempt > 0 { Thread.sleep(forTimeInterval: 0.1) }
                if Self.sameText(SelectionCapture.copy(element, kAXValueAttribute) ?? "", text) {
                    appLog("act: set \(control.kind) value (\(text.count) characters) after \(attempt * 100) ms")
                    return nil
                }
            }
            // Firefox-based browsers apply it (their page gets the input event) but may go on
            // reporting the old text while in the background; Safari reports the old text
            // because it ignored it. So for Gecko an accepted value counts.
            if capture.isGecko, result == .success {
                appLog("act: set \(control.kind) value (\(text.count) characters), unconfirmed (Gecko)")
                return nil
            }
        }
        // Pasting types into whatever is in front: only into the captured app.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == capture.pid else {
            appLog("act: \(control.kind) needs pasting, \(capture.appName) isn't in front")
            return "\(capture.appName) has to be in front to type into \"\(control.label.isEmpty ? control.kind : control.label)\""
                + " (ask the user to switch to it and tell you, then run the command again)"
        }
        // Paste: only once the control has the focus, or ⌘A would select something else.
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 0.1)
        if !isFocused(element, app: app) {
            AXUIElementPerformAction(element, kAXPressAction as CFString)
            Thread.sleep(forTimeInterval: 0.15)
        }
        guard isFocused(element, app: app) else {
            appLog("act: couldn't focus \(control.kind)")
            return "couldn't focus \"\(control.label.isEmpty ? control.kind : control.label)\""
        }
        KeyInput.replaceFocusedText(with: text)
        appLog("act: pasted into \(control.kind) (\(text.count) characters)")
        return nil
    }

    /// Line endings aside (a text area may store \r\n or \r).
    private static func sameText(_ a: String, _ b: String) -> Bool {
        func normalized(_ text: String) -> String {
            text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        }
        return normalized(a) == normalized(b)
    }

    /// The control, or something inside it (a web editor's own text area), has the focus.
    private static func isFocused(_ element: AXUIElement, app: AXUIElement) -> Bool {
        if (SelectionCapture.copy(element, kAXFocusedAttribute) as Bool?) == true { return true }
        guard var focused = SelectionCapture.element(app, kAXFocusedUIElementAttribute) else { return false }
        for _ in 0..<6 {
            if CFEqual(focused, element) { return true }
            guard let parent = SelectionCapture.element(focused, kAXParentAttribute) else { return false }
            focused = parent
        }
        return false
    }
}
