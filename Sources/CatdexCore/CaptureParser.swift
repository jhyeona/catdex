import Foundation

public enum CaptureParser {
    /// Conservative offline suggestions. Never turns an inferred candidate into a confirmed task.
    public static func candidates(_ input: String, now: Date = Date(), calendar: Calendar = .current) -> [TaskCandidate] {
        let text = input.hasPrefix("/기록") ? String(input.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines) : input
        return text.components(separatedBy: .newlines).compactMap { line in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            let actionWords = ["확인", "수정", "구현", "리뷰", "배포", "테스트", "정리", "추가", "해결", "하기", "작성", "조사", "TODO", "todo", "fix", "review"]
            guard actionWords.contains(where: { value.contains($0) }) else { return nil }
            var candidate = TaskCandidate(title: value)
            if let match = capture("(\\d+)\\s*분\\s*예상", in: value), let minutes = Int(match) {
                candidate.estimatedMinutes = (1...1440).contains(minutes) ? minutes : nil
            } else if let match = capture("(\\d+)\\s*시간\\s*예상", in: value), let hours = Int(match), (1...24).contains(hours) {
                candidate.estimatedMinutes = hours * 60
            }
            let datePattern = "모레|내일|오늘|일요일|월요일|화요일|수요일|목요일|금요일|토요일"
            if let regex = try? NSRegularExpression(pattern: datePattern),
               regex.numberOfMatches(in: value, range: NSRange(value.startIndex..., in: value)) > 1 {
                candidate.note = "날짜 표현이 여러 개입니다. 작업할 날짜와 마감을 직접 확인하세요."
                return candidate
            }
            let start = calendar.startOfDay(for: now)
            var day: Date?
            if value.contains("모레") { day = calendar.date(byAdding: .day, value: 2, to: start) }
            else if value.contains("내일") { day = calendar.date(byAdding: .day, value: 1, to: start) }
            else if value.contains("오늘") { day = start }
            else {
                let names = ["일요일", "월요일", "화요일", "수요일", "목요일", "금요일", "토요일"]
                if let weekday = names.firstIndex(where: { value.contains($0) }) {
                    let offset = (weekday + 1 - calendar.component(.weekday, from: now) + 7) % 7
                    if !value.contains("다음 주") && !value.contains("다음주") {
                        day = calendar.date(byAdding: .day, value: offset, to: start)
                    }
                }
            }
            if let day {
                let hourString = capture("(?<!\\d)(\\d{1,2})\\s*시(?!간)", in: value)
                var hour = hourString.flatMap(Int.init)
                if let h = hour, value.contains("오후"), h < 12 { hour = h + 12 }
                if hour == 12 && value.contains("오전") { hour = 0 }
                if let h = hour, !(0...23).contains(h) { hour = nil }
                // A bare '3시' is ambiguous; keep the date but ask for the time.
                if let h = hour, (1...12).contains(h), !value.contains("오전"), !value.contains("오후") {
                    hour = nil; candidate.note = "오전/오후를 확인하세요."
                }
                if value.contains("까지") || value.contains("마감") {
                    candidate.dueAt = calendar.date(bySettingHour: hour ?? 23, minute: hour == nil ? 59 : 0, second: 0, of: day)
                } else {
                    candidate.plannedDay = day
                    if let hour { candidate.preferredStartHour = hour; candidate.preferredEndHour = min(24, hour + 1) }
                    else if value.contains("오전") { candidate.preferredStartHour = 9; candidate.preferredEndHour = 12 }
                    else if value.contains("오후") { candidate.preferredStartHour = 13; candidate.preferredEndHour = 18 }
                }
            } else if value.contains("다음") || value.contains("나중") || value.contains("시") {
                candidate.note = "날짜·시간이 확실하지 않아 미지정으로 보관했습니다."
            }
            return candidate
        }
    }
    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
