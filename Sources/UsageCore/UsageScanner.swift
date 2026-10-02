import Foundation

/// Owns incremental file offsets and parsed usage; disk scanning never blocks the UI actor.
public actor UsageScanner {
    private struct CachedFile {
        var offset: UInt64 = 0
        var pending = Data()
        var modified: Date = .distantPast
        var inode: UInt64 = 0
        var parsed: ParsedLog
    }
    private var cache: [String: CachedFile] = [:]
    public init() {}

    public func scan(provider: Provider, root: URL, start: Date, now: Date = Date(), bridge: URL? = nil) -> UsageSnapshot {
        var result = UsageSnapshot()
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else {
            result.issues = ["利用ログがありません。\(provider.name)を利用すると表示されます。"]
            if let bridge { result.limits = readBridge(bridge) }
            return result
        }
        var enumerationFailed = false
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                                  options: [.skipsHiddenFiles], errorHandler: { _, _ in enumerationFailed = true; return true }) else {
            result.issues = ["利用ログのフォルダを読み取れません。"]
            return result
        }
        var combined: [String: UsageEvent] = [:]
        var activePaths = Set<String>()
        var recentFiles: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            activePaths.insert(url.path)
            do {
                let attrs = try manager.attributesOfItem(atPath: url.path)
                let modified = attrs[.modificationDate] as? Date ?? .distantPast
                if provider == .codex {
                    recentFiles.append((url, modified))
                    recentFiles.sort { $0.modified > $1.modified }
                    if recentFiles.count > 8 { recentFiles.removeLast() }
                }
                // Old files cannot have newer events; Codex directory dates alone don't cover resumed sessions.
                guard modified >= start else { continue }
                let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
                let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
                var entry = cache[url.path] ?? CachedFile(parsed: ParsedLog(sessionID: url.lastPathComponent))
                if size < entry.offset || entry.inode != inode || (size == entry.offset && modified != entry.modified) {
                    entry = CachedFile(parsed: ParsedLog(sessionID: url.lastPathComponent))
                }
                if size > entry.offset {
                    let file = try FileHandle(forReadingFrom: url)
                    defer { try? file.close() }
                    try file.seek(toOffset: entry.offset)
                    while let chunk = try file.read(upToCount: 262_144), !chunk.isEmpty {
                        entry.offset += UInt64(chunk.count)
                        entry.pending.append(chunk)
                        var consumed = entry.pending.startIndex
                        while let newline = entry.pending[consumed...].firstIndex(of: 10) {
                            entry.parsed.consume(Data(entry.pending[consumed..<newline]), provider: provider)
                            consumed = newline + 1
                        }
                        if consumed > entry.pending.startIndex { entry.pending.removeSubrange(..<consumed) }
                    }
                }
                entry.modified = modified; entry.inode = inode
                cache[url.path] = entry
                result.files += 1
                for event in entry.parsed.events.values where event.date >= start && event.date <= now {
                    if let previous = combined[event.id] {
                        var preferred = event.tokens.total > previous.tokens.total ? event : previous
                        let other = event.tokens.total > previous.tokens.total ? previous : event
                        preferred.group.model = preferred.group.model ?? other.group.model
                        preferred.group.effort = preferred.group.effort ?? other.group.effort
                        preferred.tokens.cacheWrite1h = min(preferred.tokens.cacheWrite,
                            max(preferred.tokens.cacheWrite1h, other.tokens.cacheWrite1h))
                        combined[event.id] = preferred
                    } else { combined[event.id] = event }
                }
                if let limits = entry.parsed.limits, limits.observedAt <= now,
                   result.limits == nil || limits.observedAt > result.limits!.observedAt { result.limits = limits }
                if entry.parsed.malformedLines > 0, !result.issues.contains("一部の利用ログを読み取れませんでした。") {
                    result.issues.append("一部の利用ログを読み取れませんでした。")
                }
            } catch {
                if !result.issues.contains("一部のログにアクセスできません。") { result.issues.append("一部のログにアクセスできません。") }
            }
        }
        cache = cache.filter { !($0.key.hasPrefix(root.path + "/")) || activePaths.contains($0.key) }
        for event in combined.values {
            result.tokens = result.tokens + event.tokens
            if event.tokens.total > 0 {
                result.usageByGroup[event.group, default: TokenUsage()] = result.usageByGroup[event.group, default: TokenUsage()] + event.tokens
            }
            result.lastActivity = max(result.lastActivity ?? .distantPast, event.date)
        }
        if enumerationFailed { result.issues.append("一部のフォルダにアクセスできません。") }
        // Limits are independent of the token period, including before today's first session.
        if provider == .codex, result.limits == nil {
            for candidate in recentFiles {
                if let limits = latestCodexLimits(candidate.url, now: now),
                   result.limits == nil || limits.observedAt > result.limits!.observedAt {
                    result.limits = limits
                }
            }
        }
        if let bridge { result.limits = readBridge(bridge) }
        return result
    }

    private func latestCodexLimits(_ url: URL, now: Date) -> LimitSnapshot? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard var position = try? handle.seekToEnd() else { return nil }
        var carry = Data()
        while position > 0 {
            let count = min(position, 262_144)
            position -= count
            do {
                try handle.seek(toOffset: position)
                guard var block = try handle.read(upToCount: Int(count)) else { return nil }
                block.append(carry)
                let lines = block.split(separator: 10, omittingEmptySubsequences: false)
                let complete = position == 0 ? lines[...] : lines.dropFirst()
                for line in complete.reversed() where line.range(of: Data("\"rate_limits\"".utf8)) != nil {
                    var parsed = ParsedLog(sessionID: url.lastPathComponent)
                    parsed.consume(Data(line), provider: .codex)
                    if let limits = parsed.limits, limits.observedAt <= now { return limits }
                }
                carry = position == 0 ? Data() : Data(lines.first ?? Data.SubSequence())
            } catch { return nil }
        }
        return nil
    }

    private func readBridge(_ url: URL) -> LimitSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LimitSnapshot.self, from: data)
    }
}
