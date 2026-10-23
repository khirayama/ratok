import Foundation
import Testing
@testable import UsageCore

@Test func extremeLogCountsDoNotOverflowDuringParsingAggregationOrPricing() throws {
    let usage: [String: Any] = ["input_tokens": Int.max, "output_tokens": Int.max,
                                "cache_read_input_tokens": Int.max, "cache_creation_input_tokens": Int.max]
    var parsed = ParsedLog(sessionID: "extreme")
    for id in ["one", "two"] {
        let object: [String: Any] = ["type": "assistant", "timestamp": "2026-10-01T03:00:00Z",
                                     "message": ["id": id, "model": "gpt-5", "usage": usage]]
        parsed.consume(try JSONSerialization.data(withJSONObject: object), provider: .claude)
    }
    #expect(parsed.events.count == 2)
    let total = parsed.events.values.reduce(TokenUsage()) { $0 + $1.tokens }
    #expect(total.input == Int.max)
    #expect(total.output == Int.max)
    #expect(total.total == Int.max)
    #expect(total.uncachedInput == 0)
    #expect(total.uncachedTotal == Int.max)
    let priced = APIPricing.estimate(model: "gpt-5", tokens: total)
    #expect((priced + priced).pricedTokens == Int.max)
    #expect(priced.amountUSD?.isFinite == true)
    let unpriced = APIPricing.estimate(model: nil, tokens: total)
    #expect((unpriced + unpriced).unpricedTokens == Int.max)
}

@Test func negativeStoredTokenCountsAreNormalizedBeforeArithmetic() throws {
    let data = Data(#"{"input":-9223372036854775808,"output":10,"cacheRead":-1,"cacheWrite":-1}"#.utf8)
    let tokens = try JSONDecoder().decode(TokenUsage.self, from: data)
    #expect(tokens == TokenUsage(output: 10))
    #expect(TokenUsage.delta(TokenUsage(), tokens) == TokenUsage())
}

private func permissions(_ url: URL) throws -> Int {
    try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
}

@Test func bridgeFilesRestrictAccessInAnExistingSharedDirectory() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
    let settings = directory.appendingPathComponent("settings.json")
    try Data(#"{"statusLine":{"command":"echo previous"}}"#.utf8).write(to: settings)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: settings.path)
    let helper = directory.appendingPathComponent("helper")
    try Data("#!/bin/sh\n".utf8).write(to: helper)
    let support = directory.appendingPathComponent("support")
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o755])

    try BridgeInstaller(settingsURL: settings, directory: support).install(executable: helper)
    try ClaudeBridge.capture(Data(#"{"rate_limits":{"five_hour":{"used_percentage":20}}}"#.utf8), directory: support)

    #expect(try permissions(support) == 0o700)
    #expect(try permissions(settings) == 0o600)
    for name in ["previous-statusline.json", "claude-limits.json"] {
        #expect(try permissions(support.appendingPathComponent(name)) == 0o600)
    }
    for name in ["RatokCLI", "claude-statusline.sh"] {
        #expect(try permissions(support.appendingPathComponent(name)) == 0o700)
    }
}

@Test func privateWritesReplaceSymlinksWithoutModifyingTheirTargets() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = directory.appendingPathComponent("original")
    let destination = directory.appendingPathComponent("settings.json")
    try Data("unchanged".utf8).write(to: original)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: original.path)
    try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: original)
    try PrivateFile.write(Data("private".utf8), to: destination)
    #expect(try Data(contentsOf: original) == Data("unchanged".utf8))
    #expect(try permissions(original) == 0o644)
    #expect(try Data(contentsOf: destination) == Data("private".utf8))
    #expect(try permissions(destination) == 0o600)
    #expect(try FileManager.default.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType == .typeRegular)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["original", "settings.json"])
}

@Test func failedPrivateWriteRemovesTheTemporaryFile() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    // A file cannot replace a directory; the failed rename must leave no sensitive temporary file.
    let child = directory.appendingPathComponent("child")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    #expect(throws: (any Error).self) { try PrivateFile.write(Data("secret".utf8), to: child) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["child"])
}

@Test func accountSessionDoesNotUseCachesCookiesOrStoredCredentials() {
    let configuration = ClaudeAccount.sessionConfiguration()
    #expect(configuration.urlCache == nil)
    #expect(configuration.httpCookieStorage == nil)
    #expect(!configuration.httpShouldSetCookies)
    #expect(configuration.urlCredentialStorage == nil)
    #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
}

@Test(arguments: ["https://other.example/usage", "https://api.anthropic.com/other", "http://api.anthropic.com/usage"])
func accountSessionRejectsRedirects(destination: String) async throws {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let source = try #require(URL(string: "https://api.anthropic.com/api/oauth/usage"))
    let redirect = URLRequest(url: try #require(URL(string: destination)))
    let response = try #require(HTTPURLResponse(url: source, statusCode: 302, httpVersion: nil,
                                              headerFields: ["Location": destination]))
    let forwarded: URLRequest? = await withCheckedContinuation { continuation in
        AccountSessionDelegate().urlSession(session, task: session.dataTask(with: source),
                                           willPerformHTTPRedirection: response, newRequest: redirect) {
            continuation.resume(returning: $0)
        }
    }
    #expect(forwarded == nil)
}

private final class AccountProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // Every request is intercepted; these tests never access the keychain or network.
        let valid = request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage"
            && request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token"
            && request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20"
        let response = HTTPURLResponse(url: request.url!, statusCode: valid ? 200 : 401,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"five_hour":{"utilization":42}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func accountRequestUsesOnlyTheExpectedEndpointAndRejectsHTTPFailures() async {
    let configuration = ClaudeAccount.sessionConfiguration()
    configuration.protocolClasses = [AccountProtocol.self]
    let limits = await ClaudeAccount.readLimits(token: "test-token", configuration: configuration)
    #expect(limits?.windows.first?.usedPercent == 42)
    let failed = await ClaudeAccount.readLimits(token: "invalid-token", configuration: configuration)
    #expect(failed == nil)
}
