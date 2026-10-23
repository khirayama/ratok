import Foundation
import Testing
@testable import UsageCore

@Test(arguments: [("five_hour", "seven_day"), ("primary", "secondary")])
func menuBarPrefersFiveHourLimit(_ shortID: String, _ weeklyID: String) {
    let short = LimitWindow(id: shortID, title: "5時間", usedPercent: 35, resetsAt: nil)
    let weekly = LimitWindow(id: weeklyID, title: "週間", usedPercent: 80, resetsAt: nil)
    let limits = LimitSnapshot(windows: [weekly, short], observedAt: Date())
    #expect(limits.menuBarWindow == short)
    #expect(limits.menuBarWindow?.remainingPercent(at: Date()) == 65)
}

@Test(arguments: ["seven_day", "primary", "secondary"])
func menuBarFallsBackToWeeklyLimit(_ id: String) {
    let weekly = LimitWindow(id: id, title: "週間", usedPercent: 80, resetsAt: nil)
    let other = LimitWindow(id: "spend_limit", title: "追加利用", usedPercent: 10, resetsAt: nil)
    #expect(LimitSnapshot(windows: [other, weekly], observedAt: Date()).menuBarWindow == weekly)
    #expect(LimitSnapshot(windows: [other], observedAt: Date()).menuBarWindow == nil)
    #expect(LimitSnapshot(windows: [], observedAt: Date()).menuBarWindow == nil)
}

@Test(arguments: [(-10.0, 100.0), (0.0, 100.0), (23.5, 76.5), (100.0, 0.0), (120.0, 0.0)])
func remainingPercentageIsClamped(_ used: Double, _ expected: Double) {
    let window = LimitWindow(id: "five_hour", title: "5時間", usedPercent: used, resetsAt: nil)
    #expect(window.remainingPercent(at: Date()) == expected)
}

@Test func expiredFiveHourLimitWaitsForFreshData() {
    let now = Date()
    let expired = LimitWindow(id: "primary", title: "5時間", usedPercent: 40, resetsAt: now)
    let weekly = LimitWindow(id: "secondary", title: "週間", usedPercent: 70, resetsAt: now.addingTimeInterval(3600))
    let limits = LimitSnapshot(windows: [expired, weekly], observedAt: now)
    #expect(limits.menuBarWindow == expired)
    #expect(limits.menuBarWindow?.remainingPercent(at: now) == nil)
    #expect(weekly.remainingPercent(at: now) == 30)
}

@Test(arguments: [Double.nan, .infinity, -.infinity])
func invalidLimitPercentageIsUnavailable(_ used: Double) {
    let window = LimitWindow(id: "five_hour", title: "5時間", usedPercent: used, resetsAt: nil)
    #expect(window.remainingPercent(at: Date()) == nil)
}

private func snapshot(_ read: ResetCreditRead?) throws -> ResetCreditSnapshot {
    guard case .available(let snapshot) = try #require(read) else { throw CocoaError(.coderInvalidValue) }
    return snapshot
}

@Test func codexResetCreditsKeepAvailableCreditsAndExpiry() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let line = Data(#"{"id":2,"result":{"rateLimitResetCredits":{"availableCount":3,"credits":[{"id":"a","resetType":"codexRateLimits","status":"available","grantedAt":1,"expiresAt":5000,"title":"Full reset","description":null},{"id":"b","status":"available","expiresAt":2000,"title":""},{"id":"c","status":"available","expiresAt":500,"title":null},{"id":"d","status":"redeemed","expiresAt":1500}]}}}"#.utf8)
    let credits = try snapshot(CodexAppServer.resetCredits(fromResponse: line, id: 2, now: now))
    #expect(credits.credits.map(\.id) == ["a", "b", "c"])
    #expect(credits.credits[0].title == "Full reset")
    #expect(credits.credits[1].title == nil)
    // The credit that expired before `now` is no longer usable.
    #expect(credits.remainingCount(at: now) == 2)
    #expect(credits.nextExpiry(at: now) == Date(timeIntervalSince1970: 2000))
}

@Test func codexResetCreditsWithoutDetailsKeepTheCount() throws {
    let line = Data(#"{"id":2,"result":{"rateLimitResetCredits":{"availableCount":1,"credits":null}}}"#.utf8)
    let credits = try snapshot(CodexAppServer.resetCredits(fromResponse: line, id: 2, now: Date()))
    #expect(credits.remainingCount(at: Date()) == 1)
    #expect(credits.nextExpiry(at: Date()) == nil)
}

@Test(arguments: [
    (#"{"id":2,"result":{"rateLimitResetCredits":null}}"#, ResetCreditRead.unavailable),
    (#"{"id":2,"error":{"code":-32600,"message":"not signed in"}}"#, .failed),
    (#"{"id":1,"result":{"rateLimitResetCredits":{"availableCount":1,"credits":[]}}}"#, nil),
    (#"{"method":"account/updated","params":{}}"#, nil),
    ("not json", nil),
] as [(String, ResetCreditRead?)])
func codexResetCreditsClassifyOtherMessages(_ line: String, _ expected: ResetCreditRead?) {
    #expect(CodexAppServer.resetCredits(fromResponse: Data(line.utf8), id: 2, now: Date()) == expected)
}

@Test func resetCreditsRefetchDailyUntilTheEarliestExpiryAndHourlyWhenEmpty() {
    let now = Date(timeIntervalSince1970: 0)
    func credits(_ expiries: [TimeInterval]) -> ResetCreditSnapshot {
        let rows = expiries.enumerated().map { ResetCredit(id: "\($0.offset)", expiresAt: Date(timeIntervalSince1970: $0.element)) }
        return ResetCreditSnapshot(availableCount: rows.count, credits: rows, observedAt: now)
    }
    #expect(credits([10.0 * 86_400, 20.0 * 86_400]).nextFetch(after: now) == Date(timeIntervalSince1970: 86_400))
    #expect(credits([3_000, 20 * 86_400]).nextFetch(after: now) == Date(timeIntervalSince1970: 3_000))
    #expect(credits([]).nextFetch(after: now) == Date(timeIntervalSince1970: 3_600))
    #expect(ResetCreditSnapshot(availableCount: 1, credits: [], observedAt: now).nextFetch(after: now) == Date(timeIntervalSince1970: 86_400))
}

@Test func codexAppServerLimitsIncludeLunaReserveWeekly() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let line = Data(#"{"id":2,"result":{"rateLimits":{"limitId":"codex","planType":"plus","primary":{"usedPercent":13,"windowDurationMins":300,"resetsAt":5000},"secondary":{"usedPercent":79,"windowDurationMins":10080,"resetsAt":9000}},"rateLimitsByLimitId":{"base_model_inference":{"limitId":"base_model_inference","limitName":"gpt-reserve","primary":{"usedPercent":6,"windowDurationMins":10080,"resetsAt":7000},"secondary":null},"codex":{"limitId":"codex","limitName":null,"primary":{"usedPercent":13,"windowDurationMins":300,"resetsAt":5000},"secondary":{"usedPercent":79,"windowDurationMins":10080,"resetsAt":9000}}},"rateLimitResetCredits":null}}"#.utf8)
    let limits = try #require(CodexAppServer.limits(fromResponse: line, id: 2, now: now))
    #expect(limits.windows.map(\.id) == ["primary", "secondary", "base_model_inference_primary"])
    #expect(limits.windows[2] == LimitWindow(id: "base_model_inference_primary", title: "Luna Reserve · 週間",
                                             usedPercent: 6, resetsAt: Date(timeIntervalSince1970: 7000)))
    #expect(limits.plan == "plus")
    #expect(limits.menuBarWindow?.id == "primary")
    #expect(CodexAppServer.limits(fromResponse: line, id: 3, now: now) == nil)
    #expect(CodexAppServer.limits(fromResponse: Data(#"{"id":2,"result":{"rateLimitResetCredits":null}}"#.utf8), id: 2, now: now) == nil)
}

@Test func mergedLimitsPreferTheNewerSourceAndKeepOtherPools() {
    let old = Date(timeIntervalSince1970: 0), new = Date(timeIntervalSince1970: 60)
    let reserve = LimitWindow(id: "base_model_inference_primary", title: "Luna Reserve · 週間", usedPercent: 6, resetsAt: nil)
    let account = LimitSnapshot(windows: [LimitWindow(id: "primary", title: "5時間", usedPercent: 10, resetsAt: nil), reserve],
                                observedAt: old, plan: "plus")
    let log = LimitSnapshot(windows: [LimitWindow(id: "primary", title: "5時間", usedPercent: 12, resetsAt: nil)], observedAt: new)
    for merged in [log.merging(account), account.merging(log)] {
        #expect(merged.windows.map(\.usedPercent) == [12, 6])
        #expect(merged.observedAt == new)
        #expect(merged.plan == "plus")
    }
    // A rollout from a reserve-only session still shows the main windows first.
    let reserveLog = LimitSnapshot(windows: [reserve], observedAt: new)
    #expect(reserveLog.merging(account).windows.map(\.id) == ["primary", "base_model_inference_primary"])
}

@Test func claudeAccountLimitsReadWindowsAndEnabledExtraUsage() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let body = #"{"five_hour":{"utilization":6.0,"resets_at":"2026-10-11T06:49:59.587124+00:00"},"seven_day":{"utilization":95,"resets_at":"2026-10-13T03:59:59.587142+00:00"},"seven_day_opus":null,"extra_usage":{"is_enabled":false,"utilization":null}}"#
    let limits = try #require(ClaudeAccount.limits(fromResponse: Data(body.utf8), now: now))
    #expect(limits.windows.map(\.id) == ["five_hour", "seven_day"])
    #expect(limits.windows.map(\.usedPercent) == [6, 95])
    #expect(limits.windows[0].resetsAt.map { Int($0.timeIntervalSince1970) } == 1_791_701_399)
    #expect(limits.observedAt == now)
    let extra = #"{"five_hour":null,"extra_usage":{"is_enabled":true,"utilization":40}}"#
    #expect(ClaudeAccount.limits(fromResponse: Data(extra.utf8), now: now)?.windows.map(\.id) == ["spend_limit"])
    #expect(ClaudeAccount.limits(fromResponse: Data(#"{"five_hour":null,"seven_day":null}"#.utf8), now: now) == nil)
    #expect(ClaudeAccount.limits(fromResponse: Data("not json".utf8), now: now) == nil)
}

@Test func claudeAccessTokenIsUsedOnlyUntilItExpires() {
    let now = Date(timeIntervalSince1970: 1_000)
    func token(_ json: String) -> String? { ClaudeAccount.accessToken(fromCredentials: Data(json.utf8), now: now) }
    #expect(token(#"{"claudeAiOauth":{"accessToken":"t","expiresAt":1000001}}"#) == "t")
    #expect(token(#"{"claudeAiOauth":{"accessToken":"t","expiresAt":1000000}}"#) == nil)
    #expect(token(#"{"claudeAiOauth":{"accessToken":"t"}}"#) == "t")
    #expect(token(#"{"claudeAiOauth":{"accessToken":""}}"#) == nil)
    #expect(token(#"{"mcpOAuth":{}}"#) == nil)
}
