import Foundation

/// Writes a line to stderr so it shows up in the `swift run` terminal.
nonisolated func appLog(_ message: String) {
    FileHandle.standardError.write(Data(("[Poppy] " + message + "\n").utf8))
}
