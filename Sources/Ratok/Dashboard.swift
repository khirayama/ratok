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
                    Text("Claude CodeとCodexの使用状況").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await store.refresh() } } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 28, height: 28)
                }.buttonStyle(.borderless).disabled(store.refreshing).help("使用状況を更新")
            }
            Picker("集計期間", selection: $store.period) {
                ForEach(UsagePeriod.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
                .onChange(of: store.period) { Task { await store.refresh() } }
            Picker("トークン内訳", selection: $grouping) {
                ForEach(UsageGrouping.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            HStack(alignment: .top, spacing: 10) {
                ForEach([Provider.codex, .claude]) { provider in
                    ProviderCard(provider: provider, snapshot: store.snapshots[provider],
                                 period: store.period, grouping: grouping, bridgeInstalled: store.bridgeInstalled,
                                 connect: store.toggleBridge)
                }
            }
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.red) }
            Text("トークンはこのMacのログから集計（入力はキャッシュ込み）。制限はアカウント全体の最終取得値です。")
                .font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            Text("推定コストはAPI標準単価での換算額（USD）。サブスクの請求額とは異なります。")
                .font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                .help(APIPricing.assumptions)
            HStack {
                if store.refreshing {
                    ProgressView().controlSize(.mini)
                    Text("集計中…").font(.caption).foregroundStyle(.secondary)
                } else if let updated = store.updatedAt {
                    Text("更新 \(updated.formatted(date: .omitted, time: .shortened)) · 30秒ごと")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button(store.bridgeInstalled ? "Claude連携を解除" : "Claudeの制限表示を接続", action: store.toggleBridge)
                    Divider()
                    Button("アップデートを確認…", action: updates.checkForUpdates)
                        .disabled(!updates.canCheckForUpdates)
                    Toggle("アップデートを自動確認", isOn: $updates.automaticallyChecksForUpdates)
                        .disabled(!updates.isConfigured)
                    Toggle("アップデートを自動インストール", isOn: $updates.automaticallyDownloadsUpdates)
                        .disabled(!updates.isConfigured)
                    if let message = updates.configurationMessage {
                        Text(message)
                    }
                    Divider()
                    Button("Ratokを終了") { NSApplication.shared.terminate(nil) }
                } label: { Image(systemName: "gearshape") }.menuStyle(.borderlessButton).fixedSize()
            }
        }
        .padding(14).frame(width: 660)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.locale, Locale(identifier: "ja_JP"))
    }
}

private struct ProviderCard: View {
    let provider: Provider
    let snapshot: UsageSnapshot?
    let period: UsagePeriod
    let grouping: UsageGrouping
    let bridgeInstalled: Bool
    let connect: () -> Void
    private var accent: Color { provider == .claude ? Color(red: 0.78, green: 0.43, blue: 0.29) : Color(red: 0.20, green: 0.58, blue: 0.47) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: provider.symbolName)
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(accent)
                    .frame(width: 29, height: 29).background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                Text(provider.name).font(.system(size: 14, weight: .semibold))
                Spacer()
                if let plan = snapshot?.limits?.plan { Text(plan.capitalized).font(.caption).foregroundStyle(.secondary) }
                Text(period.title).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let snapshot {
                HStack(spacing: 0) {
                    TokenMetric(title: "入力トークン", value: snapshot.tokens.input, color: accent)
                    Spacer()
                    TokenMetric(title: "出力トークン", value: snapshot.tokens.output, color: .primary)
                }
                HStack {
                    Text("キャッシュ読込 \(compact(snapshot.tokens.cacheRead))")
                    Spacer()
                    Text("書込 \(compact(snapshot.tokens.cacheWrite))")
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                HStack {
                    Text("API換算 推定コスト").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Text(snapshot.estimatedCost.displayText).font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
                }.help(APIPricing.assumptions)
                if snapshot.estimatedCost.isPartial {
                    Text("\(snapshot.estimatedCost.amountUSD == nil ? "未計算" : "* 一部のみ") · \(compact(snapshot.estimatedCost.unpricedTokens)) tokensは単価未対応")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                UsageBreakdownTable(rows: snapshot.breakdown(by: grouping), grouping: grouping)
                if let source = URL(string: APIPricing.source(for: provider)) {
                    Link("料金表 · \(APIPricing.verifiedOn)確認", destination: source)
                        .font(.system(size: 9))
                }
                Divider()
                HStack {
                    Text("サブスクリプション制限").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    if let limits = snapshot.limits {
                        HStack(spacing: 3) {
                            Text("取得")
                            Text(limits.observedAt, style: .relative)
                        }.font(.system(size: 10)).foregroundStyle(.secondary)
                            .help("取得: \(limits.observedAt.formatted())")
                    }
                }
                if let limits = snapshot.limits, !limits.windows.isEmpty {
                    ForEach(limits.windows) { window in LimitRow(window: window, accent: accent) }
                    if Date().timeIntervalSince(limits.observedAt) > 300 {
                        Text("過去の取得値です。\(provider.name)の利用時に更新されます。")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                } else if provider == .claude {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(bridgeInstalled ? "接続済み。Claude Codeで次の応答が返ると制限を表示します。プランによっては提供されません。" : "Claude Codeのstatus lineと接続すると、5時間・週間の制限を表示できます。既存の表示は引き継ぎます。")
                            .font(.caption).foregroundStyle(.secondary)
                        if !bridgeInstalled {
                            Button("Claude Codeと接続", action: connect).controlSize(.small)
                        }
                    }
                } else {
                    Text("Codexのログに記録された制限を表示します。追加枠やLuna Reserveは、ログに情報がある場合に別枠で表示します。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(snapshot.issues, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                if snapshot.files == 0, snapshot.issues.isEmpty {
                    Text("この期間の利用ログはありません。").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text("ローカルログを集計中…").font(.caption).foregroundStyle(.secondary) }
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
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(grouping.title).frame(maxWidth: .infinity, alignment: .leading)
                Text("入力").frame(width: 40, alignment: .trailing)
                Text("出力").frame(width: 40, alignment: .trailing)
                Text("推定USD").frame(width: 64, alignment: .trailing)
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            if rows.isEmpty {
                Text("この期間の利用はありません。").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(rows) { row in
                            HStack(spacing: 6) {
                                Text(title(row.id)).lineLimit(1).truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(compact(row.tokens.input)).frame(width: 40, alignment: .trailing)
                                Text(compact(row.tokens.output)).frame(width: 40, alignment: .trailing)
                                Text(row.cost.displayText).frame(width: 64, alignment: .trailing)
                            }
                            .font(.system(size: 10)).monospacedDigit().frame(height: 20)
                            .help("\(title(row.id))\n入力: \(row.tokens.input.formatted()) · 出力: \(row.tokens.output.formatted())\nキャッシュ読込: \(row.tokens.cacheRead.formatted()) · 書込: \(row.tokens.cacheWrite.formatted())（うち1時間: \(row.tokens.cacheWrite1h.formatted())）\nAPI換算 推定コスト: \(row.cost.displayText)\n単価未対応: \(row.cost.unpricedTokens.formatted()) tokens\n\(APIPricing.assumptions)")
                        }
                    }
                }.frame(height: CGFloat(min(rows.count, 5) * 24 - 4))
                if rows.contains(where: { (grouping != .effort && $0.id.model == nil) || (grouping != .model && $0.id.effort == nil) }) {
                    Text("ログに記録がない項目は「不明」です。")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func title(_ group: UsageGroup) -> String {
        switch grouping {
        case .model: group.model ?? "不明"
        case .effort: group.effort ?? "不明"
        case .modelAndEffort: "\(group.model ?? "不明") · \(group.effort ?? "不明")"
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
    private var expired: Bool { window.expired(at: Date()) }
    private var color: Color { window.usedPercent >= 90 ? .red : window.usedPercent >= 75 ? .orange : accent }
    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text(window.title).font(.caption)
                Spacer()
                Text(expired ? "再取得待ち" : "\(window.usedPercent.formatted(.number.precision(.fractionLength(0...1))))% 使用")
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
                .accessibilityLabel("\(window.title)の使用率")
                .accessibilityValue(expired ? "再取得待ち" : "\(window.usedPercent.formatted())%")
            if let reset = window.resetsAt {
                HStack {
                    Text(expired ? "リセット時刻を過ぎています" : "リセット \(reset.formatted(.dateTime.month().day().hour().minute().locale(Locale(identifier: "ja_JP"))))")
                    Spacer()
                    if !expired { Text(reset, style: .relative) }
                }.font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
}

private func compact(_ value: Int) -> String {
    value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(Locale(identifier: "en_US")))
}
