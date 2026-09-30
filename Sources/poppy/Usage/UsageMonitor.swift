import Foundation

/// Fetches the running agent's usage and decides when (DESIGN §9.7).
final class UsageMonitor {
    enum Trigger { case poll, event }

    /// What to show: a report, or nil with a reason (nil reason: still loading).
    var onChange: ((UsageReport?, String?) -> Void)?

    static let tickInterval: TimeInterval = 60
    static let pollInterval: TimeInterval = 5 * 60
    static let failureRetry: TimeInterval = 5 * 60
    static let initialBackoff: TimeInterval = 10 * 60
    static let maxBackoff: TimeInterval = 30 * 60

    private struct Source {
        var report: UsageReport?
        var failure: String?
        var nextAllowed = Date.distantPast
        var inFlight = false
        var backoff: TimeInterval = UsageMonitor.initialBackoff
    }

    /// Keyed by harness and executable prefix, so two Codex profiles with different
    /// `CODEX_HOME`s don't share an account's numbers.
    private var sources: [String: Source] = [:]
    private var sourceKey: String { "\(harness)|\(StatusHooks.executablePrefix(command))" }
    private var timer: Timer?
    private(set) var harness: Harness
    /// The running command (Codex is asked through it, so `CODEX_HOME=…` applies).
    private var command: String
    private(set) var enabled: Bool
    /// The model the agent last called (Antigravity's hook reports it); picks the ring's
    /// window (DESIGN §9.12).
    private var agentModel: String?

    init(command: String, enabled: Bool) {
        self.command = command
        harness = Harness(command: command)
        self.enabled = enabled
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    isolated deinit {
        timer?.invalidate()
    }

    static func supports(_ harness: Harness) -> Bool {
        harness == .claude || harness == .codex || harness == .antigravity
    }

    /// True when the current agent has usage to show and Show Usage is on.
    var isActive: Bool { enabled && Self.supports(harness) }

    func start() {
        publish()
        refresh(.event)
    }

    func setCommand(_ command: String) {
        self.command = command
        harness = Harness(command: command)
        agentModel = nil
        publish()
        refresh(.event)
    }

    func setAgentModel(_ model: String?) {
        guard model != agentModel else { return }
        agentModel = model
        publish()
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if enabled {
            // Turning it back on retries a refused Keychain read or a silent agy (DESIGN §9.7, §9.12).
            for key in sources.keys where sources[key]?.nextAllowed == .distantFuture {
                sources[key]?.nextAllowed = .distantPast
            }
        }
        publish()
        if enabled { refresh(.event) }
    }

    private func tick() {
        publish()  // countdowns and staleness
        refresh(.poll)
    }

    /// Fetches for the current harness unless it's too soon (DESIGN §9.7).
    func refresh(_ trigger: Trigger) {
        guard isActive else { return }
        let harness = harness
        let key = sourceKey
        var source = sources[key] ?? Source()
        let now = Date()
        guard !source.inFlight, now >= source.nextAllowed else { return }
        if trigger == .poll, let report = source.report, !report.isStale(at: now),
           now.timeIntervalSince(report.fetchedAt) < Self.pollInterval { return }
        source.inFlight = true
        sources[key] = source

        let command = command
        Task { [weak self] in
            let result: Result<UsageReport, Error>
            if harness == .claude {
                do { result = .success(try await ClaudeUsage.fetch()) } catch { result = .failure(error) }
            } else {
                result = await Task.detached { () -> Result<UsageReport, Error> in
                    do {
                        return .success(harness == .antigravity ? try AntigravityUsage.fetch(command: command)
                                                                : try CodexUsage.fetch(command: command))
                    } catch { return .failure(error) }
                }.value
            }
            self?.finished(key, harness, result)
        }
    }

    private func finished(_ key: String, _ harness: Harness, _ result: Result<UsageReport, Error>) {
        var source = sources[key] ?? Source()
        source.inFlight = false
        let now = Date()
        switch result {
        case .success(let report):
            source.report = report
            source.failure = nil
            source.backoff = Self.initialBackoff
            source.nextAllowed = now.addingTimeInterval(harness == .claude ? 120 : 60)
            appLog("usage: \(harness.displayName) \(report.summary)")
        case .failure(let error):
            if case UsageError.rateLimited = error {
                source.nextAllowed = now.addingTimeInterval(source.backoff)
                source.backoff = min(source.backoff * 2, Self.maxBackoff)
            } else if case UsageError.signedOut = error {
                source.nextAllowed = now.addingTimeInterval(60)  // cheap check, no prompt: a sign-in shows soon
            } else if case UsageError.keychainDenied = error {
                source.nextAllowed = .distantFuture  // until Show Usage is toggled or Poppy relaunches
            } else if case UsageError.noAnswer = error {
                source.nextAllowed = .distantFuture  // an expired agy login could open the browser again
            } else {
                source.nextAllowed = now.addingTimeInterval(Self.failureRetry)
            }
            source.failure = "\(error)"
            appLog("usage: \(harness.displayName) failed: \(error)")
        }
        sources[key] = source
        if key == sourceKey { publish() }
    }

    private func publish() {
        guard isActive else {
            onChange?(nil, nil)
            return
        }
        let source = sources[sourceKey]
        if var report = source?.report?.current() {
            report.ring = report.ringWindow(forModel: agentModel)
            onChange?(report, nil)
        } else if let source, !source.inFlight, source.report != nil, source.failure == nil {
            onChange?(nil, "no current usage reported")  // fetched, but every window has reset
        } else {
            onChange?(nil, source?.failure)
        }
    }
}
