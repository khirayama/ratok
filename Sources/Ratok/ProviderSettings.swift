import Foundation
import UsageCore

/// What one provider shows in the dashboard and the menu bar. How the figures are written
/// (remaining or used, the period, cache) is shared by every provider so the menu bar reads the same.
struct ProviderSettings: Codable, Equatable {
    var visible = true
    var showsName = true
    /// Limit windows shown in the menu bar, in display order. Empty hides the limit.
    var limitWindows: [LimitWindowKind] = [.fiveHour]
    var showsCost = false
    var showsTokens = false

    var showsUsage: Bool { showsCost || showsTokens }

    init() {}

    private enum CodingKeys: String, CodingKey { case visible, showsName, limitWindows, showsCost, showsTokens }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ProviderSettings()
        visible = try values.decodeIfPresent(Bool.self, forKey: .visible) ?? defaults.visible
        showsName = try values.decodeIfPresent(Bool.self, forKey: .showsName) ?? defaults.showsName
        // Unknown kinds from a newer version are dropped rather than discarding the whole setting.
        let kinds = try values.decodeIfPresent([String].self, forKey: .limitWindows)
        limitWindows = kinds.map { $0.compactMap(LimitWindowKind.init(rawValue:)) } ?? defaults.limitWindows
        showsCost = try values.decodeIfPresent(Bool.self, forKey: .showsCost) ?? defaults.showsCost
        showsTokens = try values.decodeIfPresent(Bool.self, forKey: .showsTokens) ?? defaults.showsTokens
    }

    func shows(_ kind: LimitWindowKind) -> Bool { limitWindows.contains(kind) }

    mutating func set(_ kind: LimitWindowKind, shown: Bool) {
        var kinds = Set(limitWindows)
        if shown { kinds.insert(kind) } else { kinds.remove(kind) }
        limitWindows = LimitWindowKind.allCases.filter(kinds.contains)
    }

    private static func key(for provider: Provider) -> String { "providerSettings.\(provider.rawValue)" }

    static func load(for provider: Provider, defaults: UserDefaults = .standard) -> ProviderSettings {
        if let data = defaults.data(forKey: key(for: provider)),
           let settings = try? JSONDecoder().decode(ProviderSettings.self, from: data) {
            return settings
        }
        return legacy(for: provider, defaults: defaults)
    }

    func save(for provider: Provider, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key(for: provider))
    }

    /// Settings from versions that kept one flag per option, so an update keeps the menu bar as it was.
    private static func legacy(for provider: Provider, defaults: UserDefaults) -> ProviderSettings {
        func flag(_ key: String) -> Bool? { defaults.object(forKey: key) as? Bool }
        var settings = ProviderSettings()
        switch provider {
        case .codex:
            settings.visible = flag("showChatGPT") ?? true
            settings.showsName = flag("showChatGPTNameInMenuBar") ?? flag("showCodexNameInMenuBar") ?? true
        case .claude:
            settings.visible = flag("showClaude") ?? true
            settings.showsName = flag("showClaudeNameInMenuBar") ?? true
        case .openCodeGo:
            settings.visible = flag("showOpenCodeGo") ?? true
            settings.showsName = flag("showOpenCodeGoNameInMenuBar") ?? true
        }
        if flag("showLimitsInMenuBar") == false {
            settings.limitWindows = []
        } else if flag("showBothLimitWindowsInMenuBar") == true {
            settings.limitWindows = [.fiveHour, .weekly]
        }
        settings.showsCost = flag("showCostInMenuBar") ?? false
        settings.showsTokens = flag("showTokensInMenuBar") ?? false
        return settings
    }
}

extension Provider {
    /// Limit windows this provider reports and that can be chosen for the menu bar.
    var menuBarLimitKinds: [LimitWindowKind] {
        self == .openCodeGo ? [.fiveHour, .weekly, .monthly] : [.fiveHour, .weekly]
    }
}
