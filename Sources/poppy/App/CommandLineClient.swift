import Foundation

/// `poppy [options] [directory]`: the shell command (DESIGN §9.9). Runs instead of the app
/// when the binary is started with `--cli` (the shell function passes it). It parses the
/// flags, writes a `LaunchRequest` file and hands it to the bundled app with
/// `open -g -a`, which launches Poppy if needed without bringing it forward.
nonisolated enum CommandLineClient {
    static let flag = "--cli"

    static let usage = """
    Usage: poppy [options] [directory]

    Opens Poppy on a session in <directory> (default: the current directory): the
    one already there if there is one (never restarting it), else a new session in
    the most recent pill. Options are saved, like changing them in Poppy's menu.

      -a, --agent NAME        claude, codex, agy, opencode, or an agent name from config.json
      -c, --command CMD       run CMD (any shell command) as the agent
                              (with -a or -c, only a session running that agent is reused)
          --new               always a new session, in the most recent pill
          --new-pill          always a new pill
          --pill SIZE         small, medium or large
          --auto-open WHEN    input, done, both or off
          --focus             Auto-Open takes the keyboard
          --no-focus          Auto-Open only shows the panel
          --usage             show usage
          --no-usage          hide usage
      -b, --background        don't expand the panel
      -h, --help              show this help

    """

    /// Exit status for the process.
    static func run(_ arguments: [String]) -> Int32 {
        let request: LaunchRequest
        switch parse(arguments) {
        case .help:
            print(usage, terminator: "")
            return 0
        case .failure(let message):
            fail(message + "\nRun 'poppy --help' for usage.")
            return 2
        case .request(let parsed):
            request = parsed
        }

        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else {
            fail("the poppy command needs the bundled app (./scripts/bundle.sh), not \(bundle.path)")
            return 1
        }
        let file = LaunchRequest.directoryURL
            .appendingPathComponent(LaunchRequest.filePrefix + UUID().uuidString)
            .appendingPathExtension(LaunchRequest.fileExtension)
        do {
            try FileManager.default.createDirectory(at: LaunchRequest.directoryURL, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(request)
            guard FileManager.default.createFile(atPath: file.path, contents: data,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            fail("could not write \(file.path): \(error.localizedDescription)")
            return 1
        }

        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-a", bundle.path, file.path]
        do {
            try open.run()
            open.waitUntilExit()
        } catch {
            try? FileManager.default.removeItem(at: file)
            fail("could not open Poppy: \(error.localizedDescription)")
            return 1
        }
        guard open.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: file)
            return open.terminationStatus
        }
        // Poppy deletes the file when it reads it. If it hasn't in time, withdraw the request
        // (so it can't take effect later, after the user has moved on) and say so.
        let deadline = Date().addingTimeInterval(pickupTimeout)
        while FileManager.default.fileExists(atPath: file.path), Date() < deadline { usleep(100_000) }
        if FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.removeItem(at: file)
            fail("Poppy didn't pick up the request within \(Int(pickupTimeout)) s; nothing was changed. Try again.")
            return 1
        }
        return 0
    }

    static let pickupTimeout: TimeInterval = 5

    enum Parsed {
        case request(LaunchRequest)
        case help
        case failure(String)
    }

    static func parse(_ arguments: [String]) -> Parsed {
        var request = LaunchRequest()
        var directory: String?
        var index = 0
        func value(for option: String) -> String? {
            index += 1
            return index < arguments.count ? arguments[index] : nil
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help":
                return .help
            case "-a", "--agent":
                guard let name = value(for: argument) else { return .failure("\(argument) needs an agent name") }
                guard let command = agentCommand(named: name) else {
                    let names = agentNames().joined(separator: ", ")
                    return .failure("unknown agent '\(name)' (known: \(names)); use -c for any command")
                }
                request.command = command
            case "-c", "--command":
                guard let command = value(for: argument),
                      !command.trimmingCharacters(in: .whitespaces).isEmpty else {
                    return .failure("\(argument) needs a command")
                }
                request.command = command
            case "--pill":
                guard let size = value(for: argument)?.lowercased(),
                      let preset = PanelSizes.pillPresets.first(where: { $0.name.lowercased() == size }) else {
                    return .failure("--pill needs small, medium or large")
                }
                request.pillDiameter = Double(preset.diameter)
            case "--auto-open":
                switch value(for: argument)?.lowercased() {
                case "input": (request.autoOpenOnInput, request.autoOpenOnDone) = (true, false)
                case "done": (request.autoOpenOnInput, request.autoOpenOnDone) = (false, true)
                case "both": (request.autoOpenOnInput, request.autoOpenOnDone) = (true, true)
                case "off": (request.autoOpenOnInput, request.autoOpenOnDone) = (false, false)
                default: return .failure("--auto-open needs input, done, both or off")
                }
            case "--focus": request.autoOpenFocus = true
            case "--no-focus": request.autoOpenFocus = false
            case "--usage": request.showUsage = true
            case "--no-usage": request.showUsage = false
            case "-b", "--background": request.show = false
            case "--new": request.new = true
            case "--new-pill": request.newPill = true
            default:
                if argument.hasPrefix("-"), argument != "-" {
                    return .failure("unknown option '\(argument)'")
                }
                guard directory == nil else { return .failure("only one directory can be given") }
                directory = argument
            }
            index += 1
        }

        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let path = Config.normalize(URL(fileURLWithPath: directory ?? ".", relativeTo: base).path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return .failure("'\(directory ?? path)' is not a directory")
        }
        request.directory = path
        return .request(request)
    }

    /// Built-in agents by name or command word, then config.json's agents by name.
    private static func agentCommand(named name: String) -> String? {
        let wanted = name.lowercased()
        let profiles = AgentCatalog.builtIns + (Config.load(quiet: true).agents ?? [])
        return profiles.first { profile in
            profile.name.lowercased() == wanted || profile.command.lowercased() == wanted
        }?.command
    }

    private static func agentNames() -> [String] {
        AgentCatalog.builtIns.map(\.command) + (Config.load(quiet: true).agents ?? []).map(\.name)
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data("poppy: \(message)\n".utf8))
    }

    // MARK: Installing the command

    /// Where install.sh and the intro's Install button put the command.
    static var installDirectory: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin") }

    /// The wrapper scripts/install.sh writes: `app`'s binary in client mode.
    static func wrapper(app: String, executable: String) -> String {
        let quoted = app.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$").replacingOccurrences(of: "`", with: "\\`")
        return """
        #!/bin/sh
        # Installed by Poppy. Set POPPY_APP to use a Poppy.app elsewhere.
        exec "${POPPY_APP:-\(quoted)}/Contents/MacOS/\(executable)" \(flag) "$@"

        """
    }

    /// The intro's Install button (DESIGN §9.15), for a Poppy that didn't come from
    /// install.sh: the same wrapper, for this app, mode 755. Never replaces an existing file.
    static func installWrapper(in directory: URL = installDirectory, app: String = Bundle.main.bundlePath,
                               executable: String = Bundle.main.executableURL?.lastPathComponent ?? "poppy") throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("poppy")
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
        }
        try wrapper(app: app, executable: executable).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
