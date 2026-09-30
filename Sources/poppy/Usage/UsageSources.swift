import Foundation

/// One rate-limit window (DESIGN §9.7).
nonisolated struct UsageWindow: Sendable, Equatable {
    /// 0–100.
    var usedPercent: Double
    var resetsAt: Date?
    /// The window's length, if the source says.
    var minutes: Int?
    /// A display name replacing the length label, e.g. Antigravity's "Gemini" (DESIGN §9.12).
    var name: String?
    /// Lowercased text the model in use is matched against (Antigravity's group name and
    /// description); nil for sources whose windows aren't per model.
    var matchText: String?

    init(usedPercent: Double, resetsAt: Date?, minutes: Int?, name: String? = nil, matchText: String? = nil) {
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.resetsAt = resetsAt
        self.minutes = minutes
        self.name = name
        self.matchText = matchText
    }

    var leftPercent: Double { 100 - usedPercent }

    /// The name if set, else "5h", "7d", …; `fallback` when the length isn't known.
    func label(fallback: String) -> String {
        if let name { return name }
        guard let minutes, minutes > 0 else { return fallback }
        if minutes % 1440 == 0 { return "\(minutes / 1440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }
}

/// The running agent's short (5-hour) and long (weekly) windows (DESIGN §9.7). For
/// Antigravity, its two model groups' weekly windows in fetched order (DESIGN §9.12).
nonisolated struct UsageReport: Sendable, Equatable {
    var short: UsageWindow?
    var long: UsageWindow?
    var fetchedAt: Date
    /// The pill ring's window, chosen by the monitor when publishing.
    var ring: UsageWindow?

    init(short: UsageWindow?, long: UsageWindow?, fetchedAt: Date) {
        self.short = short
        self.long = long
        self.fetchedAt = fetchedAt
    }

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

    /// The ring's window: `short`, except for per-model windows (Antigravity), where it's
    /// the one group matching the model in use, else the one closest to running out.
    func ringWindow(forModel model: String?) -> UsageWindow? {
        let present = [short, long].compactMap { $0 }
        guard present.contains(where: { $0.matchText != nil }) else { return short }
        if let model {
            let family = model.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first.map(String.init) ?? ""
            let matching = present.filter { window in
                window.matchText?.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0 == family } ?? false
            }
            if matching.count == 1 { return matching[0] }
        }
        return present.reduce(nil) { best, window in
            guard let best else { return window }
            return window.usedPercent > best.usedPercent ? window : best
        }
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
    /// `agy` has no login in the Keychain; checked without running it (DESIGN §9.12).
    case signedOut
    /// `agy -p /usage` gave no answer (e.g. an expired login waiting on a browser sign-in);
    /// not retried automatically, so a sign-in page doesn't keep opening.
    case noAnswer
    case failed(String)

    var description: String {
        switch self {
        case .rateLimited: "rate limited"
        case .keychainDenied: "Keychain access to Claude Code's login was not allowed (turn Show Usage off and on to retry)"
        case .signedOut: "Antigravity isn't signed in (sign in to agy; usage updates within a minute)"
        case .noAnswer: "no answer from agy (turn Show Usage off and on to retry)"
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

// MARK: - Antigravity: `agy -p /usage`

/// Antigravity's weekly per-model-group limits, from `agy`'s own `/usage` command in print
/// mode, which makes no model call (DESIGN §9.12). Never runs `agy` when it isn't signed
/// in: a signed-out `agy -p` opens the Google sign-in page in the browser.
nonisolated enum AntigravityUsage {
    static let timeout: TimeInterval = 25

    static func fetch(command: String) throws -> UsageReport {
        try requireSignIn()
        let script = StatusHooks.executablePrefix(command) + " -p /usage --output-format json --print-timeout 20s"
        guard let result = ChildProcess.run(ShellEnvironment.probeSpec(script: script), label: "agy usage",
                                            timeout: timeout, until: { response(in: $0) != nil }),
              let response = response(in: result.output) else {
            throw UsageError.noAnswer
        }
        guard response["status"] as? String == "SUCCESS" else {
            let text = (response["response"] as? String ?? "").split(separator: "\n").first
                .map { String($0.trimmingCharacters(in: .whitespaces).prefix(120)) } ?? ""
            throw UsageError.failed(text.isEmpty ? "agy: \(response["status"] as? String ?? "failed")" : text)
        }
        let data = (response["command"] as? [String: Any])?["data"] as? [String: Any]
        let windows = (data?["groups"] as? [Any] ?? []).compactMap(window)
        guard let first = windows.first else { throw UsageError.failed("no usage in response") }
        return UsageReport(short: first, long: windows.dropFirst().first, fetchedAt: Date())
    }

    /// `agy` keeps its login in the Keychain (service "gemini", account "antigravity").
    /// Without -w only the attributes are read, so there's no access prompt.
    private static func requireSignIn() throws {
        let spec = LaunchSpec(executable: "/usr/bin/security",
                              args: ["find-generic-password", "-s", "gemini", "-a", "antigravity"],
                              environment: [], currentDirectory: NSHomeDirectory())
        guard let result = ChildProcess.run(spec, label: "agy login check", timeout: 5),
              result.exitedNormally, result.status.map({ ($0 >> 8) & 0xff }) == 0 else {
            throw UsageError.signedOut
        }
    }

    /// The first stdout line that is `agy`'s JSON answer (dotfiles may print other lines first).
    private static func response(in output: Data) -> [String: Any]? {
        for line in output.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  (object["command"] as? [String: Any])?["name"] as? String == "usage" else { continue }
            return object
        }
        return nil
    }

    /// A group's most-used bucket; nil without a name or a bucket with a remaining fraction.
    private static func window(_ value: Any) -> UsageWindow? {
        guard let group = value as? [String: Any], let name = group["name"] as? String else { return nil }
        let buckets = (group["buckets"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        let tightest = buckets
            .compactMap { bucket in (bucket["remaining_fraction"] as? NSNumber).map { (bucket, $0.doubleValue) } }
            .min { $0.1 < $1.1 }
        guard let (bucket, remaining) = tightest else { return nil }
        let minutes: Int? = switch bucket["window"] as? String {
        case "weekly": 10080
        case "daily": 1440
        default: nil
        }
        let description = group["description"] as? String ?? ""
        return UsageWindow(usedPercent: (1 - remaining) * 100, resetsAt: date(bucket["reset_time"]),
                           minutes: minutes, name: shortName(name),
                           matchText: (name + " " + description).lowercased())
    }

    /// "Gemini Models" -> "Gemini", "Claude and GPT models" -> "Claude/GPT".
    static func shortName(_ name: String) -> String {
        var short = name
        if short.lowercased().hasSuffix(" models") { short = String(short.dropLast(" models".count)) }
        return short.replacingOccurrences(of: " and ", with: "/")
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}
