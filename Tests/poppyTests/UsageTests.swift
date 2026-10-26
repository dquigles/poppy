import Foundation
import Testing
@testable import poppy

/// Usage meters: the model and each source's parsing (DESIGN §9.7, §9.12, §9.13).
struct UsageTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func windowClampsAndLabels() {
        #expect(UsageWindow(usedPercent: 140, resetsAt: nil, minutes: nil).usedPercent == 100)
        #expect(UsageWindow(usedPercent: -3, resetsAt: nil, minutes: nil).leftPercent == 100)
        #expect(UsageWindow(usedPercent: 0, resetsAt: nil, minutes: 300).label(fallback: "x") == "5h")
        #expect(UsageWindow(usedPercent: 0, resetsAt: nil, minutes: 10080).label(fallback: "x") == "7d")
        #expect(UsageWindow(usedPercent: 0, resetsAt: nil, minutes: 90).label(fallback: "x") == "90m")
        #expect(UsageWindow(usedPercent: 0, resetsAt: nil, minutes: nil).label(fallback: "5h") == "5h")
        #expect(UsageWindow(usedPercent: 0, resetsAt: nil, minutes: 0).label(fallback: "7d") == "7d")
        #expect(UsageWindow(usedPercent: 0, resetsAt: nil, minutes: 10080, name: "Gemini").label(fallback: "x") == "Gemini")
    }

    @Test func staleAfterFifteenMinutesOrAReset() {
        let fresh = UsageReport(short: UsageWindow(usedPercent: 10, resetsAt: now.addingTimeInterval(3600), minutes: 300),
                                long: nil, fetchedAt: now)
        #expect(!fresh.isStale(at: now.addingTimeInterval(60)))
        #expect(fresh.isStale(at: now.addingTimeInterval(16 * 60)))
        let reset = UsageReport(short: UsageWindow(usedPercent: 10, resetsAt: now.addingTimeInterval(30), minutes: 300),
                                long: nil, fetchedAt: now)
        #expect(reset.isStale(at: now.addingTimeInterval(31)))
    }

    /// A window reported as already reset must not hide the other one (M15 review fix).
    @Test func currentDropsOnlyResetWindows() throws {
        let report = UsageReport(short: UsageWindow(usedPercent: 50, resetsAt: now.addingTimeInterval(-1), minutes: 300),
                                 long: UsageWindow(usedPercent: 20, resetsAt: now.addingTimeInterval(86400), minutes: 10080),
                                 fetchedAt: now)
        let current = try #require(report.current(at: now))
        #expect(current.short == nil && current.long?.usedPercent == 20)
        let none = UsageReport(short: UsageWindow(usedPercent: 50, resetsAt: now.addingTimeInterval(-1), minutes: 300),
                               long: nil, fetchedAt: now)
        #expect(none.current(at: now) == nil)
        #expect(report.current(at: now.addingTimeInterval(16 * 60)) == nil)
    }

    @Test func ringFollowsTheModelForPerModelWindows() {
        let gemini = UsageWindow(usedPercent: 10, resetsAt: nil, minutes: 10080, name: "Gemini", matchText: "gemini models")
        let claude = UsageWindow(usedPercent: 70, resetsAt: nil, minutes: 10080, name: "Claude/GPT",
                                 matchText: "claude and gpt models claude opus, gpt-oss")
        let report = UsageReport(short: gemini, long: claude, fetchedAt: now)
        #expect(report.ringWindow(forModel: "gemini-3-pro") == gemini)
        #expect(report.ringWindow(forModel: "claude-opus-4") == claude)
        #expect(report.ringWindow(forModel: nil) == claude)  // closest to running out
        #expect(report.ringWindow(forModel: "mystery") == claude)
        let plain = UsageReport(short: UsageWindow(usedPercent: 5, resetsAt: nil, minutes: 300),
                                long: UsageWindow(usedPercent: 90, resetsAt: nil, minutes: 10080), fetchedAt: now)
        #expect(plain.ringWindow(forModel: "x") == plain.short)
    }

    @Test func summary() {
        let report = UsageReport(short: UsageWindow(usedPercent: 12.4, resetsAt: nil, minutes: 300),
                                 long: UsageWindow(usedPercent: 47, resetsAt: nil, minutes: nil), fetchedAt: now)
        #expect(report.summary == "5h 12% 7d 47%")
    }

    // MARK: Claude's /usage text

    @Test func claudeLimitLines() throws {
        let text = """
        You are currently using your subscription to power your Claude Code usage

        Current session: 72% used · resets Sep 30 at 2:59pm (America/Chicago)
        Current week (all models): 47% used · resets Oct 2 at 6am (America/Chicago)
        """
        let report = try ClaudeUsage.report(fromText: text, now: now)
        #expect(report.short?.usedPercent == 72 && report.short?.minutes == 300)
        #expect(report.long?.usedPercent == 47 && report.long?.minutes == 10080)
        #expect(report.short?.resetsAt != nil && report.long?.resetsAt != nil)
    }

    @Test func claudeLineWithoutAResetStillCounts() throws {
        let report = try ClaudeUsage.report(fromText: "Current session: 3% used", now: now)
        #expect(report.short?.usedPercent == 3 && report.short?.resetsAt == nil && report.long == nil)
    }

    @Test func claudeSubscriptionWithUnknownWordingFails() {
        #expect(throws: UsageError.self) {
            try ClaudeUsage.report(fromText: "You are currently using your subscription\nSession: 4%", now: now)
        }
    }

    @Test func claudeWithoutLimitsIsUnavailable() {
        do {
            _ = try ClaudeUsage.report(fromText: "Total cost: $0.12", now: now)
            Issue.record("expected an error")
        } catch let error as UsageError {
            guard case .unavailable = error else { Issue.record("expected unavailable, got \(error)"); return }
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    private func components(_ date: Date?, _ zone: String) -> DateComponents? {
        guard let date else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    @Test func resetDateFormats() {
        // `now` is 2026-09-21 in Chicago.
        let a = components(ClaudeUsage.resetDate("Sep 30 at 2:59pm (America/Chicago)", now: now), "America/Chicago")
        #expect(a == DateComponents(year: 2026, month: 9, day: 30, hour: 14, minute: 59))
        let b = components(ClaudeUsage.resetDate("Oct 2 at 6am (America/Chicago)", now: now), "America/Chicago")
        #expect(b == DateComponents(year: 2026, month: 10, day: 2, hour: 6, minute: 0))
        let c = components(ClaudeUsage.resetDate("Jan 3, 2027 at 6am (Europe/Paris)", now: now), "Europe/Paris")
        #expect(c == DateComponents(year: 2027, month: 1, day: 3, hour: 6, minute: 0))
        let d = components(ClaudeUsage.resetDate("Oct 2, 6\u{202F}AM (UTC)", now: now), "UTC")
        #expect(d == DateComponents(year: 2026, month: 10, day: 2, hour: 6, minute: 0))
    }

    @Test func resetDateWithoutAYearRollsIntoNextYear() {
        let late = components(ClaudeUsage.resetDate("Jan 2 at 6am (UTC)", now: now), "UTC")
        #expect(late?.year == 2027)
    }

    @Test func resetDateRejectsUnknownZonesAndNonsense() {
        #expect(ClaudeUsage.resetDate("Sep 30 at 2pm (Mars/Olympus)", now: now) == nil)
        #expect(ClaudeUsage.resetDate("soon", now: now) == nil)
    }

    // MARK: Codex's app-server

    @Test func codexRateLimits() throws {
        let response = json(#"""
        {"id": 1, "result": {"rateLimits": {"primary": {"usedPercent": 12, "resetsAt": 1790003600, "windowDurationMins": 300},
                                            "secondary": {"usedPercent": 40.5, "windowDurationMins": 10080}}}}
        """#)
        let report = try CodexUsage.report(fromResponse: response)
        #expect(report.short?.usedPercent == 12 && report.short?.minutes == 300)
        #expect(report.short?.resetsAt == Date(timeIntervalSince1970: 1_790_003_600))
        #expect(report.long?.usedPercent == 40.5 && report.long?.resetsAt == nil)
    }

    @Test func codexErrorsAndEmptyAnswersFail() {
        #expect(throws: UsageError.self) {
            try CodexUsage.report(fromResponse: json(#"{"id": 1, "error": {"message": "chatgpt authentication required"}}"#))
        }
        #expect(throws: UsageError.self) { try CodexUsage.report(fromResponse: json(#"{"id": 1, "result": {}}"#)) }
        #expect(throws: UsageError.self) {
            try CodexUsage.report(fromResponse: json(#"{"id": 1, "result": {"rateLimits": {"primary": {}}}}"#))
        }
    }

    // MARK: Antigravity's /usage

    @Test func antigravityGroupsUseTheirTightestBucket() throws {
        let response = json(#"""
        {"status": "SUCCESS", "command": {"name": "usage", "data": {"groups": [
          {"name": "Gemini Models", "description": "Gemini Flash, Gemini Pro",
           "buckets": [{"window": "weekly", "remaining_fraction": 0.9, "reset_time": "2026-10-01T00:00:00Z"},
                       {"window": "daily", "remaining_fraction": 0.25, "reset_time": "2026-09-22T00:00:00.000Z"}]},
          {"name": "Claude and GPT models", "buckets": [{"window": "weekly", "remaining_fraction": 0.6}]},
          {"name": "No buckets"}
        ]}}}
        """#)
        let report = try AntigravityUsage.report(fromResponse: response)
        let gemini = try #require(report.short)
        #expect(gemini.name == "Gemini" && gemini.minutes == 1440)
        #expect(abs(gemini.usedPercent - 75) < 0.001)
        #expect(gemini.resetsAt != nil)
        #expect(gemini.matchText == "gemini models gemini flash, gemini pro")
        #expect(report.long?.name == "Claude/GPT" && report.long?.minutes == 10080)
        #expect(abs((report.long?.usedPercent ?? 0) - 40) < 0.001)
    }

    @Test func antigravityFailures() {
        #expect(throws: UsageError.self) {
            try AntigravityUsage.report(fromResponse: json(#"{"status": "ERROR", "response": "Rate limited\nmore"}"#))
        }
        #expect(throws: UsageError.self) {
            try AntigravityUsage.report(fromResponse: json(#"{"status": "SUCCESS", "command": {"data": {"groups": []}}}"#))
        }
    }

    @Test func antigravityShortNames() {
        #expect(AntigravityUsage.shortName("Gemini Models") == "Gemini")
        #expect(AntigravityUsage.shortName("Claude and GPT models") == "Claude/GPT")
        #expect(AntigravityUsage.shortName("Other") == "Other")
    }

    @Test func supportedHarnesses() {
        #expect(UsageMonitor.supports(.claude) && UsageMonitor.supports(.codex) && UsageMonitor.supports(.antigravity))
        #expect(!UsageMonitor.supports(.opencode) && !UsageMonitor.supports(.shell) && !UsageMonitor.supports(.other))
    }
}
