import Foundation

public struct TokenUsageTotals: Codable, Equatable, Sendable {
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var outputTokens: Int
    public var reasoningOutputTokens: Int
    public var totalTokens: Int

    public init(
        inputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        outputTokens: Int = 0,
        reasoningOutputTokens: Int = 0,
        totalTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
    }

    public mutating func add(_ other: TokenUsageTotals) {
        inputTokens += other.inputTokens
        cachedInputTokens += other.cachedInputTokens
        outputTokens += other.outputTokens
        reasoningOutputTokens += other.reasoningOutputTokens
        totalTokens += other.totalTokens
    }
}

public struct TokenUsageSummary: Equatable, Sendable {
    public var range: DateInterval
    public var totals: TokenUsageTotals
    public var sessionCount: Int
    public var eventCount: Int
    public var latestContextWindow: Int?

    public init(
        range: DateInterval,
        totals: TokenUsageTotals,
        sessionCount: Int,
        eventCount: Int,
        latestContextWindow: Int?
    ) {
        self.range = range
        self.totals = totals
        self.sessionCount = sessionCount
        self.eventCount = eventCount
        self.latestContextWindow = latestContextWindow
    }
}

public struct TokenUsageReader {
    public init() {}

    public func summarizeCodexSessions(
        root: URL,
        range: DateInterval,
        additionalFiles: [URL] = [],
        calendar: Calendar = .current
    ) -> TokenUsageSummary {
        let urls = sessionURLs(in: root, range: range, calendar: calendar) + additionalFiles
        return summarize(files: urls, range: range)
    }

    public func summarize(sessions: [CatdexSession], range: DateInterval) -> TokenUsageSummary {
        let urls = sessions.compactMap { session -> URL? in
            guard let path = session.codexSessionPath else { return nil }
            return URL(fileURLWithPath: path)
        }
        return summarize(files: urls, range: range)
    }

    public func summarize(files: [URL], range: DateInterval) -> TokenUsageSummary {
        var totals = TokenUsageTotals()
        var sessionPaths = Set<String>()
        var eventCount = 0
        var latestContextWindow: Int?
        var latestContextWindowTimestamp: Date?

        let fractionalFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let format = Date.ISO8601FormatStyle()

        for url in uniqueFiles(files) {
            guard !Task.isCancelled else { break }
            var lastTotalTokens: Int?
            var sessionHasUsage = false
            forEachLine(in: url) { line in
                autoreleasepool {
                    guard let event = parseTokenEvent(line, fractionalFormat: fractionalFormat, format: format) else {
                        return
                    }

                    let isRepeatedTotal = lastTotalTokens == event.totalUsage.totalTokens
                    lastTotalTokens = event.totalUsage.totalTokens

                    guard event.timestamp >= range.start,
                          event.timestamp < range.end,
                          !isRepeatedTotal
                    else {
                        return
                    }

                    totals.add(event.lastUsage)
                    eventCount += 1
                    sessionHasUsage = true
                    if let contextWindow = event.contextWindow,
                       latestContextWindowTimestamp.map({ event.timestamp >= $0 }) ?? true {
                        latestContextWindow = contextWindow
                        latestContextWindowTimestamp = event.timestamp
                    }
                }
            }

            if sessionHasUsage {
                sessionPaths.insert(url.path)
            }
        }

        return TokenUsageSummary(
            range: range,
            totals: totals,
            sessionCount: sessionPaths.count,
            eventCount: eventCount,
            latestContextWindow: latestContextWindow
        )
    }

    private func uniqueFiles(_ files: [URL]) -> [URL] {
        var seen = Set<String>()
        var unique: [URL] = []
        for url in files {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            unique.append(url)
        }
        return unique
    }

    private func sessionURLs(in root: URL, range: DateInterval, calendar: Calendar) -> [URL] {
        let fileManager = FileManager.default
        var urls: [URL] = []
        var day = calendar.startOfDay(for: range.start)
        let lastIncludedDay = calendar.startOfDay(for: range.end.addingTimeInterval(-1))

        while day <= lastIncludedDay {
            guard !Task.isCancelled else { break }
            let components = calendar.dateComponents([.year, .month, .day], from: day)
            if let year = components.year,
               let month = components.month,
               let dayValue = components.day {
                let directory = root
                    .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                    .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                    .appendingPathComponent(String(format: "%02d", dayValue), isDirectory: true)
                if let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                    urls.append(contentsOf: contents.filter { $0.pathExtension == "jsonl" })
                }
            }

            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else {
                break
            }
            day = nextDay
        }

        return urls
    }

    private func parseTokenEvent(_ line: Data, fractionalFormat: Date.ISO8601FormatStyle,
                                 format: Date.ISO8601FormatStyle) -> TokenUsageEvent? {
        // Most rollout lines contain conversation/tool output, not usage. Unicode
        // escapes take the full parser path so escaped JSON keys/types still work.
        guard line.range(of: Self.tokenMarker) != nil || line.range(of: Self.escapeMarker) != nil,
              let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let timestampString = object["timestamp"] as? String,
              let timestamp = (try? fractionalFormat.parse(timestampString)) ?? (try? format.parse(timestampString)),
              let info = payload["info"] as? [String: Any],
              let totalUsageObject = info["total_token_usage"] as? [String: Any],
              let lastUsageObject = info["last_token_usage"] as? [String: Any]
        else {
            return nil
        }

        return TokenUsageEvent(
            timestamp: timestamp,
            totalUsage: parseUsage(totalUsageObject),
            lastUsage: parseUsage(lastUsageObject),
            contextWindow: info["model_context_window"] as? Int
        )
    }

    private func parseUsage(_ object: [String: Any]) -> TokenUsageTotals {
        TokenUsageTotals(
            inputTokens: object["input_tokens"] as? Int ?? 0,
            cachedInputTokens: object["cached_input_tokens"] as? Int ?? 0,
            outputTokens: object["output_tokens"] as? Int ?? 0,
            reasoningOutputTokens: object["reasoning_output_tokens"] as? Int ?? 0,
            totalTokens: object["total_tokens"] as? Int ?? 0
        )
    }

    private static let tokenMarker = Data("token_count".utf8)
    private static let escapeMarker = Data("\\u".utf8)

    /// Read a fixed-size chunk at a time instead of retaining the entire rollout
    /// and an array of all of its lines. A line may span any number of chunks.
    private func forEachLine(in url: URL, visit: (Data) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        var pending = Data()
        while !Task.isCancelled {
            // FileHandle and Data bridging can also create autoreleased objects.
            // Drain those per chunk, not only the JSON objects per event.
            let more = autoreleasepool { () -> Bool in
                let chunk: Data
                do { chunk = try handle.read(upToCount: 64 * 1024) ?? Data() }
                catch { return false }
                if chunk.isEmpty {
                    if !pending.isEmpty { visit(pending) }
                    return false
                }
                var start = chunk.startIndex
                for newline in chunk.indices where chunk[newline] == 0x0A {
                    guard !Task.isCancelled else { return false }
                    if pending.isEmpty {
                        visit(chunk.subdata(in: start..<newline))
                    } else {
                        pending.append(contentsOf: chunk[start..<newline])
                        visit(pending)
                        pending.removeAll(keepingCapacity: false)
                    }
                    start = newline + 1
                }
                pending.append(contentsOf: chunk[start..<chunk.endIndex])
                return true
            }
            if !more { return }
        }
    }
}

private struct TokenUsageEvent {
    var timestamp: Date
    var totalUsage: TokenUsageTotals
    var lastUsage: TokenUsageTotals
    var contextWindow: Int?
}
