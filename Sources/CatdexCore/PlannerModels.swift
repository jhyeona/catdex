import Foundation

public enum PlannerError: LocalizedError {
    case invalid(String), storage(String), conflict
    public var errorDescription: String? {
        switch self {
        case .invalid(let text), .storage(let text): text
        case .conflict: "다른 창에서 변경되었습니다. 새로 열어 다시 시도하세요."
        }
    }
}

public enum WorkState: String, Codable, CaseIterable, Sendable {
    case todo, inProgress, waiting, done
    public var title: String {
        switch self { case .todo: "할 일"; case .inProgress: "진행 중"; case .waiting: "대기"; case .done: "완료" }
    }
}

public struct TaskCandidate: Codable, Identifiable, Equatable, Sendable {
    public var id: String = UUID().uuidString
    public var title: String
    public var dueAt: Date?
    public var plannedDay: Date?
    public var preferredStartHour: Int?
    public var preferredEndHour: Int?
    public var estimatedMinutes: Int?
    public var note: String = ""
    public init(title: String) { self.title = title }

    enum CodingKeys: String, CodingKey {
        case id, title, dueAt, plannedDay, preferredStartHour, preferredEndHour, estimatedMinutes, note
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        title = try c.decode(String.self, forKey: .title)
        dueAt = try c.decodeIfPresent(Date.self, forKey: .dueAt)
        plannedDay = try c.decodeIfPresent(Date.self, forKey: .plannedDay)
        preferredStartHour = try c.decodeIfPresent(Int.self, forKey: .preferredStartHour)
        preferredEndHour = try c.decodeIfPresent(Int.self, forKey: .preferredEndHour)
        estimatedMinutes = try c.decodeIfPresent(Int.self, forKey: .estimatedMinutes)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

public struct CaptureRequest: Codable, Sendable {
    public var requestID: String
    public var text: String
    public var project: String?
    public var sessionID: String?
    public var context: String?
    public var candidates: [TaskCandidate]?
    public init(requestID: String = UUID().uuidString, text: String, project: String? = nil,
                sessionID: String? = nil, context: String? = nil, candidates: [TaskCandidate]? = nil) {
        self.requestID = requestID; self.text = text; self.project = project
        self.sessionID = sessionID; self.context = context; self.candidates = candidates
    }
}

public struct PlannerRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var revision: Int = 0
    public var text: String
    public var project: String
    public var sessionID: String?
    public var context: String
    public var createdAt: Date
    public var candidates: [TaskCandidate]
    public var resolved: Bool = false
}

public struct ChecklistItem: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID().uuidString
    public var title: String
    public var done = false
    public init(title: String) { self.title = title }
}

public struct PlannerTask: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var revision: Int = 0
    public var recordID: String
    public var title: String
    public var project: String
    public var createdAt: Date
    public var state: WorkState = .todo
    public var dueAt: Date?
    public var plannedDay: Date?
    public var preferredStartHour: Int?
    public var preferredEndHour: Int?
    public var estimatedMinutes: Int?
    public var priority: Int = 1
    public var order: Double = 0
    public var pinned = false
    public var pauseNote = ""
    public var reviewAt: Date?
    public var checklist: [ChecklistItem] = []
    public var completedAt: Date?
    public var note = ""
    public init(candidate: TaskCandidate, record: PlannerRecord) {
        id = record.id + ":" + candidate.id; recordID = record.id; title = candidate.title
        project = record.project; createdAt = record.createdAt; dueAt = candidate.dueAt
        plannedDay = candidate.plannedDay; preferredStartHour = candidate.preferredStartHour
        preferredEndHour = candidate.preferredEndHour; estimatedMinutes = candidate.estimatedMinutes; note = candidate.note
    }
}

public struct PlannerBlock: Codable, Identifiable, Equatable, Sendable {
    public var id: String = UUID().uuidString
    public var taskID: String?
    public var title: String
    public var start: Date
    public var end: Date
    public init(taskID: String? = nil, title: String, start: Date, end: Date) {
        self.taskID = taskID; self.title = title; self.start = start; self.end = end
    }
}

public struct PlannerPreferences: Codable, Equatable, Sendable {
    public var startHour = 9
    public var endHour = 18
    public var lunchStartHour = 12
    public var lunchEndHour = 13
    public var lunchEnabled = true
    public var weekdays: [Int] = [2, 3, 4, 5, 6]
    public var gapMinutes = 10
    public var alwaysOnTop = true
    public var shortcutKeyCode: UInt32 = 40 // K; Control-Option-Space is reserved for macOS input sources.
    public var shortcutModifiers: UInt32 = 6144 // control + option (Carbon)
    public init() {}
    public func validate() throws {
        guard (0...23).contains(startHour), (1...24).contains(endHour), startHour < endHour,
              (0...23).contains(lunchStartHour), (1...24).contains(lunchEndHour),
              !lunchEnabled || lunchStartHour < lunchEndHour, (0...60).contains(gapMinutes),
              weekdays.allSatisfy({ (1...7).contains($0) }) else {
            throw PlannerError.invalid("업무시간과 점심시간의 시작·종료를 확인하세요.")
        }
    }
}

public struct PlannerSnapshot: Equatable, Sendable {
    public var records: [PlannerRecord] = []
    public var tasks: [PlannerTask] = []
    public var blocks: [PlannerBlock] = []
    public var preferences = PlannerPreferences()
    public init() {}
}

public enum PlannerCoding {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
}
