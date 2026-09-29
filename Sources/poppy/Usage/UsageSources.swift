import Foundation

/// One rate-limit window (DESIGN §9.7).
nonisolated struct UsageWindow: Sendable, Equatable {
    /// 0–100.
    var usedPercent: Double
    var resetsAt: Date?
    /// The window's length, if the source says.
    var minutes: Int?

    init(usedPercent: Double, resetsAt: Date?, minutes: Int?) {
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.resetsAt = resetsAt
        self.minutes = minutes
    }

    var leftPercent: Double { 100 - usedPercent }

    /// "5h", "7d", …; `fallback` when the length isn't known.
    func label(fallback: String) -> String {
        guard let minutes, minutes > 0 else { return fallback }
        if minutes % 1440 == 0 { return "\(minutes / 1440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }
}

/// The running agent's short (5-hour) and long (weekly) windows (DESIGN §9.7).
nonisolated struct UsageReport: Sendable, Equatable {
    var short: UsageWindow?
    var long: UsageWindow?
    var fetchedAt: Date

    static let maxAge: TimeInterval = 15 * 60

    /// Due for a new fetch: too old, or a window has reset since.
    func isStale(at now: Date = Date()) -> Bool {
        if now.timeIntervalSince(fetchedAt) > Self.maxAge { return true }
        return [short, long].contains { window in window?.resetsAt.map { $0 <= now } ?? false }
    }

    /// What may be shown now: windows that have reset are dropped (their numbers no longer
    /// apply) and the rest kept; nil when too old or nothing is left.
    func current(at now: Date = Date()) -> UsageReport? {
        guard now.timeIntervalSince(fetchedAt) <= Self.maxAge else { return nil }
        let live = { (window: UsageWindow?) in window.flatMap { w in w.resetsAt.map { $0 > now } ?? true ? w : nil } }
        let report = UsageReport(short: live(short), long: live(long), fetchedAt: fetchedAt)
        return report.short == nil && report.long == nil ? nil : report
    }

    var summary: String {
        [("5h", short), ("7d", long)].compactMap { fallback, window in
            window.map { "\($0.label(fallback: fallback)) \(Int($0.usedPercent.rounded()))%" }
        }.joined(separator: " ")
    }
}

nonisolated enum UsageError: Error, CustomStringConvertible {
    case rateLimited
    /// The Keychain read was refused, cancelled or timed out; not retried automatically,
    /// so the access prompt doesn't keep coming back.
    case keychainDenied
    case failed(String)

    var description: String {
        switch self {
        case .rateLimited: "rate limited"
        case .keychainDenied: "Keychain access to Claude Code's login was not allowed (turn Show Usage off and on to retry)"
        case .failed(let reason): reason
        }
    }
}

// MARK: - Claude: the OAuth usage endpoint

/// The same numbers Claude Code's `/usage` shows, from the endpoint it calls, with the
/// token it keeps in the Keychain (DESIGN §9.7). Undocumented: every field is optional.
nonisolated enum ClaudeUsage {
    static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let userAgent = "claude-code/2.1.0"

    /// `@concurrent`: the token read blocks (the `security` subprocess), so never on the main actor.
    @concurrent static func fetch() async throws -> UsageReport {
        let token = try accessToken()
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageError.failed(error.localizedDescription)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 429 { throw UsageError.rateLimited }
        guard code == 200 else { throw UsageError.failed("HTTP \(code)") }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.failed("unexpected response")
        }
        let report = UsageReport(short: window(root["five_hour"], minutes: 300),
                                 long: window(root["seven_day"], minutes: 10080),
                                 fetchedAt: Date())
        guard report.short != nil || report.long != nil else { throw UsageError.failed("no usage in response") }
        return report
    }

    private static func window(_ value: Any?, minutes: Int) -> UsageWindow? {
        guard let object = value as? [String: Any],
              let used = (object["utilization"] as? NSNumber)?.doubleValue else { return nil }
        return UsageWindow(usedPercent: used, resetsAt: (object["resets_at"] as? String).flatMap(parseDate),
                           minutes: minutes)
    }

    /// ISO 8601, with or without fractional seconds (the endpoint sends microseconds).
    static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    /// Read on every fetch (Claude rotates it); never stored or logged.
    private static func accessToken() throws -> String {
        var text = try keychainCredentials()
        if text == nil {
            let file = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/.credentials.json")
            text = try? String(contentsOf: file, encoding: .utf8)
        }
        guard let text, let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.failed("not signed in to Claude Code")
        }
        let oauth = root["claudeAiOauth"] as? [String: Any] ?? root
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw UsageError.failed("not signed in to Claude Code")
        }
        // Claude refreshes an expired token the next time it runs.
        if let expires = (oauth["expiresAt"] as? NSNumber)?.doubleValue,
           Date(timeIntervalSince1970: expires / 1000) < Date() {
            throw UsageError.failed("Claude Code's login token has expired")
        }
        return token
    }

    /// The Keychain item Claude Code maintains, via `security` (DESIGN §9.7). Nil if
    /// there's no such item; throws `keychainDenied` if reading it was refused, cancelled
    /// or timed out (60 s, time to answer the access prompt).
    private static func keychainCredentials() throws -> String? {
        let spec = LaunchSpec(executable: "/usr/bin/security",
                              args: ["find-generic-password", "-s", "Claude Code-credentials", "-w"],
                              environment: [], currentDirectory: NSHomeDirectory())
        guard let result = ChildProcess.run(spec, label: "keychain read", timeout: 60), result.exitedNormally else {
            throw UsageError.keychainDenied
        }
        let code = result.status.map { ($0 >> 8) & 0xff } ?? -1
        if code == 44 { return nil }  // errSecItemNotFound: not signed in (or a file login)
        guard code == 0 else { throw UsageError.keychainDenied }
        let text = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

// MARK: - Codex: app-server's rate-limit RPC

/// Asks a short-lived `codex app-server` for its rate limits over JSON-RPC on stdio
/// (DESIGN §9.7). Codex handles its own login; an API-key login has no limits to report.
nonisolated enum CodexUsage {
    static let timeout: TimeInterval = 10

    static func fetch(command: String) throws -> UsageReport {
        let messages: [[String: Any]] = [
            ["method": "initialize", "id": 0,
             "params": ["clientInfo": ["name": "poppy", "title": "Poppy", "version": "1.0"]]],
            ["method": "initialized", "params": NSNull()],
            ["method": "account/rateLimits/read", "id": 1, "params": NSNull()],
        ]
        var input = Data()
        for message in messages {
            input.append(try JSONSerialization.data(withJSONObject: message))
            input.append(0x0A)
        }
        let spec = ShellEnvironment.probeSpec(script: StatusHooks.executablePrefix(command) + " app-server")
        guard let result = ChildProcess.run(spec, label: "codex app-server", input: input, timeout: timeout,
                                            until: { response(in: $0) != nil }),
              let response = response(in: result.output) else {
            throw UsageError.failed("no answer from codex app-server")
        }
        if let error = response["error"] as? [String: Any] {
            throw UsageError.failed(error["message"] as? String ?? "codex app-server error")
        }
        guard let limits = (response["result"] as? [String: Any])?["rateLimits"] as? [String: Any] else {
            throw UsageError.failed("no rate limits in response")
        }
        let report = UsageReport(short: window(limits["primary"]), long: window(limits["secondary"]),
                                 fetchedAt: Date())
        guard report.short != nil || report.long != nil else { throw UsageError.failed("no rate limits in response") }
        return report
    }

    /// The first complete stdout line that is the JSON-RPC response with id 1.
    private static func response(in output: Data) -> [String: Any]? {
        for line in output.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  (object["id"] as? NSNumber)?.intValue == 1 else { continue }
            return object
        }
        return nil
    }

    private static func window(_ value: Any?) -> UsageWindow? {
        guard let object = value as? [String: Any],
              let used = (object["usedPercent"] as? NSNumber)?.doubleValue else { return nil }
        let resets = (object["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return UsageWindow(usedPercent: used, resetsAt: resets,
                           minutes: (object["windowDurationMins"] as? NSNumber)?.intValue)
    }
}
