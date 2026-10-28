import Carbon
import Foundation
import Testing
@testable import poppy

/// Hotkey strings (DESIGN §11.1).
struct HotKeyComboTests {
    @Test func parsesAndWritesBack() throws {
        let combo = try #require(HotKeyCombo(spec: "ctrl+opt+space"))
        #expect(combo.keyCode == UInt32(kVK_Space))
        #expect(combo.modifiers == UInt32(controlKey | optionKey))
        #expect(combo.spec == "ctrl+opt+space")
        #expect(combo.displayString == "⌃⌥Space")
    }

    @Test(arguments: [
        ("Command+Shift+K", "shift+cmd+k", "⇧⌘K"),
        ("alt+control+return", "ctrl+opt+return", "⌃⌥↩"),
        ("cmd+opt+grave", "opt+cmd+grave", "⌥⌘`"),
        ("cmd+`", "cmd+grave", "⌘`"),
        ("ctrl + opt + v", "ctrl+opt+v", "⌃⌥V"),
        ("f5", "f5", "F5"),
        ("opt+shift+cmd+4", "opt+shift+cmd+4", "⌥⇧⌘4"),
    ])
    func aliasesAndCanonicalForm(spec: String, canonical: String, display: String) throws {
        let combo = try #require(HotKeyCombo(spec: spec))
        #expect(combo.spec == canonical)
        #expect(combo.displayString == display)
        #expect(HotKeyCombo(spec: combo.spec) == combo)
    }

    @Test(arguments: ["", "space", "shift+a", "ctrl+opt", "ctrl+a+b", "ctrl+hyper", "ctrl+opt+numpad5"])
    func rejectsInvalid(spec: String) {
        #expect(HotKeyCombo(spec: spec) == nil)
    }

    @Test func checkRule() {
        #expect(HotKeyCombo.check(keyCode: kVK_ANSI_A, modifiers: UInt32(shiftKey)) == .needsModifier)
        #expect(HotKeyCombo.check(keyCode: kVK_ANSI_A, modifiers: UInt32(cmdKey)) == nil)
        #expect(HotKeyCombo.check(keyCode: kVK_F1, modifiers: 0) == nil)
        #expect(HotKeyCombo.check(keyCode: 0x7FFF, modifiers: UInt32(cmdKey)) == .unsupportedKey)
    }

    @Test func carbonModifiersIgnoreOtherFlags() {
        #expect(HotKeyCombo.carbonModifiers([.command, .shift, .capsLock, .function]) == UInt32(cmdKey | shiftKey))
    }
}

/// Pasting text, files and images into the agent (DESIGN §9.10).
struct AttachmentsTests {
    @Test func sanitizedDropsControlCharacters() {
        #expect(Attachments.sanitized("a\u{1B}[201~b") == "a[201~b")  // can't end a bracketed paste
        #expect(Attachments.sanitized("one\r\ntwo\rthree") == "one\ntwo\nthree")
        #expect(Attachments.sanitized("tab\there\u{7F}\u{85}\u{0}") == "tab\there")
        #expect(Attachments.sanitized("héllo 🌸") == "héllo 🌸")
    }

    @Test func escapeLikeTerminal() {
        #expect(Attachments.escape("/tmp/My File (1).png") == #"/tmp/My\ File\ \(1\).png"#)
        #expect(Attachments.escape("/a/$HOME&'x'") == #"/a/\$HOME\&\'x\'"#)
        #expect(Attachments.escape("/plain/path.txt") == "/plain/path.txt")
    }

    @Test func pasteTextJoinsEscapedPathsAndSkipsControlCharacters() {
        let urls = [URL(fileURLWithPath: "/tmp/a b.png"), URL(fileURLWithPath: "/tmp/bad\nname"), URL(fileURLWithPath: "/tmp/c")]
        #expect(Attachments.pasteText(for: urls) == #"/tmp/a\ b.png /tmp/c "#)
        #expect(Attachments.pasteText(for: []) == "")
    }
}

/// The `poppy` shell command (DESIGN §9.9) and request files.
struct CommandLineTests {
    private func request(_ arguments: [String]) -> LaunchRequest? {
        if case .request(let request) = CommandLineClient.parse(arguments) { return request }
        return nil
    }

    private func failure(_ arguments: [String]) -> String? {
        if case .failure(let message) = CommandLineClient.parse(arguments) { return message }
        return nil
    }

    @Test func directoryDefaultsToTheCurrentOne() throws {
        let parsed = try #require(request([]))
        #expect(parsed.directory == Config.normalize(FileManager.default.currentDirectoryPath))
        #expect(parsed.show && parsed.new == nil && parsed.newPill == nil && parsed.command == nil)
    }

    @Test func options() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let parsed = try #require(request(["-a", "Codex", "--pill", "large", "--auto-open", "both", "--no-focus",
                                           "--no-usage", "-b", "--new", "--new-pill", folder.path + "/./"]))
        #expect(parsed.command == "codex")
        #expect(parsed.pillDiameter != nil)
        #expect(parsed.autoOpenOnInput == true && parsed.autoOpenOnDone == true && parsed.autoOpenFocus == false)
        #expect(parsed.showUsage == false && !parsed.show && parsed.new == true && parsed.newPill == true)
        #expect(parsed.directory == Config.normalize(folder.path))
    }

    @Test(arguments: [("agy", "agy"), ("antigravity", "agy"), ("claude", "claude"), ("OPENCODE", "opencode")])
    func agentsByNameOrCommand(name: String, command: String) {
        #expect(request(["-a", name])?.command == command)
    }

    @Test func autoOpenModes() {
        #expect(request(["--auto-open", "input"]).map { [$0.autoOpenOnInput, $0.autoOpenOnDone] } == [true, false])
        #expect(request(["--auto-open", "done"]).map { [$0.autoOpenOnInput, $0.autoOpenOnDone] } == [false, true])
        #expect(request(["--auto-open", "off"]).map { [$0.autoOpenOnInput, $0.autoOpenOnDone] } == [false, false])
    }

    @Test(arguments: [["-a"], ["-a", "nope"], ["-c", "  "], ["--pill", "huge"], ["--auto-open", "sometimes"],
                      ["--bogus"], [".", "."], ["/definitely/not/here"]])
    func failures(arguments: [String]) {
        #expect(failure(arguments) != nil)
    }

    @Test func help() {
        guard case .help = CommandLineClient.parse(["--focus", "-h"]) else { Issue.record("expected help"); return }
    }

    @Test func requestFilesMustBeInTheRunFolder() {
        let run = LaunchRequest.directoryURL
        #expect(LaunchRequest.isRequestFile(run.appendingPathComponent("request-1.json")))
        #expect(!LaunchRequest.isRequestFile(run.appendingPathComponent("request-1.txt")))
        #expect(!LaunchRequest.isRequestFile(run.appendingPathComponent("status-1-2")))
        #expect(!LaunchRequest.isRequestFile(URL(fileURLWithPath: "/tmp/request-1.json")))
        #expect(!LaunchRequest.isRequestFile(run.appendingPathComponent("sub/request-1.json")))
        #expect(ActRequest.isRequestFile(run.appendingPathComponent("act-9.json")))
        #expect(!ActRequest.isRequestFile(run.appendingPathComponent("request-9.json")))
        #expect(ActRequest.replyURL(for: run.appendingPathComponent("act-9.json")).lastPathComponent == "act-9.json.reply")
    }

    @Test func requestRoundTrip() throws {
        var original = LaunchRequest()
        original.directory = "/tmp"
        original.newPill = true
        original.show = false
        let again = try JSONDecoder().decode(LaunchRequest.self, from: JSONEncoder().encode(original))
        #expect(again == original)
    }
}

/// Act on Selection's first message and plans (DESIGN §9.14).
struct ActTests {
    private func capture(selection: String = "What is 2+2?", image: String? = nil, controls: [ActControl] = []) -> ActCapture {
        ActCapture(pid: 1, appName: "Safari", windowTitle: "Quiz", selection: selection, controls: controls,
                   elements: [:], imagePath: image)
    }

    @Test func promptHasTheSelectionControlsAndTool() {
        let controls = [
            ActControl(id: "e1", kind: "button", label: "Submit", value: "", enabled: false, focused: false, inWeb: true, isText: false),
            ActControl(id: "e2", kind: "checkbox", label: "A \"quoted\"\nlabel", value: "checked", enabled: true,
                       focused: false, inWeb: true, isText: false),
            ActControl(id: "e3", kind: "text field", label: "", value: "", enabled: true, focused: true, inWeb: false, isText: true),
        ]
        let text = ActPrompt.text(for: capture(controls: controls), id: "cap1", tool: "poppy-act")
        #expect(text.contains("App: Safari, window \"Quiz\""))
        #expect(text.contains("<<<\nWhat is 2+2?\n>>>"))
        #expect(text.contains("e1 button (disabled): \"Submit\""))
        #expect(text.contains(#"e2 checkbox (checked): "A \"quoted\"\nlabel""#))
        #expect(text.contains("e3 text field (focused) = empty"))
        #expect(text.contains("poppy-act cap1 press e3 e5"))
    }

    @Test func promptForAScreenshotOrNoControls() {
        let text = ActPrompt.text(for: capture(selection: "", image: "/tmp/shot.png"), id: "c", tool: "t")
        #expect(text.contains("screenshot of the region instead: /tmp/shot.png"))
        #expect(!text.contains("<<<"))
        #expect(text.contains("(none: this app exposes no controls"))
    }

    @Test func planDecodes() throws {
        let plan = try JSONDecoder().decode(ActPlan.self, from: Data(#"{"actions": [{"op": "press", "id": "e1", "text": ""}]}"#.utf8))
        #expect(plan.actions.first?.op == "press" && plan.actions.first?.id == "e1")
    }
}

/// The terminal's look (DESIGN §9.1).
struct TerminalLookTests {
    @Test func cursorStyles() {
        var config = Config()
        config.cursorStyle = .bar
        config.cursorBlink = false
        #expect(TerminalLook(config).cursorStyle == .steadyBar)
        config.cursorStyle = .underline
        config.cursorBlink = true
        #expect(TerminalLook(config).cursorStyle == .blinkUnderline)
        #expect(TerminalLook(Config()).cursorStyle == .blinkBlock)
    }

    @Test func explicitThemesPickTheirPalette() {
        var config = Config()
        config.terminalTheme = .light
        #expect(TerminalLook(config).palette == .light)
        config.terminalTheme = .dark
        #expect(TerminalLook(config).palette == .dark)
    }

    @Test func missingFontFallsBackToSystemMono() {
        var config = Config()
        config.terminalFont = "NoSuchFont-Regular"
        config.terminalFontSize = 15
        let font = TerminalLook(config).resolvedFont()
        #expect(font.pointSize == 15)
        #expect(font.isFixedPitch)
    }
}

struct CommandInstallTests {
    /// The wrapper runs the app's binary with --cli and the arguments, also from a path with
    /// spaces and shell characters, and never replaces an existing command.
    @Test func wrapperRunsTheAppsBinary() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = folder.appendingPathComponent("My $Apps \"x\"/Poppy.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let out = folder.appendingPathComponent("args")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(out.path)'\n"
            .write(to: macOS.appendingPathComponent("poppy"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: macOS.appendingPathComponent("poppy").path)
        let bin = folder.appendingPathComponent("bin")
        try CommandLineClient.installWrapper(in: bin, app: app.path, executable: "poppy")

        #expect(runShell("'\(bin.path)/poppy' -b 'a dir'") == 0)
        #expect(read(out) == "--cli\n-b\na dir\n")
        #expect(throws: (any Error).self) {
            try CommandLineClient.installWrapper(in: bin, app: app.path, executable: "poppy")
        }
    }
}
