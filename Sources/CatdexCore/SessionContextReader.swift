import Foundation

public struct CatdexContextEvent: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case user
        case assistant
        case tool
        case review
        case status
    }

    public var timestamp: Date?
    public var kind: Kind
    public var title: String
    public var detail: String

    public init(timestamp: Date?, kind: Kind, title: String, detail: String) {
        self.timestamp = timestamp
        self.kind = kind
        self.title = title
        self.detail = detail
    }
}

public struct CatdexSessionContext: Equatable, Sendable {
    public var codexSessionPath: String?
    public var lastUserMessage: CatdexContextEvent?
    public var lastAssistantMessage: CatdexContextEvent?
    public var recentEvents: [CatdexContextEvent]
    public var unavailableReason: String?

    public init(
        codexSessionPath: String?,
        lastUserMessage: CatdexContextEvent? = nil,
        lastAssistantMessage: CatdexContextEvent? = nil,
        recentEvents: [CatdexContextEvent],
        unavailableReason: String? = nil
    ) {
        self.codexSessionPath = codexSessionPath
        self.lastUserMessage = lastUserMessage
        self.lastAssistantMessage = lastAssistantMessage
        self.recentEvents = recentEvents
        self.unavailableReason = unavailableReason
    }
}

public struct SessionContextReader {
    private let maxEvents: Int
    private let maxDetailLength: Int

    public init(maxEvents: Int = 8, maxDetailLength: Int = 520) {
        self.maxEvents = maxEvents
        self.maxDetailLength = maxDetailLength
    }

    public func readContext(for session: CatdexSession) -> CatdexSessionContext {
        guard let path = session.codexSessionPath else {
            return CatdexSessionContext(
                codexSessionPath: nil,
                recentEvents: [],
                unavailableReason: "Codex session file is not available yet."
            )
        }

        guard FileManager.default.fileExists(atPath: path) else {
            return CatdexSessionContext(
                codexSessionPath: path,
                recentEvents: [],
                unavailableReason: "Codex session file no longer exists."
            )
        }

        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return CatdexSessionContext(
                codexSessionPath: path,
                recentEvents: [],
                unavailableReason: "Codex session file could not be read."
            )
        }

        var events: [CatdexContextEvent] = []
        for line in content.split(separator: "\n") {
            guard let event = parseLine(String(line)) else { continue }
            if events.last?.kind == event.kind,
               events.last?.title == event.title,
               events.last?.detail == event.detail {
                continue
            }
            events.append(event)
        }

        let lastUserIndex = events.lastIndex { $0.kind == .user }
        let lastUserMessage = lastUserIndex.map { events[$0] }
        let answerSearchRange: ArraySlice<CatdexContextEvent>
        if let lastUserIndex {
            answerSearchRange = events[events.index(after: lastUserIndex)...]
        } else {
            answerSearchRange = events[...]
        }
        let lastAssistantMessage = answerSearchRange.last {
            $0.kind == .assistant && $0.title == "Assistant final"
        }

        return CatdexSessionContext(
            codexSessionPath: path,
            lastUserMessage: lastUserMessage,
            lastAssistantMessage: lastAssistantMessage,
            recentEvents: Array(events.suffix(maxEvents)),
            unavailableReason: nil
        )
    }

    private func parseLine(_ line: String) -> CatdexContextEvent? {
        guard let object = parseJSONObject(line),
              let type = object["type"] as? String,
              type != "session_meta",
              let payload = object["payload"] as? [String: Any],
              let payloadType = payload["type"] as? String
        else {
            return nil
        }

        let timestamp = parseDate(object["timestamp"] as? String)

        switch (type, payloadType) {
        case ("event_msg", "user_message"):
            return makeEvent(timestamp: timestamp, kind: .user, title: "User", detail: payload["message"] as? String)

        case ("response_item", "message"):
            let role = payload["role"] as? String
            let phase = payload["phase"] as? String
            let detail = extractContentText(from: payload)
            if role == "user" {
                return makeEvent(timestamp: timestamp, kind: .user, title: "User", detail: detail)
            }
            if role == "assistant" {
                return makeEvent(
                    timestamp: timestamp,
                    kind: .assistant,
                    title: phase == "final_answer" ? "Assistant final" : "Assistant",
                    detail: detail
                )
            }
            return nil

        case ("event_msg", "agent_message"):
            let phase = payload["phase"] as? String
            return makeEvent(
                timestamp: timestamp,
                kind: .assistant,
                title: phase == "final_answer" ? "Assistant final" : "Assistant update",
                detail: payload["message"] as? String
            )

        case ("response_item", "function_call"),
             ("response_item", "custom_tool_call"):
            let name = payload["name"] as? String ?? "tool"
            let arguments = payload["arguments"] as? String ?? payload["input"] as? String
            let isReview = name == "request_user_input" || (arguments?.contains("require_escalated") == true)
            return makeEvent(
                timestamp: timestamp,
                kind: isReview ? .review : .tool,
                title: isReview ? "Review required" : "Tool call: \(name)",
                detail: arguments ?? name
            )

        case ("event_msg", "task_started"):
            return makeEvent(timestamp: timestamp, kind: .status, title: "Task started", detail: "Codex started a turn.")

        case ("event_msg", "task_complete"):
            return makeEvent(timestamp: timestamp, kind: .status, title: "Task complete", detail: "Codex finished the turn.")

        case ("event_msg", "turn_aborted"):
            return makeEvent(timestamp: timestamp, kind: .status, title: "Turn aborted", detail: payload["message"] as? String ?? "The turn was aborted.")

        default:
            return nil
        }
    }

    private func makeEvent(timestamp: Date?, kind: CatdexContextEvent.Kind, title: String, detail: String?) -> CatdexContextEvent? {
        guard let detail = normalized(detail), !detail.isEmpty else { return nil }
        return CatdexContextEvent(
            timestamp: timestamp,
            kind: kind,
            title: title,
            detail: clipped(detail)
        )
    }

    private func extractContentText(from payload: [String: Any]) -> String? {
        if let text = payload["message"] as? String {
            return text
        }

        guard let content = payload["content"] as? [[String: Any]] else {
            return nil
        }

        let parts = content.compactMap { item -> String? in
            if let text = item["text"] as? String {
                return text
            }
            return item["input"] as? String
        }
        return parts.joined(separator: "\n")
    }

    private func normalized(_ string: String?) -> String? {
        guard let string else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lines = trimmed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return lines.joined(separator: "\n")
    }

    private func clipped(_ string: String) -> String {
        guard string.count > maxDetailLength else { return string }
        let end = string.index(string.startIndex, offsetBy: maxDetailLength)
        return String(string[..<end]) + "..."
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
