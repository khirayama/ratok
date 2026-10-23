import Foundation

import UsageCore

enum AppLanguage: String, CaseIterable, Identifiable {
    case japanese = "ja"
    case english = "en"

    var id: String { rawValue }
    var locale: Locale { Locale(identifier: self == .japanese ? "ja_JP" : "en_US") }
    var title: String { self == .japanese ? "日本語" : "English" }
}

func localized(_ japanese: String, _ english: String, language: AppLanguage) -> String {
    language == .japanese ? japanese : english
}

func localizedWindowTitle(_ window: LimitWindow, language: AppLanguage) -> String {
    guard language == .english else { return window.title }
    switch window.id {
    case "primary", "five_hour", "5h": return "5-hour"
    case "secondary", "weekly", "7d": return "Weekly"
    default:
        if window.title == "5時間" { return "5-hour" }
        if window.title == "週間" { return "Weekly" }
        if window.title == "追加利用" { return "Extra usage" }
        if window.title.hasSuffix(" · 5時間") { return window.title.dropLast(3) + "5-hour" }
        if window.title.hasSuffix(" · 週間") { return window.title.dropLast(2) + "Weekly" }
        return window.title
    }
}

func periodTitle(_ period: UsagePeriod, language: AppLanguage) -> String {
    switch period {
    case .today: localized("今日", "Today", language: language)
    case .week: localized("7日間", "7 days", language: language)
    case .month: localized("30日間", "30 days", language: language)
    case .thisMonth: localized("今月", "This month", language: language)
    }
}

func compact(_ value: Int) -> String {
    value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(Locale(identifier: "en_US")))
}

func pricingAssumptions(language: AppLanguage) -> String {
    localized(
        APIPricing.assumptions,
        "Estimated USD at standard API rates, not subscription charges. Uses standard short-context rates; excludes Fast, long-context, and regional surcharges, Batch discounts, tool fees, and taxes. Claude usage through cloud providers is estimated at Anthropic rates. Claude cache writes are split by one-hour retention when logged; writes without a recorded retention time use the five-minute rate. Models that require dedicated image or audio usage details are excluded. Rates verified on \(APIPricing.verifiedOn); updated with app releases.",
        language: language
    )
}
