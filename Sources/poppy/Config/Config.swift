import Foundation

/// Files live in ~/.config/poppy/ (DESIGN §8).
nonisolated enum ConfigPaths {
    static let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/poppy")
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
    static let defaultHotkey = "ctrl+opt+space"

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

    /// Saves "hotkey" (DESIGN §8.1).
    static func saveHotkey(_ spec: String) -> Bool {
        saveValue(spec, forKey: "hotkey")
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

nonisolated struct SavedPoint: Codable, Sendable {
    var x: Double
    var y: Double
}

nonisolated struct SavedSize: Codable, Sendable {
    var width: Double
    var height: Double
}

/// App-written panel state (DESIGN §8.2).
nonisolated struct PanelState: Codable, Sendable {
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
