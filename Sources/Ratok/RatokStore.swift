import Foundation
import Observation
import UsageCore

enum MenuBarPercentageMode: String {
    case remaining, used
}

@Observable
final class UsageStore {
    var language: AppLanguage = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "ja") ?? .japanese {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "appLanguage") }
    }
    var showCodexNameInMenuBar = UserDefaults.standard.object(forKey: "showCodexNameInMenuBar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showCodexNameInMenuBar, forKey: "showCodexNameInMenuBar") }
    }
    var showClaudeNameInMenuBar = UserDefaults.standard.object(forKey: "showClaudeNameInMenuBar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showClaudeNameInMenuBar, forKey: "showClaudeNameInMenuBar") }
    }
    var showBothLimitWindowsInMenuBar = UserDefaults.standard.bool(forKey: "showBothLimitWindowsInMenuBar") {
        didSet { UserDefaults.standard.set(showBothLimitWindowsInMenuBar, forKey: "showBothLimitWindowsInMenuBar") }
    }
    var menuBarPercentageMode = MenuBarPercentageMode(rawValue: UserDefaults.standard.string(forKey: "menuBarPercentageMode") ?? "remaining") ?? .remaining {
        didSet { UserDefaults.standard.set(menuBarPercentageMode.rawValue, forKey: "menuBarPercentageMode") }
    }
    var period = UsagePeriod.today {
        didSet {
            if oldValue != period { snapshots = [:] }
        }
    }
    var snapshots: [Provider: UsageSnapshot] = [:]
    var refreshing = false
    var updatedAt: Date?
    var bridgeInstalled = BridgeInstaller().installed
    var error: String?
    @ObservationIgnored private let scanner = UsageScanner()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    func menuPercentageText(for provider: Provider, window: LimitWindow?) -> String {
        let percentage: Double?
        if menuBarPercentageMode == .used {
            percentage = window?.usedPercent.isFinite == true ? window?.usedPercent : nil
        } else {
            percentage = provider == .claude
                ? window?.lastKnownRemainingPercent
                : window?.remainingPercent(at: Date())
        }
        guard let percentage else { return "—" }
        return "\(Int(percentage.rounded()))%"
    }

    func menuBarWindows(for provider: Provider) -> [LimitWindow] {
        guard let limits = snapshots[provider]?.limits else { return [] }
        guard showBothLimitWindowsInMenuBar else { return limits.menuBarWindow.map { [$0] } ?? [] }
        let fiveHour = limits.windows.first(where: isFiveHourWindow)
        let weekly = limits.windows.first(where: isWeeklyWindow)
        return [fiveHour, weekly].compactMap { $0 }
    }

    func menuBarValue(for provider: Provider) -> String {
        let windows = menuBarWindows(for: provider)
        guard !windows.isEmpty else { return "—" }
        guard showBothLimitWindowsInMenuBar else { return menuPercentageText(for: provider, window: windows[0]) }
        let fiveHour = windows.first(where: isFiveHourWindow)
        let weekly = windows.first(where: isWeeklyWindow)
        let values = [fiveHour, weekly].map { window in
            window.map { menuPercentageText(for: provider, window: $0) } ?? "—"
        }
        return values.joined(separator: "/")
    }

    private func isFiveHourWindow(_ window: LimitWindow) -> Bool {
        ["primary", "five_hour", "5h"].contains(window.id) || window.title == "5時間"
    }

    private func isWeeklyWindow(_ window: LimitWindow) -> Bool {
        ["secondary", "seven_day", "weekly", "7d"].contains(window.id) || window.title == "週間"
    }

    func menuHelp(for provider: Provider) -> String {
        let windows = menuBarWindows(for: provider)
        guard !windows.isEmpty else {
            return language == .japanese ? "\(provider.name): 制限未取得" : "\(provider.name): limits unavailable"
        }
        if showBothLimitWindowsInMenuBar {
            return windows.map { window in
                let title = localizedWindowTitle(window, language: language)
                let value = menuPercentageText(for: provider, window: window)
                let metric = percentageMetricName
                return "\(provider.name): \(title) \(language == .japanese ? "枠の" : "")\(metric) \(value)"
            }.joined(separator: "\n")
        }
        guard let window = windows.first else { return "" }
        let title = localizedWindowTitle(window, language: language)
        let value = menuPercentageText(for: provider, window: window)
        if menuBarPercentageMode == .used {
            return language == .japanese
                ? "\(provider.name): \(title)枠の使用量（最終取得） \(value)"
                : "\(provider.name): \(title) used at last fetch \(value)"
        }
        if provider == .claude {
            if language == .english {
                let status = window.expired(at: Date()) ? " (reset; waiting for refresh)" : ""
                return "\(provider.name): \(title) remaining at last fetch \(value)\(status)"
            }
            let status = window.expired(at: Date()) ? "（リセット済み・再取得待ち）" : ""
            return "\(provider.name): \(title)枠の最終取得残量 \(value)\(status)"
        }
        if window.expired(at: Date()) {
            return language == .japanese ? "\(provider.name): \(title)枠の再取得待ち" : "\(provider.name): \(title) waiting for refresh"
        }
        return language == .japanese ? "\(provider.name): \(title)枠の残量 \(value)" : "\(provider.name): \(title) remaining \(value)"
    }

    private var percentageMetricName: String {
        if language == .japanese { return menuBarPercentageMode == .used ? "使用量" : "残量" }
        return menuBarPercentageMode == .used ? "used" : "remaining"
    }

    init() {
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let selectedPeriod = period
        let now = Date()
        let start = selectedPeriod.start(now: now)
        let claude = await scanner.scan(provider: .claude, root: UsagePaths.claude.appendingPathComponent("projects"),
                                        start: start, now: now, bridge: UsagePaths.claudeLimits)
        let codex = await scanner.scan(provider: .codex, root: UsagePaths.codex.appendingPathComponent("sessions"), start: start, now: now)
        // A period selection can change while disk reads are in progress.
        guard selectedPeriod == period else {
            refreshing = false
            await refresh()
            return
        }
        snapshots = [.claude: claude, .codex: codex]
        updatedAt = Date()
        bridgeInstalled = BridgeInstaller().installed
    }

    func toggleBridge() {
        do {
            let installer = BridgeInstaller()
            if installer.installed { try installer.uninstall() }
            else {
                guard let executable = Bundle.main.executableURL else { throw CocoaError(.fileNoSuchFile) }
                try installer.install(executable: executable)
            }
            bridgeInstalled = installer.installed
            error = nil
            Task { await refresh() }
        } catch {
            self.error = language == .japanese
                ? "Claude連携を変更できませんでした: \(error.localizedDescription)"
                : "Could not change Claude integration: \(error.localizedDescription)"
        }
    }
}
