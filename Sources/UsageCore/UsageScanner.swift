import Foundation

/// Owns incremental file offsets and parsed usage; disk scanning never blocks the UI actor.
public actor UsageScanner {
    private struct CachedFile: Sendable {
        var offset: UInt64 = 0
        var pending = Data()
        var modified: Date = .distantPast
        var inode: UInt64 = 0
        var parsed: ParsedLog
    }

    /// What one slice of the file list found; slices are counted in parallel and merged on the actor.
    private struct ChunkResult: Sendable {
        var entries: [String: CachedFile] = [:]
        var combined: [String: UsageEvent] = [:]
        var files = 0
        var limits: LimitSnapshot?
        var issues: Set<String> = []
    }

    /// One result slot per slice. Each slot is written by exactly one worker, so the buffer needs
    /// no further locking, and the work stays synchronous instead of occupying cooperative threads.
    private final class ChunkBuffer: @unchecked Sendable {
        let buffer: UnsafeMutableBufferPointer<ChunkResult?>
        init(count: Int) {
            buffer = .allocate(capacity: count)
            buffer.initialize(repeating: nil)
        }
        deinit {
            buffer.deinitialize()
            buffer.deallocate()
        }
    }

    private var cache: [String: CachedFile] = [:]
    public init() {}

    public func scan(provider: Provider, root: URL, start: Date, now: Date = Date(), bridge: URL? = nil) async -> UsageSnapshot {
        await scanByEndpoint(provider: provider, root: root, start: start, now: now, bridge: bridge)[provider] ?? UsageSnapshot()
    }

    /// Splits one log source into the API endpoints each request actually used. Claude Code
    /// message IDs distinguish Anthropic from OpenCode Go, and Codex records `model_provider`.
    /// `progress` receives the figures counted so far, at most a few times a second, so a long
    /// scan can show numbers while it runs.
    public func scanByEndpoint(provider: Provider, root: URL, start: Date, now: Date = Date(), bridge: URL? = nil,
                               progress: (@Sendable ([Provider: UsageSnapshot]) async -> Void)? = nil) async -> [Provider: UsageSnapshot] {
        var empty = UsageSnapshot()
        guard FileManager.default.fileExists(atPath: root.path) else {
            empty.issues = ["利用ログがありません。\(provider.name)を利用すると表示されます。"]
            if let bridge { empty.limits = readBridge(bridge) }
            // Report the (empty) result so the caller does not keep showing a loading state.
            await progress?([provider: empty])
            return [provider: empty]
        }
        guard let listing = logFiles(under: root) else {
            empty.issues = ["利用ログのフォルダを読み取れません。"]
            await progress?([provider: empty])
            return [provider: empty]
        }
        let bridgeLimits = bridge.flatMap { readBridge($0) }
        let activePaths = Set(listing.urls.map(\.path))
        var issues = Set<String>()

        // The directory walk already prefetched modification dates: reading them adds no stat, and
        // files older than the period never need to be opened.
        var candidates: [(url: URL, modified: Date)] = []
        var recentFiles: [(url: URL, modified: Date)] = []
        for url in listing.urls {
            let modified: Date
            do {
                modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    ?? .distantPast
            } catch {
                issues.insert("一部のログにアクセスできません。")
                continue
            }
            if provider == .codex { recentFiles.append((url, modified)) }
            // Old files cannot have newer events; Codex directory dates alone don't cover resumed sessions.
            if modified >= start { candidates.append((url, modified)) }
        }
        recentFiles.sort { $0.modified > $1.modified }
        if recentFiles.count > 8 { recentFiles.removeLast(recentFiles.count - 8) }

        var combined: [String: UsageEvent] = [:]
        var limits: LimitSnapshot?
        var files = 0

        func apply(_ part: ChunkResult) {
            for (path, entry) in part.entries { cache[path] = entry }
            for event in part.combined.values { Self.merge(event, into: &combined) }
            files += part.files
            issues.formUnion(part.issues)
            if let partLimits = part.limits, limits == nil || partLimits.observedAt > limits!.observedAt {
                limits = partLimits
            }
        }

        // Everything after the file walk, so partial and final results are built the same way.
        func build(final: Bool) -> [Provider: UsageSnapshot] {
            var snapshots: [Provider: UsageSnapshot] = [:]
            for event in combined.values {
                var snapshot = snapshots[event.endpoint] ?? UsageSnapshot()
                snapshot.endpoint = event.endpoint
                snapshot.tokens = snapshot.tokens + event.tokens
                if event.tokens.total > 0 {
                    snapshot.usageByGroup[event.group, default: TokenUsage()] =
                        snapshot.usageByGroup[event.group, default: TokenUsage()] + event.tokens
                }
                snapshot.lastActivity = max(snapshot.lastActivity ?? .distantPast, event.date)
                snapshot.files = snapshot.tokens.total > 0 ? files : 0
                snapshots[event.endpoint] = snapshot
            }
            var allIssues = issues
            if listing.enumerationFailed { allIssues.insert("一部のフォルダにアクセスできません。") }
            var effectiveLimits = limits
            // Reading the newest rollouts again is only needed once the walk has finished.
            if final, provider == .codex, effectiveLimits == nil {
                for candidate in recentFiles {
                    if let fresh = latestCodexLimits(candidate.url, now: now),
                       effectiveLimits == nil || fresh.observedAt > effectiveLimits!.observedAt {
                        effectiveLimits = fresh
                    }
                }
            }
            if bridge != nil { effectiveLimits = bridgeLimits }

            // The log provider owns the files/issues/limits; other endpoints found in the same
            // logs (for example OpenCode Go inside Claude Code) get their tokens only.
            var primary = snapshots[provider] ?? UsageSnapshot()
            primary.endpoint = provider
            primary.files = primary.tokens.total > 0 ? files : 0
            primary.issues = allIssues.sorted()
            primary.limits = effectiveLimits
            if !primary.issues.isEmpty { primary.files = files }
            snapshots[provider] = primary
            return snapshots
        }

        var lastProgress = Date.distantPast
        if !candidates.isEmpty {
            let parallelism = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 1))
            var index = 0
            var slice = 8
            // The first batch is small so figures land quickly; later batches grow so the cores
            // stay busy without paying per-task overhead for every file.
            while index < candidates.count {
                var batch: [[(url: URL, modified: Date)]] = []
                while batch.count < parallelism, index < candidates.count {
                    let end = min(index + slice, candidates.count)
                    batch.append(Array(candidates[index..<end]))
                    index = end
                }
                slice = min(slice * 2, 512)
                let chunks = batch
                // Each chunk gets only the cache entries it needs; merging stays on the actor.
                let cachedChunks: [[String: CachedFile]] = chunks.map { chunk in
                    var cached: [String: CachedFile] = [:]
                    for file in chunk { cached[file.url.path] = cache[file.url.path] }
                    return cached
                }
                let results = ChunkBuffer(count: chunks.count)
                DispatchQueue.concurrentPerform(iterations: chunks.count) { position in
                    results.buffer[position] = Self.scanChunk(chunks[position], cache: cachedChunks[position],
                                                              provider: provider, start: start, now: now)
                }
                for part in results.buffer {
                    if let part { apply(part) }
                }
                if let progress, Date().timeIntervalSince(lastProgress) >= 0.3 {
                    lastProgress = Date()
                    await progress(build(final: false))
                }
            }
        }
        cache = cache.filter { !($0.key.hasPrefix(root.path + "/")) || activePaths.contains($0.key) }
        return build(final: true)
    }

    /// Counts one slice of files. Runs off the actor, so its cache is a snapshot of the entries it needs.
    private nonisolated static func scanChunk(
        _ candidates: [(url: URL, modified: Date)],
        cache: [String: CachedFile],
        provider: Provider,
        start: Date,
        now: Date
    ) -> ChunkResult {
        var result = ChunkResult()
        let manager = FileManager.default
        for candidate in candidates {
            let url = candidate.url
            do {
                let attrs = try manager.attributesOfItem(atPath: url.path)
                let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
                let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
                var entry = cache[url.path] ?? CachedFile(parsed: ParsedLog(sessionID: url.lastPathComponent))
                if size < entry.offset || entry.inode != inode || (size == entry.offset && candidate.modified != entry.modified) {
                    entry = CachedFile(parsed: ParsedLog(sessionID: url.lastPathComponent))
                }
                if size > entry.offset {
                    try read(url: url, into: &entry, provider: provider)
                }
                entry.modified = candidate.modified; entry.inode = inode
                result.entries[url.path] = entry
                result.files += 1
                for event in entry.parsed.events.values where event.date >= start && event.date <= now {
                    merge(event, into: &result.combined)
                }
                if let entryLimits = entry.parsed.limits, entryLimits.observedAt <= now,
                   result.limits == nil || entryLimits.observedAt > result.limits!.observedAt {
                    result.limits = entryLimits
                }
                if entry.parsed.malformedLines > 0 { result.issues.insert("一部の利用ログを読み取れませんでした。") }
            } catch {
                result.issues.insert("一部のログにアクセスできません。")
            }
        }
        return result
    }

    /// Appends new bytes to a file's cache entry, parsing only the lines that carry usage.
    private nonisolated static func read(url: URL, into entry: inout CachedFile, provider: Provider) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        try file.seek(toOffset: entry.offset)
        while let chunk = try file.read(upToCount: 262_144), !chunk.isEmpty {
            entry.offset += UInt64(chunk.count)
            var buffer = entry.pending
            buffer.append(chunk)
            var consumed = 0
            // memchr/memmem instead of Collection.firstIndex: logs are gigabytes of conversation
            // text, and the generic search is an order of magnitude slower.
            buffer.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count, let hit = memchr(base + offset, 10, raw.count - offset) {
                    let end = UnsafeRawPointer(hit) - base
                    if ParsedLog.isRelevant(base + offset, end - offset, provider: provider) {
                        entry.parsed.consume(Data(bytes: base + offset, count: end - offset), provider: provider)
                    }
                    offset = end + 1
                }
                consumed = offset
            }
            entry.pending = consumed == buffer.count ? Data() : Data(buffer[consumed...])
        }
    }

    /// Keeps one event per message ID, preferring the record with the larger usage.
    private nonisolated static func merge(_ event: UsageEvent, into combined: inout [String: UsageEvent]) {
        guard let previous = combined[event.id] else { combined[event.id] = event; return }
        var preferred = event.tokens.total > previous.tokens.total ? event : previous
        let other = event.tokens.total > previous.tokens.total ? previous : event
        preferred.group.model = preferred.group.model ?? other.group.model
        preferred.group.effort = preferred.group.effort ?? other.group.effort
        preferred.group.tool = preferred.group.tool ?? other.group.tool
        preferred.endpoint = event.endpoint
        preferred.tokens.cacheWrite1h = min(preferred.tokens.cacheWrite,
            max(preferred.tokens.cacheWrite1h, other.tokens.cacheWrite1h))
        combined[event.id] = preferred
    }

    /// NSEnumerator cannot be iterated from async code, and a scan needs its file list up front anyway.
    private func logFiles(under root: URL) -> (urls: [URL], enumerationFailed: Bool)? {
        var failed = false
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles], errorHandler: { _, _ in failed = true; return true }) else { return nil }
        var urls: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            urls.append(url)
        }
        return (urls, failed)
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
