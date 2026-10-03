import AppKit
import SwiftUI
import UsageCore

struct Dashboard: View {
    @Bindable var store: UsageStore
    @ObservedObject var updates: AppUpdater
    @State private var grouping = UsageGrouping.model
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ratok").font(.system(size: 18, weight: .semibold, design: .rounded))
                    Text(localized("Claude CodeとCodexの使用状況", "Claude Code and Codex usage", language: store.language)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await store.refresh() } } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 28, height: 28)
                }.buttonStyle(.borderless).disabled(store.refreshing).help(localized("使用状況を更新", "Refresh usage", language: store.language))
            }
            Picker(localized("集計期間", "Period", language: store.language), selection: $store.period) {
                ForEach(UsagePeriod.allCases) { Text(periodTitle($0, language: store.language)).tag($0) }
            }.pickerStyle(.segmented)
                .onChange(of: store.period) { Task { await store.refresh() } }
            Picker(localized("トークン内訳", "Token breakdown", language: store.language), selection: $grouping) {
                ForEach(UsageGrouping.allCases) { Text(groupingTitle($0, language: store.language)).tag($0) }
            }.pickerStyle(.segmented)
            HStack(alignment: .top, spacing: 10) {
                ForEach([Provider.codex, .claude]) { provider in
                    ProviderCard(provider: provider, snapshot: store.snapshots[provider],
                                 period: store.period, grouping: grouping, language: store.language, bridgeInstalled: store.bridgeInstalled,
                                 connect: store.toggleBridge)
                }
            }
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.red) }
            Text(localized("トークンはこのMacのログから集計（入力はキャッシュ込み）。制限はアカウント全体の最終取得値です。", "Tokens are counted from logs on this Mac (input includes cache). Limits show the latest account-wide values retrieved.", language: store.language))
                .font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            Text(localized("推定コストはAPI標準単価での換算額（USD）。サブスクの請求額とは異なります。", "Estimated cost uses standard API rates (USD); it is not your subscription bill.", language: store.language))
                .font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                .help(pricingAssumptions(language: store.language))
            HStack {
                if store.refreshing {
                    ProgressView().controlSize(.mini)
                    Text(localized("集計中…", "Loading usage…", language: store.language)).font(.caption).foregroundStyle(.secondary)
                } else if let updated = store.updatedAt {
                    Text(localized("更新 \(updated.formatted(date: .omitted, time: .shortened)) · 30秒ごと", "Updated \(updated.formatted(date: .omitted, time: .shortened)) · every 30 sec", language: store.language))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Picker(localized("表示言語", "Language", language: store.language), selection: $store.language) {
                        ForEach(AppLanguage.allCases) { language in Text(language.title).tag(language) }
                    }
                    Divider()
                    Toggle(localized("Codexの文字を表示", "Show Codex label", language: store.language), isOn: $store.showCodexNameInMenuBar)
                    Toggle(localized("CCの文字を表示", "Show CC label", language: store.language), isOn: $store.showClaudeNameInMenuBar)
                    Toggle(localized("5h・週間の両方を表示", "Show both 5h and weekly limits", language: store.language), isOn: $store.showBothLimitWindowsInMenuBar)
                    Picker(localized("割合の表示", "Percentage display", language: store.language), selection: $store.menuBarPercentageMode) {
                        Text(localized("残量", "Remaining", language: store.language)).tag(MenuBarPercentageMode.remaining)
                        Text(localized("使用量", "Used", language: store.language)).tag(MenuBarPercentageMode.used)
                    }
                    Divider()
                    Button(store.bridgeInstalled
                           ? localized("Claude連携を解除", "Disconnect Claude integration", language: store.language)
                           : localized("Claudeの制限表示を接続", "Connect Claude limits", language: store.language), action: store.toggleBridge)
                    Divider()
                    Button(localized("アップデートを確認…", "Check for Updates…", language: store.language), action: updates.checkForUpdates)
                        .disabled(!updates.canCheckForUpdates)
                    Toggle(localized("アップデートを自動確認", "Automatically Check for Updates", language: store.language), isOn: $updates.automaticallyChecksForUpdates)
                        .disabled(!updates.isConfigured)
                    Toggle(localized("アップデートを自動インストール", "Automatically Install Updates", language: store.language), isOn: $updates.automaticallyDownloadsUpdates)
                        .disabled(!updates.isConfigured)
                    if let message = updates.configurationMessage(for: store.language) {
                        Text(message)
                    }
                    Divider()
                    Button(localized("Ratokを終了", "Quit Ratok", language: store.language)) { NSApplication.shared.terminate(nil) }
                } label: { Image(systemName: "gearshape") }.menuStyle(.borderlessButton).fixedSize()
            }
        }
        .padding(14).frame(width: 660)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.locale, store.language.locale)
    }
}

private struct ProviderCard: View {
    let provider: Provider
    let snapshot: UsageSnapshot?
    let period: UsagePeriod
    let grouping: UsageGrouping
    let language: AppLanguage
    let bridgeInstalled: Bool
    let connect: () -> Void
    private var accent: Color { provider == .claude ? Color(red: 0.78, green: 0.43, blue: 0.29) : Color(red: 0.20, green: 0.58, blue: 0.47) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(nsImage: provider.markImage).renderingMode(.template)
                    .resizable().scaledToFit().foregroundStyle(accent)
                    .frame(width: 29, height: 29).background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                Text(provider.name).font(.system(size: 14, weight: .semibold))
                Spacer()
                if let plan = snapshot?.limits?.plan { Text(plan.capitalized).font(.caption).foregroundStyle(.secondary) }
                Text(periodTitle(period, language: language)).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let snapshot {
                HStack(spacing: 0) {
                    TokenMetric(title: localized("入力トークン", "Input tokens", language: language), value: snapshot.tokens.input, color: accent)
                    Spacer()
                    TokenMetric(title: localized("出力トークン", "Output tokens", language: language), value: snapshot.tokens.output, color: .primary)
                }
                HStack {
                    Text(localized("キャッシュ読込 \(compact(snapshot.tokens.cacheRead))", "Cache read \(compact(snapshot.tokens.cacheRead))", language: language))
                    Spacer()
                    Text(localized("書込 \(compact(snapshot.tokens.cacheWrite))", "write \(compact(snapshot.tokens.cacheWrite))", language: language))
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                HStack {
                    Text(localized("API換算 推定コスト", "Estimated API cost", language: language)).font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Text(costText(snapshot.estimatedCost, language: language)).font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
                }.help(pricingAssumptions(language: language))
                Text("\(snapshot.estimatedCost.amountUSD == nil ? localized("未計算", "Not priced", language: language) : localized("* 一部のみ", "* Partial", language: language)) · \(compact(snapshot.estimatedCost.unpricedTokens)) \(localized("tokensは単価未対応", "tokens not priced", language: language))")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .opacity(snapshot.estimatedCost.isPartial ? 1 : 0)
                UsageBreakdownTable(rows: snapshot.breakdown(by: grouping), grouping: grouping, language: language)
                if let source = URL(string: APIPricing.source(for: provider)) {
                    Link(localized("料金表 · \(APIPricing.verifiedOn)確認", "Rates · verified \(APIPricing.verifiedOn)", language: language), destination: source)
                        .font(.system(size: 9))
                }
                Divider()
                HStack {
                    Text(localized("サブスクリプション制限", "Subscription limits", language: language)).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    if let limits = snapshot.limits {
                        HStack(spacing: 3) {
                            Text(localized("取得", "Fetched", language: language))
                            Text(limits.observedAt, style: .relative)
                        }.font(.system(size: 10)).foregroundStyle(.secondary)
                            .help(localized("取得: \(limits.observedAt.formatted())", "Fetched: \(limits.observedAt.formatted())", language: language))
                    }
                }
                if let limits = snapshot.limits, !limits.windows.isEmpty {
                    ForEach(limits.windows) { window in LimitRow(window: window, accent: accent, language: language) }
                    if Date().timeIntervalSince(limits.observedAt) > 300 {
                        Text(localized("過去の取得値です。\(provider.name)の利用時に更新されます。", "This value is from an earlier fetch. It updates when you use \(provider.name).", language: language))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                } else if provider == .claude {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(bridgeInstalled
                             ? localized("接続済み。Claude Codeで次の応答が返ると制限を表示します。プランによっては提供されません。", "Connected. Limits appear after Claude Code's next response; availability depends on your plan.", language: language)
                             : localized("Claude Codeのstatus lineと接続すると、5時間・週間の制限を表示できます。既存の表示は引き継ぎます。", "Connect to the Claude Code status line to show 5-hour and weekly limits. Your existing status line is preserved.", language: language))
                            .font(.caption).foregroundStyle(.secondary)
                        if !bridgeInstalled {
                            Button(localized("Claude Codeと接続", "Connect Claude Code", language: language), action: connect).controlSize(.small)
                        }
                    }
                } else {
                    Text(localized("Codexのログに記録された制限を表示します。追加枠やLuna Reserveは、ログに情報がある場合に別枠で表示します。", "Shows limits recorded in Codex logs. Extra usage and Luna Reserve appear separately when recorded in the logs.", language: language))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(snapshot.issues, id: \.self) { Text(localizedIssue($0, language: language)).font(.caption).foregroundStyle(.orange) }
                if snapshot.files == 0, snapshot.issues.isEmpty {
                    Text(localized("この期間の利用ログはありません。", "No usage logs for this period.", language: language)).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text(localized("ローカルログを集計中…", "Reading local logs…", language: language)).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.055)))
    }
}

private struct UsageBreakdownTable: View {
    let rows: [UsageBreakdown]
    let grouping: UsageGrouping
    let language: AppLanguage
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(groupingTitle(grouping, language: language)).frame(maxWidth: .infinity, alignment: .leading)
                Text(localized("入力", "Input", language: language)).frame(width: 40, alignment: .trailing)
                Text(localized("出力", "Output", language: language)).frame(width: 40, alignment: .trailing)
                Text(localized("推定USD", "Est. USD", language: language)).frame(width: 64, alignment: .trailing)
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            if rows.isEmpty {
                Text(localized("この期間の利用はありません。", "No usage for this period.", language: language))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(height: CGFloat(5 * 24 - 4), alignment: .topLeading)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(rows) { row in
                            HStack(spacing: 6) {
                                Text(title(row.id)).lineLimit(1).truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(compact(row.tokens.input)).frame(width: 40, alignment: .trailing)
                                Text(compact(row.tokens.output)).frame(width: 40, alignment: .trailing)
                                Text(costText(row.cost, language: language)).frame(width: 64, alignment: .trailing)
                            }
                            .font(.system(size: 10)).monospacedDigit().frame(height: 20)
                            .help(localized("\(title(row.id))\n入力: \(row.tokens.input.formatted()) · 出力: \(row.tokens.output.formatted())\nキャッシュ読込: \(row.tokens.cacheRead.formatted()) · 書込: \(row.tokens.cacheWrite.formatted())（うち1時間: \(row.tokens.cacheWrite1h.formatted())）\nAPI換算 推定コスト: \(costText(row.cost, language: language))\n単価未対応: \(row.cost.unpricedTokens.formatted()) tokens\n\(pricingAssumptions(language: language))", "\(title(row.id))\nInput: \(row.tokens.input.formatted()) · Output: \(row.tokens.output.formatted())\nCache read: \(row.tokens.cacheRead.formatted()) · write: \(row.tokens.cacheWrite.formatted()) (including one-hour: \(row.tokens.cacheWrite1h.formatted()))\nEstimated API cost: \(costText(row.cost, language: language))\nUnpriced: \(row.cost.unpricedTokens.formatted()) tokens\n\(pricingAssumptions(language: language))", language: language))
                        }
                    }
                }.frame(height: CGFloat(5 * 24 - 4))
            }
            Text(localized("ログに記録がない項目は「不明」です。", "Items missing from logs are marked Unknown.", language: language))
                .font(.system(size: 9)).foregroundStyle(.secondary)
                .opacity(rows.contains(where: { (grouping != .effort && $0.id.model == nil) || (grouping != .model && $0.id.effort == nil) }) ? 1 : 0)
        }
    }

    private func title(_ group: UsageGroup) -> String {
        switch grouping {
        case .model: group.model ?? localized("不明", "Unknown", language: language)
        case .effort: group.effort ?? localized("不明", "Unknown", language: language)
        case .modelAndEffort: "\(group.model ?? localized("不明", "Unknown", language: language)) · \(group.effort ?? localized("不明", "Unknown", language: language))"
        }
    }
}

private struct TokenMetric: View {
    let title: String
    let value: Int
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(compact(value)).font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit().foregroundStyle(color)
        }.help(value.formatted() + " tokens")
    }
}

private struct LimitRow: View {
    let window: LimitWindow
    let accent: Color
    let language: AppLanguage
    private var expired: Bool { window.expired(at: Date()) }
    private var color: Color { window.usedPercent >= 90 ? .red : window.usedPercent >= 75 ? .orange : accent }
    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text(localizedWindowTitle(window, language: language)).font(.caption)
                Spacer()
                Text(expired
                     ? localized("再取得待ち", "Waiting for refresh", language: language)
                     : localized("\(window.usedPercent.formatted(.number.precision(.fractionLength(0...1))))% 使用", "\(window.usedPercent.formatted(.number.precision(.fractionLength(0...1))))% used", language: language))
                    .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(expired ? .secondary : color)
            }
            GeometryReader { geometry in
                Capsule().fill(color.opacity(0.12))
                    .overlay(alignment: .leading) {
                        Capsule().fill(color)
                            .frame(width: geometry.size.width * (expired ? 0 : min(max(window.usedPercent, 0), 100) / 100))
                    }
            }.frame(height: 4)
                .opacity(expired ? 0.35 : 1)
                .accessibilityLabel(localized("\(window.title)の使用率", "\(localizedWindowTitle(window, language: language)) usage", language: language))
                .accessibilityValue(expired ? localized("再取得待ち", "Waiting for refresh", language: language) : "\(window.usedPercent.formatted())%")
            if let reset = window.resetsAt {
                HStack {
                    Text(expired
                         ? localized("リセット時刻を過ぎています", "Reset time has passed", language: language)
                         : localized("リセット \(reset.formatted(.dateTime.month().day().hour().minute().locale(language.locale)))", "Resets \(reset.formatted(.dateTime.month().day().hour().minute().locale(language.locale)))", language: language))
                    Spacer()
                    if !expired { Text(reset, style: .relative) }
                }.font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
}

private func periodTitle(_ period: UsagePeriod, language: AppLanguage) -> String {
    switch period {
    case .today: localized("今日", "Today", language: language)
    case .week: localized("7日間", "7 days", language: language)
    case .month: localized("30日間", "30 days", language: language)
    }
}

private func groupingTitle(_ grouping: UsageGrouping, language: AppLanguage) -> String {
    switch grouping {
    case .model: localized("モデル別", "By model", language: language)
    case .effort: localized("effort別", "By effort", language: language)
    case .modelAndEffort: localized("モデル×effort", "Model × effort", language: language)
    }
}

private func costText(_ cost: CostEstimate, language: AppLanguage) -> String {
    if cost.amountUSD == nil && language == .english { return "Unpriced" }
    return cost.displayText
}

private func localizedIssue(_ issue: String, language: AppLanguage) -> String {
    guard language == .english else { return issue }
    return switch issue {
    case "一部の利用ログを読み取れませんでした。": "Some usage logs could not be read."
    case "一部のログにアクセスできません。": "Some logs could not be accessed."
    case "一部のフォルダにアクセスできません。": "Some folders could not be accessed."
    default: issue
    }
}

private func compact(_ value: Int) -> String {
    value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(Locale(identifier: "en_US")))
}
