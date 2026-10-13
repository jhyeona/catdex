import Foundation
import CSQLite

/// Each operation opens its own connection. WAL + BEGIN IMMEDIATE serializes CLI/app writes.
public final class PlannerStore {
    public let url: URL
    public init(paths: CatdexPaths = CatdexPaths()) { url = paths.root.appendingPathComponent("planner.sqlite") }

    private func connection<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db = pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw PlannerError.storage("작업 저장소를 열 수 없습니다.")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)
        try execute(db, "PRAGMA journal_mode=WAL")
        try execute(db, "CREATE TABLE IF NOT EXISTS planner_meta (version INTEGER NOT NULL)")
        try execute(db, "INSERT INTO planner_meta SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM planner_meta)")
        var version: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT version FROM planner_meta", -1, &version, nil) == SQLITE_OK else { throw failure(db) }
        let supportedVersion = sqlite3_step(version) == SQLITE_ROW && sqlite3_column_int(version, 0) == 1
        sqlite3_finalize(version)
        guard supportedVersion else {
            throw PlannerError.storage("더 새로운 작업 저장소입니다. Catdex를 업데이트하세요.")
        }
        try execute(db, "CREATE TABLE IF NOT EXISTS planner_items (kind TEXT NOT NULL, id TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(kind,id))")
        return try body(db)
    }
    private func failure(_ db: OpaquePointer) -> PlannerError { .storage(String(cString: sqlite3_errmsg(db))) }
    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        let deadline = Date().addingTimeInterval(5)
        while true {
            let code = sqlite3_exec(db, sql, nil, nil, nil)
            if code == SQLITE_OK { return }
            // SQLite's busy handler is not invoked for every schema/WAL transition.
            guard (code == SQLITE_BUSY || code == SQLITE_LOCKED), Date() < deadline else { throw failure(db) }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
    private func transaction<T>(_ db: OpaquePointer, _ body: () throws -> T) throws -> T {
        try execute(db, "BEGIN IMMEDIATE")
        do { let value = try body(); try execute(db, "COMMIT"); return value }
        catch { try? execute(db, "ROLLBACK"); throw error }
    }
    private func rows<T: Decodable>(_ db: OpaquePointer, kind: String) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM planner_items WHERE kind=? ORDER BY rowid", -1, &statement, nil) == SQLITE_OK else { throw failure(db) }
        defer { sqlite3_finalize(statement) }
        try bind(db, statement, 1, kind)
        var result: [T] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW, let bytes = sqlite3_column_text(statement, 0) else { throw failure(db) }
            result.append(try PlannerCoding.decoder().decode(T.self, from: Data(String(cString: bytes).utf8)))
        }
        return result
    }
    private func bind(_ db: OpaquePointer, _ statement: OpaquePointer?, _ index: Int32, _ text: String) throws {
        let result = text.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard result == SQLITE_OK else { throw failure(db) }
    }
    private func put<T: Encodable>(_ db: OpaquePointer, kind: String, id: String, value: T) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO planner_items(kind,id,payload) VALUES(?,?,?) ON CONFLICT(kind,id) DO UPDATE SET payload=excluded.payload", -1, &statement, nil) == SQLITE_OK else { throw failure(db) }
        defer { sqlite3_finalize(statement) }
        try bind(db, statement, 1, kind); try bind(db, statement, 2, id)
        try bind(db, statement, 3, String(decoding: PlannerCoding.encoder().encode(value), as: UTF8.self))
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure(db) }
    }
    private func remove(_ db: OpaquePointer, kind: String, id: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM planner_items WHERE kind=? AND id=?", -1, &statement, nil) == SQLITE_OK else { throw failure(db) }
        defer { sqlite3_finalize(statement) }
        try bind(db, statement, 1, kind); try bind(db, statement, 2, id)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure(db) }
    }
    private func read(_ db: OpaquePointer) throws -> PlannerSnapshot {
        var snapshot = PlannerSnapshot()
        snapshot.records = try rows(db, kind: "record")
        snapshot.tasks = try rows(db, kind: "task")
        snapshot.blocks = try rows(db, kind: "block")
        snapshot.preferences = try rows(db, kind: "preferences").first ?? PlannerPreferences()
        return snapshot
    }
    public func snapshot() throws -> PlannerSnapshot {
        try connection { db in
            try execute(db, "BEGIN")
            do { let value = try read(db); try execute(db, "COMMIT"); return value }
            catch { try? execute(db, "ROLLBACK"); throw error }
        }
    }
    @discardableResult
    public func capture(_ request: CaptureRequest, now: Date = Date(), calendar: Calendar = .current) throws -> PlannerRecord {
        guard !request.requestID.isEmpty, !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PlannerError.invalid("requestID와 기록 내용을 입력하세요.")
        }
        return try connection { db in try transaction(db) {
            let existing: [PlannerRecord] = try rows(db, kind: "record")
            if let record = existing.first(where: { $0.id == request.requestID }) {
                guard record.text == request.text, record.project == (request.project ?? ""),
                      record.sessionID == request.sessionID, record.context == (request.context ?? "") else {
                    throw PlannerError.invalid("같은 requestID에 다른 기록을 저장할 수 없습니다.")
                }
                return record
            }
            // Raw text persists even if a supplied candidate is unusable.
            let candidates = request.candidates ?? CaptureParser.candidates(request.text, now: now, calendar: calendar)
            let valid = candidates.filter { (try? Self.validate($0)) != nil }
            let record = PlannerRecord(id: request.requestID, text: request.text, project: request.project ?? "",
                                       sessionID: request.sessionID, context: request.context ?? "", createdAt: now, candidates: valid)
            try put(db, kind: "record", id: record.id, value: record)
            return record
        } }
    }
    /// Direct entry creates the source record and its task together, without an inbox step.
    @discardableResult
    public func addTask(title: String, day: Date, project: String = "", requestID: String = UUID().uuidString,
                        calendar: Calendar = .current) throws -> PlannerTask {
        var candidate = TaskCandidate(title: title.trimmingCharacters(in: .whitespacesAndNewlines))
        candidate.plannedDay = calendar.startOfDay(for: day)
        try Self.validate(candidate)
        guard !requestID.isEmpty else { throw PlannerError.invalid("저장 요청 ID가 없습니다.") }
        return try connection { db in try transaction(db) {
            let records: [PlannerRecord] = try rows(db, kind: "record")
            if let existing = records.first(where: { $0.id == requestID }) {
                let tasks: [PlannerTask] = try rows(db, kind: "task")
                guard existing.text == title, existing.project == project, existing.resolved,
                      existing.candidates.count == 1, existing.candidates[0].plannedDay == candidate.plannedDay,
                      let task = tasks.first(where: { $0.recordID == requestID }) else {
                    throw PlannerError.invalid("같은 저장 요청에 다른 할 일을 추가할 수 없습니다.")
                }
                return task
            }
            var record = PlannerRecord(id: requestID, text: title, project: project, context: "", createdAt: Date(), candidates: [candidate])
            record.resolved = true
            let task = PlannerTask(candidate: candidate, record: record)
            try put(db, kind: "record", id: record.id, value: record)
            try put(db, kind: "task", id: task.id, value: task)
            return task
        } }
    }

    public static func validate(_ candidate: TaskCandidate) throws {
        guard !candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              candidate.estimatedMinutes.map({ (1...1440).contains($0) }) ?? true,
              candidate.preferredStartHour.map({ (0...23).contains($0) }) ?? true,
              candidate.preferredEndHour.map({ (1...24).contains($0) }) ?? true else {
            throw PlannerError.invalid("제목, 예상시간(1~1440분), 희망 시간대를 확인하세요.")
        }
        if let start = candidate.preferredStartHour, let end = candidate.preferredEndHour, start >= end {
            throw PlannerError.invalid("희망 시간대의 종료는 시작보다 늦어야 합니다.")
        }
    }
    /// Resolves selected candidates atomically; unselected candidates remain in the original memo.
    public func resolve(record: PlannerRecord, selected: [TaskCandidate]) throws {
        try connection { db in try transaction(db) {
            let records: [PlannerRecord] = try rows(db, kind: "record")
            guard var current = records.first(where: { $0.id == record.id }), current.revision == record.revision,
                  !current.resolved else { throw PlannerError.conflict }
            guard Set(selected.map(\.id)).count == selected.count else { throw PlannerError.invalid("중복 후보입니다.") }
            for candidate in selected {
                try Self.validate(candidate)
                let task = PlannerTask(candidate: candidate, record: current)
                try put(db, kind: "task", id: task.id, value: task)
            }
            current.resolved = true; current.revision += 1
            try put(db, kind: "record", id: current.id, value: current)
        } }
    }
    public func saveTask(_ task: PlannerTask) throws {
        try connection { db in try transaction(db) {
            let tasks: [PlannerTask] = try rows(db, kind: "task")
            guard let current = tasks.first(where: { $0.id == task.id }), current.revision == task.revision else { throw PlannerError.conflict }
            var candidate = TaskCandidate(title: task.title)
            candidate.estimatedMinutes = task.estimatedMinutes; candidate.preferredStartHour = task.preferredStartHour
            candidate.preferredEndHour = task.preferredEndHour; try Self.validate(candidate)
            guard (0...2).contains(task.priority) else { throw PlannerError.invalid("우선순위를 확인하세요.") }
            if task.pinned && task.state != .done && tasks.filter({ $0.id != task.id && $0.pinned && $0.state != .done }).count >= 3 {
                throw PlannerError.invalid("핵심 작업은 최대 3개까지 고정할 수 있습니다.")
            }
            var updated = task; updated.revision += 1
            updated.completedAt = task.state == .done ? (task.completedAt ?? Date()) : nil
            try put(db, kind: "task", id: task.id, value: updated)
            let blocks: [PlannerBlock] = try rows(db, kind: "block")
            for var block in blocks where block.taskID == task.id {
                if current.plannedDay != updated.plannedDay &&
                    !(updated.plannedDay.map { Calendar.current.isDate($0, inSameDayAs: block.start) } ?? false) {
                    try remove(db, kind: "block", id: block.id)
                } else if current.title != updated.title {
                    block.title = updated.title
                    try put(db, kind: "block", id: block.id, value: block)
                }
            }
        } }
    }
    public func savePreferences(_ preferences: PlannerPreferences) throws {
        try preferences.validate()
        try connection { db in try transaction(db) { try put(db, kind: "preferences", id: "default", value: preferences) } }
    }
    public func removeBlock(_ block: PlannerBlock) throws {
        try connection { db in try transaction(db) {
            let blocks: [PlannerBlock] = try rows(db, kind: "block")
            guard blocks.contains(block) else { throw PlannerError.conflict }
            try remove(db, kind: "block", id: block.id)
        } }
    }
    public func addBlocks(_ additions: [PlannerBlock], replacing: [PlannerBlock] = [], expected: PlannerSnapshot? = nil, enforceRecommendation: Bool = false) throws {
        try connection { db in try transaction(db) {
            let current = try read(db)
            if let expected, (expected.tasks != current.tasks || expected.blocks != current.blocks || expected.preferences != current.preferences) {
                throw PlannerError.conflict
            }
            guard replacing.allSatisfy({ current.blocks.contains($0) }) else { throw PlannerError.conflict }
            var occupied = current.blocks.filter { block in !replacing.contains(where: { $0.id == block.id }) }
            if enforceRecommendation {
                try PlannerScheduler.validateRecommendation(additions, occupied: occupied, snapshot: current)
            }
            for block in additions {
                guard block.start < block.end, !block.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw PlannerError.invalid("일정 제목과 시작·종료 시간을 확인하세요.")
                }
                guard !occupied.contains(where: { $0.start < block.end && block.start < $0.end }) else {
                    throw PlannerError.invalid("다른 일정과 시간이 겹칩니다.")
                }
                if let id = block.taskID {
                    guard current.tasks.contains(where: { $0.id == id && $0.state != .done && $0.state != .waiting }),
                          !occupied.contains(where: { $0.taskID == id }) else {
                        throw PlannerError.invalid("완료·대기 작업이거나 이미 배치된 작업입니다. 기존 일정을 이동하세요.")
                    }
                }
                occupied.append(block)
            }
            for block in replacing { try remove(db, kind: "block", id: block.id) }
            for block in additions {
                try put(db, kind: "block", id: block.id, value: block)
                if var task = current.tasks.first(where: { $0.id == block.taskID }) {
                    task.plannedDay = Calendar.current.startOfDay(for: block.start)
                    task.revision += 1
                    try put(db, kind: "task", id: task.id, value: task)
                }
            }
        } }
    }
}
