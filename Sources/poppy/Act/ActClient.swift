import Foundation

/// What `poppy-act` asks the app to do on a capture (DESIGN §9.14), and the app's answer.
nonisolated struct ActRequest: Codable, Sendable {
    var capture: String
    var actions: [ActPlan.Action]

    nonisolated struct Reply: Codable, Sendable {
        var ok: Bool
        var message: String
    }

    static let filePrefix = "act-"
    static let replySuffix = ".reply"

    /// A request file `poppy-act` wrote, in the same private folder as the `poppy` command's.
    static func isRequestFile(_ url: URL) -> Bool {
        url.isFileURL
            && url.deletingLastPathComponent().resolvingSymlinksInPath().path
                == LaunchRequest.directoryURL.resolvingSymlinksInPath().path
            && url.lastPathComponent.hasPrefix(filePrefix)
            && url.pathExtension == LaunchRequest.fileExtension
    }

    static func replyURL(for request: URL) -> URL {
        request.appendingPathExtension(String(replySuffix.dropFirst()))
    }
}

/// `poppy-act <capture> press <id>…` / `poppy-act <capture> text <id> [text…]` (DESIGN
/// §9.14): what an Act on Selection session runs to act in the captured app. Poppy's own
/// binary started with `--act` (through the `poppy-act` script Poppy writes); it hands the
/// app a request file like the `poppy` command (§9.9) and prints the app's answer.
nonisolated enum ActClient {
    static let flag = "--act"
    static let replyTimeout: TimeInterval = 30

    static let usage = """
    Usage: poppy-act <capture> press <id>...
           poppy-act <capture> text <id> [text]   (without text, it's read from stdin)

    """

    static func run(_ arguments: [String]) -> Int32 {
        guard arguments.count >= 3 else { return fail(usage) }
        let capture = arguments[0]
        let op = arguments[1]
        let ids = Array(arguments.dropFirst(2))
        var actions: [ActPlan.Action]
        switch op {
        case "press":
            actions = ids.map { ActPlan.Action(op: "press", id: $0, text: "") }
        case "text":
            var text = ids.dropFirst().joined(separator: " ")
            if ids.count == 1 {
                text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                if text.hasSuffix("\n") { text.removeLast() }  // a heredoc's last newline
            }
            actions = [ActPlan.Action(op: "enterText", id: ids[0], text: text)]
        default:
            return fail(usage)
        }

        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return fail("poppy-act needs the bundled app") }
        let file = LaunchRequest.directoryURL
            .appendingPathComponent(ActRequest.filePrefix + UUID().uuidString)
            .appendingPathExtension(LaunchRequest.fileExtension)
        let reply = ActRequest.replyURL(for: file)
        do {
            let data = try JSONEncoder().encode(ActRequest(capture: capture, actions: actions))
            guard FileManager.default.createFile(atPath: file.path, contents: data,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            return fail("could not write \(file.path): \(error.localizedDescription)")
        }

        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-a", bundle.path, file.path]
        do {
            try open.run()
            open.waitUntilExit()
        } catch {
            try? FileManager.default.removeItem(at: file)
            return fail("could not reach Poppy: \(error.localizedDescription)")
        }

        let deadline = Date().addingTimeInterval(replyTimeout)
        while !FileManager.default.fileExists(atPath: reply.path), Date() < deadline { usleep(100_000) }
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: reply)
        }
        guard let data = try? Data(contentsOf: reply),
              let answer = try? JSONDecoder().decode(ActRequest.Reply.self, from: data) else {
            return fail("Poppy didn't answer within \(Int(replyTimeout)) s; nothing may have been done.")
        }
        if answer.ok {
            print(answer.message)
            return 0
        }
        return fail(answer.message)
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("poppy-act: \(message)\n".utf8))
        return 1
    }
}
