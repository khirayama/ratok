import Foundation

public enum Provider: String, CaseIterable, Sendable, Identifiable {
    case claude, codex
    public var id: String { rawValue }
    public var name: String { self == .claude ? "Claude Code" : "Codex" }
}

public enum UsagePeriod: Int, CaseIterable, Sendable, Identifiable {
    case today = 1, week = 7, month = 30
    public var id: Int { rawValue }
    public var title: String {
        switch self { case .today: "今日"; case .week: "7日間"; case .month: "30日間" }
    }
    public func start(now: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 1 - rawValue, to: day) ?? day
    }
}

public struct TokenUsage: Codable, Sendable, Equatable {
    /// All input, including cache reads and writes.
    public var input: Int = 0
    public var output: Int = 0
    public var cacheRead: Int = 0
    public var cacheWrite: Int = 0
    /// One-hour Claude cache writes, included in `cacheWrite`.
    public var cacheWrite1h: Int = 0
    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, cacheWrite1h: Int = 0) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
        self.cacheWrite1h = cacheWrite1h
    }
    public var uncachedInput: Int { max(0, input - cacheRead - cacheWrite) }
    public var total: Int { input + output }
    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(input: lhs.input + rhs.input, output: lhs.output + rhs.output,
             cacheRead: lhs.cacheRead + rhs.cacheRead, cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
             cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h)
    }
    static func delta(_ next: Self, _ previous: Self) -> Self {
        Self(input: max(0, next.input - previous.input), output: max(0, next.output - previous.output),
             cacheRead: max(0, next.cacheRead - previous.cacheRead), cacheWrite: max(0, next.cacheWrite - previous.cacheWrite),
             cacheWrite1h: max(0, next.cacheWrite1h - previous.cacheWrite1h))
    }

    private enum CodingKeys: String, CodingKey { case input, output, cacheRead, cacheWrite, cacheWrite1h }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        input = try values.decode(Int.self, forKey: .input)
        output = try values.decode(Int.self, forKey: .output)
        cacheRead = try values.decode(Int.self, forKey: .cacheRead)
        cacheWrite = try values.decode(Int.self, forKey: .cacheWrite)
        cacheWrite1h = try values.decodeIfPresent(Int.self, forKey: .cacheWrite1h) ?? 0
    }
}

public struct LimitWindow: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var usedPercent: Double
    public var resetsAt: Date?
    public init(id: String, title: String, usedPercent: Double, resetsAt: Date?) {
        self.id = id; self.title = title; self.usedPercent = usedPercent; self.resetsAt = resetsAt
    }
    public func expired(at now: Date) -> Bool { resetsAt.map { $0 <= now } ?? false }
    public var lastKnownRemainingPercent: Double? {
        guard usedPercent.isFinite else { return nil }
        return 100 - min(max(usedPercent, 0), 100)
    }
    public func remainingPercent(at now: Date) -> Double? {
        guard !expired(at: now) else { return nil }
        return lastKnownRemainingPercent
    }
}

public struct LimitSnapshot: Codable, Sendable, Equatable {
    public var windows: [LimitWindow]
    public var observedAt: Date
    public var plan: String?
    public init(windows: [LimitWindow], observedAt: Date, plan: String? = nil) {
        self.windows = windows; self.observedAt = observedAt; self.plan = plan
    }
    public var menuBarWindow: LimitWindow? {
        windows.first { $0.id == "primary" || $0.title == "5時間" }
            ?? windows.first { $0.id == "secondary" || $0.title == "週間" }
    }
}

public enum UsageGrouping: String, CaseIterable, Sendable, Identifiable {
    case model, effort, modelAndEffort
    public var id: String { rawValue }
    public var title: String {
        switch self { case .model: "モデル別"; case .effort: "effort別"; case .modelAndEffort: "モデル×effort" }
    }
}

public struct UsageGroup: Hashable, Sendable {
    public var model: String?
    public var effort: String?
    public init(model: String? = nil, effort: String? = nil) {
        self.model = model; self.effort = effort
    }
}

public struct UsageBreakdown: Sendable, Identifiable {
    public var id: UsageGroup
    public var tokens: TokenUsage
    public var cost: CostEstimate
}

public struct UsageSnapshot: Sendable {
    public var tokens: TokenUsage = .init()
    public var usageByGroup: [UsageGroup: TokenUsage] = [:]
    public var limits: LimitSnapshot?
    public var lastActivity: Date?
    public var files = 0
    public var issues: [String] = []
    public init() {}

    public var estimatedCost: CostEstimate {
        usageByGroup.reduce(CostEstimate()) { $0 + APIPricing.estimate(model: $1.key.model, tokens: $1.value) }
    }

    public func breakdown(by grouping: UsageGrouping) -> [UsageBreakdown] {
        var totals: [UsageGroup: TokenUsage] = [:]
        var costs: [UsageGroup: CostEstimate] = [:]
        for (group, tokens) in usageByGroup {
            let key = switch grouping {
            case .model: UsageGroup(model: group.model)
            case .effort: UsageGroup(effort: group.effort)
            case .modelAndEffort: group
            }
            totals[key, default: TokenUsage()] = totals[key, default: TokenUsage()] + tokens
            // Price by the original model before combining different models into an effort row.
            costs[key, default: CostEstimate()] = costs[key, default: CostEstimate()] + APIPricing.estimate(model: group.model, tokens: tokens)
        }
        return totals.map { UsageBreakdown(id: $0.key, tokens: $0.value, cost: costs[$0.key, default: CostEstimate()]) }.sorted {
            if $0.tokens.total != $1.tokens.total { return $0.tokens.total > $1.tokens.total }
            if $0.id.model != $1.id.model { return ($0.id.model ?? "") < ($1.id.model ?? "") }
            return ($0.id.effort ?? "") < ($1.id.effort ?? "")
        }
    }
}

public enum UsagePaths {
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    public static var support: URL {
        home.appendingPathComponent("Library/Application Support/Ratok", isDirectory: true)
    }
    public static var legacySupport: URL {
        home.appendingPathComponent("Library/Application Support/UsageBar", isDirectory: true)
    }
    public static var claudeLimits: URL {
        let current = support.appendingPathComponent("claude-limits.json")
        let legacy = legacySupport.appendingPathComponent("claude-limits.json")
        return FileManager.default.fileExists(atPath: current.path) ? current : legacy
    }
    public static var claude: URL {
        ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".claude", isDirectory: true)
    }
    public static var codex: URL {
        ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex", isDirectory: true)
    }
}
