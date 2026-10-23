import AppKit
@preconcurrency import SwiftTerm

/// How every terminal view looks (DESIGN §9.1): font, colors, background opacity and
/// cursor, from the global settings. Applied to each view at creation and again, live,
/// whenever a setting changes.
struct TerminalLook: Equatable {
    var font: String?
    var fontSize: Double
    var theme: TerminalTheme
    var opacity: Double
    var cursor: CursorShape
    var blink: Bool

    init(_ config: Config) {
        font = config.terminalFont
        fontSize = config.terminalFontSize
        theme = config.terminalTheme
        opacity = config.terminalOpacity
        cursor = config.cursorStyle
        blink = config.cursorBlink
    }

    /// The saved font, or the system's monospaced one (also when the saved one is gone).
    func resolvedFont() -> NSFont {
        let size = CGFloat(fontSize)
        if let font {
            if let named = NSFont(name: font, size: size) { return named }
            if Self.missingLogged.insert(font).inserted {
                appLog("terminal: font \(font) is not installed, using System Mono")
            }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static var missingLogged: Set<String> = []

    /// Light or dark colors. Follow system goes by the app's appearance, not the view's:
    /// the glass may switch its content's look over light backgrounds.
    var palette: TerminalPalette {
        switch theme {
        case .dark: .dark
        case .light: .light
        case .system: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        }
    }

    var cursorStyle: CursorStyle {
        switch (cursor, blink) {
        case (.block, true): .blinkBlock
        case (.block, false): .steadyBlock
        case (.bar, true): .blinkBar
        case (.bar, false): .steadyBar
        case (.underline, true): .blinkUnderline
        case (.underline, false): .steadyUnderline
        }
    }

    /// Sets everything on `view`. A font change reflows the terminal once (one SIGWINCH);
    /// the rest only redraws. `previous` skips what didn't change.
    func apply(to view: PoppyTerminalView, previous: TerminalLook? = nil) {
        let font = resolvedFont()
        if view.font != font { view.font = font }
        let palette = palette
        if previous == nil || palette != view.appliedPalette {
            view.nativeForegroundColor = palette.foreground
            view.nativeBackgroundColor = palette.background
            view.caretColor = palette.cursor
            view.selectedTextBackgroundColor = palette.selection
            view.installColors(palette.ansi)
            view.appliedPalette = palette
        }
        view.backgroundOpacity = CGFloat(opacity)  // after the background, which sets the alpha
        if previous?.cursorStyle != cursorStyle { view.terminal.setCursorStyle(cursorStyle) }
    }
}

/// One theme's colors (DESIGN §9.1).
struct TerminalPalette: Equatable {
    var foreground: NSColor
    var background: NSColor
    var cursor: NSColor
    var selection: NSColor
    var ansi: [SwiftTerm.Color]

    /// Today's colors: the ones Poppy always had, with SwiftTerm's own (Terminal.app) palette.
    static let dark = TerminalPalette(
        foreground: NSColor(white: 0.92, alpha: 1),
        background: NSColor(white: 0.05, alpha: 1),
        cursor: NSColor(white: 0.92, alpha: 1),  // the foreground, as SwiftTerm draws it by default
        selection: NSColor(srgbRed: 0, green: 166.0 / 255.0, blue: 178.0 / 255.0, alpha: 1),
        ansi: SwiftTerm.Color.terminalAppColors)

    /// Dark text on a light background; the ANSI colors are darkened so yellow, cyan and
    /// "white" stay readable on it.
    static let light = TerminalPalette(
        foreground: NSColor(white: 0.12, alpha: 1),
        background: NSColor(white: 0.97, alpha: 1),
        cursor: NSColor(white: 0.25, alpha: 1),
        selection: NSColor(srgbRed: 0.66, green: 0.80, blue: 1.0, alpha: 1),
        ansi: Self.colors([
            (0, 0, 0), (180, 36, 25), (24, 128, 30), (138, 100, 0),
            (28, 70, 200), (150, 40, 160), (0, 120, 136), (118, 118, 118),
            (92, 92, 92), (214, 54, 40), (38, 152, 46), (166, 124, 0),
            (52, 98, 230), (180, 60, 190), (0, 146, 162), (70, 70, 70),
        ]))

    private static func colors(_ rgb: [(UInt16, UInt16, UInt16)]) -> [SwiftTerm.Color] {
        rgb.map { SwiftTerm.Color(red8: $0.0, green8: $0.1, blue8: $0.2) }
    }

    static func == (a: TerminalPalette, b: TerminalPalette) -> Bool {
        a.foreground == b.foreground && a.background == b.background
    }
}
