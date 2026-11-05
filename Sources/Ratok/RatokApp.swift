import AppKit
import SwiftUI
import UsageCore

@main
enum EntryPoint {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--capture-claude") {
            let directory: URL
            if let index = args.firstIndex(of: "--support-directory"), args.indices.contains(index + 1) {
                directory = URL(fileURLWithPath: args[index + 1])
            } else { directory = UsagePaths.support }
            do { try ClaudeBridge.capture(FileHandle.standardInput.readDataToEndOfFile(), directory: directory) }
            catch { exit(1) }
            return
        }
        if args.contains("--diagnose") {
            Task {
                let scanner = UsageScanner()
                var combined: [Provider: UsageSnapshot] = [:]
                for logProvider in [Provider.claude, .codex] {
                    let root = logProvider == .claude
                        ? UsagePaths.claude.appendingPathComponent("projects")
                        : UsagePaths.codex.appendingPathComponent("sessions")
                    let snapshots = await scanner.scanByEndpoint(
                        provider: logProvider, root: root, start: UsagePeriod.today.start(now: Date()),
                        bridge: logProvider == .claude ? UsagePaths.claudeLimits : nil)
                    for (endpoint, snapshot) in snapshots {
                        combined[endpoint] = combined[endpoint]?.merging(snapshot) ?? snapshot
                    }
                }
                for endpoint in [Provider.claude, .codex, .openCodeGo] {
                    guard let snapshot = combined[endpoint] else { continue }
                    let cost = snapshot.estimatedCost
                    let usd = cost.amountUSD.map { String(format: "%.6f", $0) } ?? "unavailable"
                    print("\(endpoint.name) [\(endpoint.endpointName)]: input=\(snapshot.tokens.input) output=\(snapshot.tokens.output) cacheRead=\(snapshot.tokens.cacheRead) cacheWrite=\(snapshot.tokens.cacheWrite) files=\(snapshot.files) limits=\(snapshot.limits?.windows.count ?? 0) issues=\(snapshot.issues.count) apiEstimateUSD=\(usd) unpricedTokens=\(cost.unpricedTokens)")
                }
                let account = await ClaudeAccount.readLimits()
                print("Claude account limits: " + (account?.windows.map { "\($0.id)=\($0.usedPercent)%" }.joined(separator: " ") ?? "unavailable"))
                if let key = OpenCodeGoCredentials.detect()?.key {
                    switch await OpenCodeGoAccount.readLimits(key: key) {
                    case .available(let limits):
                        print("OpenCode Go limits: " + limits.windows.map { "\($0.id)=\($0.usedPercent)%" }.joined(separator: " "))
                    case .unauthorized:
                        print("OpenCode Go limits: API key rejected")
                    case .failed:
                        print("OpenCode Go limits: unavailable")
                    }
                } else {
                    print("OpenCode Go limits: API key not found")
                }
                exit(0)
            }
            dispatchMain()
        }
        if args.contains("--preview") { RatokPreviewApp.main() }
        else { RatokApp.main() }
    }
}

struct RatokApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = UsageStore()
    @StateObject private var updates = AppUpdater()
    var body: some Scene {
        MenuBarExtra {
            Dashboard(store: store, updates: updates)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

struct RatokPreviewApp: App {
    @State private var store = UsageStore()
    @StateObject private var updates = AppUpdater(enabled: false)
    var body: some Scene {
        WindowGroup("Ratok Preview") { Dashboard(store: store, updates: updates) }
            .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}
