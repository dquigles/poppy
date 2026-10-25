import Foundation

/// Files live in ~/.config/poppy/, or ~/.config/poppy-dev/ for Poppy Dev (DESIGN §8, §12.1).
nonisolated enum ConfigPaths {
    static let directory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(AppVariant.isDev ? ".config/poppy-dev" : ".config/poppy")
    static let config = directory.appendingPathComponent("config.json")
    static let state = directory.appendingPathComponent("state.json")

    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// User-edited settings, read once at launch (DESIGN §8.1).
nonisolated struct Config: Codable, Sendable {
    static let defaultCommand = "claude"
    static let defaultCwd = "~"
    /// Poppy Dev has none by default, so it never takes the installed Poppy's (DESIGN §12.1).
    static let defaultHotkey = AppVariant.isDev ? "" : "ctrl+opt+space"

    var command: String
    var cwd: String
    var hotkey: String
    /// Extra agents for the menu's Agent submenu (DESIGN §9.5). Optional; never written by Poppy.
    var agents: [AgentProfile]?
    /// Install status hooks for the agent (DESIGN §9.6). Default true.
    var statusHooks = true
    /// Auto-open when the agent needs input / is done (DESIGN §7.15). Default false.
    var autoOpenOnInput = false
    var autoOpenOnDone = false
    /// Auto-open takes the keyboard (true) or only shows the panel (DESIGN §7.15). Default true.
    var autoOpenFocus = true
    /// Usage footer and pill ring (DESIGN §9.7). Default true.
    var showUsage = true
    /// Which pill the hotkey opens when there are several (DESIGN §11). Default recent.
    var hotkeyTarget = HotkeyTarget.recent
    /// A click outside folds the panel (DESIGN §6.3); off, it stays open. Default true.
    var foldOnClickOutside = true
    /// The open panel fades to `inactiveOpacity` while it isn't focused (DESIGN §7.20).
    var fadeWhenInactive = false
    var inactiveOpacity = 0.5
    /// No pill on screen while collapsed; opened from the menu bar (DESIGN §7.21).
    var hidePill = false
    /// The terminal's look (DESIGN §9.1); `terminalFont` is a PostScript name, nil for
    /// the system's monospaced font.
    var terminalFont: String?
    var terminalFontSize = 13.0
    var terminalTheme = TerminalTheme.dark
    var terminalOpacity = 0.8
    var cursorStyle = CursorShape.block
    var cursorBlink = true
    /// A finished mouse selection is copied (DESIGN §9.1). Default false.
    var copyOnSelect = false
    /// Quit asks first while an agent is working or waiting (DESIGN §4). Default true.
    var confirmQuit = true
    /// Act on Selection's hotkey (DESIGN §9.14); none by default.
    var actHotkey = ""
    /// When finished Act on Selection sessions close (DESIGN §9.14).
    var actCleanup = ActCleanup.next
    /// Act on Selection is on: its hotkey is registered (DESIGN §9.14). Missing, it's on
    /// when a hotkey was already set.
    var actEnabled = false
    /// The intro was finished or skipped, so it doesn't show at launch (DESIGN §9.15).
    var introShown = false

    static let inactiveOpacityRange = 0.2...0.9
    static let fontSizeRange = 9.0...24.0
    static let terminalOpacityRange = 0.3...1.0

    init(command: String = Config.defaultCommand, cwd: String = Config.defaultCwd, hotkey: String = Config.defaultHotkey) {
        self.command = command
        self.cwd = cwd
        self.hotkey = hotkey
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? Self.defaultCommand
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? Self.defaultCwd
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? Self.defaultHotkey
        // Flags: a wrong type falls back to the default instead of failing the whole file.
        statusHooks = (try? c.decodeIfPresent(Bool.self, forKey: .statusHooks)) ?? true
        autoOpenOnInput = (try? c.decodeIfPresent(Bool.self, forKey: .autoOpenOnInput)) ?? false
        autoOpenOnDone = (try? c.decodeIfPresent(Bool.self, forKey: .autoOpenOnDone)) ?? false
        autoOpenFocus = (try? c.decodeIfPresent(Bool.self, forKey: .autoOpenFocus)) ?? true
        showUsage = (try? c.decodeIfPresent(Bool.self, forKey: .showUsage)) ?? true
        hotkeyTarget = (try? c.decodeIfPresent(HotkeyTarget.self, forKey: .hotkeyTarget)) ?? .recent
        foldOnClickOutside = (try? c.decodeIfPresent(Bool.self, forKey: .foldOnClickOutside)) ?? true
        fadeWhenInactive = (try? c.decodeIfPresent(Bool.self, forKey: .fadeWhenInactive)) ?? false
        inactiveOpacity = Self.clamped((try? c.decodeIfPresent(Double.self, forKey: .inactiveOpacity)) ?? 0.5,
                                       to: Self.inactiveOpacityRange)
        hidePill = (try? c.decodeIfPresent(Bool.self, forKey: .hidePill)) ?? false
        terminalFont = (try? c.decodeIfPresent(String.self, forKey: .terminalFont)).flatMap { $0.isEmpty ? nil : $0 }
        terminalFontSize = Self.clamped((try? c.decodeIfPresent(Double.self, forKey: .terminalFontSize)) ?? 13,
                                        to: Self.fontSizeRange).rounded()
        terminalTheme = (try? c.decodeIfPresent(TerminalTheme.self, forKey: .terminalTheme)) ?? .dark
        terminalOpacity = Self.clamped((try? c.decodeIfPresent(Double.self, forKey: .terminalOpacity)) ?? 0.8,
                                       to: Self.terminalOpacityRange)
        cursorStyle = (try? c.decodeIfPresent(CursorShape.self, forKey: .cursorStyle)) ?? .block
        cursorBlink = (try? c.decodeIfPresent(Bool.self, forKey: .cursorBlink)) ?? true
        copyOnSelect = (try? c.decodeIfPresent(Bool.self, forKey: .copyOnSelect)) ?? false
        confirmQuit = (try? c.decodeIfPresent(Bool.self, forKey: .confirmQuit)) ?? true
        actHotkey = (try? c.decodeIfPresent(String.self, forKey: .actHotkey)) ?? ""
        actCleanup = (try? c.decodeIfPresent(ActCleanup.self, forKey: .actCleanup)) ?? .next
        actEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .actEnabled)) ?? !actHotkey.isEmpty
        introShown = (try? c.decodeIfPresent(Bool.self, forKey: .introShown)) ?? false
        // A bad "agents" entry must not discard the rest of the file: drop the whole list.
        do {
            agents = try c.decodeIfPresent([AgentProfile].self, forKey: .agents)?.filter {
                !$0.name.trimmingCharacters(in: .whitespaces).isEmpty
                    && !$0.command.trimmingCharacters(in: .whitespaces).isEmpty
            }
        } catch {
            appLog("config.json \"agents\" is invalid, ignoring it: \(error)")
            agents = nil
        }
    }

    static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Loads config.json (writing defaults if missing), then applies the
    /// POPPY_COMMAND override and the empty-command fallback. `quiet` (the `poppy` shell
    /// command, DESIGN §9.9) only reads: no defaults file, no log lines.
    static func load(quiet: Bool = false) -> Config {
        var config = Config()
        let url = ConfigPaths.config
        if FileManager.default.fileExists(atPath: url.path) {
            // Never overwrite an existing file, even one we can't read or parse.
            do {
                config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
            } catch {
                if !quiet { appLog("config.json could not be read, using defaults: \(error)") }
            }
            if quiet { return config }
        } else if quiet {
            return config
        } else {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try ConfigPaths.write(encoder.encode(config), to: url)
                appLog("wrote default config to \(url.path)")
            } catch {
                appLog("could not write default config: \(error)")
            }
        }

        if let override = ProcessInfo.processInfo.environment["POPPY_COMMAND"], !override.isEmpty {
            config.command = override
        }
        if config.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appLog("command is empty, using \(defaultCommand)")
            config.command = defaultCommand
        }
        return config
    }

    /// Writes only `key` into config.json, keeping every other key and value as the
    /// user wrote them (DESIGN §8.1). Refuses to touch a file that doesn't parse as a
    /// JSON object. Returns false on failure.
    static func saveValue(_ value: Any, forKey key: String) -> Bool {
        let url = ConfigPaths.config
        var object: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                guard let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                    appLog("config.json is not a JSON object; \(key) not saved")
                    return false
                }
                object = parsed
            } catch {
                appLog("config.json could not be read; \(key) not saved: \(error)")
                return false
            }
        }
        object[key] = value
        guard JSONSerialization.isValidJSONObject(object) else {
            appLog("\(key): not a JSON value; not saved")
            return false
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: object,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try ConfigPaths.write(data, to: url)
            appLog("saved \(key) \(value) to \(url.path)")
            return true
        } catch {
            appLog("could not save \(key): \(error)")
            return false
        }
    }

    /// lastPathComponent of the command's first word, e.g. "/usr/local/bin/claude --x" -> "claude".
    var pillTitle: String {
        let first = command.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? command
        return (first as NSString).lastPathComponent
    }

    /// One spelling per directory (e.g. /private/tmp and /tmp, "a/../b"), so the same
    /// folder never counts as a change (DESIGN §9.8).
    static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// `path` with the home directory written as "~" (how Poppy saves `cwd`, DESIGN §9.8).
    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~/" + path.dropFirst(home.count + 1) }
        return path
    }

    /// `cwd` with "~" / "~/" expanded; falls back to home if not an existing directory.
    var resolvedWorkingDirectory: String {
        let home = NSHomeDirectory()
        let path: String
        if cwd == "~" {
            path = home
        } else if cwd.hasPrefix("~/") {
            path = home + "/" + cwd.dropFirst(2)
        } else {
            path = cwd
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            return path
        }
        appLog("cwd \(cwd) is not a directory, using \(home)")
        return home
    }
}

/// "Hotkey opens" (DESIGN §11): the pill used last, the one that needs you most, or the
/// next one in turn.
nonisolated enum HotkeyTarget: String, Codable, Sendable, CaseIterable {
    case recent, urgent, cycle

    var title: String {
        switch self {
        case .recent: "Most recent pill"
        case .urgent: "Most urgent first"
        case .cycle: "Each pill in turn"
        }
    }
}

/// The terminal's colors (DESIGN §9.1): today's dark ones, light ones, or whichever
/// matches the system's appearance.
nonisolated enum TerminalTheme: String, Codable, Sendable, CaseIterable {
    case dark, light, system

    var title: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .system: "Follow system"
        }
    }
}

/// When a finished Act on Selection session (done, never looked at) closes (DESIGN §9.14).
nonisolated enum ActCleanup: String, Codable, Sendable, CaseIterable {
    case next, timer, keep

    static let delay: TimeInterval = 5 * 60

    var title: String {
        switch self {
        case .next: "When the next one starts"
        case .timer: "5 minutes after it's done"
        case .keep: "Never"
        }
    }
}

/// The cursor's shape (DESIGN §9.1); blinking is a separate setting.
nonisolated enum CursorShape: String, Codable, Sendable, CaseIterable {
    case block, bar, underline

    var title: String { rawValue.capitalized }
}

nonisolated struct SavedPoint: Codable, Sendable {
    var x: Double
    var y: Double
}

nonisolated struct SavedSize: Codable, Sendable {
    var width: Double
    var height: Double
}

/// One session of a saved pill (DESIGN §8.2): restarted fresh at launch.
nonisolated struct SavedSession: Codable, Sendable {
    var command: String
    /// `~`-abbreviated, like config.json's `cwd`.
    var cwd: String
    /// Only a name the user chose; default names are worked out again.
    var name: String?
}

/// One pill of the saved layout (DESIGN §8.2).
nonisolated struct SavedPill: Codable, Sendable {
    var origin: SavedPoint?
    var expandedSize: SavedSize?
    var sidebarCollapsed: Bool?
    var sidebarWidth: Double?
    var selected: Int?
    /// Stays open when clicking outside (DESIGN §6.3).
    var pinned: Bool?
    var sessions: [SavedSession]
}

/// App-written panel state (DESIGN §8.2).
nonisolated struct PanelState: Codable, Sendable {
    /// The layout (M25). Without it (an older file) `pillOrigin` and `expandedSize` make
    /// one pill; they're still written, from the first pill.
    var pills: [SavedPill]?
    var pillOrigin: SavedPoint?
    /// Pill diameter preset (DESIGN §7.14); nil means the default.
    var pillDiameter: Double?
    /// Expanded panel size after a user resize (DESIGN §7.13); nil means the default.
    var expandedSize: SavedSize?
    /// Working directories, most recent first (DESIGN §9.8); absolute paths.
    var recentDirectories: [String]?

    static func load() -> PanelState {
        guard let data = try? Data(contentsOf: ConfigPaths.state) else { return PanelState() }
        do {
            return try JSONDecoder().decode(PanelState.self, from: data)
        } catch {
            appLog("state.json is invalid, ignoring: \(error)")
            return PanelState()
        }
    }

    func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try ConfigPaths.write(encoder.encode(self), to: ConfigPaths.state)
        } catch {
            appLog("could not save state: \(error)")
        }
    }
}
