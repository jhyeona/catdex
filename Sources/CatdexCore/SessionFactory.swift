import Foundation

public enum SessionFactory {
    public static func makeID(task: String, date: Date = Date(), pid: Int32 = getpid()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        let slug = task
            .lowercased()
            .unicodeScalars
            .map { scalar -> Character in
                CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
            }
            .reduce(into: "") { result, character in
                if character == "-", result.last == "-" {
                    return
                }
                result.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        let suffix = slug.isEmpty ? "codex" : String(slug.prefix(32))
        return "\(formatter.string(from: date))-\(pid)-\(suffix)"
    }
}
