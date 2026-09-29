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
    }

    /// Loads config.json (writing defaults if missing), then applies the
    /// POPPY_COMMAND override and the empty-command fallback.
    static func load() -> Config {
        var config = Config()
        let url = ConfigPaths.config
        if FileManager.default.fileExists(atPath: url.path) {
            // Never overwrite an existing file, even one we can't read or parse.
            do {
                config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
            } catch {
                appLog("config.json could not be read, using defaults: \(error)")
            }
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

    /// Writes only the "hotkey" key into config.json, keeping every other key and
    /// value as the user wrote them (DESIGN §8.1). Refuses to touch a file that
    /// doesn't parse as a JSON object. Returns false on failure.
    static func saveHotkey(_ spec: String) -> Bool {
        let url = ConfigPaths.config
        var object: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                guard let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                    appLog("config.json is not a JSON object; hotkey not saved")
                    return false
                }
                object = parsed
            } catch {
                appLog("config.json could not be read; hotkey not saved: \(error)")
                return false
            }
        }
        object["hotkey"] = spec
        do {
            let data = try JSONSerialization.data(withJSONObject: object,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try ConfigPaths.write(data, to: url)
            appLog("saved hotkey \(spec) to \(url.path)")
            return true
        } catch {
            appLog("could not save hotkey: \(error)")
            return false
        }
    }

    /// lastPathComponent of the command's first word, e.g. "/usr/local/bin/claude --x" -> "claude".
    var pillTitle: String {
        let first = command.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? command
        return (first as NSString).lastPathComponent
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

/// App-written panel state (DESIGN §8.2).
nonisolated struct PanelState: Codable, Sendable {
    var pillOrigin: SavedPoint?

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
