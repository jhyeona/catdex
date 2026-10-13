import XCTest
@testable import CatdexCore

final class CodexActivityReaderTests: XCTestCase {
    func testLongRunningElevatedCommandsNeverRequestReview() throws {
        for (name, arguments) in [
            ("exec_command", #"{"cmd":"swift test","sandbox_permissions":"require_escalated","justification":"테스트를 실행할까요?"}"#),
            ("functions.exec", #"text(await tools.exec_command({cmd:"swift test",sandbox_permissions:"require_escalated",justification:"테스트를 실행할까요?"}));"#)
        ] {
            // No output yet: a slow auto-approved command used to trigger an alert.
            let snapshot = try read([call(name, arguments: arguments)])
            XCTAssertEqual(snapshot.state, .responding)
            XCTAssertNil(snapshot.reviewQuestion)
            var notifications = CodexReviewNotificationTracker()
            XCTAssertFalse(notifications.shouldNotify(snapshot))
        }
    }

    func testQuestionWaitsForItsOwnAnswerAndNotifiesOnlyOnce() throws {
        var events = [question(), call("exec_command", id: "other", arguments: "{}"), output("other")]
        let waiting = try read(events)
        XCTAssertEqual(waiting.state, .review)
        XCTAssertEqual(waiting.reviewQuestion, "진행할까요?")
        var notifications = CodexReviewNotificationTracker()
        XCTAssertTrue(notifications.shouldNotify(waiting))
        XCTAssertFalse(notifications.shouldNotify(waiting))

        events.append(output("question"))
        let answered = try read(events)
        XCTAssertEqual(answered.state, .responding)
        XCTAssertNil(answered.reviewQuestion)
        XCTAssertFalse(notifications.shouldNotify(answered))
        XCTAssertFalse(notifications.shouldNotify(waiting))

        events.append(question(id: "next"))
        XCTAssertTrue(notifications.shouldNotify(try read(events)))
    }

    func testTurnLifecycleClearsUnansweredRequests() throws {
        let endings: [([String: Any], CatdexState)] = [
            (event("task_complete"), .waiting),
            (event("turn_aborted"), .failed),
            (event("task_started"), .responding),
            (event("user_message"), .responding),
            (item(["type": "message", "role": "user"]), .responding),
            (item(["type": "message", "role": "assistant", "phase": "final_answer"]), .waiting),
            (["type": "event_msg", "payload": ["type": "agent_message", "phase": "final_answer"]], .waiting)
        ]
        for (ending, state) in endings {
            let snapshot = try read([question(), ending])
            XCTAssertEqual(snapshot.state, state)
            XCTAssertNil(snapshot.reviewQuestion)
            XCTAssertNil(snapshot.reviewCallID)
            var notifications = CodexReviewNotificationTracker()
            XCTAssertFalse(notifications.shouldNotify(snapshot))
        }
    }

    func testConsecutiveQuestionsHaveSeparateNotifications() throws {
        var notifications = CodexReviewNotificationTracker()
        XCTAssertTrue(notifications.shouldNotify(try read([question()])))
        let next = try read([question(), question(id: "next"), output("question")])
        XCTAssertEqual(next.state, .review)
        XCTAssertEqual(next.reviewCallID, "next")
        XCTAssertTrue(notifications.shouldNotify(next))
        XCTAssertFalse(notifications.shouldNotify(next))
    }

    func testMalformedOrAlreadyAnsweredQuestionsDoNotAlert() throws {
        for events in [
            [question(), output("question")],
            [item(["type": "function_call", "name": "request_user_input",
                   "arguments": #"{"questions":[{"question":"진행할까요?"}]}"#])],
            [call("request_user_input_async", arguments: #"{"questions":[{"title":"선호하는 방식은?"}]}"#)]
        ] {
            let snapshot = try read(events)
            XCTAssertNotEqual(snapshot.state, .review)
            var notifications = CodexReviewNotificationTracker()
            XCTAssertFalse(notifications.shouldNotify(snapshot))
        }
    }

    func testCompletedOldTurnDoesNotLeakIntoNewTurn() throws {
        let snapshot = try read([
            question(), event("turn_aborted"), event("task_started"),
            call("exec_command", arguments: #"{"cmd":"swift build","sandbox_permissions":"require_escalated"}"#)
        ])
        XCTAssertEqual(snapshot.state, .responding)
        XCTAssertNil(snapshot.reviewCallID)
    }

    func testCustomToolQuestionResolvesOnCustomOutput() throws {
        let call = item(["type": "custom_tool_call", "name": "functions.exec", "call_id": "custom",
                         "input": #"await tools.request_user_input({questions:[{question:"진행할까요?"}]});"#])
        XCTAssertEqual(try read([call]).state, .review)
        XCTAssertEqual(try read([call, item(["type": "custom_tool_call_output", "call_id": "custom"])]).state, .responding)
    }

    private func item(_ payload: [String: Any]) -> [String: Any] {
        ["type": "response_item", "payload": payload]
    }

    private func event(_ type: String) -> [String: Any] {
        ["type": "event_msg", "payload": ["type": type]]
    }

    private func call(_ name: String, id: String = "command", arguments: String) -> [String: Any] {
        item(["type": "function_call", "name": name, "call_id": id, "arguments": arguments])
    }

    private func question(id: String = "question") -> [String: Any] {
        call("request_user_input", id: id, arguments: #"{"questions":[{"question":"진행할까요?"}]}"#)
    }

    private func output(_ id: String) -> [String: Any] {
        item(["type": "function_call_output", "call_id": id, "output": "completed"])
    }

    private func read(_ events: [[String: Any]]) throws -> CodexActivitySnapshot {
        let lines = try events.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        return CodexActivityReader.read(lines.joined(separator: "\n"), sessionPath: "/tmp/session.jsonl")
    }
}
