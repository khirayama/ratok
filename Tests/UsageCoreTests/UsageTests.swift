import Foundation
import Testing
@testable import UsageCore

private func line(_ value: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}

private func codex(_ total: Int, output: Int, last: Int? = nil, at date: String = "2026-10-02T03:00:00Z") throws -> Data {
    try line(["type": "event_msg", "timestamp": date, "payload": [
        "type": "token_count", "info": [
            "total_token_usage": ["input_tokens": total, "output_tokens": output, "cached_input_tokens": total / 2],
            "last_token_usage": ["input_tokens": last ?? total, "output_tokens": output, "cached_input_tokens": (last ?? total) / 2]
        ]
    ]])
}

private func claude(_ id: String, input: Int = 10, output: Int = 20, at date: String = "2026-10-02T03:00:00.123Z",
                    model: String? = nil, effort: String? = nil, perTurnEffort: String? = nil) throws -> Data {
    var message: [String: Any] = ["id": id, "usage": ["input_tokens": input, "output_tokens": output,
                                                   "cache_read_input_tokens": 100, "cache_creation_input_tokens": 50]]
    message["model"] = model
    var object: [String: Any] = ["type": "assistant", "timestamp": date, "requestId": "request-\(id)", "message": message]
    object["effort"] = effort; object["perTurnEffort"] = perTurnEffort
    return try line(object)
}

private func context(model: String?, effort: String?) throws -> Data {
    var payload: [String: Any] = [:]
    payload["model"] = model; payload["effort"] = effort
    return try line(["type": "turn_context", "payload": payload])
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ratok-tests-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func codexCumulativeCountsDoNotDoubleCountRepeatedEvents() throws {
    var parsed = ParsedLog(sessionID: "session")
    parsed.consume(try codex(100, output: 10), provider: .codex)
    parsed.consume(try codex(100, output: 10, at: "2026-10-02T03:01:00Z"), provider: .codex)
    parsed.consume(try codex(160, output: 30, at: "2026-10-02T03:02:00Z"), provider: .codex)
    let total = parsed.events.values.reduce(TokenUsage()) { $0 + $1.tokens }
    #expect(total == TokenUsage(input: 160, output: 30, cacheRead: 80))
    #expect(parsed.events.count == 2)
}

@Test func codexFirstRecordUsesLastUsageAndResetsAreCounted() throws {
    var parsed = ParsedLog(sessionID: "session")
    parsed.consume(try codex(10_000, output: 10, last: 100), provider: .codex)
    parsed.consume(try codex(50, output: 5, at: "2026-10-02T04:00:00Z"), provider: .codex)
    #expect(parsed.events.values.reduce(0) { $0 + $1.tokens.input } == 150)
}

@Test func claudeStreamingRecordsIncludeCacheAndKeepLatestOutput() throws {
    var parsed = ParsedLog(sessionID: "session")
    parsed.consume(try claude("message", output: 5), provider: .claude)
    parsed.consume(try claude("message", output: 30), provider: .claude)
    let event = try #require(parsed.events.values.first)
    #expect(parsed.events.count == 1)
    #expect(event.tokens == TokenUsage(input: 160, output: 30, cacheRead: 100, cacheWrite: 50))
    #expect(event.tokens.uncachedInput == 10)
}

@Test func dailyTotalsUseEventTimestampsAndIncrementalReadsWaitForCompleteLines() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("session.jsonl")
    var bytes = try codex(100, output: 10, at: "2026-10-01T14:59:00Z")
    bytes.append(10)
    let next = try codex(180, output: 30, at: "2026-10-01T15:01:00Z")
    bytes.append(next.prefix(next.count / 2))
    try bytes.write(to: file)
    let scanner = UsageScanner()
    let start = try #require(ParsedLog.date("2026-10-01T15:00:00Z"))
    let now = try #require(ParsedLog.date("2026-10-03T00:00:00Z"))
    let initial = await scanner.scan(provider: .codex, root: directory, start: start, now: now)
    #expect(initial.tokens.total == 0)
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: next.suffix(next.count - next.count / 2) + Data([10]))
    try handle.close()
    let completed = await scanner.scan(provider: .codex, root: directory, start: start, now: now)
    #expect(completed.tokens == TokenUsage(input: 80, output: 20, cacheRead: 40))
    #expect(completed.usageByGroup == [UsageGroup(): completed.tokens])
    let unchanged = await scanner.scan(provider: .codex, root: directory, start: start, now: now)
    #expect(unchanged.tokens == completed.tokens)
    #expect(unchanged.usageByGroup == completed.usageByGroup)
}

@Test func duplicateClaudeLogsAndReplacedFilesAreHandled() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = directory.appendingPathComponent("first.jsonl")
    let second = directory.appendingPathComponent("copy.jsonl")
    let data = try claude("same") + Data([10])
    try data.write(to: first); try data.write(to: second)
    let scanner = UsageScanner()
    let start = try #require(ParsedLog.date("2026-10-02T00:00:00Z"))
    let now = try #require(ParsedLog.date("2026-10-03T00:00:00Z"))
    let initial = await scanner.scan(provider: .claude, root: directory, start: start, now: now)
    #expect(initial.tokens.input == 160)
    try FileManager.default.removeItem(at: second)
    try (try claude("new", input: 50) + Data([10])).write(to: first, options: .atomic)
    let replaced = await scanner.scan(provider: .claude, root: directory, start: start, now: now)
    #expect(replaced.tokens.input == 200)
    #expect(replaced.usageByGroup == [UsageGroup(): replaced.tokens])
}

@Test func codexAttributesDeltasToEachTurnWithoutCarryingMissingSettings() throws {
    var parsed = ParsedLog(sessionID: "session")
    parsed.consume(try codex(100, output: 10), provider: .codex)
    parsed.consume(try context(model: "model-a", effort: "high"), provider: .codex)
    parsed.consume(try codex(160, output: 30, at: "2026-10-02T03:01:00Z"), provider: .codex)
    parsed.consume(try context(model: "model-b", effort: "low"), provider: .codex)
    // A repeated cumulative count after switching model is not new usage.
    parsed.consume(try codex(160, output: 30, at: "2026-10-02T03:02:00Z"), provider: .codex)
    parsed.consume(try codex(200, output: 40, at: "2026-10-02T03:03:00Z"), provider: .codex)
    parsed.consume(try context(model: "model-b", effort: nil), provider: .codex)
    parsed.consume(try codex(250, output: 50, at: "2026-10-02T03:04:00Z"), provider: .codex)
    let events = parsed.events.values.sorted { $0.date < $1.date }
    #expect(events.map(\.group) == [UsageGroup(), UsageGroup(model: "model-a", effort: "high"),
                                    UsageGroup(model: "model-b", effort: "low"), UsageGroup(model: "model-b")])
    #expect(events.map(\.tokens.input) == [100, 60, 40, 50])
    #expect(events.map(\.tokens.output) == [10, 20, 10, 10])
}

@Test func claudeStreamingPreservesMetadataAndUsesPerTurnEffort() throws {
    var parsed = ParsedLog(sessionID: "session")
    parsed.consume(try claude("message", output: 5, model: "model-a", effort: "low", perTurnEffort: "high"), provider: .claude)
    parsed.consume(try claude("message", output: 30), provider: .claude)
    let event = try #require(parsed.events.values.first)
    #expect(parsed.events.count == 1)
    #expect(event.group == UsageGroup(model: "model-a", effort: "high"))
    #expect(event.tokens.output == 30)
    parsed.consume(try claude("fallback", model: "model-b", effort: "medium"), provider: .claude)
    #expect(parsed.events["fallback:request-fallback"]?.group == UsageGroup(model: "model-b", effort: "medium"))
}

@Test func groupedTotalsSharePeriodAndDeduplicationAndSumToOverallUsage() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let entries = [
        try claude("old", input: 9_000, at: "2026-10-01T03:00:00Z", model: "old", effort: "high"),
        try claude("a", output: 5, model: "model-a", effort: "high"),
        try claude("a", output: 30),
        try claude("b", input: 40, output: 10, model: "model-a", effort: "low"),
        try claude("c", input: 100, model: "model-b", effort: "high"),
        try claude("unknown")
    ]
    let data = entries.reduce(into: Data()) { $0.append($1); $0.append(10) }
    try data.write(to: directory.appendingPathComponent("session.jsonl"))
    // Duplicate with less metadata must still count once and keep known settings.
    try (try claude("a", output: 30) + Data([10])).write(to: directory.appendingPathComponent("copy.jsonl"))
    let snapshot = await UsageScanner().scan(provider: .claude, root: directory,
        start: try #require(ParsedLog.date("2026-10-02T00:00:00Z")),
        now: try #require(ParsedLog.date("2026-10-03T00:00:00Z")))
    #expect(snapshot.usageByGroup.count == 4)
    #expect(snapshot.usageByGroup[UsageGroup(model: "model-a", effort: "high")]?.output == 30)
    #expect(snapshot.usageByGroup[UsageGroup()] == TokenUsage(input: 160, output: 20, cacheRead: 100, cacheWrite: 50))
    #expect(snapshot.breakdown(by: .model).map(\.id) == [UsageGroup(model: "model-a"), UsageGroup(model: "model-b"), UsageGroup()])
    #expect(snapshot.breakdown(by: .effort).first?.id == UsageGroup(effort: "high"))
    for grouping in UsageGrouping.allCases {
        #expect(snapshot.breakdown(by: grouping).reduce(TokenUsage()) { $0 + $1.tokens } == snapshot.tokens)
    }
}

@Test func incrementalCodexReadsKeepContextAcrossScansAndPeriodChanges() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("session.jsonl")
    let data = try context(model: "model-a", effort: "high") + Data([10])
        + codex(100, output: 10, at: "2026-10-01T23:59:00Z") + Data([10])
    try data.write(to: file)
    let scanner = UsageScanner()
    let today = try #require(ParsedLog.date("2026-10-02T00:00:00Z"))
    let now = try #require(ParsedLog.date("2026-10-03T00:00:00Z"))
    let initial = await scanner.scan(provider: .codex, root: directory, start: today, now: now)
    #expect(initial.usageByGroup.isEmpty)
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: try codex(160, output: 30) + Data([10]))
    try handle.close()
    let updated = await scanner.scan(provider: .codex, root: directory, start: today, now: now)
    #expect(updated.usageByGroup == [UsageGroup(model: "model-a", effort: "high"): TokenUsage(input: 60, output: 20, cacheRead: 30)])
    let week = await scanner.scan(provider: .codex, root: directory, start: today.addingTimeInterval(-86_400), now: now)
    #expect(week.usageByGroup == [UsageGroup(model: "model-a", effort: "high"): week.tokens])
    #expect(week.tokens.input == 160)
}

@Test func rateLimitOnlyEventsWorkWithoutTokenUsage() throws {
    var parsed = ParsedLog(sessionID: "session")
    parsed.consume(try line(["type": "event_msg", "timestamp": "2026-10-02T03:00:00Z", "payload": [
        "type": "token_count", "info": NSNull(), "rate_limits": ["limit_id": "codex", "plan_type": "plus",
            "primary": ["used_percent": 35.0, "window_minutes": 300, "resets_at": 1_790_924_645]]
    ]]), provider: .codex)
    #expect(parsed.events.isEmpty)
    let limit = try #require(parsed.limits)
    #expect(limit.windows.first?.usedPercent == 35)
    #expect(limit.plan == "plus")
    #expect(limit.windows.first?.expired(at: .distantFuture) == true)
}

@Test func bridgeStoresOnlyLimitsAndKeepsLastKnownWindows() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try ClaudeBridge.capture(try line(["cwd": "private/path", "session_id": "private-id", "rate_limits": [
        "five_hour": ["used_percentage": 23.5, "resets_at": 1_790_924_645]
    ]]), directory: directory)
    let file = directory.appendingPathComponent("claude-limits.json")
    let saved = try Data(contentsOf: file)
    #expect(!String(decoding: saved, as: UTF8.self).contains("private"))
    let limits = try JSONDecoder().decode(LimitSnapshot.self, from: saved)
    #expect(limits.windows.first?.usedPercent == 23.5)
    try ClaudeBridge.capture(try line([:]), directory: directory)
    #expect(try Data(contentsOf: file) == saved)
    try ClaudeBridge.capture(try line(["rate_limits": [
        "seven_day": ["used_percentage": 80, "resets_at": 1_791_000_000]
    ]]), directory: directory)
    let merged = try JSONDecoder().decode(LimitSnapshot.self, from: Data(contentsOf: file))
    #expect(merged.windows.map(\.id) == ["five_hour", "seven_day"])
    #expect(merged.windows.first?.usedPercent == 23.5)
}

@Test func codexLimitsRemainVisibleOutsideTheTokenPeriod() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("yesterday.jsonl")
    let oldDate = try #require(ParsedLog.date("2026-10-01T03:00:00Z"))
    let data = try line(["type": "event_msg", "timestamp": "2026-10-01T03:00:00Z", "payload": [
        "type": "token_count", "rate_limits": ["primary": ["used_percent": 75.0, "window_minutes": 300]]
    ]]) + Data([10])
    try data.write(to: file)
    try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)
    let scanner = UsageScanner()
    let start = try #require(ParsedLog.date("2026-10-02T00:00:00Z"))
    let snapshot = await scanner.scan(provider: .codex, root: directory, start: start,
                                     now: try #require(ParsedLog.date("2026-10-02T12:00:00Z")))
    #expect(snapshot.tokens.total == 0)
    #expect(snapshot.files == 0)
    #expect(snapshot.limits?.windows.first?.usedPercent == 75)
}

@Test func bridgeInstallerPreservesExistingStatusLineAndOtherSettings() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let support = directory.appendingPathComponent("support ' quoted")
    let settingsURL = directory.appendingPathComponent("settings.json")
    let original: [String: Any] = ["type": "command", "command": "printf 'existing-output'", "padding": 2, "refreshInterval": 5]
    try line(["statusLine": original, "theme": "dark"]).write(to: settingsURL)
    let executable = directory.appendingPathComponent("fake-helper")
    try Data("#!/bin/sh\n/bin/cat >/dev/null\n".utf8).write(to: executable)
    let installer = BridgeInstaller(settingsURL: settingsURL, directory: support)
    try installer.install(executable: executable)
    #expect(installer.installed)
    try installer.install(executable: executable)
    let wrapped = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
    #expect(wrapped?["theme"] as? String == "dark")
    #expect((wrapped?["statusLine"] as? [String: Any])?["padding"] as? Int == 2)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [support.appendingPathComponent("claude-statusline.sh").path]
    let input = Pipe(); let output = Pipe()
    process.standardInput = input; process.standardOutput = output
    try process.run()
    try input.fileHandleForWriting.write(contentsOf: Data("{}".utf8))
    try input.fileHandleForWriting.close()
    let result = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(String(decoding: result, as: UTF8.self) == "existing-output")
    try installer.uninstall()
    #expect(!installer.installed)
    let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
    #expect((restored?["statusLine"] as? NSDictionary) == (original as NSDictionary))
    #expect(restored?["theme"] as? String == "dark")
}

@Test func bridgeUninstallKeepsUserChangesMadeAfterInstallation() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let settings = directory.appendingPathComponent("settings.json")
    let executable = directory.appendingPathComponent("helper")
    try Data("#!/bin/sh\n".utf8).write(to: executable)
    let installer = BridgeInstaller(settingsURL: settings, directory: directory.appendingPathComponent("support"))
    try installer.install(executable: executable)
    try line(["statusLine": ["type": "command", "command": "my-new-command"]]).write(to: settings)
    try installer.uninstall()
    let changed = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
    #expect((changed?["statusLine"] as? [String: Any])?["command"] as? String == "my-new-command")
}

@Test func periodsFollowLocalCalendarIncludingDST() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
    let now = try #require(ParsedLog.date("2026-03-09T12:00:00Z"))
    #expect(UsagePeriod.week.start(now: now, calendar: calendar) == ParsedLog.date("2026-03-03T05:00:00Z"))
}
