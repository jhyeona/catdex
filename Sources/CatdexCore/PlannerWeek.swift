import Foundation

/// A Monday–Sunday week, using calendar arithmetic across time-zone changes.
public struct PlannerWeek: Equatable, Sendable {
    public let days: [Date]
    public let end: Date

    public init(containing date: Date, calendar: Calendar = .current) {
        let day = calendar.startOfDay(for: date)
        let offset = (calendar.component(.weekday, from: day) + 5) % 7
        let start = calendar.date(byAdding: .day, value: -offset, to: day)!
        days = (0..<7).map { calendar.date(byAdding: .day, value: $0, to: start)! }
        end = calendar.date(byAdding: .day, value: 7, to: start)!
    }

    public func contains(_ date: Date) -> Bool { date >= days[0] && date < end }

    public func intersects(_ block: PlannerBlock) -> Bool {
        block.start < end && block.end > days[0]
    }
}
