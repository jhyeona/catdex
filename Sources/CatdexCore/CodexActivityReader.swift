import Foundation

public struct CodexActivitySnapshot {
    public var state: CatdexState
    public var message: String
    public var sessionPath: String?
    public var reviewQuestion: String?
    public var reviewCallID: String?

    public init(state: CatdexState, message: String, sessionPath: String? = nil,
                reviewQuestion: String? = nil, reviewCallID: String? = nil) {
        self.state = state
        self.message = message
        self.sessionPath = sessionPath
        self.reviewQuestion = reviewQuestion
        self.reviewCallID = reviewCallID
    }
}

/// A tool requesting elevated execution is not evidence of a pending approval.
/// Only unresolved, blocking user-input requests put a rollout in review.
public enum CodexActivityReader {
    public static func read(_ content: String, sessionPath: String? = nil) -> CodexActivitySnapshot {
        var state = CatdexState.waiting
        var message = "👀 Waiting for prompt"
        var pendingReviewCalls: [String] = []
        var pendingReviewQuestions: [String: String] = [:]
        var reviewQuestion: String?

        for line in content.split(separator: "\n") {
            guard let object = parseJSONObject(String(line)),
                  let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String
            else {
                continue
            }

            switch (type, payloadType) {
            case ("event_msg", "task_started"),
                 ("event_msg", "user_message"):
                pendingReviewCalls.removeAll()
                pendingReviewQuestions.removeAll()
                state = .responding
                message = "✍️ Answering"

            case ("event_msg", "agent_reasoning"),
                 ("response_item", "reasoning"):
                state = .responding
                message = "✍️ Thinking"

            case ("event_msg", "agent_message"):
                if payload["phase"] as? String == "final_answer" {
                    pendingReviewCalls.removeAll()
                    pendingReviewQuestions.removeAll()
                    state = .waiting
                    message = "👀 Answer complete; waiting"
                } else {
                    state = .responding
                    message = "✍️ Updating progress"
                }

            case ("response_item", "message"):
                let role = payload["role"] as? String
                let phase = payload["phase"] as? String
                if role == "user" {
                    pendingReviewCalls.removeAll()
                    pendingReviewQuestions.removeAll()
                    state = .responding
                    message = "✍️ Answering"
                } else if role == "assistant", phase == "final_answer" {
                    pendingReviewCalls.removeAll()
                    pendingReviewQuestions.removeAll()
                    state = .waiting
                    message = "👀 Answer complete; waiting"
                } else if role == "assistant" {
                    state = .responding
                    message = "✍️ Updating progress"
                }

            case ("event_msg", "task_complete"):
                pendingReviewCalls.removeAll()
                pendingReviewQuestions.removeAll()
                state = .waiting
                message = "👀 Answer complete; waiting"

            case ("event_msg", "turn_aborted"):
                pendingReviewCalls.removeAll()
                pendingReviewQuestions.removeAll()
                state = .failed
                message = "🙀 Turn aborted"

            case ("response_item", "function_call"),
                 ("response_item", "custom_tool_call"):
                let name = payload["name"] as? String ?? "tool"
                let callID = payload["call_id"] as? String
                let arguments = payload["arguments"] as? String ?? payload["input"] as? String ?? ""
                if let callID, let reviewRequest = CodexReviewRequestParser.parse(
                    toolName: name,
                    arguments: arguments
                ) {
                    let question = reviewRequest.notificationText
                    if !pendingReviewCalls.contains(callID) {
                        pendingReviewCalls.append(callID)
                    }
                    if let question {
                        pendingReviewQuestions[callID] = question
                    }
                    state = .review
                    message = "🐱❓ Confirmation required"
                    reviewQuestion = question
                } else {
                    state = .responding
                    message = "✍️ Running \(name)"
                }

            case ("response_item", "function_call_output"),
                 ("response_item", "custom_tool_call_output"):
                if let callID = payload["call_id"] as? String {
                    pendingReviewCalls.removeAll { $0 == callID }
                    pendingReviewQuestions.removeValue(forKey: callID)
                }
                if state != .failed {
                    state = .responding
                    message = "✍️ Processing tool result"
                }

            default:
                continue
            }
        }

        let activeReviewCalls = pendingReviewCalls
        if !activeReviewCalls.isEmpty {
            state = .review
            message = "🐱❓ Confirmation required"
            reviewQuestion = activeReviewCalls.lazy.compactMap { pendingReviewQuestions[$0] }.first
        }

        return CodexActivitySnapshot(
            state: state,
            message: message,
            sessionPath: sessionPath,
            reviewQuestion: state == .review ? reviewQuestion : nil,
            reviewCallID: activeReviewCalls.first
        )
    }

    private static func parseJSONObject(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// Notify once per request, even if later progress briefly changes session state.
public struct CodexReviewNotificationTracker {
    private var notifiedRequests: Set<String> = []

    public init() {}

    public mutating func shouldNotify(_ snapshot: CodexActivitySnapshot) -> Bool {
        guard snapshot.state == .review, let callID = snapshot.reviewCallID else { return false }
        let key = "\(snapshot.sessionPath ?? "")#\(callID)"
        return notifiedRequests.insert(key).inserted
    }
}
