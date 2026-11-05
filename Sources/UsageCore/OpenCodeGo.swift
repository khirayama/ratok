import Foundation

public enum OpenCodeGoKeySource: String, Sendable, Equatable {
    case keychain
    case environment
    case claudeSettings
    case opencodeAuth
}

public struct OpenCodeGoCredential: Sendable, Equatable {
    public var key: String
    public var source: OpenCodeGoKeySource
    public init(key: String, source: OpenCodeGoKeySource) {
        self.key = key
        self.source = source
    }
}

public struct OpenCodeGoKeychainError: Error, LocalizedError, Sendable {
    public var status: Int32
    public var errorDescription: String? {
        "OpenCode Go APIキーをKeychainに保存できませんでした（\(status)）。"
    }
}

/// Finds the OpenCode Go API key without reading shell startup files. A key saved in Ratok's
/// Keychain wins; otherwise the same environment variables and local settings used by the
/// Claude Code / Codex wrappers are checked.
public enum OpenCodeGoCredentials {
    private static let service = "dev.ratok.mac.opencode-go"
    private static let account = "api-key"

    public static func detect(environment: [String: String] = ProcessInfo.processInfo.environment,
                              home: URL = FileManager.default.homeDirectoryForCurrentUser) -> OpenCodeGoCredential? {
        if let key = keychainKey() {
            return OpenCodeGoCredential(key: key, source: .keychain)
        }
        if let key = key(fromEnvironment: environment) {
            return OpenCodeGoCredential(key: key, source: .environment)
        }
        if let key = key(fromClaudeSettings: home.appendingPathComponent(".claude/settings.json")) {
            return OpenCodeGoCredential(key: key, source: .claudeSettings)
        }
        if let key = key(fromOpenCodeAuth: home.appendingPathComponent(".local/share/opencode/auth.json")) {
            return OpenCodeGoCredential(key: key, source: .opencodeAuth)
        }
        return nil
    }

    static func key(fromEnvironment environment: [String: String]) -> String? {
        if let key = usable(environment["OPENCODE_API_KEY"]) { return key }
        let baseURL = environment["ANTHROPIC_BASE_URL"] ?? ""
        guard baseURL.contains("opencode.ai/inference/go") else { return nil }
        return usable(environment["ANTHROPIC_AUTH_TOKEN"])
    }

    static func key(fromClaudeSettings url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = object["env"] as? [String: Any] else { return nil }
        let values = env.compactMapValues { $0 as? String }
        return key(fromEnvironment: values)
    }

    static func key(fromOpenCodeAuth url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let provider = object["opencode-go"] as? [String: Any] else { return nil }
        return usable(provider["key"] as? String)
    }

    static func usable(_ value: String?) -> String? {
        guard let value else { return nil }
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: \.isWhitespace) else { return nil }
        return key
    }

    public static func keychainKey() -> String? {
        let result = security(["find-generic-password", "-s", service, "-a", account, "-w"])
        guard result.status == 0,
              let key = String(data: result.data, encoding: .utf8) else { return nil }
        return usable(key)
    }

    public static func saveToKeychain(_ value: String) throws {
        guard let key = usable(value) else { throw OpenCodeGoKeychainError(status: 22) }
        // The login keychain is shared with the `security` CLI, so ad-hoc app updates do not
        // change the item's access control.
        let result = security(["add-generic-password", "-U", "-s", service, "-a", account, "-w", key])
        guard result.status == 0 else { throw OpenCodeGoKeychainError(status: result.status) }
    }

    public static func removeFromKeychain() {
        _ = security(["delete-generic-password", "-s", service, "-a", account])
    }

    private static func security(_ arguments: [String]) -> (status: Int32, data: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (1, Data()) }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}

public enum OpenCodeGoRead: Sendable, Equatable {
    case available(LimitSnapshot)
    case unauthorized
    case failed
}

/// Reads OpenCode Go's account-wide usage windows from the endpoint behind the inference API.
/// The endpoint is used by the Claude Code and Codex harnesses and is not a documented public API.
public enum OpenCodeGoAccount {
    static func limits(fromResponse data: Data, now: Date) -> LimitSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = object["usage"] as? [String: Any] else { return nil }
        let windows = [("rolling", "primary", "5時間"), ("weekly", "secondary", "週間"), ("monthly", "monthly", "月間")]
            .compactMap { key, id, title -> LimitWindow? in
                guard let value = usage[key] as? [String: Any],
                      let percent = (value["percent"] as? NSNumber)?.doubleValue,
                      percent.isFinite else { return nil }
                let reset = (value["resetsAt"] as? String).flatMap(ParsedLog.date)
                return LimitWindow(id: id, title: title, usedPercent: max(0, percent), resetsAt: reset)
            }
        guard !windows.isEmpty else { return nil }
        return LimitSnapshot(windows: windows, observedAt: now)
    }

    public static func readLimits(key: String, timeout: TimeInterval = 20,
                                  now: Date = Date()) async -> OpenCodeGoRead {
        guard let key = OpenCodeGoCredentials.usable(key) else { return .unauthorized }
        let url = URL(string: "https://opencode.ai/inference/go/v1/usage")!
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: sessionConfiguration(), delegate: AccountSessionDelegate(),
                                 delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return .failed }
        switch http.statusCode {
        case 200:
            guard let limits = limits(fromResponse: data, now: now) else { return .failed }
            return .available(limits)
        case 401, 403:
            return .unauthorized
        default:
            return .failed
        }
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
}
