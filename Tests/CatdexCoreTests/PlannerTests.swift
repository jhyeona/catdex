import XCTest
@testable import CatdexCore

final class PlannerTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Seoul")!; return c
    }
    private func date(_ day: Int = 6, _ hour: Int = 9, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }
    private func store() throws -> PlannerStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return PlannerStore(paths: CatdexPaths(root: root))
    }
    private func task(_ title: String = "확인", minutes: Int? = 40) -> PlannerTask {
        var candidate = TaskCandidate(title: title); candidate.estimatedMinutes = minutes; candidate.plannedDay = date()
        let record = PlannerRecord(id: UUID().uuidString, text: title, project: "/tmp/project", context: "재현 조건", createdAt: date(), candidates: [candidate])
        return PlannerTask(candidate: candidate, record: record)
    }
    func testDirectTaskEntryIsImmediatelyUsableAndRetrySafe() throws {
        let store = try store()
        let first = try store.addTask(title: "  로그인 오류 수정  ", day: date(7, 15), project: "/tmp/a", requestID: "direct", calendar: calendar)
        let retry = try store.addTask(title: "  로그인 오류 수정  ", day: date(7, 10), project: "/tmp/a", requestID: "direct", calendar: calendar)
        XCTAssertEqual(first.id, retry.id)
        XCTAssertEqual(first.title, "로그인 오류 수정")
        XCTAssertEqual(first.plannedDay, date(7, 0))
        let snapshot = try store.snapshot()
        XCTAssertEqual(snapshot.tasks.count, 1)
        XCTAssertEqual(snapshot.records.count, 1)
        XCTAssertTrue(snapshot.records[0].resolved)
        XCTAssertEqual(snapshot.records[0].text, "  로그인 오류 수정  ")
        XCTAssertThrowsError(try store.addTask(title: "다른 작업", day: date(7), requestID: "direct", calendar: calendar))
        XCTAssertThrowsError(try store.addTask(title: "  로그인 오류 수정  ", day: date(8), project: "/tmp/a", requestID: "direct", calendar: calendar))
        XCTAssertEqual(try store.snapshot().tasks.count, 1)
    }
    func testEmptyDirectTaskDoesNotLeaveAnInboxRecord() throws {
        let store = try store()
        XCTAssertThrowsError(try store.addTask(title: " \n ", day: date(), calendar: calendar))
        XCTAssertTrue(try store.snapshot().records.isEmpty)
        XCTAssertTrue(try store.snapshot().tasks.isEmpty)
        let pending = try store.capture(CaptureRequest(requestID: "existing-note", text: "기존 메모", candidates: []))
        XCTAssertThrowsError(try store.addTask(title: "기존 메모", day: date(), requestID: pending.id, calendar: calendar))
        XCTAssertFalse(try store.snapshot().records[0].resolved)
    }
    func testCaptureIsIdempotentAndOriginalSurvivesResolutionAndSessionCleanup() throws {
        let store = try store()
        let input = CaptureRequest(requestID: "same", text: "/기록 내일 오전 로그인 버그 확인 40분 예상", project: "/tmp/a", sessionID: "thread", context: "재현: 만료 후 갱신")
        let first = try store.capture(input, now: date(), calendar: calendar)
        let again = try store.capture(input, now: date(7), calendar: calendar)
        XCTAssertEqual(first.id, again.id)
        XCTAssertEqual(again.candidates.count, 1)
        try store.resolve(record: again, selected: again.candidates)
        _ = try StatusStore(paths: CatdexPaths(root: store.url.deletingLastPathComponent())).pruneFinished(olderThan: 0)
        let loaded = try PlannerStore(paths: CatdexPaths(root: store.url.deletingLastPathComponent())).snapshot()
        XCTAssertEqual(loaded.records.count, 1); XCTAssertEqual(loaded.tasks.count, 1)
        XCTAssertEqual(loaded.records[0].text, input.text); XCTAssertEqual(loaded.records[0].context, input.context)
        XCTAssertEqual(loaded.tasks[0].plannedDay, calendar.startOfDay(for: date(7)))
        XCTAssertNil(loaded.tasks[0].dueAt)
        XCTAssertThrowsError(try store.resolve(record: again, selected: again.candidates))
    }
    func testMemoAndPartialCandidateRegistration() throws {
        let store = try store()
        let memo = try store.capture(CaptureRequest(text: "토큰 만료는 서버 시간 기준"), now: date())
        XCTAssertTrue(memo.candidates.isEmpty)
        try store.resolve(record: memo, selected: [])
        let multi = try store.capture(CaptureRequest(text: "작업 둘", candidates: [TaskCandidate(title: "A"), TaskCandidate(title: "B")]), now: date())
        var edited = multi.candidates[1]; edited.title = "B 수정"
        try store.resolve(record: multi, selected: [edited])
        let snapshot = try store.snapshot()
        XCTAssertEqual(snapshot.tasks.map(\.title), ["B 수정"])
        XCTAssertEqual(snapshot.records.count, 2)
    }
    func testInvalidCandidateDoesNotLoseOriginalAndIDReuseCannotOverwrite() throws {
        let store = try store()
        var candidate = TaskCandidate(title: "잘못된 후보"); candidate.estimatedMinutes = -1
        let input = CaptureRequest(requestID: "stable", text: "원문", candidates: [candidate])
        let record = try store.capture(input)
        XCTAssertEqual(record.text, "원문"); XCTAssertTrue(record.candidates.isEmpty)
        XCTAssertThrowsError(try store.capture(CaptureRequest(requestID: "stable", text: "다른 원문")))
        XCTAssertEqual(try store.snapshot().records[0].text, "원문")
    }
    func testOptimisticTaskUpdateAndPinLimit() throws {
        let store = try store()
        let record = try store.capture(CaptureRequest(text: "네 작업", candidates: (1...4).map { TaskCandidate(title: "작업 \($0)") }))
        try store.resolve(record: record, selected: record.candidates)
        let tasks = try store.snapshot().tasks
        for var task in tasks.prefix(3) { task.pinned = true; try store.saveTask(task) }
        var fourth = tasks[3]; fourth.pinned = true
        XCTAssertThrowsError(try store.saveTask(fourth))
        var stale = tasks[0]; stale.pauseNote = "이전 버전"
        XCTAssertThrowsError(try store.saveTask(stale))
        var current = try store.snapshot().tasks[0]
        current.pauseNote = "다음 테스트부터"; current.state = .done
        try store.saveTask(current)
        let reopened = try store.snapshot().tasks[0]
        XCTAssertEqual(reopened.pauseNote, "다음 테스트부터"); XCTAssertNotNil(reopened.completedAt)
    }
    func testOfflineParserDistinguishesDeadlineAndAmbiguousTime() {
        let desired = CaptureParser.candidates("내일 오전 로그인 버그 확인 40분 예상", now: date(), calendar: calendar)[0]
        XCTAssertEqual(desired.estimatedMinutes, 40); XCTAssertNil(desired.dueAt)
        XCTAssertEqual(desired.preferredStartHour, 9); XCTAssertEqual(desired.preferredEndHour, 12)
        let due = CaptureParser.candidates("금요일까지 리뷰", now: date(), calendar: calendar)[0]
        XCTAssertEqual(due.dueAt, date(9, 23, 59)); XCTAssertNil(due.plannedDay)
        let unclear = CaptureParser.candidates("내일 3시 확인", now: date(), calendar: calendar)[0]
        XCTAssertNil(unclear.preferredStartHour); XCTAssertFalse(unclear.note.isEmpty)
        let later = CaptureParser.candidates("나중에 버그 수정", now: date(), calendar: calendar)[0]
        XCTAssertNil(later.plannedDay); XCTAssertNil(later.dueAt)
    }
    func testRecommendationHonorsLunchFixedBlocksAndGaps() throws {
        var snapshot = PlannerSnapshot()
        snapshot.tasks = [task("A", minutes: 90), task("B", minutes: 90), task("C", minutes: 60)]
        snapshot.tasks[0].order = 0; snapshot.tasks[1].order = 1; snapshot.tasks[2].order = 2
        snapshot.blocks = [PlannerBlock(title: "회의", start: date(6, 10), end: date(6, 11))]
        let result = PlannerScheduler.propose(snapshot: snapshot, day: date(), now: date(), calendar: calendar)
        XCTAssertEqual(result.blocks.count, 3)
        XCTAssertEqual(result.blocks[0].start, date(6, 13))
        XCTAssertEqual(result.blocks[1].start, date(6, 14, 40))
        XCTAssertEqual(result.blocks[2].start, date(6, 9)) // smaller task fits earlier free slot
        try PlannerScheduler.validateRecommendation(result.blocks, occupied: snapshot.blocks, snapshot: snapshot, calendar: calendar)
    }
    func testRecommendationUsesDeadlineThenPriorityAndReportsCapacity() {
        var snapshot = PlannerSnapshot()
        var late = task("늦은 마감"); late.dueAt = date(6, 17); late.priority = 2
        var early = task("빠른 마감"); early.dueAt = date(6, 10)
        var huge = task("불가능", minutes: 1440); huge.priority = 2
        snapshot.tasks = [late, early, huge, task("기본시간", minutes: nil)]
        let result = PlannerScheduler.propose(snapshot: snapshot, day: date(), now: date(), calendar: calendar)
        XCTAssertEqual(result.blocks.first?.taskID, early.id)
        XCTAssertNotNil(result.unplaced[huge.id])
        XCTAssertEqual(result.assumedDurationTaskIDs, [snapshot.tasks[3].id])
        XCTAssertFalse(result.blocks.contains { $0.end > date(6, 18) })
    }
    func testWeekendAndWaitingTasksAreNotScheduled() {
        var snapshot = PlannerSnapshot()
        var waiting = task(); waiting.state = .waiting; waiting.reviewAt = date()
        snapshot.tasks = [waiting, task("할 일")]
        XCTAssertTrue(PlannerScheduler.isToday(waiting, day: date(), calendar: calendar))
        let today = PlannerScheduler.propose(snapshot: snapshot, day: date(), now: date(), calendar: calendar)
        XCTAssertEqual(today.blocks.count, 1)
        snapshot.tasks[1].plannedDay = date(10)
        let weekend = PlannerScheduler.propose(snapshot: snapshot, day: date(10), now: date(10), calendar: calendar)
        XCTAssertTrue(weekend.blocks.isEmpty); XCTAssertEqual(weekend.unplaced.count, 1)
    }
    func testReschedulingIsExplicitAndKeepsFutureConfirmedBlocks() {
        var snapshot = PlannerSnapshot(); snapshot.tasks = [task("밀린 작업"), task("확정 작업")]
        snapshot.blocks = [PlannerBlock(taskID: snapshot.tasks[0].id, title: "밀린 작업", start: date(5, 9), end: date(5, 10)),
                           PlannerBlock(taskID: snapshot.tasks[1].id, title: "확정 작업", start: date(6, 14), end: date(6, 15))]
        let normal = PlannerScheduler.propose(snapshot: snapshot, day: date(), now: date(), calendar: calendar)
        XCTAssertTrue(normal.blocks.isEmpty); XCTAssertTrue(normal.replacing.isEmpty)
        let retry = PlannerScheduler.propose(snapshot: snapshot, day: date(), now: date(), rescheduleOverdue: true, calendar: calendar)
        XCTAssertEqual(retry.replacing.map(\.id), [snapshot.blocks[0].id]); XCTAssertEqual(retry.blocks.count, 1)
        XCTAssertEqual(snapshot.blocks[1].start, date(6, 14))
    }
    func testAtomicScheduleRejectsConflictsAndStaleProposal() throws {
        let store = try store()
        let block = PlannerBlock(title: "회의", start: date(), end: date(6, 10))
        try store.addBlocks([block])
        let expected = try store.snapshot()
        XCTAssertThrowsError(try store.addBlocks([PlannerBlock(title: "충돌", start: date(6, 9, 30), end: date(6, 11))]))
        XCTAssertEqual(try store.snapshot().blocks.count, 1)
        let other = PlannerBlock(title: "다른 일정", start: date(6, 13), end: date(6, 14))
        try store.addBlocks([other])
        XCTAssertThrowsError(try store.addBlocks([], expected: expected))
        var moved = block; moved.start = date(6, 12); moved.end = date(6, 14)
        XCTAssertThrowsError(try store.addBlocks([moved], replacing: [block]))
        XCTAssertTrue(try store.snapshot().blocks.contains(block))
    }
    func testManualRecommendationEditCannotOverlapLunchOrBreakGap() throws {
        var snapshot = PlannerSnapshot(); snapshot.tasks = [task("A"), task("B")]
        let a = PlannerBlock(taskID: snapshot.tasks[0].id, title: "A", start: date(6, 11, 40), end: date(6, 12, 20))
        XCTAssertThrowsError(try PlannerScheduler.validateRecommendation([a], occupied: [], snapshot: snapshot, calendar: calendar))
        let b = PlannerBlock(taskID: snapshot.tasks[0].id, title: "A", start: date(), end: date(6, 9, 40))
        let c = PlannerBlock(taskID: snapshot.tasks[1].id, title: "B", start: date(6, 9, 45), end: date(6, 10, 25))
        XCTAssertThrowsError(try PlannerScheduler.validateRecommendation([b,c], occupied: [], snapshot: snapshot, calendar: calendar))
    }
    func testCLIJSONAcceptsOptionalFieldsAndRejectsMissingRequestID() throws {
        let request = try PlannerCoding.decoder().decode(CaptureRequest.self, from: Data(#"{"requestID":"test","text":"원문","candidates":[{"title":"작업","dueAt":"2026-10-09T17:00:00+09:00"}]}"#.utf8))
        XCTAssertEqual(request.candidates?.first?.dueAt, date(9, 17))
        XCTAssertNotNil(request.candidates?.first?.id)
        XCTAssertThrowsError(try PlannerCoding.decoder().decode(CaptureRequest.self, from: Data(#"{"text":"원문"}"#.utf8)))
    }
    func testDraggingAssignsDayAndPostponingClearsOldBlockAtomically() throws {
        let store = try store()
        let record = try store.capture(CaptureRequest(text: "버그 확인", candidates: [TaskCandidate(title: "버그 확인")]))
        try store.resolve(record: record, selected: record.candidates)
        let task = try store.snapshot().tasks[0]
        let block = PlannerBlock(taskID: task.id, title: task.title, start: date(), end: date(6, 10))
        try store.addBlocks([block])
        var assigned = try store.snapshot().tasks[0]
        XCTAssertTrue(Calendar.current.isDate(try XCTUnwrap(assigned.plannedDay), inSameDayAs: block.start))
        assigned.plannedDay = date(7)
        try store.saveTask(assigned)
        XCTAssertTrue(try store.snapshot().blocks.isEmpty)
        XCTAssertEqual(try store.snapshot().tasks[0].plannedDay, date(7))
    }

    func testMultipleDateExpressionsRemainUnconfirmed() {
        let candidate = CaptureParser.candidates("내일 작업 시작 금요일까지 구현", now: date(), calendar: calendar)[0]
        XCTAssertNil(candidate.plannedDay); XCTAssertNil(candidate.dueAt)
        XCTAssertTrue(candidate.note.contains("여러 개"))
    }

    func testWorkingHoursRemainLocalAcrossDSTChange() {
        var local = Calendar(identifier: .gregorian); local.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let day = local.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 8))!
        var snapshot = PlannerSnapshot(); snapshot.preferences.weekdays = [1]
        var value = task(); value.plannedDay = day; snapshot.tasks = [value]
        let result = PlannerScheduler.propose(snapshot: snapshot, day: day, now: day, calendar: local)
        XCTAssertEqual(result.blocks.count, 1)
        XCTAssertEqual(local.component(.hour, from: result.blocks[0].start), 9)
    }

}
