import Foundation

public enum ClaudeBridge {
    public static func capture(_ data: Data, directory: URL = UsagePaths.support, now: Date = Date()) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let rate = object["rate_limits"] as? [String: Any] ?? [:]
        let target = directory.appendingPathComponent("claude-limits.json")
        let previous = (try? Data(contentsOf: target)).flatMap { try? JSONDecoder().decode(LimitSnapshot.self, from: $0) }
        var captured = false
        let windows = [("five_hour", "5時間"), ("seven_day", "週間"), ("spend_limit", "追加利用")].compactMap { key, title -> LimitWindow? in
            guard let value = rate[key] as? [String: Any],
                  let percent = value["used_percentage"] as? Double, percent.isFinite else {
                return previous?.windows.first { $0.id == key }
            }
            captured = true
            return LimitWindow(id: key, title: title, usedPercent: max(0, percent),
                               resetsAt: (value["resets_at"] as? Double).map(Date.init(timeIntervalSince1970:)))
        }
        // Status lines rendered before a session's first response carry no rate_limits; keep the last known values.
        guard captured else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let snapshot = LimitSnapshot(windows: windows, observedAt: now)
        try JSONEncoder().encode(snapshot).write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
}

public struct BridgeInstaller: Sendable {
    public let settingsURL: URL
    public let directory: URL
    public init(settingsURL: URL = UsagePaths.claude.appendingPathComponent("settings.json"), directory: URL = UsagePaths.support) {
        self.settingsURL = settingsURL; self.directory = directory
    }
    private var wrapper: URL { directory.appendingPathComponent("claude-statusline.sh") }
    private var backup: URL { directory.appendingPathComponent("previous-statusline.json") }
    private var command: String { "/bin/sh " + Self.quote(wrapper.path) }
    private var legacyWrapper: URL { UsagePaths.legacySupport.appendingPathComponent("claude-statusline.sh") }
    private var legacyBackup: URL { UsagePaths.legacySupport.appendingPathComponent("previous-statusline.json") }
    private var legacyCommand: String { "/bin/sh " + Self.quote(legacyWrapper.path) }

    public var installed: Bool {
        guard let settings = try? readSettings(), let status = settings["statusLine"] as? [String: Any] else { return false }
        let installedCommand = status["command"] as? String
        return installedCommand == command || installedCommand == legacyCommand
    }

    public func install(executable: URL) throws {
        let manager = FileManager.default
        var settings = try readSettings()
        let previous = settings["statusLine"] as? [String: Any]
        if previous?["command"] as? String == command { return }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let helper = directory.appendingPathComponent("RatokCLI")
        if executable.standardizedFileURL != helper.standardizedFileURL {
            let executableData = try Data(contentsOf: executable)
            try executableData.write(to: helper, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        }
        let saved: [String: Any] = ["statusLine": settings["statusLine"] ?? NSNull()]
        try JSONSerialization.data(withJSONObject: saved, options: [.prettyPrinted, .sortedKeys]).write(to: backup, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        let originalCommand = previous?["command"] as? String
        let output = originalCommand.map { "/bin/sh -c \(Self.quote($0)) < \"$ratok_input\"" } ?? "printf 'Claude Code · Ratok\\n'"
        let script = """
        #!/bin/sh
        # Ratok captures only rate-limit fields, then preserves the original status line.
        umask 077
        ratok_input=$(/usr/bin/mktemp -t ratok-statusline) || exit 1
        trap '/bin/rm -f "$ratok_input"' EXIT HUP INT TERM
        /bin/cat > "$ratok_input"
        \(Self.quote(helper.path)) --capture-claude --support-directory \(Self.quote(directory.path)) < "$ratok_input" 2>/dev/null
        \(output)
        """
        try Data(script.utf8).write(to: wrapper, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        var status = previous ?? [:]
        status["type"] = "command"; status["command"] = command
        settings["statusLine"] = status
        try writeSettings(settings)
    }

    public func uninstall() throws {
        var settings = try readSettings()
        guard let status = settings["statusLine"] as? [String: Any],
              let installedCommand = status["command"] as? String,
              installedCommand == command || installedCommand == legacyCommand else { return }
        let backupURL = installedCommand == legacyCommand ? legacyBackup : backup
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: backupURL)) as? [String: Any]
        if let previous = saved?["statusLine"], !(previous is NSNull) { settings["statusLine"] = previous }
        else { settings.removeValue(forKey: "statusLine") }
        try writeSettings(settings)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("claude-limits.json"))
    }

    private func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        guard let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return settings
    }
    private func writeSettings(_ settings: [String: Any]) throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let mode = (try? FileManager.default.attributesOfItem(atPath: settingsURL.path)[.posixPermissions]) ?? 0o600
        try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]).write(to: settingsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: settingsURL.path)
    }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
