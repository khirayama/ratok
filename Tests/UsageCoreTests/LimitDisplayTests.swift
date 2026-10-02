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
