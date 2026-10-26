import Foundation

/// A fresh folder under the system temp directory, removed by the caller.
func temporaryFolder() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("poppy-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Runs `script` with /bin/sh, `stdin` on its input and `environment` added; returns its exit status.
@discardableResult
func runShell(_ script: String, stdin: String = "", environment: [String: String] = [:]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    var env = ProcessInfo.processInfo.environment
    env["POPPY_STATUS_FILE"] = nil
    env.merge(environment) { $1 }
    process.environment = env
    let input = Pipe()
    process.standardInput = input
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try! process.run()
    input.fileHandleForWriting.write(Data(stdin.utf8))
    try? input.fileHandleForWriting.close()
    process.waitUntilExit()
    return process.terminationStatus
}

func read(_ url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
}

func json(_ text: String) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
}
