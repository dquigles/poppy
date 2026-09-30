import Foundation

/// `poppy [options] [directory]`: the shell command (DESIGN §9.9). Runs instead of the app
/// when the binary is started with `--cli` (the shell function passes it). It parses the
/// flags, writes a `LaunchRequest` file and hands it to the bundled app with
/// `open -g -a`, which launches Poppy if needed without bringing it forward.
nonisolated enum CommandLineClient {
    static let flag = "--cli"

    static let usage = """
    Usage: poppy [options] [directory]

    Opens Poppy with the agent in <directory> (default: the current directory).
    Options are saved, like changing them in Poppy's menu.

      -a, --agent NAME        claude, codex, agy, opencode, or an agent name from config.json
      -c, --command CMD       run CMD (any shell command) as the agent
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
}
