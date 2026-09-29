import AppKit
import Carbon

/// A hotkey: Carbon key code + Carbon modifier mask (DESIGN §11.1). One key table
/// drives parsing config strings, writing them back, display, and recording.
nonisolated struct HotKeyCombo: Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32

    private nonisolated struct Key: Sendable {
        let code: Int
        /// Canonical config token first; the rest are accepted aliases.
        let tokens: [String]
        let display: String
        /// F-keys may be used without modifiers.
        var standalone = false
    }

    // Letters and digits: US-layout key codes (kVK_ANSI_*), tokens are the character.
    private static let keys: [Key] = {
        var keys: [Key] = []
        let letters: [(String, Int)] = [
            ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D), ("e", kVK_ANSI_E),
            ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H), ("i", kVK_ANSI_I), ("j", kVK_ANSI_J),
            ("k", kVK_ANSI_K), ("l", kVK_ANSI_L), ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O),
            ("p", kVK_ANSI_P), ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
            ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X), ("y", kVK_ANSI_Y),
            ("z", kVK_ANSI_Z),
            ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3), ("4", kVK_ANSI_4),
            ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8), ("9", kVK_ANSI_9),
        ]
        for (token, code) in letters {
            keys.append(Key(code: code, tokens: [token], display: token.uppercased()))
        }
        // Punctuation: named tokens (so JSON never needs escaping), the character as an alias.
        let punctuation: [(String, String, Int)] = [
            ("grave", "`", kVK_ANSI_Grave), ("minus", "-", kVK_ANSI_Minus), ("equal", "=", kVK_ANSI_Equal),
            ("leftbracket", "[", kVK_ANSI_LeftBracket), ("rightbracket", "]", kVK_ANSI_RightBracket),
            ("backslash", "\\", kVK_ANSI_Backslash), ("semicolon", ";", kVK_ANSI_Semicolon),
            ("quote", "'", kVK_ANSI_Quote), ("comma", ",", kVK_ANSI_Comma), ("period", ".", kVK_ANSI_Period),
            ("slash", "/", kVK_ANSI_Slash),
        ]
        for (name, char, code) in punctuation {
            keys.append(Key(code: code, tokens: [name, char], display: char))
        }
        keys += [
            Key(code: kVK_Space, tokens: ["space"], display: "Space"),
            Key(code: kVK_Return, tokens: ["return", "enter"], display: "↩"),
            Key(code: kVK_Tab, tokens: ["tab"], display: "⇥"),
            Key(code: kVK_Escape, tokens: ["escape", "esc"], display: "⎋"),
            Key(code: kVK_Delete, tokens: ["delete", "backspace"], display: "⌫"),
            Key(code: kVK_ForwardDelete, tokens: ["forwarddelete"], display: "⌦"),
            Key(code: kVK_LeftArrow, tokens: ["left"], display: "←"),
            Key(code: kVK_RightArrow, tokens: ["right"], display: "→"),
            Key(code: kVK_UpArrow, tokens: ["up"], display: "↑"),
            Key(code: kVK_DownArrow, tokens: ["down"], display: "↓"),
            Key(code: kVK_Home, tokens: ["home"], display: "↖"),
            Key(code: kVK_End, tokens: ["end"], display: "↘"),
            Key(code: kVK_PageUp, tokens: ["pageup"], display: "⇞"),
            Key(code: kVK_PageDown, tokens: ["pagedown"], display: "⇟"),
        ]
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (index, code) in functionKeys.enumerated() {
            keys.append(Key(code: code, tokens: ["f\(index + 1)"], display: "F\(index + 1)", standalone: true))
        }
        return keys
    }()

    private static let keysByToken: [String: Key] = {
        var map: [String: Key] = [:]
        for key in keys { for token in key.tokens { map[token] = key } }
        return map
    }()

    private static let keysByCode: [Int: Key] = Dictionary(keys.map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })

    /// Modifiers in Apple's display order: token, Carbon mask, symbol.
    private static let modifierOrder: [(String, Int, String)] = [
        ("ctrl", controlKey, "⌃"), ("opt", optionKey, "⌥"), ("shift", shiftKey, "⇧"), ("cmd", cmdKey, "⌘"),
    ]

    private static let modifierTokens: [String: Int] = [
        "ctrl": controlKey, "control": controlKey,
        "opt": optionKey, "option": optionKey, "alt": optionKey,
        "cmd": cmdKey, "command": cmdKey,
        "shift": shiftKey,
    ]

    /// The rule for every combo, parsed or recorded: an F-key alone is fine; any
    /// other key needs ⌃, ⌥ or ⌘ (⇧ alone would swallow typed capitals system-wide).
    enum Problem: Equatable { case unsupportedKey, needsModifier }

    static func check(keyCode: Int, modifiers: UInt32) -> Problem? {
        guard let key = keysByCode[keyCode] else { return .unsupportedKey }
        let strong = UInt32(controlKey | optionKey | cmdKey)
        if !key.standalone && modifiers & strong == 0 { return .needsModifier }
        return nil
    }

    /// "ctrl+opt+space" -> combo. Exactly one key token; nil if invalid.
    init?(spec: String) {
        var modifiers: UInt32 = 0
        var key: Key?
        // "+" is only ever the separator; split drops empty pieces.
        for raw in spec.lowercased().split(separator: "+") {
            let token = raw.trimmingCharacters(in: .whitespaces)
            if let modifier = Self.modifierTokens[token] {
                modifiers |= UInt32(modifier)
            } else if let match = Self.keysByToken[token] {
                guard key == nil else { return nil }
                key = match
            } else {
                return nil
            }
        }
        guard let key, Self.check(keyCode: key.code, modifiers: modifiers) == nil else { return nil }
        self.keyCode = UInt32(key.code)
        self.modifiers = modifiers
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Carbon modifier mask for an NSEvent's flags (⌃⌥⇧⌘ only; fn, caps lock and keypad ignored).
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask = 0
        if flags.contains(.control) { mask |= controlKey }
        if flags.contains(.option) { mask |= optionKey }
        if flags.contains(.shift) { mask |= shiftKey }
        if flags.contains(.command) { mask |= cmdKey }
        return UInt32(mask)
    }

    /// Canonical config string, e.g. "ctrl+opt+space".
    var spec: String {
        var parts = Self.modifierOrder.filter { modifiers & UInt32($0.1) != 0 }.map(\.0)
        parts.append(Self.keysByCode[Int(keyCode)]?.tokens.first ?? "?")
        return parts.joined(separator: "+")
    }

    /// Menu/recorder form, e.g. "⌃⌥Space".
    var displayString: String {
        Self.modifierSymbols(modifiers) + (Self.keysByCode[Int(keyCode)]?.display ?? "?")
    }

    static func modifierSymbols(_ modifiers: UInt32) -> String {
        modifierOrder.filter { modifiers & UInt32($0.1) != 0 }.map(\.2).joined()
    }
}
