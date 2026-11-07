import Foundation
import Observation
import UsageCore

enum MenuBarPercentageMode: String {
    case remaining, used
}

enum OpenCodeGoStatus {
    case idle, available, unauthorized, failed
}

@Observable
final class UsageStore {
    var language: AppLanguage = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "ja") ?? .japanese {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "appLanguage") }
    }
    var providerSettings: [Provider: ProviderSettings] = Dictionary(
        uniqueKeysWithValues: Provider.allCases.map { ($0, ProviderSettings.load(for: $0)) }) {
        didSet {
            for provider in Provider.allCases where oldValue[provider] != providerSettings[provider] {
                settings(for: provider).save(for: provider)
            }
            if showsMenuBarUsage, !showsMenuBarUsage(oldValue) { Task { await refresh() } }
        }
    }
    var menuBarPercentageMode = MenuBarPercentageMode(rawValue: UserDefaults.standard.string(forKey: "menuBarPercentageMode") ?? "remaining") ?? .remaining {
        didSet { UserDefaults.standard.set(menuBarPercentageMode.rawValue, forKey: "menuBarPercentageMode") }
    }
    var includeCacheInMenuBarTokens = UserDefaults.standard.bool(forKey: "includeCacheInMenuBarTokens") {
        didSet { UserDefaults.standard.set(includeCacheInMenuBarTokens, forKey: "includeCacheInMenuBarTokens") }
    }
    var menuBarPeriod = UsagePeriod(rawValue: UserDefaults.standard.string(forKey: "menuBarPeriod") ?? "today") ?? .today {
        didSet {
            UserDefaults.standard.set(menuBarPeriod.rawValue, forKey: "menuBarPeriod")
            guard oldValue != menuBarPeriod else { return }
            menuBarSnapshots = openCodeGoSnapshots
            if showsMenuBarUsage { Task { await refresh() } }
        }
    }
    var period = UsagePeriod(rawValue: UserDefaults.standard.string(forKey: "period") ?? "today") ?? .today {
        didSet {
            guard oldValue != period else { return }
            UserDefaults.standard.set(period.rawValue, forKey: "period")
            // Keep the menu bar's figures while the dashboard switches to another period.
            if oldValue == menuBarPeriod { menuBarSnapshots = snapshots }
            // Limits do not depend on the period, so they stay on screen while the new period is counted.
            scanGeneration += 1
            snapshots = snapshots.mapValues { $0.keepingLimits() }
            liveScans = [:]
            awaitingProviders = [.claude, .codex, .openCodeGo]
            countingUsage = false
        }
    }
    var grouping = UsageGrouping(rawValue: UserDefaults.standard.string(forKey: "usageGrouping") ?? "model") ?? .model {
        didSet { UserDefaults.standard.set(grouping.rawValue, forKey: "usageGrouping") }
    }
    var snapshots: [Provider: UsageSnapshot] = [:]
    /// Providers with no figures on screen yet for the selected period.
    private(set) var awaitingProviders: Set<Provider> = []
    /// True while a slow scan is still refining the figures on screen.
    private(set) var countingUsage = false
    /// Usage for the menu bar period, scanned only when it differs from the dashboard period.
    var menuBarSnapshots: [Provider: UsageSnapshot] = [:]
    var openCodeGoKeySource: OpenCodeGoKeySource?
    var openCodeGoStatus: OpenCodeGoStatus = .idle
    var openCodeGoRefreshing = false
    var codexResetCredits: ResetCreditSnapshot?
    @ObservationIgnored private var codexAccountLimits: LimitSnapshot?
    @ObservationIgnored private var claudeAccountLimits: LimitSnapshot?
    @ObservationIgnored private var claudeAccountRequestedAt: Date?
    @ObservationIgnored private var openCodeGoKey: String?
    @ObservationIgnored private var openCodeGoLastSnapshot: UsageSnapshot?
    @ObservationIgnored private var openCodeGoRequestedAt: Date?
    @ObservationIgnored private var openCodeGoNextFetch: Date?
    @ObservationIgnored private var openCodeGoGeneration = 0
    var refreshing = false
    var updatedAt: Date?
    var bridgeInstalled = BridgeInstaller().installed
    var error: String?
    // Separate scanners so the Claude and ChatGPT logs are counted at the same time.
    @ObservationIgnored private let claudeScanner = UsageScanner()
    @ObservationIgnored private let codexScanner = UsageScanner()
    /// Figures streamed so far, keyed by the log source they came from.
    @ObservationIgnored private var liveScans: [Provider: [Provider: UsageSnapshot]] = [:]
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var resetCreditsRequestedAt: Date?
    @ObservationIgnored private var resetCreditsNextFetch: Date?

    func settings(for provider: Provider) -> ProviderSettings {
        providerSettings[provider] ?? ProviderSettings()
    }

    func updateSettings(for provider: Provider, _ change: (inout ProviderSettings) -> Void) {
        var settings = settings(for: provider)
        change(&settings)
        providerSettings[provider] = settings
    }

    func isVisible(_ provider: Provider) -> Bool { settings(for: provider).visible }

    func showsMenuBarName(for provider: Provider) -> Bool { settings(for: provider).showsName }

    /// Providers shown in the dashboard and menu bar, in menu bar order.
    var visibleProviders: [Provider] {
        Provider.menuBarOrder.filter(isVisible)
    }

    /// Log-backed providers shown in the dashboard. OpenCode Go has its own account card.
    var visibleUsageProviders: [Provider] {
        visibleProviders.filter { $0 != .openCodeGo }
    }

    /// OpenCode Go has no useful menu bar entry until a key has been found or saved.
    var menuBarProviders: [Provider] {
        visibleProviders.filter { $0 != .openCodeGo || openCodeGoKeySource != nil }
    }

    var openCodeGoKeyConfigured: Bool { openCodeGoKeySource != nil }
    var openCodeGoUsesSavedKey: Bool { openCodeGoKeySource == .keychain }

    private var openCodeGoSnapshots: [Provider: UsageSnapshot] {
        guard let snapshot = openCodeGoLastSnapshot else { return [:] }
        var go = snapshot
        go.endpoint = .openCodeGo
        return [.openCodeGo: go]
    }

    /// Limits come from the OpenCode Go account API; token counts come from local logs.
    private func applyOpenCodeGoLimits(to snapshots: inout [Provider: UsageSnapshot]) {
        var go = snapshots[.openCodeGo] ?? UsageSnapshot()
        go.endpoint = .openCodeGo
        if let account = openCodeGoLastSnapshot {
            go.limits = account.limits
            for issue in account.issues where !go.issues.contains(issue) {
                go.issues.append(issue)
            }
        }
        snapshots[.openCodeGo] = go
    }

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
        return String(format: "%.0f%%", percentage.rounded())
    }

    /// Windows chosen for the menu bar; nil marks one the provider has not reported yet.
    func menuBarWindows(for provider: Provider) -> [LimitWindow?] {
        let kinds = settings(for: provider).limitWindows
        return snapshots[provider]?.limits?.menuBarWindows(for: kinds) ?? kinds.map { _ in nil }
    }

    func menuBarValue(for provider: Provider) -> String {
        let windows = menuBarWindows(for: provider)
        guard windows.contains(where: { $0 != nil }) else { return "—" }
        return windows.map { window in
            window.map { menuPercentageText(for: provider, window: $0) } ?? "—"
        }.joined(separator: "/")
    }

    var showsMenuBarUsage: Bool { showsMenuBarUsage(providerSettings) }

    private func showsMenuBarUsage(_ settings: [Provider: ProviderSettings]) -> Bool {
        Provider.allCases.contains { provider in
            guard let settings = settings[provider], settings.visible, settings.showsUsage else { return false }
            return provider != .openCodeGo || openCodeGoKeySource != nil
        }
    }

    /// The period that needs a scan of its own; nil when the dashboard's scan already covers it.
    private var menuBarScanPeriod: UsagePeriod? {
        showsMenuBarUsage && menuBarPeriod != period ? menuBarPeriod : nil
    }

    func menuBarUsage(for provider: Provider) -> UsageSnapshot? {
        guard menuBarPeriod == period else { return menuBarSnapshots[provider] }
        // The figures on screen belong to the previous period until the new one has been counted.
        return awaitingProviders.contains(provider) ? nil : snapshots[provider]
    }

    func menuBarValues(for provider: Provider) -> [String] {
        let settings = settings(for: provider)
        var values: [String] = []
        if !settings.limitWindows.isEmpty { values.append(menuBarValue(for: provider)) }
        let usage = menuBarUsage(for: provider)
        if settings.showsCost { values.append(usage.map { menuBarCostText($0.estimatedCost) } ?? "—") }
        if settings.showsTokens { values.append(usage.map { compact(menuBarTokenCount($0.tokens)) } ?? "—") }
        return values
    }

    private func menuBarTokenCount(_ tokens: TokenUsage) -> Int {
        includeCacheInMenuBarTokens ? tokens.total : tokens.uncachedTotal
    }

    private func menuBarCostText(_ cost: CostEstimate) -> String {
        guard let amount = cost.amountUSD else { return "—" }
        // Cents only add width once the amount reaches three digits.
        guard amount >= 100 else { return cost.displayText }
        let dollars = amount.formatted(.currency(code: "USD").precision(.fractionLength(0)).locale(Locale(identifier: "en_US")))
        return dollars + (cost.isPartial ? "*" : "")
    }

    func menuHelp(for provider: Provider) -> String {
        let settings = settings(for: provider)
        var lines = settings.limitWindows.isEmpty ? [] : [limitHelp(for: provider)]
        if settings.showsUsage { lines.append(usageHelp(for: provider)) }
        return lines.isEmpty ? provider.name : lines.joined(separator: "\n")
    }

    private func usageHelp(for provider: Provider) -> String {
        let period = periodTitle(menuBarPeriod, language: language)
        guard let usage = menuBarUsage(for: provider) else {
            return localized("\(provider.name): \(period)の使用量を集計中", "\(provider.name): loading usage for \(period)", language: language)
        }
        let settings = settings(for: provider)
        var parts: [String] = []
        if settings.showsCost {
            let cost = usage.estimatedCost
            let text = cost.amountUSD == nil && language == .english ? "Unpriced" : cost.displayText
            parts.append(localized("API換算 推定コスト \(text)", "estimated API cost \(text)", language: language))
        }
        if settings.showsTokens {
            let tokens = usage.tokens
            let count = menuBarTokenCount(tokens).formatted()
            let input = (includeCacheInMenuBarTokens ? tokens.input : tokens.uncachedInput).formatted()
            let cache = includeCacheInMenuBarTokens
                ? localized("キャッシュ込み", "including cache", language: language)
                : localized("キャッシュ除く", "excluding cache", language: language)
            parts.append(localized("トークン \(count)（入力 \(input) · 出力 \(tokens.output.formatted())、\(cache)）",
                                   "\(count) tokens (input \(input) · output \(tokens.output.formatted()), \(cache))",
                                   language: language))
        }
        return localized("\(provider.name): \(period)の\(parts.joined(separator: "、"))",
                         "\(provider.name): \(period) \(parts.joined(separator: ", "))", language: language)
    }

    private func limitHelp(for provider: Provider) -> String {
        let windows = menuBarWindows(for: provider)
        guard windows.contains(where: { $0 != nil }) else {
            return language == .japanese ? "\(provider.name): 制限未取得" : "\(provider.name): limits unavailable"
        }
        let kinds = settings(for: provider).limitWindows
        return zip(kinds, windows).map { kind, window in
            guard let window else {
                let title = limitKindTitle(kind, language: language)
                return language == .japanese ? "\(provider.name): \(title)枠は未取得" : "\(provider.name): \(title) unavailable"
            }
            return windowHelp(for: provider, window: window)
        }.joined(separator: "\n")
    }

    private func windowHelp(for provider: Provider, window: LimitWindow) -> String {
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

    init() {
        let credential = OpenCodeGoCredentials.detect()
        openCodeGoKey = credential?.key
        openCodeGoKeySource = credential?.source
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func refresh(manual: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        refreshCodexAccount(force: manual)
        refreshClaudeAccount(force: manual)
        refreshOpenCodeGo(force: manual)
        let selectedPeriod = period
        let selectedMenuBarPeriod = menuBarScanPeriod
        let now = Date()
        let generation = scanGeneration
        // Stream figures while counting only when the screen has nothing for this period yet.
        let streaming = !awaitingProviders.isEmpty || snapshots.isEmpty
        if streaming {
            liveScans = [:]
            countingUsage = true
        }
        let usage = await scanUsage(start: selectedPeriod.start(now: now), now: now, generation: generation,
                                    period: selectedPeriod, streaming: streaming)
        countingUsage = false
        var menuUsage: [Provider: UsageSnapshot] = [:]
        if let selectedMenuBarPeriod {
            menuUsage = await scanUsage(start: selectedMenuBarPeriod.start(now: now), now: now, generation: generation,
                                        period: selectedPeriod, streaming: false)
        }
        // A period selection can change while disk reads are in progress.
        guard selectedPeriod == period, selectedMenuBarPeriod == menuBarScanPeriod, generation == scanGeneration else {
            refreshing = false
            await refresh()
            return
        }
        snapshots = usage
        menuBarSnapshots = menuUsage
        awaitingProviders = []
        liveScans = [:]
        applyOpenCodeGoLimits(to: &snapshots)
        applyOpenCodeGoLimits(to: &menuBarSnapshots)
        mergeCodexAccountLimits()
        mergeClaudeAccountLimits()
        updatedAt = Date()
        bridgeInstalled = BridgeInstaller().installed
    }

    private func scanUsage(start: Date, now: Date, generation: Int, period selectedPeriod: UsagePeriod,
                           streaming: Bool) async -> [Provider: UsageSnapshot] {
        // Both log trees are read at once, so the wait is the slower of the two rather than their sum.
        func progress(for root: Provider) -> (@Sendable ([Provider: UsageSnapshot]) async -> Void)? {
            guard streaming else { return nil }
            return { snapshots in
                await self.applyPartial(snapshots, from: root, generation: generation, period: selectedPeriod)
            }
        }
        async let claude = claudeScanner.scanByEndpoint(
            provider: .claude, root: UsagePaths.claude.appendingPathComponent("projects"),
            start: start, now: now, bridge: UsagePaths.claudeLimits, progress: progress(for: .claude))
        async let codex = codexScanner.scanByEndpoint(
            provider: .codex, root: UsagePaths.codex.appendingPathComponent("sessions"),
            start: start, now: now, progress: progress(for: .codex))
        let (claudeSnapshots, codexSnapshots) = await (claude, codex)
        var merged: [Provider: UsageSnapshot] = [:]
        for snapshots in [claudeSnapshots, codexSnapshots] {
            for (endpoint, snapshot) in snapshots {
                merged[endpoint] = merged[endpoint]?.merging(snapshot) ?? snapshot
            }
        }
        return merged
    }

    /// Shows the figures one log source has counted so far, while the other one is still being read.
    private func applyPartial(_ snapshots: [Provider: UsageSnapshot], from root: Provider,
                              generation: Int, period selectedPeriod: UsagePeriod) {
        guard generation == scanGeneration, selectedPeriod == period else { return }
        liveScans[root] = snapshots
        // Start from the limits already on screen so providers that have not reported yet keep theirs.
        var merged = self.snapshots.mapValues { $0.keepingLimits() }
        for scans in liveScans.values {
            for (endpoint, snapshot) in scans {
                merged[endpoint] = merged[endpoint]?.merging(snapshot) ?? snapshot
            }
        }
        applyKnownLimits(to: &merged)
        self.snapshots = merged
        awaitingProviders.subtract(snapshots.keys)
    }

    /// Account limits come from outside the log scan, so they are kept on figures as they stream in.
    private func applyKnownLimits(to snapshots: inout [Provider: UsageSnapshot]) {
        applyOpenCodeGoLimits(to: &snapshots)
        if let account = codexAccountLimits, var codex = snapshots[.codex] {
            codex.limits = codex.limits?.merging(account) ?? account
            snapshots[.codex] = codex
        }
        if let account = claudeAccountLimits, var claude = snapshots[.claude] {
            claude.limits = claude.limits?.merging(account) ?? account
            snapshots[.claude] = claude
        }
    }

    /// Rollouts record only the pool a session used, so pools such as Luna Reserve come from the app server.
    private func mergeCodexAccountLimits() {
        guard let account = codexAccountLimits, var codex = snapshots[.codex] else { return }
        codex.limits = codex.limits?.merging(account) ?? account
        snapshots[.codex] = codex
    }

    /// The status line only reports while Claude Code responds, so resets in between come from the account.
    private func mergeClaudeAccountLimits() {
        guard let account = claudeAccountLimits, var claude = snapshots[.claude] else { return }
        claude.limits = claude.limits?.merging(account) ?? account
        snapshots[.claude] = claude
    }

    private func refreshClaudeAccount(force: Bool) {
        // Read every 5 minutes like Codex; a failed read keeps the last known value until the next one.
        let now = Date()
        if let last = claudeAccountRequestedAt, now.timeIntervalSince(last) < (force ? 10 : 300) { return }
        claudeAccountRequestedAt = now
        Task {
            guard let limits = await ClaudeAccount.readLimits() else { return }
            claudeAccountLimits = limits
            mergeClaudeAccountLimits()
        }
    }

    private func refreshCodexAccount(force: Bool) {
        // The answer comes from the network: limits are read every 5 minutes, and banked resets, which
        // rarely change, on their own slower schedule when no limits are returned.
        let now = Date()
        if let last = resetCreditsRequestedAt, now.timeIntervalSince(last) < 10 { return }
        if !force, let next = resetCreditsNextFetch, now < next { return }
        resetCreditsRequestedAt = now
        // Until the answer arrives, don't start a second read on the next 30-second tick.
        resetCreditsNextFetch = now.addingTimeInterval(300)
        Task {
            let read = await Task.detached(operation: { CodexAppServer.readAccount() }).value
            let finished = Date()
            switch read.resetCredits {
            case .available(let credits):
                codexResetCredits = credits
                resetCreditsNextFetch = credits.nextFetch(after: finished)
            case .unavailable:
                codexResetCredits = nil
                resetCreditsNextFetch = finished.addingTimeInterval(3600)
            case .failed:
                // Offline, signed out, or Codex missing keeps the last known value; retry sooner.
                resetCreditsNextFetch = finished.addingTimeInterval(300)
            }
            if let limits = read.limits {
                codexAccountLimits = limits
                mergeCodexAccountLimits()
                resetCreditsNextFetch = min(resetCreditsNextFetch ?? .distantFuture, finished.addingTimeInterval(300))
            }
        }
    }

    private func refreshOpenCodeGo(force: Bool) {
        guard let key = openCodeGoKey else { return }
        let now = Date()
        if let last = openCodeGoRequestedAt, now.timeIntervalSince(last) < (force ? 10 : 300) { return }
        if !force, let next = openCodeGoNextFetch, now < next { return }
        openCodeGoRequestedAt = now
        // Until the answer arrives, don't start a second read on the next 30-second tick.
        openCodeGoNextFetch = now.addingTimeInterval(300)
        openCodeGoRefreshing = true
        let generation = openCodeGoGeneration
        Task {
            let read = await OpenCodeGoAccount.readLimits(key: key)
            let finished = Date()
            guard generation == openCodeGoGeneration else { return }
            openCodeGoRefreshing = false
            switch read {
            case .available(let limits):
                openCodeGoStatus = .available
                var snapshot = UsageSnapshot()
                snapshot.endpoint = .openCodeGo
                snapshot.limits = limits
                openCodeGoLastSnapshot = snapshot
                openCodeGoNextFetch = finished.addingTimeInterval(300)
            case .unauthorized:
                openCodeGoStatus = .unauthorized
                openCodeGoLastSnapshot = openCodeGoSnapshot(issue: "OpenCode GoのAPIキーが無効です。")
            case .failed:
                openCodeGoStatus = .failed
                openCodeGoLastSnapshot = openCodeGoSnapshot(issue: "OpenCode Goの利用状況を取得できませんでした。")
            }
            openCodeGoNextFetch = min(openCodeGoNextFetch ?? .distantFuture, finished.addingTimeInterval(300))
            if let account = openCodeGoLastSnapshot {
                // The API only knows limits; keep the token figures the local logs already counted.
                var go = snapshots[.openCodeGo] ?? UsageSnapshot()
                go.endpoint = .openCodeGo
                go.limits = account.limits
                go.issues = account.issues
                snapshots[.openCodeGo] = go
                if var menuGo = menuBarSnapshots[.openCodeGo] {
                    menuGo.endpoint = .openCodeGo
                    menuGo.limits = account.limits
                    menuGo.issues = account.issues
                    menuBarSnapshots[.openCodeGo] = menuGo
                }
            }
        }
    }

    private func openCodeGoSnapshot(issue: String) -> UsageSnapshot {
        var snapshot = openCodeGoLastSnapshot ?? UsageSnapshot()
        snapshot.endpoint = .openCodeGo
        snapshot.issues = [issue]
        return snapshot
    }

    func saveOpenCodeGoKey(_ key: String) throws {
        try OpenCodeGoCredentials.saveToKeychain(key)
        openCodeGoKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        openCodeGoKeySource = .keychain
        openCodeGoLastSnapshot = nil
        openCodeGoStatus = .idle
        var go = snapshots[.openCodeGo] ?? UsageSnapshot()
        go.endpoint = .openCodeGo
        go.limits = nil
        go.issues = []
        snapshots[.openCodeGo] = go
        if var menuGo = menuBarSnapshots[.openCodeGo] {
            menuGo.endpoint = .openCodeGo
            menuGo.limits = nil
            menuGo.issues = []
            menuBarSnapshots[.openCodeGo] = menuGo
        }
        openCodeGoRequestedAt = nil
        openCodeGoNextFetch = nil
        openCodeGoGeneration += 1
        openCodeGoRefreshing = false
        error = nil
        refreshOpenCodeGo(force: true)
    }

    func removeOpenCodeGoKey() {
        OpenCodeGoCredentials.removeFromKeychain()
        let credential = OpenCodeGoCredentials.detect()
        openCodeGoKey = credential?.key
        openCodeGoKeySource = credential?.source
        openCodeGoLastSnapshot = nil
        openCodeGoStatus = .idle
        var go = snapshots[.openCodeGo] ?? UsageSnapshot()
        go.endpoint = .openCodeGo
        go.limits = nil
        go.issues = []
        snapshots[.openCodeGo] = go
        if var menuGo = menuBarSnapshots[.openCodeGo] {
            menuGo.endpoint = .openCodeGo
            menuGo.limits = nil
            menuGo.issues = []
            menuBarSnapshots[.openCodeGo] = menuGo
        }
        openCodeGoRequestedAt = nil
        openCodeGoNextFetch = nil
        openCodeGoGeneration += 1
        openCodeGoRefreshing = false
        if openCodeGoKey != nil { refreshOpenCodeGo(force: true) }
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
