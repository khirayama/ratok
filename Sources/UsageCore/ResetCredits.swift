import Foundation

/// A banked Codex rate-limit reset that has not been redeemed yet.
public struct ResetCredit: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String?
    public var expiresAt: Date?
    public init(id: String, title: String? = nil, expiresAt: Date? = nil) {
        self.id = id; self.title = title; self.expiresAt = expiresAt
    }
}

public struct ResetCreditSnapshot: Sendable, Equatable {
    public var availableCount: Int
    /// Detail rows for available credits. The backend may cap this list below `availableCount`.
    public var credits: [ResetCredit]
    public var observedAt: Date
    public init(availableCount: Int, credits: [ResetCredit], observedAt: Date) {
        self.availableCount = availableCount; self.credits = credits; self.observedAt = observedAt
    }
    /// Credits already past their expiry are not counted; credits without details are trusted as reported.
    public func remainingCount(at now: Date) -> Int {
        max(0, availableCount - credits.count { $0.expiresAt.map { $0 <= now } ?? false })
    }
    public func nextExpiry(at now: Date) -> Date? {
        credits.compactMap(\.expiresAt).filter { $0 > now }.min()
    }
    /// Banked resets rarely change: check daily and when the earliest one expires, hourly while there are none.
    public func nextFetch(after now: Date) -> Date {
        guard remainingCount(at: now) > 0 else { return now.addingTimeInterval(3600) }
        return min(now.addingTimeInterval(86_400), nextExpiry(at: now) ?? .distantFuture)
    }
}

public enum ResetCreditRead: Sendable, Equatable {
    case available(ResetCreditSnapshot)
    /// The source answered, but it has no banked-reset information for this account.
    case unavailable
    /// Not installed, signed out, offline, or an unexpected answer; the last known value stays valid.
    case failed
}

/// One answer from the Codex app server: banked resets plus the current limits of every pool.
public struct CodexAccountRead: Sendable, Equatable {
    public var resetCredits: ResetCreditRead
    /// Includes pools such as Luna Reserve that rollouts only record while that pool is in use.
    public var limits: LimitSnapshot?
    public init(resetCredits: ResetCreditRead, limits: LimitSnapshot? = nil) {
        self.resetCredits = resetCredits; self.limits = limits
    }
}

/// Reads banked resets and limits through the Codex CLI's own app server, so Codex keeps handling authentication.
public enum CodexAppServer {
    /// Parses one JSON-RPC line; returns nil unless it answers request `id` with at least one limit window.
    static func limits(fromResponse line: Data, id: Int, now: Date) -> LimitSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (object["id"] as? NSNumber)?.intValue == id,
              let result = object["result"] as? [String: Any] else { return nil }
        let main = result["rateLimits"] as? [String: Any]
        var buckets = (result["rateLimitsByLimitId"] as? [String: Any] ?? [:]).compactMapValues { $0 as? [String: Any] }
        if buckets.isEmpty, let main { buckets = [main["limitId"] as? String ?? "codex": main] }
        // JSON objects are unordered: show the main Codex pool first, then the others by name.
        let ids = buckets.keys.sorted { ($0 == "codex" ? "" : $0) < ($1 == "codex" ? "" : $1) }
        let windows = ids.flatMap { key -> [LimitWindow] in
            guard let bucket = buckets[key] else { return [] }
            return ParsedLog.codexWindows(in: bucket, bucket: bucket["limitId"] as? String ?? key,
                                          name: bucket["limitName"] as? String, observedAt: now)
        }
        guard !windows.isEmpty else { return nil }
        return LimitSnapshot(windows: windows, observedAt: now, plan: main?["planType"] as? String)
    }

    /// Parses one JSON-RPC line; returns nil unless it answers request `id`.
    static func resetCredits(fromResponse line: Data, id: Int, now: Date) -> ResetCreditRead? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (object["id"] as? NSNumber)?.intValue == id else { return nil }
        guard let result = object["result"] as? [String: Any] else { return .failed }
        guard let summary = result["rateLimitResetCredits"] as? [String: Any],
              let count = (summary["availableCount"] as? NSNumber)?.intValue else { return .unavailable }
        let credits = (summary["credits"] as? [[String: Any]] ?? []).compactMap { value -> ResetCredit? in
            guard let id = value["id"] as? String, value["status"] as? String == "available" else { return nil }
            let title = (value["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let expires = (value["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return ResetCredit(id: id, title: title, expiresAt: expires)
        }
        return .available(ResetCreditSnapshot(availableCount: max(0, count), credits: credits, observedAt: now))
    }

    /// Blocks until Codex answers or `timeout` passes.
    public static func readAccount(timeout: TimeInterval = 20, now: Date = Date()) -> CodexAccountRead {
        let process = Process()
        // Apps launched from Finder lack the user's PATH (npm, Homebrew, version managers); their shell has it.
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-ilc", "exec codex app-server"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return CodexAccountRead(resetCredits: .failed) }
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning { process.terminate() }
        }
        let requests = [
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"ratok","title":"Ratok","version":"1"}}}"#,
            #"{"method":"initialized"}"#,
            #"{"id":2,"method":"account/rateLimits/read","params":{}}"#,
        ].joined(separator: "\n") + "\n"
        do { try input.fileHandleForWriting.write(contentsOf: Data(requests.utf8)) } catch { return CodexAccountRead(resetCredits: .failed) }
        var pending = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { return CodexAccountRead(resetCredits: .failed) }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                if let read = resetCredits(fromResponse: line, id: 2, now: now) {
                    return CodexAccountRead(resetCredits: read, limits: limits(fromResponse: line, id: 2, now: now))
                }
            }
        }
    }
}
