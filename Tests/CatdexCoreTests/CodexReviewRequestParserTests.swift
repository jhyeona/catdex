import XCTest
@testable import CatdexCore

final class CodexReviewRequestParserTests: XCTestCase {
    func testDoesNotInferApprovalFromDirectEscalation() {
        let arguments = #"{"cmd":"pod install","sandbox_permissions":"require_escalated","justification":"Pod 설치를 진행할까요?"}"#

        let request = CodexReviewRequestParser.parse(
            toolName: "exec_command",
            arguments: arguments
        )

        XCTAssertNil(request)
    }

    func testParsesDirectUserInputQuestion() {
        let arguments = #"{"questions":[{"header":"배포","question":"지금 배포할까요?","options":[]}]}"#

        let request = CodexReviewRequestParser.parse(
            toolName: "request_user_input",
            arguments: arguments
        )

        XCTAssertEqual(request?.notificationText, "지금 배포할까요?")
    }

    func testDoesNotInferApprovalFromEscalationWrappedByExecJavaScript() {
        let arguments = #"""
        const r = await tools.exec_command({
          cmd: "pod install",
          sandbox_permissions: "require_escalated",
          justification: "iOS 의존성을 설치할까요?"
        });
        text(r.output);
        """#

        let request = CodexReviewRequestParser.parse(toolName: "exec", arguments: arguments)

        XCTAssertNil(request)
    }

    func testDoesNotInferApprovalFromJSONStyleEscalationWrappedByExecJavaScript() {
        let arguments = #"""
        const r = await tools.exec_command({"cmd":"git fetch","sandbox_permissions":"require_escalated","justification":"원격 변경을 가져올까요?"});
        text(r.output);
        """#

        let request = CodexReviewRequestParser.parse(toolName: "exec", arguments: arguments)

        XCTAssertNil(request)
    }

    func testParsesUserInputWrappedByExecJavaScript() {
        let arguments = #"""
        const r = await tools.request_user_input({
          questions: [{
            header: "방식",
            question: "어떤 방식으로 진행할까요?",
            options: []
          }]
        });
        text(r);
        """#

        let request = CodexReviewRequestParser.parse(toolName: "exec", arguments: arguments)

        XCTAssertEqual(request?.notificationText, "어떤 방식으로 진행할까요?")
    }

    func testDoesNotTreatSearchTextAsEscalation() {
        let arguments = #"""
        const r = await tools.exec_command({
          cmd: "rg 'sandbox_permissions.*require_escalated' Sources"
        });
        text(r.output);
        """#

        let request = CodexReviewRequestParser.parse(toolName: "exec", arguments: arguments)

        XCTAssertNil(request)
    }

    func testDoesNotTreatToolCallTextInsideStringAsEscalation() {
        let arguments = #"""
        const source = 'tools.exec_command({sandbox_permissions: "require_escalated", justification: "잘못된 질문"})';
        const r = await tools.exec_command({cmd: "printf source"});
        text(r.output);
        """#

        let request = CodexReviewRequestParser.parse(toolName: "exec", arguments: arguments)

        XCTAssertNil(request)
    }

    func testDoesNotTreatNonblockingOrEmptyQuestionsAsReview() {
        for (tool, arguments) in [
            ("request_user_input_async", #"{"questions":[{"title":"선호하는 방식이 있나요?"}]}"#),
            ("request_user_input", #"{"questions":[]}"#),
            ("request_user_input", #"{"questions":[{"question":"  "}]}"#),
            ("request_user_input", "invalid JSON"),
            ("exec", #"await tools.request_user_input_async({questions:[{title:"선호하는 방식이 있나요?"}]});"#)
        ] {
            XCTAssertNil(CodexReviewRequestParser.parse(toolName: tool, arguments: arguments))
        }
    }

    func testParsesNamespacedQuestion() {
        let request = CodexReviewRequestParser.parse(
            toolName: "functions.request_user_input",
            arguments: #"{"questions":[{"question":"배포를 진행할까요?"}]}"#
        )
        XCTAssertEqual(request?.notificationText, "배포를 진행할까요?")
    }

    func testTrimsAndClipsNotificationQuestion() {
        let longQuestion = String(repeating: "가", count: 230)
        let arguments = """
        {"questions":[{"question":"  \(longQuestion)  "}]}
        """

        let request = CodexReviewRequestParser.parse(
            toolName: "request_user_input",
            arguments: arguments
        )

        XCTAssertEqual(request?.notificationText, String(repeating: "가", count: 220) + "...")
    }
}
