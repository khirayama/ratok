import Foundation

/// Reads Claude subscription limits from the endpoint behind Claude Code's `/usage`, so they stay current
/// while Claude Code is not running. The endpoint is not a documented API and may change without notice.
public enum ClaudeAccount {
    /// Parses the usage response; returns nil unless it has at least one limit window.
    static func limits(fromResponse data: Data, now: Date) -> LimitSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var windows = [("five_hour", "5時間"), ("seven_day", "週間")].compactMap { key, title -> LimitWindow? in
            guard let value = object[key] as? [String: Any],
                  let percent = (value["utilization"] as? NSNumber)?.doubleValue, percent.isFinite else { return nil }
            return LimitWindow(id: key, title: title, usedPercent: max(0, percent),
                               resetsAt: (value["resets_at"] as? String).flatMap(ParsedLog.date))
        }
        if let extra = object["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true,
           let percent = (extra["utilization"] as? NSNumber)?.doubleValue, percent.isFinite {
            windows.append(LimitWindow(id: "spend_limit", title: "追加利用", usedPercent: max(0, percent), resetsAt: nil))
        }
        guard !windows.isEmpty else { return nil }
        return LimitSnapshot(windows: windows, observedAt: now)
    }

    /// Extracts Claude Code's access token from its stored credentials; nil when missing or expired.
    /// Claude Code renews the token itself, so an expired one is left alone until Claude Code runs again.
    static func accessToken(fromCredentials data: Data, now: Date) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        if let expires = (oauth["expiresAt"] as? NSNumber)?.doubleValue, expires / 1000 <= now.timeIntervalSince1970 { return nil }
        return token
    }

    /// Claude Code keeps its credentials in the login keychain on macOS and in a file elsewhere.
    private static func credentials() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0, !data.isEmpty { return data }
        }
        return try? Data(contentsOf: UsagePaths.claude.appendingPathComponent(".credentials.json"))
    }

    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    /// Returns nil when signed out, offline, the token has expired, or the answer is unexpected;
    /// the last known value stays valid. The token is sent only to Anthropic and never stored.
    public static func readLimits(timeout: TimeInterval = 20, now: Date = Date()) async -> LimitSnapshot? {
        guard let token = credentials().flatMap({ accessToken(fromCredentials: $0, now: now) }) else { return nil }
        return await readLimits(token: token, timeout: timeout, now: now)
    }

    // A dedicated ephemeral session keeps account responses out of the shared disk cache and
    // prevents an authenticated request from being redirected to another URL.
    static func readLimits(token: String, timeout: TimeInterval = 20, now: Date = Date(),
                           configuration: URLSessionConfiguration = sessionConfiguration()) async -> LimitSnapshot? {
        let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let session = URLSession(configuration: configuration, delegate: AccountSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return limits(fromResponse: data, now: now)
    }
}

final class AccountSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
