import Foundation

struct UsageEvent: Sendable {
    var id: String
    var date: Date
    var tokens: TokenUsage
    var group: UsageGroup = .init()
}

struct ParsedLog: Sendable {
    var events: [String: UsageEvent] = [:]
    var previousCodex: TokenUsage?
    var codexGroup = UsageGroup()
    var limits: LimitSnapshot?
    var sessionID: String
    var malformedLines = 0

    init(sessionID: String) { self.sessionID = sessionID }

    mutating func consume(_ line: Data, provider: Provider) {
        // Skip conversation content before deserializing large JSON messages.
        let marker = provider == .codex ? Data("\"token_count\"".utf8) : Data("\"usage\"".utf8)
        let context = provider == .codex && (line.range(of: Data("\"session_meta\"".utf8)) != nil
            || line.range(of: Data("\"turn_context\"".utf8)) != nil)
        guard context || line.range(of: marker) != nil else { return }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            malformedLines += 1; return
        }
        if provider == .codex, let payload = object["payload"] as? [String: Any] {
            if object["type"] as? String == "session_meta" {
                if let id = payload["id"] as? String { sessionID = id }
                return
            }
            if object["type"] as? String == "turn_context" {
                // Each turn replaces the settings, including missing/unspecified effort.
                codexGroup = UsageGroup(model: Self.metadata(payload, "model"), effort: Self.metadata(payload, "effort"))
                return
            }
        }
        guard let timestamp = object["timestamp"] as? String, let date = Self.date(timestamp) else { return }
        switch provider {
        case .claude:
            guard object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { return }
            let read = Self.integer(usage, "cache_read_input_tokens")
            let write = Self.integer(usage, "cache_creation_input_tokens")
            let creation = usage["cache_creation"] as? [String: Any] ?? [:]
            let tokens = TokenUsage(input: Self.integer(usage, "input_tokens") + read + write,
                                    output: Self.integer(usage, "output_tokens"), cacheRead: read, cacheWrite: write,
                                    cacheWrite1h: min(write, Self.integer(creation, "ephemeral_1h_input_tokens")))
            guard let id = message["id"] as? String ?? object["uuid"] as? String else { return }
            // Streaming records repeat a message ID; retain the latest usage, don't add it twice.
            let key = "\(id):\(object["requestId"] as? String ?? "")"
            let group = UsageGroup(model: Self.metadata(message, "model"),
                                   effort: Self.metadata(object, "perTurnEffort") ?? Self.metadata(object, "effort"))
            if let old = events[key] {
                events[key] = UsageEvent(id: key, date: min(old.date, date), tokens: TokenUsage(
                    input: max(old.tokens.input, tokens.input), output: max(old.tokens.output, tokens.output),
                    cacheRead: max(old.tokens.cacheRead, tokens.cacheRead), cacheWrite: max(old.tokens.cacheWrite, tokens.cacheWrite),
                    cacheWrite1h: max(old.tokens.cacheWrite1h, tokens.cacheWrite1h)),
                    group: UsageGroup(model: group.model ?? old.group.model, effort: group.effort ?? old.group.effort))
            } else {
                events[key] = UsageEvent(id: key, date: date, tokens: tokens, group: group)
            }
        case .codex:
            guard object["type"] as? String == "event_msg", let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count" else { return }
            let windows = Self.codexLimitWindows(payload, observedAt: date)
            if !windows.isEmpty,
               limits == nil || date >= limits!.observedAt {
                let rate = payload["rate_limits"] as? [String: Any]
                limits = LimitSnapshot(windows: windows, observedAt: date, plan: rate?["plan_type"] as? String)
            }
            guard let info = payload["info"] as? [String: Any], let total = info["total_token_usage"] as? [String: Any] else { return }
            let next = Self.codexTokens(total)
            let delta: TokenUsage
            if let previous = previousCodex, next.input >= previous.input, next.output >= previous.output {
                delta = .delta(next, previous)
            } else if let last = info["last_token_usage"] as? [String: Any] {
                delta = Self.codexTokens(last)
            } else { delta = next }
            previousCodex = next
            guard delta.total > 0 else { return }
            let key = "\(sessionID):\(timestamp):\(next.input):\(next.output)"
            events[key] = UsageEvent(id: key, date: date, tokens: delta, group: codexGroup)
        }
    }

    static func codexTokens(_ value: [String: Any]) -> TokenUsage {
        TokenUsage(input: integer(value, "input_tokens"), output: integer(value, "output_tokens"),
                   cacheRead: integer(value, "cached_input_tokens"), cacheWrite: integer(value, "cache_write_input_tokens"))
    }

    /// Codex rollouts traditionally contain one `rate_limits` bucket. Newer
    /// usage responses can also include additional named buckets, including
    /// the Luna Reserve pool. Keep each bucket separate so percentages from
    /// different quotas are never combined.
    private static func codexLimitWindows(_ payload: [String: Any], observedAt: Date) -> [LimitWindow] {
        var windows: [LimitWindow] = []
        if let rate = payload["rate_limits"] as? [String: Any] {
            let bucket = rate["limit_id"] as? String ?? "codex"
            let name = rate["limit_name"] as? String
            windows += codexWindows(in: rate, bucket: bucket, name: name, observedAt: observedAt)
        }

        for value in payload["additional_rate_limits"] as? [[String: Any]] ?? [] {
            let nested = value["rate_limit"] as? [String: Any] ?? value
            let bucket = (value["metered_feature"] as? String)
                ?? (value["limit_id"] as? String)
                ?? (value["limit_name"] as? String)
                ?? "additional"
            let name = (value["limit_name"] as? String) ?? (value["name"] as? String)
            windows += codexWindows(in: nested, bucket: bucket, name: name, observedAt: observedAt)
        }
        return windows
    }

    private static func codexWindows(in bucket: [String: Any], bucket id: String, name: String?, observedAt: Date) -> [LimitWindow] {
        let displayName: String
        if id == "gpt-reserve" || id == "gpt_reserve" || id == "luna_reserve"
            || id == "base_model_inference" {
            displayName = "Luna Reserve"
        } else if let name, !name.isEmpty {
            displayName = name
        } else if id == "codex" {
            displayName = ""
        } else {
            displayName = id.replacingOccurrences(of: "_", with: " ").capitalized
        }

        return [("primary", "5時間"), ("secondary", "週間")].compactMap { key, fallbackTitle in
            let camelKey = key == "primary" ? "primaryWindow" : "secondaryWindow"
            let window = bucket[key] as? [String: Any]
                ?? (bucket["\(key)_window"] as? [String: Any])
                ?? (bucket[camelKey] as? [String: Any])
            guard let window,
                  let percent = ((window["used_percent"] ?? window["usedPercent"]) as? NSNumber)?.doubleValue,
                  percent.isFinite else { return nil }
            let minutes = (window["window_minutes"] as? NSNumber)?.intValue
                ?? (window["window_duration_mins"] as? NSNumber)?.intValue
                ?? (window["windowDurationMins"] as? NSNumber)?.intValue
            let periodTitle = minutes == 300 ? "5時間" : minutes == 10080 ? "週間" : minutes.map { "\($0)分" } ?? fallbackTitle
            let title = displayName.isEmpty ? periodTitle : "\(displayName) · \(periodTitle)"
            let reset = (window["resets_at"] as? NSNumber)?.doubleValue
                ?? (window["resetsAt"] as? NSNumber)?.doubleValue
                ?? (window["resets_in_seconds"] as? NSNumber).map { observedAt.addingTimeInterval($0.doubleValue).timeIntervalSince1970 }
            return LimitWindow(id: id == "codex" ? key : "\(id)_\(key)", title: title,
                               usedPercent: percent,
                               resetsAt: reset.map(Date.init(timeIntervalSince1970:)))
        }
    }

    static func integer(_ value: [String: Any], _ key: String) -> Int { max(0, value[key] as? Int ?? 0) }
    private static func metadata(_ value: [String: Any], _ key: String) -> String? {
        guard let text = value[key] as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    static func date(_ value: String) -> Date? {
        // Date.ISO8601FormatStyle accepts fractional seconds without shared mutable formatters.
        (try? Date(value, strategy: .iso8601.year().month().day().dateSeparator(.dash)
            .time(includingFractionalSeconds: true).timeZone(separator: .colon)))
        ?? (try? Date(value, strategy: .iso8601))
    }
}
