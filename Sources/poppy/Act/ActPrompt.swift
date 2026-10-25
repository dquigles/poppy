import Foundation

/// Actions on a capture's controls (DESIGN §9.14), from `poppy-act` or Poppy Dev's `actRun`.
nonisolated struct ActPlan: Codable, Sendable {
    nonisolated struct Action: Codable, Sendable {
        /// "press" or "enterText".
        var op: String
        var id: String
        /// The text for enterText; empty for press.
        var text: String
    }

    var actions: [Action]
}

/// The first message of an Act on Selection session (DESIGN §9.14): what was selected, the
/// window's controls, and how to act on them with `poppy-act`.
nonisolated enum ActPrompt {
    static func text(for capture: ActCapture, id: String, tool: String) -> String {
        var lines = [
            "I pressed my Act on Selection hotkey in \(capture.appName) to have you deal with what I selected. "
                + "Work out what it is and what I need. If it's something to do in the app (a question with "
                + "choices, a field to fill in, a coding problem, …), do it with the commands below. If it's "
                + "something to understand (an error, code, a passage, a term), explain it here instead and don't "
                + "touch the app.",
            "",
            "App: \(capture.appName)" + (capture.windowTitle.isEmpty ? "" : ", window \"\(capture.windowTitle)\""),
        ]
        if let image = capture.imagePath {
            lines += ["", "I didn't select text; I took a screenshot of the region instead: \(image). Read it first."]
        } else {
            lines += ["", "Selected text:", "<<<", capture.selection, ">>>"]
        }
        lines += ["", "Controls in the window (id, kind, state, label, value):"]
        if capture.controls.isEmpty { lines.append("(none: this app exposes no controls, so you can only answer here)") }
        for control in capture.controls {
            var line = "\(control.id) \(control.kind)"
            var states: [String] = []
            if control.focused { states.append("focused") }
            if !control.enabled { states.append("disabled") }
            if !control.isText, !control.value.isEmpty { states.append(control.value) }
            if !states.isEmpty { line += " (\(states.joined(separator: ", ")))" }
            if !control.label.isEmpty { line += ": \"\(oneLine(control.label))\"" }
            if control.isText { line += control.value.isEmpty ? " = empty" : " = \"\(oneLine(control.value))\"" }
            lines.append(line)
        }
        lines += [
            "",
            "To act in the app (it works while I'm in another app; I'm not switching to you):",
            "- Press buttons, checkboxes, radio buttons, switches or links: \(tool) \(id) press e3 e5",
            "- Replace a text field's, text area's or code editor's whole content (the text comes from stdin):",
            "  \(tool) \(id) text e7 <<'POPPY_EOF'",
            "  the text",
            "  POPPY_EOF",
            "The command says whether it worked. Rules:",
            "- Use only ids from the list. For checkboxes, press only those whose state must change.",
            "- For code, enter the complete solution, in the language of the starter code or the problem, keeping "
                + "any given function signature.",
            "- Don't press submit, next, send, delete or similar buttons unless the selection itself asks for it.",
            "- Act right away without asking me. Then end with one short line saying what you did (or your answer).",
        ]
        return lines.joined(separator: "\n")
    }

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
