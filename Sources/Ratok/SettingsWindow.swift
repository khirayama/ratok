import AppKit
import SwiftUI
import UsageCore

/// A regular window so settings stay open while several of them are changed. The app has no Dock icon,
/// so the window is managed here and the app is brought forward when it opens.
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(store: UsageStore, updates: AppUpdater) {
        if window == nil {
            let controller = NSHostingController(rootView: SettingsView(store: store, updates: updates))
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        updateTitle(language: store.language)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func updateTitle(language: AppLanguage) {
        window?.title = localized("Ratokの設定", "Ratok Settings", language: language)
    }
}

private enum SettingsTab: Hashable {
    case general
    case provider(Provider)
}

struct SettingsView: View {
    @Bindable var store: UsageStore
    @ObservedObject var updates: AppUpdater
    @State private var tab = SettingsTab.general

    var body: some View {
        VStack(spacing: 0) {
            MenuBarPreview(store: store)
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
            TabView(selection: $tab) {
                GeneralSettings(store: store, updates: updates)
                    .tabItem { Text(localized("一般", "General", language: store.language)) }
                    .tag(SettingsTab.general)
                ForEach(Provider.menuBarOrder) { provider in
                    ProviderSettingsView(store: store, provider: provider)
                        .tabItem { Text(provider.name) }
                        .tag(SettingsTab.provider(provider))
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 12)
        }
        .frame(width: 520, height: 560)
        .environment(\.locale, store.language.locale)
        .onChange(of: store.language) { SettingsWindowController.shared.updateTitle(language: store.language) }
    }
}

/// The menu bar item as it looks now, so each change can be seen without looking up.
private struct MenuBarPreview: View {
    let store: UsageStore
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localized("メニューバーのプレビュー", "Menu bar preview", language: store.language))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                // The template image takes the window's text color here, as it takes the menu bar's there.
                Image(nsImage: MenuBarLabel(store: store).image)
                    .renderingMode(.template).foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        }
    }
}

private struct GeneralSettings: View {
    @Bindable var store: UsageStore
    @ObservedObject var updates: AppUpdater
    private var language: AppLanguage { store.language }

    var body: some View {
        Form {
            Picker(localized("表示言語", "Language", language: language), selection: $store.language) {
                ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
            }
            Section {
                Picker(localized("制限の割合", "Limit percentage", language: language), selection: $store.menuBarPercentageMode) {
                    Text(localized("残量", "Remaining", language: language)).tag(MenuBarPercentageMode.remaining)
                    Text(localized("使用量", "Used", language: language)).tag(MenuBarPercentageMode.used)
                }.pickerStyle(.segmented)
                Toggle(localized("割合に%記号を付ける", "Show % sign", language: language),
                       isOn: $store.showsMenuBarPercentSign)
                Picker(localized("コスト・トークンの期間", "Cost and token period", language: language), selection: $store.menuBarPeriod) {
                    ForEach(UsagePeriod.allCases) { Text(periodTitle($0, language: language)).tag($0) }
                }
                Toggle(localized("トークン量にキャッシュを含める", "Include cache in token count", language: language),
                       isOn: $store.includeCacheInMenuBarTokens)
            } header: {
                Text(localized("メニューバー（全プロバイダー共通）", "Menu bar (all providers)", language: language))
            } footer: {
                Text(localized("何を表示するかは各プロバイダーのタブで選びます。", "Choose what each provider shows in its own tab.", language: language))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(localized("アップデート", "Updates", language: language)) {
                Toggle(localized("アップデートを自動確認", "Automatically check for updates", language: language),
                       isOn: $updates.automaticallyChecksForUpdates)
                    .disabled(!updates.isConfigured)
                Toggle(localized("アップデートを自動インストール", "Automatically install updates", language: language),
                       isOn: $updates.automaticallyDownloadsUpdates)
                    .disabled(!updates.isConfigured)
                HStack {
                    if let message = updates.configurationMessage(for: language) {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(localized("今すぐ確認…", "Check now…", language: language), action: updates.checkForUpdates)
                        .disabled(!updates.canCheckForUpdates)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ProviderSettingsView: View {
    @Bindable var store: UsageStore
    let provider: Provider
    private var language: AppLanguage { store.language }
    private var settings: ProviderSettings { store.settings(for: provider) }

    private func binding<Value>(_ keyPath: WritableKeyPath<ProviderSettings, Value>) -> Binding<Value> {
        Binding(get: { store.settings(for: provider)[keyPath: keyPath] },
                set: { value in store.updateSettings(for: provider) { $0[keyPath: keyPath] = value } })
    }

    private func limitBinding(_ kind: LimitWindowKind) -> Binding<Bool> {
        Binding(get: { store.settings(for: provider).shows(kind) },
                set: { shown in store.updateSettings(for: provider) { $0.set(kind, shown: shown) } })
    }

    var body: some View {
        Form {
            Section {
                Toggle(localized("ダッシュボードとメニューバーに表示", "Show in dashboard and menu bar", language: language),
                       isOn: binding(\.visible))
            }
            Section {
                Toggle(localized("名称「\(provider.menuBarName)」", "Name “\(provider.menuBarName)”", language: language),
                       isOn: binding(\.showsName))
                LabeledContent(localized("制限の割合", "Limit percentage", language: language)) {
                    HStack(spacing: 12) {
                        ForEach(provider.menuBarLimitKinds) { kind in
                            Toggle(limitKindTitle(kind, language: language), isOn: limitBinding(kind))
                                .toggleStyle(.checkbox)
                        }
                    }
                }
                Toggle(localized("推定コスト（API換算）", "Estimated cost (API rates)", language: language),
                       isOn: binding(\.showsCost))
                Toggle(localized("トークン量", "Token count", language: language), isOn: binding(\.showsTokens))
            } header: {
                Text(localized("メニューバーに表示する項目", "Shown in the menu bar", language: language))
            } footer: {
                Text(menuBarFootnote).font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!settings.visible)
            connection
        }
        .formStyle(.grouped)
    }

    private var menuBarFootnote: String {
        let multiple = localized("複数の枠を選ぶと「5時間/週間」の順に並べて表示します。",
                                 "Several windows are shown in order, such as 5-hour/weekly.", language: language)
        switch provider {
        case .codex:
            return multiple + localized("選んだ枠をプランが提供しない場合は、提供されている枠を表示します。",
                                        " If your plan has none of the chosen windows, the one it has is shown.", language: language)
        case .claude:
            return multiple
        case .openCodeGo:
            return multiple + localized("APIキーが見つかるまでメニューバーには表示されません。",
                                        " OpenCode Go stays out of the menu bar until an API key is found.", language: language)
        }
    }

    @ViewBuilder private var connection: some View {
        switch provider {
        case .codex:
            Section(localized("データ", "Data", language: language)) {
                Text(localized("トークンは~/.codex/sessionsのログから、制限とリセット権はCodex CLIから取得します。設定は不要です。",
                               "Tokens come from logs in ~/.codex/sessions; limits and banked resets come from the Codex CLI. No setup needed.",
                               language: language))
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .claude:
            Section(localized("Claude Code連携", "Claude Code integration", language: language)) {
                LabeledContent(localized("状態", "Status", language: language)) {
                    Text(store.bridgeInstalled
                         ? localized("接続済み", "Connected", language: language)
                         : localized("未接続", "Not connected", language: language))
                }
                HStack {
                    Text(localized("status lineから制限を受け取ります。既存のstatus lineはそのまま動作します。",
                                   "Limits arrive through the status line; your existing status line keeps working.",
                                   language: language))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(store.bridgeInstalled
                           ? localized("解除", "Disconnect", language: language)
                           : localized("接続", "Connect", language: language), action: store.toggleBridge)
                }
                if let error = store.error { Text(error).font(.caption).foregroundStyle(.red) }
            }
        case .openCodeGo:
            Section(localized("APIキー", "API key", language: language)) {
                OpenCodeGoKeySettings(store: store)
            }
        }
    }
}

private struct OpenCodeGoKeySettings: View {
    let store: UsageStore
    @State private var editing = false
    private var language: AppLanguage { store.language }

    var body: some View {
        if editing {
            OpenCodeGoKeyEditor(store: store) { editing = false }
        } else {
            LabeledContent(localized("状態", "Status", language: language)) {
                Text(openCodeGoSourceTitle(store.openCodeGoKeySource, language: language))
            }
            HStack {
                Text(localized("キーはKeychainに保存し、使用率の取得にのみ使います。",
                               "The key is stored in Keychain and only used to read usage.", language: language))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if store.openCodeGoUsesSavedKey {
                    Button(localized("削除", "Remove", language: language), role: .destructive) { store.removeOpenCodeGoKey() }
                }
                Button(store.openCodeGoKeyConfigured
                       ? localized("変更…", "Change…", language: language)
                       : localized("設定…", "Set…", language: language)) { editing = true }
            }
        }
    }
}

extension Provider {
    /// The order providers appear in the menu bar, the dashboard, and settings.
    static let menuBarOrder: [Provider] = [.codex, .claude, .openCodeGo]
}
