import Foundation

/// Standard API token-rate equivalent in USD; excludes subscription fees and billing modifiers.
public struct CostEstimate: Sendable, Equatable {
    public private(set) var subtotalUSD: Double = 0
    public private(set) var pricedTokens: Int = 0
    public private(set) var unpricedTokens: Int = 0
    public init() {}
    public var isPartial: Bool { unpricedTokens > 0 }
    public var amountUSD: Double? { pricedTokens > 0 || unpricedTokens == 0 ? subtotalUSD : nil }
    public var displayText: String {
        guard let amountUSD else { return "単価未対応" }
        let amount = amountUSD > 0 && amountUSD < 0.01 ? "<$0.01" : amountUSD.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
        return amount + (isPartial ? "*" : "")
    }
    public static func + (lhs: Self, rhs: Self) -> Self {
        var result = Self()
        result.subtotalUSD = lhs.subtotalUSD + rhs.subtotalUSD
        result.pricedTokens = lhs.pricedTokens + rhs.pricedTokens
        result.unpricedTokens = lhs.unpricedTokens + rhs.unpricedTokens
        return result
    }
    fileprivate init(usd: Double, priced: Int, unpriced: Int) {
        subtotalUSD = usd; pricedTokens = priced; unpricedTokens = unpriced
    }
}

public enum APIPricing {
    public static let verifiedOn = "2026-10-02"
    public static let assumptions = "USD・API標準単価での換算額です。サブスクの請求額ではありません。短いコンテキストの通常料金を使用し、Fast/長文/地域指定の割増、Batch割引、ツール料金、税は含みません。クラウド経由のClaudeもAnthropic標準単価で換算します。Claudeのキャッシュ書込は1時間分をログから区別し、保持時間が未記録の分は5分単価で計算します。画像生成・音声など専用の利用内訳が必要なモデルは対象外です。単価は\(verifiedOn)確認、アプリ更新時に更新します。"
    public static func source(for provider: Provider) -> String {
        provider == .codex ? "https://developers.openai.com/api/docs/pricing" : "https://platform.claude.com/docs/en/about-claude/pricing"
    }

    public static func estimate(model: String?, tokens: TokenUsage) -> CostEstimate {
        guard tokens.total > 0 else { return CostEstimate() }
        guard let model, let rates = rates(for: model) else {
            return CostEstimate(usd: 0, priced: 0, unpriced: tokens.total)
        }
        let oneHour = min(tokens.cacheWrite, tokens.cacheWrite1h)
        let usd = (Double(tokens.uncachedInput) * rates.input
                   + Double(tokens.output) * rates.output
                   + Double(tokens.cacheRead) * rates.read
                   + Double(tokens.cacheWrite - oneHour) * rates.write
                   + Double(oneHour) * rates.write1h) / 1_000_000
        return CostEstimate(usd: usd, priced: tokens.total, unpriced: 0)
    }

    private struct Rates: Sendable {
        let input: Double
        let output: Double
        let read: Double
        let write: Double
        let write1h: Double
        init(input: Double, output: Double, read: Double? = nil, write: Double? = nil, write1h: Double? = nil) {
            self.input = input; self.output = output
            // Models without a separate cache tariff retain ordinary input pricing.
            self.read = read ?? input; self.write = write ?? input
            self.write1h = write1h ?? write ?? input
        }
    }
    // USD per million tokens, verified against the linked official rate cards.
    // Do not infer prices for reserve pools, unknown models, or unlisted variants.
    private static let catalog: [String: Rates] = [
        "gpt-6.1-sol": Rates(input: 2, output: 10, read: 0.10, write: 2.50),
        "gpt-6-sol": Rates(input: 2, output: 10, read: 0.20, write: 2.50),
        "gpt-6-luna": Rates(input: 0.10, output: 0.50, read: 0.01, write: 0.125),
        "gpt-6-astra": Rates(input: 10, output: 50, read: 1, write: 12.50),
        "gpt-5.6-sol": Rates(input: 4, output: 20, read: 0.40, write: 5),
        "gpt-5.6-terra": Rates(input: 2, output: 12, read: 0.20, write: 2.50),
        "gpt-5.6-luna": Rates(input: 0.20, output: 1.20, read: 0.02, write: 0.25),
        "gpt-5.6-cyber": Rates(input: 12.50, output: 75, read: 1.25, write: 15.625),
        "gpt-5.5": Rates(input: 5, output: 30, read: 0.50),
        "gpt-5.5-pro": Rates(input: 30, output: 180),
        "gpt-5.4": Rates(input: 2.50, output: 15, read: 0.25, write: 2.50),
        "gpt-5.4-mini": Rates(input: 0.75, output: 4.50, read: 0.075),
        "gpt-5.4-nano": Rates(input: 0.20, output: 1.25, read: 0.02),
        "gpt-5.4-pro": Rates(input: 30, output: 180),
        "gpt-5.3-codex": Rates(input: 1.75, output: 14, read: 0.175),
        "gpt-5.3-chat-latest": Rates(input: 1.75, output: 14, read: 0.175),
        "gpt-5.2": Rates(input: 1.75, output: 14, read: 0.175),
        "gpt-5.2-pro": Rates(input: 21, output: 168),
        "gpt-5.2-codex": Rates(input: 1.75, output: 14, read: 0.175),
        "gpt-5.2-chat-latest": Rates(input: 1.75, output: 14, read: 0.175),
        "gpt-5.1": Rates(input: 1.25, output: 10, read: 0.125),
        "gpt-5.1-codex": Rates(input: 1.25, output: 10, read: 0.125),
        "gpt-5.1-codex-max": Rates(input: 1.25, output: 10, read: 0.125),
        "gpt-5.1-codex-mini": Rates(input: 0.25, output: 2, read: 0.025),
        "gpt-5.1-chat-latest": Rates(input: 1.25, output: 10, read: 0.125),
        "gpt-5": Rates(input: 1.25, output: 10, read: 0.125),
        "gpt-5-pro": Rates(input: 15, output: 120),
        "gpt-5-mini": Rates(input: 0.25, output: 2, read: 0.025),
        "gpt-5-nano": Rates(input: 0.05, output: 0.40, read: 0.005),
        "gpt-5-codex": Rates(input: 1.25, output: 10, read: 0.125),
        "gpt-5-chat-latest": Rates(input: 1.25, output: 10, read: 0.125),
        "codex-mini-latest": Rates(input: 1.50, output: 6, read: 0.375),
        "chat-latest": Rates(input: 5, output: 30, read: 0.50),
        "gpt-4.1": Rates(input: 2, output: 8, read: 0.50),
        "gpt-4.1-mini": Rates(input: 0.40, output: 1.60, read: 0.10),
        "gpt-4.1-nano": Rates(input: 0.10, output: 0.40, read: 0.025),
        "gpt-4o": Rates(input: 2.50, output: 10, read: 1.25),
        // This snapshot has a different published rate from later GPT-4o snapshots.
        "gpt-4o-2024-05-13": Rates(input: 5, output: 15),
        "gpt-4o-mini": Rates(input: 0.15, output: 0.60, read: 0.075),
        "gpt-4.5-preview": Rates(input: 75, output: 150, read: 37.50),
        "gpt-4-turbo": Rates(input: 10, output: 30),
        "gpt-4-turbo-preview": Rates(input: 10, output: 30),
        "gpt-4": Rates(input: 30, output: 60),
        "gpt-4-0613": Rates(input: 30, output: 60),
        "gpt-3.5-turbo": Rates(input: 0.50, output: 1.50),
        "gpt-3.5-turbo-0125": Rates(input: 0.50, output: 1.50),
        "gpt-3.5-turbo-1106": Rates(input: 1, output: 2),
        "gpt-3.5-turbo-instruct": Rates(input: 1.50, output: 2),
        "chatgpt-4o-latest": Rates(input: 5, output: 15),
        "o1": Rates(input: 15, output: 60, read: 7.50),
        "o1-pro": Rates(input: 150, output: 600),
        "o1-preview": Rates(input: 15, output: 60, read: 7.50),
        "o1-mini": Rates(input: 1.10, output: 4.40, read: 0.55),
        "o3": Rates(input: 2, output: 8, read: 0.50),
        "o3-pro": Rates(input: 20, output: 80),
        "o3-mini": Rates(input: 1.10, output: 4.40, read: 0.55),
        "o4-mini": Rates(input: 1.10, output: 4.40, read: 0.275),
        "o3-deep-research": Rates(input: 10, output: 40, read: 2.50),
        "o4-mini-deep-research": Rates(input: 2, output: 8, read: 0.50),
        "computer-use-preview": Rates(input: 3, output: 12),
        "gpt-4o-search-preview": Rates(input: 2.50, output: 10),
        "gpt-4o-mini-search-preview": Rates(input: 0.15, output: 0.60),
        "gpt-5-search-api": Rates(input: 1.25, output: 10, read: 0.125),
        // Published API equivalent; billing for Rosalind begins on 2026-10-05.
        "gpt-rosalind-research": Rates(input: 5, output: 25, read: 0.50),
        "davinci-002": Rates(input: 2, output: 2),
        "babbage-002": Rates(input: 0.40, output: 0.40),
        "text-embedding-3-small": Rates(input: 0.02, output: 0),
        "text-embedding-3-large": Rates(input: 0.13, output: 0),
        "text-embedding-ada-002": Rates(input: 0.10, output: 0),
        "omni-moderation-latest": Rates(input: 0, output: 0),
        "claude-fable-5-1": Rates(input: 10, output: 50, read: 0.25, write: 12.50, write1h: 20),
        "claude-mythos-5-1": Rates(input: 10, output: 50, read: 0.25, write: 12.50, write1h: 20),
        "claude-fable-5": Rates(input: 10, output: 50, read: 1, write: 12.50, write1h: 20),
        "claude-mythos-5": Rates(input: 10, output: 50, read: 1, write: 12.50, write1h: 20),
        "claude-mythos-preview": Rates(input: 25, output: 125, read: 2.50, write: 31.25, write1h: 50),
        "claude-opus-5-5": Rates(input: 4, output: 20, read: 0.20, write: 5, write1h: 8),
        "claude-sonnet-5-5": Rates(input: 2, output: 10, read: 0.20, write: 2.50, write1h: 4),
        "claude-haiku-4-5": Rates(input: 1, output: 5, read: 0.10, write: 1.25, write1h: 2),
        "claude-opus-5": Rates(input: 5, output: 25, read: 0.50, write: 6.25, write1h: 10),
        "claude-sonnet-5": Rates(input: 2, output: 10, read: 0.20, write: 2.50, write1h: 4),
        "claude-opus-4-8": Rates(input: 5, output: 25, read: 0.50, write: 6.25, write1h: 10),
        "claude-opus-4-7": Rates(input: 5, output: 25, read: 0.50, write: 6.25, write1h: 10),
        "claude-opus-4-6": Rates(input: 5, output: 25, read: 0.50, write: 6.25, write1h: 10),
        "claude-opus-4-5": Rates(input: 5, output: 25, read: 0.50, write: 6.25, write1h: 10),
        "claude-opus-4-1": Rates(input: 15, output: 75, read: 1.50, write: 18.75, write1h: 30),
        "claude-opus-4": Rates(input: 15, output: 75, read: 1.50, write: 18.75, write1h: 30),
        "claude-sonnet-4-6": Rates(input: 3, output: 15, read: 0.30, write: 3.75, write1h: 6),
        "claude-sonnet-4-5": Rates(input: 3, output: 15, read: 0.30, write: 3.75, write1h: 6),
        "claude-sonnet-4": Rates(input: 3, output: 15, read: 0.30, write: 3.75, write1h: 6),
        "claude-3-5-haiku": Rates(input: 0.80, output: 4, read: 0.08, write: 1, write1h: 1.60)
    ]

    // Alias targets are verified with the official model pages on `verifiedOn`.
    private static let aliases = [
        "gpt-5.6": "gpt-5.6-sol",
        "gpt-daybreak-blue-latest": "gpt-5.6-sol",
        "gpt-daybreak-red-latest": "gpt-5.6-cyber",
        "gpt-4-0314": "gpt-4",
        "gpt-4-0125-preview": "gpt-4-turbo-preview",
        "gpt-4-1106-vision-preview": "gpt-4-turbo-preview"
    ]

    private static func rates(for model: String) -> Rates? {
        if let rates = catalog[model] { return rates }
        var normalized = model
        // Official Bedrock and Vertex IDs use the same model, with provider decorations.
        if normalized.hasPrefix("anthropic.claude-") {
            normalized = String(normalized.dropFirst("anthropic.".count))
                .replacingOccurrences(of: "-v1(?::0)?$", with: "", options: .regularExpression)
        }
        if normalized.hasPrefix("claude-") {
            normalized = normalized.replacingOccurrences(of: "@([0-9]{8})$", with: "-$1", options: .regularExpression)
        }
        // Match dated snapshots only; a suffix such as "-pro" must retain its own price.
        let base = normalized.replacingOccurrences(of: "-(?:[0-9]{8}|[0-9]{4}-[0-9]{2}-[0-9]{2})$", with: "", options: .regularExpression)
        return catalog[aliases[base] ?? base]
    }
}
