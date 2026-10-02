import Foundation
import Observation
import UsageCore

@Observable
final class UsageStore {
    var language: AppLanguage = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "ja") ?? .japanese {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "appLanguage") }
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

    func menuRemainingText(for provider: Provider) -> String {
        let window = snapshots[provider]?.limits?.menuBarWindow
        let remaining = provider == .claude
            ? window?.lastKnownRemainingPercent
            : window?.remainingPercent(at: Date())
        guard let remaining else { return "—" }
        return "\(Int(remaining.rounded()))%"
    }

    func menuHelp(for provider: Provider) -> String {
        guard let window = snapshots[provider]?.limits?.menuBarWindow else {
            return language == .japanese ? "\(provider.name): 制限未取得" : "\(provider.name): limits unavailable"
        }
        let title = localizedWindowTitle(window, language: language)
        if provider == .claude {
            if language == .english {
                let status = window.expired(at: Date()) ? " (reset; waiting for refresh)" : ""
                return "\(provider.name): \(title) remaining at last fetch \(menuRemainingText(for: provider))\(status)"
            }
            let status = window.expired(at: Date()) ? "（リセット済み・再取得待ち）" : ""
            return "\(provider.name): \(title)枠の最終取得残量 \(menuRemainingText(for: provider))\(status)"
        }
        if window.expired(at: Date()) {
            return language == .japanese ? "\(provider.name): \(title)枠の再取得待ち" : "\(provider.name): \(title) waiting for refresh"
        }
        return language == .japanese ? "\(provider.name): \(title)枠の残量 \(menuRemainingText(for: provider))" : "\(provider.name): \(title) remaining \(menuRemainingText(for: provider))"
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
