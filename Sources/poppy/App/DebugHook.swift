import Foundation

/// Poppy Dev only (DESIGN §12.2): lets `scripts/test-sessions.py` drive sessions without
/// the mouse. It reads `debug-cmd-<id>.json` files from Poppy Dev's own `run/` folder
/// (only this user can write there, like the `poppy` command's requests), runs each through
/// the same code as the UI, and answers with `debug-state-<id>.json`: the panel's and every
/// session's state. The installed Poppy never starts it.
final class DebugHook {
    nonisolated struct Command: Decodable, Sendable {
        var id: String
        var op: String
        var index: Int?
        var command: String?
        var directory: String?
        var name: String?
        var key: String?
        var value: Bool?
        var width: Double?
        /// The pill an op acts on (default: the most recent), DESIGN §12.2.
        var pill: Int?
        var new: Bool?
        var newPill: Bool?
        /// A drop's target pill, and a new pill's point (M26).
        var target: Int?
        var x: Double?
        var y: Double?
    }

    static let commandPrefix = "debug-cmd-"
    static let statePrefix = "debug-state-"
    private weak var manager: PillManager?
    /// Act on Selection's `actCapture` / `actRun` (DESIGN §9.14).
    private weak var act: ActController?
    private var timer: Timer?

    init(manager: PillManager, act: ActController) {
        self.manager = manager
        self.act = act
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        appLog("debug hook: watching \(LaunchRequest.directoryURL.path)/\(Self.commandPrefix)*.json")
    }

    isolated deinit {
        timer?.invalidate()
    }

    private func poll() {
        let directory = LaunchRequest.directoryURL
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names.sorted() where name.hasPrefix(Self.commandPrefix) && name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            defer { try? FileManager.default.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url),
                  let command = try? JSONDecoder().decode(Command.self, from: data) else {
                appLog("debug hook: \(name) is invalid")
                continue
            }
            if command.op != "state" { appLog("debug hook: \(command.op)\(command.index.map { " \($0)" } ?? "")") }
            let error = command.op.hasPrefix("act") ? act?.debugRun(command) : manager?.debugRun(command)
            answer(command, error: error)
        }
    }

    private func answer(_ command: Command, error: String?) {
        let id = command.id
        var state = manager?.debugState(for: command) ?? [:]
        state.merge(act?.debugState() ?? [:]) { $1 }
        state["id"] = id
        if let error { state["error"] = error }
        let url = LaunchRequest.directoryURL.appendingPathComponent("\(Self.statePrefix)\(id).json")
        do {
            let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            appLog("debug hook: could not write \(url.lastPathComponent): \(error)")
        }
    }
}
