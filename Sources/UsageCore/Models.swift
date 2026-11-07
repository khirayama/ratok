import Foundation

public enum Provider: String, CaseIterable, Sendable, Identifiable {
    case codex, claude, openCodeGo = "opencode-go"
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .codex: "ChatGPT"
        case .claude: "Claude"
        case .openCodeGo: "OpenCode Go"
        }
    }
    public var endpointName: String {
        switch self {
        case .codex: "OpenAI API"
        case .claude: "Anthropic API"
        case .openCodeGo: "OpenCode Go API"
        }
    }
}

public enum Tool: String, CaseIterable, Sendable, Identifiable {
    case claudeCode = "claude-code", codex
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }
}

public enum UsagePeriod: String, CaseIterable, Sendable, Identifiable {
    case today, week, month, thisMonth
    public var id: String { rawValue }
    public var title: String {
        switch self { case .today: "今日"; case .week: "7日間"; case .month: "30日間"; case .thisMonth: "今月" }
    }
    public func start(now: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: now)
        let days: Int
        switch self {
        case .today: days = 1
        case .week: days = 7
        case .month: days = 30
        case .thisMonth: return calendar.dateInterval(of: .month, for: now)?.start ?? day
        }
        return calendar.date(byAdding: .day, value: 1 - days, to: day) ?? day
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
        self.input = max(0, input); self.output = max(0, output)
        self.cacheRead = max(0, cacheRead); self.cacheWrite = max(0, cacheWrite)
        self.cacheWrite1h = max(0, cacheWrite1h)
    }
    public var uncachedInput: Int { max(0, max(0, input - cacheRead) - cacheWrite) }
    public var total: Int { Self.sum(input, output) }
    public var uncachedTotal: Int { Self.sum(uncachedInput, output) }
    /// Corrupt logs must not crash the app with an integer overflow. Saturate counters at Int.max.
    static func sum(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = max(0, lhs).addingReportingOverflow(max(0, rhs))
        return overflow ? .max : value
    }
    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(input: sum(lhs.input, rhs.input), output: sum(lhs.output, rhs.output),
             cacheRead: sum(lhs.cacheRead, rhs.cacheRead), cacheWrite: sum(lhs.cacheWrite, rhs.cacheWrite),
             cacheWrite1h: sum(lhs.cacheWrite1h, rhs.cacheWrite1h))
    }
    static func delta(_ next: Self, _ previous: Self) -> Self {
        Self(input: max(0, next.input - previous.input), output: max(0, next.output - previous.output),
             cacheRead: max(0, next.cacheRead - previous.cacheRead), cacheWrite: max(0, next.cacheWrite - previous.cacheWrite),
             cacheWrite1h: max(0, next.cacheWrite1h - previous.cacheWrite1h))
    }

    private enum CodingKeys: String, CodingKey { case input, output, cacheRead, cacheWrite, cacheWrite1h }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(input: try values.decode(Int.self, forKey: .input),
                  output: try values.decode(Int.self, forKey: .output),
                  cacheRead: try values.decode(Int.self, forKey: .cacheRead),
                  cacheWrite: try values.decode(Int.self, forKey: .cacheWrite),
                  cacheWrite1h: try values.decodeIfPresent(Int.self, forKey: .cacheWrite1h) ?? 0)
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

/// The account-wide limit windows that can be chosen for the menu bar. Additional pools such as
/// Luna Reserve are titled with their name and are not matched.
public enum LimitWindowKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case fiveHour, weekly, monthly
    public var id: String { rawValue }
    private var title: String {
        switch self {
        case .fiveHour: "5時間"
        case .weekly: "週間"
        case .monthly: "月間"
        }
    }
    public func matches(_ window: LimitWindow) -> Bool {
        if window.title == title { return true }
        // Codex names its main windows primary and secondary; a weekly-only plan reports a weekly primary.
        let periodTitles = Self.allCases.map(\.title)
        switch self {
        case .fiveHour:
            return ["five_hour", "5h"].contains(window.id)
                || (window.id == "primary" && !periodTitles.contains(window.title))
        case .weekly:
            return ["seven_day", "weekly", "7d"].contains(window.id)
                || (window.id == "secondary" && !periodTitles.contains(window.title))
        case .monthly:
            return window.id == "monthly"
        }
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
        window(.fiveHour) ?? window(.weekly)
    }
    public func window(_ kind: LimitWindowKind) -> LimitWindow? {
        windows.first(where: kind.matches)
    }
    /// The windows to show for the selected kinds, in the order given; nil marks a window not reported yet.
    /// When none of them is known, the usual 5-hour-then-weekly choice is shown so a plan without the
    /// selected windows still shows something.
    public func menuBarWindows(for kinds: [LimitWindowKind]) -> [LimitWindow?] {
        guard !kinds.isEmpty else { return [] }
        let selected = kinds.map(window)
        if selected.allSatisfy({ $0 == nil }), let fallback = menuBarWindow { return [fallback] }
        return selected
    }
    /// Combines two sources for the same account: the newer one wins per window, and windows only the
    /// older one knows are kept. The main Codex windows stay ahead of additional pools.
    public func merging(_ other: LimitSnapshot) -> LimitSnapshot {
        let (newer, older) = observedAt >= other.observedAt ? (self, other) : (other, self)
        let known = Set(newer.windows.map(\.id))
        let all = newer.windows + older.windows.filter { !known.contains($0.id) }
        let main: (LimitWindow) -> Bool = { $0.id == "primary" || $0.id == "secondary" }
        return LimitSnapshot(windows: all.filter(main) + all.filter { !main($0) },
                             observedAt: newer.observedAt, plan: newer.plan ?? older.plan)
    }
}

public enum UsageGrouping: String, CaseIterable, Sendable, Identifiable {
    case model, effort, modelAndEffort, tool, toolAndModel
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .model: "モデル別"
        case .effort: "effort別"
        case .modelAndEffort: "モデル×effort"
        case .tool: "ツール別"
        case .toolAndModel: "ツール×モデル"
        }
    }
}

public struct UsageGroup: Hashable, Sendable {
    public var model: String?
    public var effort: String?
    public var tool: Tool?
    public init(model: String? = nil, effort: String? = nil, tool: Tool? = nil) {
        self.model = model; self.effort = effort; self.tool = tool
    }
}

public struct UsageBreakdown: Sendable, Identifiable {
    public var id: UsageGroup
    public var tokens: TokenUsage
    public var cost: CostEstimate
}

public struct UsageSnapshot: Sendable {
    public var endpoint: Provider?
    public var tokens: TokenUsage = .init()
    public var usageByGroup: [UsageGroup: TokenUsage] = [:]
    public var limits: LimitSnapshot?
    public var lastActivity: Date?
    public var files = 0
    public var issues: [String] = []
    public init() {}

    /// The same snapshot without its token figures. Limits are independent of the selected period,
    /// so they can keep showing while a newly selected period is counted.
    public func keepingLimits() -> UsageSnapshot {
        var result = UsageSnapshot()
        result.endpoint = endpoint
        result.limits = limits
        result.issues = issues
        return result
    }

    public var estimatedCost: CostEstimate {
        usageByGroup.reduce(CostEstimate()) {
            $0 + APIPricing.estimate(model: $1.key.model, tokens: $1.value, endpoint: endpoint)
        }
    }

    public func breakdown(by grouping: UsageGrouping) -> [UsageBreakdown] {
        var totals: [UsageGroup: TokenUsage] = [:]
        var costs: [UsageGroup: CostEstimate] = [:]
        for (group, tokens) in usageByGroup {
            let key = switch grouping {
            case .model: UsageGroup(model: group.model)
            case .effort: UsageGroup(effort: group.effort)
            case .modelAndEffort: UsageGroup(model: group.model, effort: group.effort)
            case .tool: UsageGroup(tool: group.tool)
            case .toolAndModel: UsageGroup(model: group.model, tool: group.tool)
            }
            totals[key, default: TokenUsage()] = totals[key, default: TokenUsage()] + tokens
            // Price by the original model before combining models or tools into one row.
            costs[key, default: CostEstimate()] = costs[key, default: CostEstimate()]
                + APIPricing.estimate(model: group.model, tokens: tokens, endpoint: endpoint)
        }
        return totals.map { UsageBreakdown(id: $0.key, tokens: $0.value, cost: costs[$0.key, default: CostEstimate()]) }.sorted {
            if $0.tokens.total != $1.tokens.total { return $0.tokens.total > $1.tokens.total }
            if $0.id.tool != $1.id.tool { return ($0.id.tool?.rawValue ?? "") < ($1.id.tool?.rawValue ?? "") }
            if $0.id.model != $1.id.model { return ($0.id.model ?? "") < ($1.id.model ?? "") }
            return ($0.id.effort ?? "") < ($1.id.effort ?? "")
        }
    }

    /// Combines snapshots of the same endpoint, such as OpenCode Go usage found in
    /// both Claude Code and Codex logs.
    public func merging(_ other: UsageSnapshot) -> UsageSnapshot {
        var result = self
        result.endpoint = endpoint ?? other.endpoint
        result.tokens = tokens + other.tokens
        for (group, tokens) in other.usageByGroup {
            result.usageByGroup[group, default: TokenUsage()] = result.usageByGroup[group, default: TokenUsage()] + tokens
        }
        if let otherLimits = other.limits {
            result.limits = result.limits?.merging(otherLimits) ?? otherLimits
        }
        let times = [lastActivity, other.lastActivity].compactMap { $0 }
        result.lastActivity = times.max()
        result.files = TokenUsage.sum(files, other.files)
        for issue in other.issues where !result.issues.contains(issue) {
            result.issues.append(issue)
        }
        return result
    }
}

public enum UsagePaths {
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    public static var support: URL {
        ProcessInfo.processInfo.environment["RATOK_SUPPORT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent("Library/Application Support/Ratok", isDirectory: true)
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
