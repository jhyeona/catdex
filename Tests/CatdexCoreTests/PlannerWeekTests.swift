import XCTest
@testable import CatdexCore

final class PlannerWeekTests: XCTestCase {
    func testMondayThroughSundayAcrossYearBoundary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        calendar.firstWeekday = 1 // The planner stays Monday-first regardless of the locale.
        let selected = calendar.date(from: DateComponents(year: 2027, month: 1, day: 3, hour: 23))!
        let week = PlannerWeek(containing: selected, calendar: calendar)
        XCTAssertEqual(week.days.count, 7)
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: week.days[0]), DateComponents(year: 2026, month: 12, day: 28))
        XCTAssertEqual(calendar.component(.weekday, from: week.days[6]), 1)
        XCTAssertTrue(week.contains(selected))
        XCTAssertFalse(week.contains(week.end))
        XCTAssertFalse(week.contains(week.days[0].addingTimeInterval(-1)))
        XCTAssertTrue(week.intersects(PlannerBlock(title: "Across midnight", start: week.days[0].addingTimeInterval(-3600), end: week.days[0].addingTimeInterval(3600))))
        XCTAssertFalse(week.intersects(PlannerBlock(title: "Ends at boundary", start: week.days[0].addingTimeInterval(-3600), end: week.days[0])))
        XCTAssertFalse(week.intersects(PlannerBlock(title: "Next week", start: week.end, end: week.end.addingTimeInterval(3600))))
    }

    func testWeekUsesLocalMidnightAcrossDaylightSavingTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        for (month, day, hours) in [(3, 8, 167), (11, 1, 169)] {
            let selected = calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
            let week = PlannerWeek(containing: selected, calendar: calendar)
            XCTAssertEqual(week.end.timeIntervalSince(week.days[0]), Double(hours * 3600))
            XCTAssertTrue(week.days.allSatisfy { calendar.component(.hour, from: $0) == 0 })
            XCTAssertEqual(Set(week.days.map { calendar.component(.weekday, from: $0) }).count, 7)
        }
    }
}
