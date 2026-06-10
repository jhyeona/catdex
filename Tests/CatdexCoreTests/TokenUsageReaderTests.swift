import XCTest
@testable import CatdexCore

final class TokenUsageReaderTests: XCTestCase {
    func testSummarizeUsesLastTokenUsageInsideRange() throws {
        let jsonl = try makeJSONL([
            tokenLine(
                timestamp: "2026-06-01T00:00:01.123Z",
                total: (input: 100, cached: 10, output: 20, reasoning: 5, total: 120),
                last: (input: 100, cached: 10, output: 20, reasoning: 5, total: 120)
            ),
            tokenLine(
                timestamp: "2026-06-02T00:00:01.123Z",
                total: (input: 170, cached: 20, output: 40, reasoning: 10, total: 210),
                last: (input: 70, cached: 10, output: 20, reasoning: 5, total: 90)
            )
        ])
        let session = session(codexSessionPath: jsonl.path)
        let range = DateInterval(
            start: iso("2026-06-01T00:00:00Z"),
            end: iso("2026-06-03T00:00:00Z")
        )

        let summary = TokenUsageReader().summarize(sessions: [session], range: range)

        XCTAssertEqual(summary.totals.inputTokens, 170)
        XCTAssertEqual(summary.totals.cachedInputTokens, 20)
        XCTAssertEqual(summary.totals.outputTokens, 40)
        XCTAssertEqual(summary.totals.reasoningOutputTokens, 10)
        XCTAssertEqual(summary.totals.totalTokens, 210)
        XCTAssertEqual(summary.sessionCount, 1)
        XCTAssertEqual(summary.eventCount, 2)
        XCTAssertEqual(summary.latestContextWindow, 258400)
    }

    func testSummarizeSkipsDuplicateTotalUsageEvents() throws {
        let first = tokenLine(
            timestamp: "2026-06-01T00:00:01Z",
            total: (input: 100, cached: 0, output: 20, reasoning: 0, total: 120),
            last: (input: 100, cached: 0, output: 20, reasoning: 0, total: 120)
        )
        let duplicate = tokenLine(
            timestamp: "2026-06-01T00:00:02Z",
            total: (input: 100, cached: 0, output: 20, reasoning: 0, total: 120),
            last: (input: 100, cached: 0, output: 20, reasoning: 0, total: 120)
        )
        let jsonl = try makeJSONL([first, duplicate])
        let range = DateInterval(
            start: iso("2026-06-01T00:00:00Z"),
            end: iso("2026-06-02T00:00:00Z")
        )

        let summary = TokenUsageReader().summarize(sessions: [session(codexSessionPath: jsonl.path)], range: range)

        XCTAssertEqual(summary.totals.totalTokens, 120)
        XCTAssertEqual(summary.eventCount, 1)
    }

    func testSummarizeDeduplicatesFiles() throws {
        let jsonl = try makeJSONL([
            tokenLine(
                timestamp: "2026-06-01T00:00:01Z",
                total: (input: 100, cached: 0, output: 20, reasoning: 0, total: 120),
                last: (input: 100, cached: 0, output: 20, reasoning: 0, total: 120)
            )
        ])
        let range = DateInterval(
            start: iso("2026-06-01T00:00:00Z"),
            end: iso("2026-06-02T00:00:00Z")
        )

        let summary = TokenUsageReader().summarize(files: [jsonl, jsonl], range: range)

        XCTAssertEqual(summary.totals.totalTokens, 120)
        XCTAssertEqual(summary.sessionCount, 1)
        XCTAssertEqual(summary.eventCount, 1)
    }

    func testSummarizeSkipsDuplicateTotalUsageAcrossRangeStart() throws {
        let beforeRange = tokenLine(
            timestamp: "2026-05-31T23:59:59Z",
            total: (input: 100, cached: 0, output: 20, reasoning: 0, total: 120),
            last: (input: 100, cached: 0, output: 20, reasoning: 0, total: 120)
        )
        let repeatedInsideRange = tokenLine(
            timestamp: "2026-06-01T00:00:01Z",
            total: (input: 100, cached: 0, output: 20, reasoning: 0, total: 120),
            last: (input: 100, cached: 0, output: 20, reasoning: 0, total: 120)
        )
        let nextInsideRange = tokenLine(
            timestamp: "2026-06-01T00:00:02Z",
            total: (input: 140, cached: 0, output: 30, reasoning: 0, total: 170),
            last: (input: 40, cached: 0, output: 10, reasoning: 0, total: 50)
        )
        let jsonl = try makeJSONL([beforeRange, repeatedInsideRange, nextInsideRange])
        let range = DateInterval(
            start: iso("2026-06-01T00:00:00Z"),
            end: iso("2026-06-02T00:00:00Z")
        )

        let summary = TokenUsageReader().summarize(sessions: [session(codexSessionPath: jsonl.path)], range: range)

        XCTAssertEqual(summary.totals.totalTokens, 50)
        XCTAssertEqual(summary.eventCount, 1)
    }

    func testSummarizeCodexSessionsScansDateDirectoriesInRange() throws {
        let root = try temporaryDirectory()
        let dayDirectory = root
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("06", isDirectory: true)
            .appendingPathComponent("01", isDirectory: true)
        try FileManager.default.createDirectory(at: dayDirectory, withIntermediateDirectories: true)
        let file = dayDirectory.appendingPathComponent("rollout.jsonl")
        try tokenLine(
            timestamp: "2026-06-01T02:00:00Z",
            total: (input: 50, cached: 5, output: 10, reasoning: 2, total: 60),
            last: (input: 50, cached: 5, output: 10, reasoning: 2, total: 60)
        ).write(to: file, atomically: true, encoding: .utf8)

        let range = DateInterval(
            start: iso("2026-06-01T00:00:00Z"),
            end: iso("2026-06-02T00:00:00Z")
        )

        let summary = TokenUsageReader().summarizeCodexSessions(root: root, range: range, calendar: Calendar(identifier: .gregorian))

        XCTAssertEqual(summary.totals.totalTokens, 60)
        XCTAssertEqual(summary.sessionCount, 1)
        XCTAssertEqual(summary.eventCount, 1)
    }

    func testSummarizeExcludesEventsOutsideRange() throws {
        let jsonl = try makeJSONL([
            tokenLine(
                timestamp: "2026-05-31T23:59:59Z",
                total: (input: 10, cached: 0, output: 1, reasoning: 0, total: 11),
                last: (input: 10, cached: 0, output: 1, reasoning: 0, total: 11)
            ),
            tokenLine(
                timestamp: "2026-06-01T00:00:01Z",
                total: (input: 20, cached: 0, output: 2, reasoning: 0, total: 22),
                last: (input: 20, cached: 0, output: 2, reasoning: 0, total: 22)
            ),
            tokenLine(
                timestamp: "2026-06-02T00:00:00Z",
                total: (input: 30, cached: 0, output: 3, reasoning: 0, total: 33),
                last: (input: 10, cached: 0, output: 1, reasoning: 0, total: 11)
            )
        ])
        let range = DateInterval(
            start: iso("2026-06-01T00:00:00Z"),
            end: iso("2026-06-02T00:00:00Z")
        )

        let summary = TokenUsageReader().summarize(sessions: [session(codexSessionPath: jsonl.path)], range: range)

        XCTAssertEqual(summary.totals.totalTokens, 22)
        XCTAssertEqual(summary.eventCount, 1)
    }

    private func session(codexSessionPath: String) -> CatdexSession {
        CatdexSession(
            id: UUID().uuidString,
            state: .waiting,
            task: "Usage test",
            workspace: "/tmp/project",
            updatedAt: Date(),
            lastMessage: "waiting",
            codexSessionPath: codexSessionPath
        )
    }

    private func makeJSONL(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("catdex-token-usage-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("catdex-token-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func tokenLine(
        timestamp: String,
        total: (input: Int, cached: Int, output: Int, reasoning: Int, total: Int),
        last: (input: Int, cached: Int, output: Int, reasoning: Int, total: Int)
    ) -> String {
        """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(total.input),"cached_input_tokens":\(total.cached),"output_tokens":\(total.output),"reasoning_output_tokens":\(total.reasoning),"total_tokens":\(total.total)},"last_token_usage":{"input_tokens":\(last.input),"cached_input_tokens":\(last.cached),"output_tokens":\(last.output),"reasoning_output_tokens":\(last.reasoning),"total_tokens":\(last.total)},"model_context_window":258400},"rate_limits":null}}
        """
    }

    private func iso(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }
}
