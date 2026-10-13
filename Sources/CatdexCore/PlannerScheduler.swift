import Foundation

public struct ScheduleProposal: Sendable {
    public var blocks: [PlannerBlock]
    public var unplaced: [String: String]
    public var replacing: [PlannerBlock]
    public var assumedDurationTaskIDs: [String]
}

public enum PlannerScheduler {
    public static func isToday(_ task: PlannerTask, day: Date, calendar: Calendar = .current) -> Bool {
        guard task.state != .done else { return false }
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))!
        if task.state == .waiting { return task.reviewAt.map { $0 < end } ?? false }
        return task.pinned || task.plannedDay.map { calendar.isDate($0, inSameDayAs: day) } == true || task.dueAt.map { $0 < end } == true
    }

    public static func propose(snapshot: PlannerSnapshot, day: Date, now: Date = Date(),
                               rescheduleOverdue: Bool = false, calendar: Calendar = .current) -> ScheduleProposal {
        let prefs = snapshot.preferences
        var result = ScheduleProposal(blocks: [], unplaced: [:], replacing: [], assumedDurationTaskIDs: [])
        let startOfDay = calendar.startOfDay(for: day)
        func at(_ hour: Int) -> Date {
            if hour == 24 { return calendar.date(byAdding: .day, value: 1, to: startOfDay)! }
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: startOfDay)!
        }
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        if rescheduleOverdue {
            result.replacing = snapshot.blocks.filter { block in
                block.taskID != nil && block.end <= now && snapshot.tasks.contains { $0.id == block.taskID && $0.state != .done && $0.state != .waiting }
            }
        }
        var occupied = snapshot.blocks.filter { block in !result.replacing.contains { $0.id == block.id } }
        let rescheduledIDs = Set(result.replacing.compactMap(\.taskID))
        let tasks = snapshot.tasks.filter { task in
            task.state != .done && task.state != .waiting &&
            (isToday(task, day: day, calendar: calendar) || rescheduledIDs.contains(task.id)) &&
            !occupied.contains { $0.taskID == task.id }
        }.sorted {
            if $0.dueAt != $1.dueAt { return ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
        }
        if prefs.lunchEnabled {
            occupied.append(PlannerBlock(title: "점심", start: at(prefs.lunchStartHour), end: at(prefs.lunchEndHour)))
        }
        for task in tasks {
            guard prefs.weekdays.contains(calendar.component(.weekday, from: day)) else {
                result.unplaced[task.id] = "업무일이 아닙니다."; continue
            }
            let minutes = task.estimatedMinutes ?? 30
            if task.estimatedMinutes == nil { result.assumedDurationTaskIDs.append(task.id) }
            var cursor = max(at(prefs.startHour), now)
            if let hour = task.preferredStartHour { cursor = max(cursor, at(hour)) }
            var limit = min(at(prefs.endHour), task.dueAt ?? endOfDay)
            if let hour = task.preferredEndHour { limit = min(limit, at(hour)) }
            // Start on a five-minute boundary.
            let offset = cursor.timeIntervalSince(startOfDay)
            cursor = startOfDay.addingTimeInterval(ceil(offset / 300) * 300)
            let duration = Double(minutes * 60)
            let gap = Double(prefs.gapMinutes * 60)
            for busy in occupied.sorted(by: { $0.start < $1.start }) {
                let padding = busy.taskID == nil ? 0 : gap
                if cursor + duration <= busy.start - padding { break }
                if cursor < busy.end + padding && cursor + duration > busy.start - padding {
                    cursor = busy.end + padding
                }
            }
            if cursor + duration <= limit {
                let block = PlannerBlock(taskID: task.id, title: task.title, start: cursor, end: cursor + duration)
                result.blocks.append(block); occupied.append(block)
            } else { result.unplaced[task.id] = "마감·희망 시간대 안에 \(minutes)분의 빈 시간이 없습니다." }
        }
        return result
    }
    public static func validateRecommendation(_ blocks: [PlannerBlock], occupied: [PlannerBlock],
                                              snapshot: PlannerSnapshot, calendar: Calendar = .current) throws {
        let prefs = snapshot.preferences
        for block in blocks {
            guard let task = snapshot.tasks.first(where: { $0.id == block.taskID }) else { throw PlannerError.conflict }
            let day = calendar.startOfDay(for: block.start)
            func at(_ hour: Int) -> Date {
                if hour == 24 { return calendar.date(byAdding: .day, value: 1, to: day)! }
                return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
            }
            guard prefs.weekdays.contains(calendar.component(.weekday, from: day)),
                  block.start >= at(max(prefs.startHour, task.preferredStartHour ?? 0)),
                  block.end <= at(min(prefs.endHour, task.preferredEndHour ?? 24)),
                  task.dueAt.map({ block.end <= $0 }) ?? true else {
                throw PlannerError.invalid("추천 일정이 업무시간·희망 시간대·마감을 벗어났습니다.")
            }
            if prefs.lunchEnabled && block.start < at(prefs.lunchEndHour) && block.end > at(prefs.lunchStartHour) {
                throw PlannerError.invalid("추천 일정이 점심시간과 겹칩니다.")
            }
            let gap = Double(prefs.gapMinutes * 60)
            if (occupied + blocks.filter { $0.id != block.id }).contains(where: {
                $0.start - ($0.taskID == nil ? 0 : gap) < block.end && block.start < $0.end + ($0.taskID == nil ? 0 : gap)
            }) { throw PlannerError.invalid("다른 일정 또는 작업 사이 여유시간과 겹칩니다.") }
        }
    }

}
