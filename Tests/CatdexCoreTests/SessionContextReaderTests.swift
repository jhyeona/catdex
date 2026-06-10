import XCTest
@testable import CatdexCore

final class SessionContextReaderTests: XCTestCase {
    func testReadContextExtractsRecentReadableEvents() throws {
        let jsonl = try makeJSONL([
            #"{"timestamp":"2026-06-10T00:00:00Z","type":"session_meta","payload":{"cwd":"/tmp/project","base_instructions":{"text":"do not show this"}}}"#,
            #"{"timestamp":"2026-06-10T00:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"check the build"}}"#,
            #"{"timestamp":"2026-06-10T00:00:02Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"swift test\"}","call_id":"call_1"}}"#,
            #"{"timestamp":"2026-06-10T00:00:03Z","type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"Build passed."}]}}"#
        ])
        let session = CatdexSession(
            id: "test",
            state: .waiting,
            task: "Test task",
            workspace: "/tmp/project",
            updatedAt: Date(),
            lastMessage: "waiting",
            codexSessionPath: jsonl.path
        )

        let context = SessionContextReader(maxEvents: 10).readContext(for: session)

        XCTAssertNil(context.unavailableReason)
        XCTAssertEqual(context.recentEvents.map(\.title), ["User", "Tool call: exec_command", "Assistant final"])
        XCTAssertEqual(context.recentEvents.first?.detail, "check the build")
        XCTAssertEqual(context.recentEvents.last?.detail, "Build passed.")
        XCTAssertEqual(context.lastUserMessage?.detail, "check the build")
        XCTAssertEqual(context.lastAssistantMessage?.detail, "Build passed.")
    }

    func testReadContextReportsMissingSessionPath() {
        let session = CatdexSession(
            id: "test",
            state: .starting,
            task: "Test task",
            workspace: "/tmp/project",
            updatedAt: Date(),
            lastMessage: "starting"
        )

        let context = SessionContextReader().readContext(for: session)

        XCTAssertEqual(context.recentEvents, [])
        XCTAssertNotNil(context.unavailableReason)
    }

    func testLastAssistantMessagePrefersFinalAnswerOverLaterUpdate() throws {
        let jsonl = try makeJSONL([
            #"{"timestamp":"2026-06-10T00:00:01Z","type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"Final result."}]}}"#,
            #"{"timestamp":"2026-06-10T00:00:02Z","type":"event_msg","payload":{"type":"agent_message","phase":"commentary","message":"Later progress update."}}"#
        ])
        let session = CatdexSession(
            id: "test",
            state: .waiting,
            task: "Test task",
            workspace: "/tmp/project",
            updatedAt: Date(),
            lastMessage: "waiting",
            codexSessionPath: jsonl.path
        )

        let context = SessionContextReader(maxEvents: 10).readContext(for: session)

        XCTAssertEqual(context.lastAssistantMessage?.title, "Assistant final")
        XCTAssertEqual(context.lastAssistantMessage?.detail, "Final result.")
    }

    func testReadContextParsesFractionalTimestamps() throws {
        let jsonl = try makeJSONL([
            #"{"timestamp":"2026-06-10T00:00:01.123Z","type":"event_msg","payload":{"type":"user_message","message":"fractional user"}}"#,
            #"{"timestamp":"2026-06-10T00:00:02.456Z","type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"fractional answer"}]}}"#
        ])
        let session = CatdexSession(
            id: "test",
            state: .waiting,
            task: "Test task",
            workspace: "/tmp/project",
            updatedAt: Date(),
            lastMessage: "waiting",
            codexSessionPath: jsonl.path
        )

        let context = SessionContextReader(maxEvents: 10).readContext(for: session)

        XCTAssertNotNil(context.lastUserMessage?.timestamp)
        XCTAssertNotNil(context.lastAssistantMessage?.timestamp)
    }

    private func makeJSONL(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("catdex-context-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
