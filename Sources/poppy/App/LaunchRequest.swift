import Foundation

/// Changes asked for by the `poppy` shell command (DESIGN §9.9), or by a folder handed to
/// Poppy. Nil fields are left as they are; the rest are applied and saved like the
/// matching menu items.
nonisolated struct LaunchRequest: Codable, Sendable, Equatable {
    var directory: String?
    var command: String?
    var pillDiameter: Double?
    var autoOpenOnInput: Bool?
    var autoOpenOnDone: Bool?
    var autoOpenFocus: Bool?
    var showUsage: Bool?
    /// Expand (and focus) the panel afterward.
    var show = true

    /// Request files live next to the status files; only this user can write there.
    static let directoryURL = ConfigPaths.directory.appendingPathComponent("run")
    static let filePrefix = "request-"
    static let fileExtension = "json"
    static let maxFileAge: TimeInterval = 5 * 60

    /// True for a file the client wrote (checked before reading it). Symlinks are resolved
    /// on both sides (e.g. a dotfile manager's symlinked ~/.config).
    static func isRequestFile(_ url: URL) -> Bool {
        url.isFileURL
            && url.deletingLastPathComponent().resolvingSymlinksInPath().path
                == directoryURL.resolvingSymlinksInPath().path
            && url.lastPathComponent.hasPrefix(filePrefix)
            && url.pathExtension == fileExtension
    }

    /// Reads and deletes a request file; nil (logged) if it can't be read.
    static func consume(_ url: URL) -> LaunchRequest? {
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            return try JSONDecoder().decode(LaunchRequest.self, from: Data(contentsOf: url))
        } catch {
            appLog("request \(url.lastPathComponent) is invalid: \(error)")
            return nil
        }
    }

    /// Deletes request files left behind (e.g. Poppy failed to launch).
    static func removeStaleFiles() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where isRequestFile(file) {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if Date().timeIntervalSince(date ?? .distantPast) > maxFileAge {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
