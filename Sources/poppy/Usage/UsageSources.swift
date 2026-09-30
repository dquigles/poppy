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
    /// Nothing to show for this login (e.g. Claude with an API key); retried rarely.
    case unavailable(String)
    /// `agy` has no login in the Keychain; checked without running it (DESIGN §9.12).
    case signedOut
    /// `agy -p /usage` gave no answer (e.g. an expired login waiting on a browser sign-in);
    /// not retried automatically, so a sign-in page doesn't keep opening.
    case noAnswer
    case failed(String)

    var description: String {
        switch self {
        case .unavailable(let reason): reason
        case .signedOut: "Antigravity isn't signed in (sign in to agy; usage updates within a minute)"
        case .noAnswer: "no answer from agy (turn Show Usage off and on to retry)"
        case .failed(let reason): reason
        }
    }
}

// MARK: - Claude: `claude -p /usage`

/// The limits Claude Code's own `/usage` shows, from print mode: no model call, not saved as
/// a session, run from a temp folder with user settings skipped so the user's own hooks
/// don't fire (DESIGN §9.13). The numbers are display text, so a wording change in a Claude
/// Code update shows as a failure, never as wrong numbers.
nonisolated enum ClaudeUsage {
    static let timeout: TimeInterval = 20

    static func fetch(command: String) throws -> UsageReport {
        let folder = FileManager.default.temporaryDirectory.path
        // cd first: the login shell's dotfiles may change folder, and a folder's .claude/
        // settings (or ~/.claude/settings.json, from home) would bring its hooks back.
        let script = "cd '" + folder.replacingOccurrences(of: "'", with: "'\\''") + "' && "
            + StatusHooks.executablePrefix(command)
            + " -p /usage --output-format json --no-session-persistence --setting-sources project"
        var spec = ShellEnvironment.probeSpec(script: script)
        spec.currentDirectory = folder
        guard let run = ChildProcess.run(spec, label: "claude usage", timeout: timeout,
                                         until: { result(in: $0) != nil }),
              let object = result(in: run.output) else {
            throw UsageError.failed("no answer from claude")
        }
        let text = object["result"] as? String ?? ""
        if object["is_error"] as? Bool == true {
            throw UsageError.failed(firstLine(text) ?? "claude /usage failed")
        }
        var short: UsageWindow?
        var long: UsageWindow?
        for line in text.split(separator: "\n") {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard let match = linePattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let title = Range(match.range(at: 1), in: line).map({ String(line[$0]) }),
                  let used = Range(match.range(at: 2), in: line).flatMap({ Double(line[$0]) }) else { continue }
            let resets = Range(match.range(at: 3), in: line).flatMap { resetDate(String(line[$0])) }
            if title == "Current session" {
                short = UsageWindow(usedPercent: used, resetsAt: resets, minutes: 300)
            } else {
                long = UsageWindow(usedPercent: used, resetsAt: resets, minutes: 10080)
            }
        }
        guard short != nil || long != nil else {
            // Claude Code prints this header only for a subscription login (read from its code);
            // with it, the limit lines' wording changed. Without it (API key, signed out, a
            // gateway) /usage shows only costs.
            if text.hasPrefix("You are currently using your") {
                throw UsageError.failed("couldn't read Claude's /usage (Claude Code may have changed its wording)")
            }
            throw UsageError.unavailable("no subscription limits reported (not signed in, or an API-key login)")
        }
        return UsageReport(short: short, long: long, fetchedAt: Date())
    }

    /// "Current session: 72% used · resets Sep 30 at 2:59pm (America/Chicago)" (U+00B7).
    private static let linePattern = try! NSRegularExpression(
        pattern: "^(Current session|Current week \\(all models\\)): (\\d+)% used(?: \u{00B7} resets (.+))?$")

    /// The first stdout line that is the print-mode result (dotfiles may print other lines first).
    private static func result(in output: Data) -> [String: Any]? {
        for line in output.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "result" else { continue }
            return object
        }
        return nil
    }

    private static func firstLine(_ text: String) -> String? {
        let line = text.split(separator: "\n").first.map { String($0.trimmingCharacters(in: .whitespaces).prefix(120)) }
        return line?.isEmpty == false ? line : nil
    }

    /// "Sep 30 at 2:59pm (America/Chicago)", "Oct 2 at 6am (…)", "Jan 3, 2027 at 6am (…)";
    /// nil if it can't be read (the window is still shown, without a countdown).
    static func resetDate(_ text: String, now: Date = Date()) -> Date? {
        var text = text.trimmingCharacters(in: .whitespaces)
        var zone = TimeZone.current
        if text.hasSuffix(")"), let open = text.lastIndex(of: "(") {
            let name = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
            // An unknown zone would silently read the time in the wrong one: no date instead.
            guard let parsed = TimeZone(identifier: name) ?? TimeZone(abbreviation: name) else { return nil }
            zone = parsed
            text = text[..<open].trimmingCharacters(in: .whitespaces)
        }
        // Any space before am/pm removed (ICU may use U+202F or U+00A0), and am/pm uppercased.
        text = text.replacingOccurrences(of: "[\\s\u{202F}\u{00A0}]+([AaPp][Mm])$", with: "$1",
                                         options: .regularExpression)
        if let suffix = ["am", "pm"].first(where: { text.lowercased().hasSuffix($0) }) {
            text = text.dropLast(2) + suffix.uppercased()
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.defaultDate = calendar.date(from: DateComponents(year: calendar.component(.year, from: now), month: 1, day: 1))
        for separator in [" 'at' ", ", "] {
            for (format, hasYear) in [("MMM d, yyyy\(separator)h:mma", true), ("MMM d, yyyy\(separator)ha", true),
                                      ("MMM d\(separator)h:mma", false), ("MMM d\(separator)ha", false)] {
                formatter.dateFormat = format
                guard let date = formatter.date(from: text) else { continue }
                // No year: a reset is never far in the past, so a date over 30 days ago is next year's.
                if !hasYear, date < now.addingTimeInterval(-30 * 86400) {
                    return calendar.date(byAdding: .year, value: 1, to: date)
                }
                return date
            }
        }
        return nil
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
