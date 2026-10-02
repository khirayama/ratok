import Foundation
import Testing

// Official current text-model inventories, checked on 2026-10-02.
@Test(arguments: [
    "gpt-6-astra", "gpt-6.1-sol", "gpt-6-sol", "gpt-6-luna",
    "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.6-cyber",
    "gpt-5.5", "gpt-5.5-pro", "gpt-5.4", "gpt-5.4-pro", "gpt-5.4-mini",
    "gpt-5.2", "gpt-5.2-pro", "gpt-5", "gpt-5-pro", "gpt-5-mini", "gpt-5-nano",
    "gpt-4.1", "gpt-4.1-mini", "gpt-4o", "gpt-4o-mini", "o3", "o3-pro",
    "gpt-5-search-api", "gpt-rosalind-research", "chat-latest",
    "claude-fable-5-1", "claude-mythos-5-1", "claude-fable-5", "claude-mythos-5",
    "claude-opus-5-5", "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7",
    "claude-opus-4-6", "claude-opus-4-5-20251101", "claude-sonnet-5-5",
    "claude-sonnet-5", "claude-sonnet-4-6", "claude-haiku-4-5-20251001",
    // Deprecated but still available models in the Claude status table.
    "claude-sonnet-4-5-20250929", "claude-mythos-preview"
])
func currentPublicTextModelsHaveKnownPrices(model: String) throws {
    let estimate = APIPricing.estimate(model: model, tokens: TokenUsage(input: 1_000, output: 100))
    #expect(try #require(estimate.amountUSD) > 0)
    #expect(estimate.pricedTokens == 1_100)
    #expect(estimate.unpricedTokens == 0)
}

@Test(arguments: [("claude-fable-5-1", 92.75), ("claude-mythos-5-1", 92.75),
                  ("claude-fable-5", 93.50), ("claude-mythos-5", 93.50),
                  ("claude-mythos-preview", 233.75), ("claude-opus-4-7", 46.75),
                  ("claude-sonnet-4-6", 28.05)])
func additionalClaudeModelsPriceBothCacheDurations(model: String, expectedUSD: Double) throws {
    let tokens = TokenUsage(input: 4_000_000, output: 1_000_000, cacheRead: 1_000_000,
                            cacheWrite: 2_000_000, cacheWrite1h: 1_000_000)
    let estimate = APIPricing.estimate(model: model, tokens: tokens)
    #expect(abs(try #require(estimate.amountUSD) - expectedUSD) < 0.000001)
}

@Test(arguments: [
    ("anthropic.claude-opus-5-5", "claude-opus-5-5"),
    ("anthropic.claude-opus-4-6-v1", "claude-opus-4-6"),
    ("anthropic.claude-sonnet-4-5-20250929-v1:0", "claude-sonnet-4-5"),
    ("claude-haiku-4-5@20251001", "claude-haiku-4-5")
])
func officialClaudeCloudIDsUseTheSameAPIEquivalent(model: String, canonical: String) {
    let tokens = TokenUsage(input: 10_000, output: 1_000, cacheRead: 1_000, cacheWrite: 1_000)
    let estimate = APIPricing.estimate(model: model, tokens: tokens)
    #expect(!estimate.isPartial)
    #expect(estimate == APIPricing.estimate(model: canonical, tokens: tokens))
}

@Test func oldSnapshotsAndFreeModelsKeepTheirOwnPublishedRates() {
    let tokens = TokenUsage(input: 2_000_000, output: 1_000_000, cacheRead: 1_000_000)
    #expect(APIPricing.estimate(model: "gpt-4o-2024-05-13", tokens: tokens).amountUSD == 25)
    #expect(APIPricing.estimate(model: "gpt-4o-2024-08-06", tokens: tokens).amountUSD == 13.75)
    #expect(APIPricing.estimate(model: "gpt-3.5-turbo-1106", tokens: tokens).amountUSD == 4)
    #expect(APIPricing.estimate(model: "gpt-4-0125-preview", tokens: tokens).amountUSD == 50)
    #expect(APIPricing.estimate(model: "text-embedding-3-small", tokens: TokenUsage(input: 1_000_000)).amountUSD == 0.02)
    let moderation = APIPricing.estimate(model: "omni-moderation-latest", tokens: tokens)
    #expect(moderation.amountUSD == 0)
    #expect(moderation.pricedTokens == tokens.total)
    #expect(!moderation.isPartial)
}
@testable import UsageCore

@Test func claudePricesEachCacheCategoryWithoutCountingItAsOrdinaryInput() {
    let tokens = TokenUsage(input: 4_000_000, output: 1_000_000, cacheRead: 1_000_000,
                            cacheWrite: 2_000_000, cacheWrite1h: 1_000_000)
    let estimate = APIPricing.estimate(model: "claude-opus-5-5", tokens: tokens)
    // $4 input + $20 output + $0.20 read + $5 five-minute write + $8 one-hour write.
    #expect(abs(estimate.subtotalUSD - 37.20) < 0.000001)
    #expect(estimate.pricedTokens == 5_000_000)
    #expect(!estimate.isPartial)
    #expect(estimate.displayText == "$37.20")
}

@Test func codexPricesCacheReadsAndWritesSeparately() {
    let tokens = TokenUsage(input: 2_000_000, output: 1_000_000, cacheRead: 500_000, cacheWrite: 500_000)
    let estimate = APIPricing.estimate(model: "gpt-6.1-sol", tokens: tokens)
    #expect(abs(estimate.subtotalUSD - 13.30) < 0.000001)
}

@Test(arguments: [("gpt-6-astra", 73.50), ("gpt-6-sol", 14.70),
                  ("gpt-6.1-sol", 14.60), ("gpt-6-luna", 0.735)])
func gpt6ModelsUseDistinctRatesIncludingSolCacheDiscount(model: String, expectedUSD: Double) throws {
    let tokens = TokenUsage(input: 3_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheWrite: 1_000_000)
    let estimate = APIPricing.estimate(model: model, tokens: tokens)
    #expect(abs(try #require(estimate.amountUSD) - expectedUSD) < 0.000001)
    #expect(!estimate.isPartial)
}

@Test(arguments: [("gpt-5.5", 35.50), ("gpt-5.4-mini", 5.325),
                  ("gpt-5.1-codex-mini", 2.275), ("gpt-5.3-codex", 15.925),
                  ("codex-mini-latest", 7.875)])
func earlierCodexModelsRetainTheirPublishedStandardRates(model: String, expectedUSD: Double) throws {
    let estimate = APIPricing.estimate(model: model,
        tokens: TokenUsage(input: 2_000_000, output: 1_000_000, cacheRead: 1_000_000))
    #expect(abs(try #require(estimate.amountUSD) - expectedUSD) < 0.000001)
    #expect(!estimate.isPartial)
}

@Test(arguments: [("gpt-5-pro", 165.0), ("gpt-5.2-pro", 231.0),
                  ("gpt-5.4-pro", 270.0), ("gpt-5.5-pro", 270.0)])
func proModelsDoNotInventCacheDiscounts(model: String, expectedUSD: Double) {
    let estimate = APIPricing.estimate(model: model,
        tokens: TokenUsage(input: 3_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheWrite: 1_000_000))
    #expect(estimate.amountUSD == expectedUSD)
}

@Test(arguments: [("gpt-daybreak-blue-latest", "gpt-5.6-sol"),
                  ("gpt-daybreak-red-latest", "gpt-5.6-cyber")])
func publishedDaybreakAliasesUseTheirVerifiedTargets(alias: String, target: String) {
    let tokens = TokenUsage(input: 2_000_000, output: 1_000_000, cacheRead: 1_000_000)
    let estimate = APIPricing.estimate(model: alias, tokens: tokens)
    #expect(!estimate.isPartial)
    #expect(estimate == APIPricing.estimate(model: target, tokens: tokens))
}

@Test(arguments: [
    ("gpt-5.6", 29.40),
    ("gpt-5.6-sol", 29.40),
    ("gpt-5.6-terra", 16.70),
    ("gpt-5.6-luna", 1.67),
    ("gpt-5.6-cyber", 104.375)
])
func gpt56ModelsUseTheirOwnRatesIncludingCaches(model: String, expectedUSD: Double) throws {
    // One million tokens in each category: ordinary input, read, write, output.
    let tokens = TokenUsage(input: 3_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheWrite: 1_000_000)
    let estimate = APIPricing.estimate(model: model, tokens: tokens)
    #expect(abs(try #require(estimate.amountUSD) - expectedUSD) < 0.000001)
    #expect(estimate.pricedTokens == 4_000_000)
    #expect(!estimate.isPartial)
}

@Test func effortCostsCombineModelPricesAndKeepUnknownUsageVisible() throws {
    var snapshot = UsageSnapshot()
    snapshot.usageByGroup = [
        UsageGroup(model: "claude-opus-5-5", effort: "high"): TokenUsage(input: 1_000_000, output: 1_000_000),
        UsageGroup(model: "gpt-6.1-sol", effort: "high"): TokenUsage(input: 1_000_000, output: 1_000_000),
        UsageGroup(effort: "high"): TokenUsage(input: 100),
        UsageGroup(model: "gpt-6-luna", effort: "low"): TokenUsage(input: 1_000_000)
    ]
    snapshot.tokens = snapshot.usageByGroup.values.reduce(TokenUsage(), +)
    let overall = snapshot.estimatedCost
    #expect(abs(overall.subtotalUSD - 36.10) < 0.000001)
    #expect(overall.unpricedTokens == 100)
    #expect(overall.isPartial)
    #expect(overall.displayText == "$36.10*")
    let high = try #require(snapshot.breakdown(by: .effort).first { $0.id.effort == "high" })
    #expect(high.cost.subtotalUSD == 36)
    #expect(high.cost.unpricedTokens == 100)
    for grouping in UsageGrouping.allCases {
        let sum = snapshot.breakdown(by: grouping).reduce(CostEstimate()) { $0 + $1.cost }
        #expect(abs(sum.subtotalUSD - overall.subtotalUSD) < 0.000001)
        #expect(sum.unpricedTokens == overall.unpricedTokens)
        #expect(sum.pricedTokens == overall.pricedTokens)
    }
}

@Test(arguments: [nil, "gpt-reserve", "codex-auto-review", "gpt-6.1-sol-pro", "gpt-6-astra-new", "gpt-5.6-pro", "gpt-5.6-luna-new", "claude-opus-5-5-new", "anthropic.claude-opus-5-5-new-v1:0", "gpt-live-1", "gpt-image-2.5-sunburst"] as [String?])
func unlistedModelsAreUnavailableInsteadOfFree(model: String?) {
    let estimate = APIPricing.estimate(model: model, tokens: TokenUsage(input: 1_000, output: 100))
    #expect(estimate.amountUSD == nil)
    #expect(estimate.unpricedTokens == 1_100)
    #expect(estimate.displayText == "単価未対応")
}

@Test(arguments: [("claude-opus-5-5-20260922", 4.0), ("gpt-6.1-sol-2026-09-29", 2.0),
                  ("gpt-6-sol-2026-09-22", 2.0), ("gpt-6-astra-2026-09-03", 10.0),
                  ("gpt-6-luna-2026-09-22", 0.10), ("gpt-5.5-pro-2026-04-23", 30.0),
                  ("gpt-5.6-2026-07-09", 4.0), ("gpt-5.6-sol-2026-07-09", 4.0),
                  ("gpt-5.6-terra-2026-07-09", 2.0), ("gpt-5.6-luna-2026-07-09", 0.20),
                  ("gpt-5.6-cyber-2026-07-09", 12.50)])
func datedModelIDsUseTheirModelRate(model: String, expected: Double) {
    let estimate = APIPricing.estimate(model: model, tokens: TokenUsage(input: 1_000_000))
    #expect(estimate.amountUSD == expected)
}

@Test func zeroUsageAndTinyCostsAreDistinctFromUnpricedUsage() {
    #expect(APIPricing.estimate(model: nil, tokens: TokenUsage()).displayText == "$0.00")
    #expect(APIPricing.estimate(model: "gpt-6-luna", tokens: TokenUsage(input: 1)).displayText == "<$0.01")
}

@Test func cacheWriteDurationSurvivesStreamingDeduplicationAndScanning() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ratok-pricing-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var object: [String: Any] = ["type": "assistant", "timestamp": "2026-10-02T03:00:00Z", "requestId": "r",
        "message": ["id": "m", "model": "claude-opus-5-5", "usage": ["input_tokens": 1_000_000,
            "output_tokens": 5, "cache_read_input_tokens": 1_000_000, "cache_creation_input_tokens": 2_000_000,
            "cache_creation": ["ephemeral_5m_input_tokens": 1_000_000, "ephemeral_1h_input_tokens": 1_000_000]]]]
    var data = try JSONSerialization.data(withJSONObject: object) + Data([10])
    // A later streaming record may omit the cache-duration details.
    object["message"] = ["id": "m", "model": "claude-opus-5-5", "usage": ["input_tokens": 1_000_000,
        "output_tokens": 1_000_000, "cache_read_input_tokens": 1_000_000, "cache_creation_input_tokens": 2_000_000]]
    data.append(try JSONSerialization.data(withJSONObject: object) + Data([10]))
    try data.write(to: directory.appendingPathComponent("session.jsonl"))
    // A copied log with equal totals but no duration details should keep the known one-hour count.
    try (try JSONSerialization.data(withJSONObject: object) + Data([10])).write(to: directory.appendingPathComponent("duplicate.jsonl"))
    let scanner = UsageScanner()
    let start = try #require(ParsedLog.date("2026-10-02T00:00:00Z"))
    let now = try #require(ParsedLog.date("2026-10-03T00:00:00Z"))
    let snapshot = await scanner.scan(provider: .claude, root: directory, start: start, now: now)
    #expect(snapshot.tokens.cacheWrite1h == 1_000_000)
    #expect(abs(snapshot.estimatedCost.subtotalUSD - 37.20) < 0.000001)
    #expect(snapshot.breakdown(by: .effort).first?.cost == snapshot.estimatedCost)
    let unchanged = await scanner.scan(provider: .claude, root: directory, start: start, now: now)
    #expect(unchanged.estimatedCost == snapshot.estimatedCost)
    let tomorrow = await scanner.scan(provider: .claude, root: directory, start: now, now: now)
    #expect(tomorrow.estimatedCost.displayText == "$0.00")
}

@Test func tokenUsageDecodesOldValuesWithoutCacheDuration() throws {
    let data = Data(#"{"input":160,"output":20,"cacheRead":100,"cacheWrite":50}"#.utf8)
    let decoded = try JSONDecoder().decode(TokenUsage.self, from: data)
    #expect(decoded.cacheWrite1h == 0)
    let tokens = TokenUsage(input: 160, output: 20, cacheRead: 100, cacheWrite: 50, cacheWrite1h: 25)
    #expect(try JSONDecoder().decode(TokenUsage.self, from: JSONEncoder().encode(tokens)) == tokens)
}
