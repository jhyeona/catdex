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
        calendar: Calendar = .current
    ) -> TokenUsageSummary {
        let urls = sessionURLs(in: root, range: range, calendar: calendar)
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

        for url in files {
            guard !Task.isCancelled else { break }
            guard FileManager.default.fileExists(atPath: url.path),
                  let content = try? String(contentsOf: url, encoding: .utf8)
            else {
                continue
            }

            var lastTotalTokens: Int?
            var sessionHasUsage = false
            for line in content.split(separator: "\n") {
                guard !Task.isCancelled else { break }
                guard let event = parseTokenEvent(String(line)) else {
                    continue
                }

                let isRepeatedTotal = lastTotalTokens == event.totalUsage.totalTokens
                lastTotalTokens = event.totalUsage.totalTokens

                guard event.timestamp >= range.start,
                      event.timestamp < range.end,
                      !isRepeatedTotal
                else {
                    continue
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

    private func parseTokenEvent(_ line: String) -> TokenUsageEvent? {
        guard let object = parseJSONObject(line),
              object["type"] as? String == "event_msg",
              let timestamp = parseDate(object["timestamp"] as? String),
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
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

    private func parseJSONObject(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: string) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

private struct TokenUsageEvent {
    var timestamp: Date
    var totalUsage: TokenUsageTotals
    var lastUsage: TokenUsageTotals
    var contextWindow: Int?
}
