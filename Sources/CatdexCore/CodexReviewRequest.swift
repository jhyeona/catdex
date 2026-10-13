import Foundation

public struct CodexReviewRequest: Equatable, Sendable {
    public let notificationText: String?
}

public enum CodexReviewRequestParser {
    // Elevated commands can be auto-approved. Their arguments do not tell us
    // whether a person needs to act; only a blocking question does.
    public static func parse(toolName: String, arguments: String) -> CodexReviewRequest? {
        let normalizedToolName = toolName.split(separator: ".").last.map(String.init) ?? toolName

        if let object = parseJSONObject(arguments) {
            if normalizedToolName == "request_user_input",
               let question = notificationText(fromQuestions: object["questions"]) {
                return CodexReviewRequest(
                    notificationText: question
                )
            }
        }

        guard normalizedToolName == "exec" else {
            return nil
        }

        for call in JavaScriptToolCall.calls(in: arguments) {
            if call.name == "request_user_input",
               let question = notificationText(
                   JavaScriptObject.stringValue(forKey: "question", in: call.objectLiteral)
               ) {
                return CodexReviewRequest(notificationText: question)
            }
        }

        return nil
    }

    private static func notificationText(fromQuestions value: Any?) -> String? {
        guard let questions = value as? [[String: Any]] else {
            return nil
        }

        return questions.lazy.compactMap { notificationText($0["question"] as? String) }.first
    }

    private static func notificationText(_ value: String?) -> String? {
        guard let value else { return nil }
        let lines = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let normalized = lines.joined(separator: "\n")
        guard !normalized.isEmpty else { return nil }

        let maxLength = 220
        guard normalized.count > maxLength else { return normalized }
        let end = normalized.index(normalized.startIndex, offsetBy: maxLength)
        return String(normalized[..<end]) + "..."
    }

    private static func parseJSONObject(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }
}

private struct JavaScriptToolCall {
    let name: String
    let objectLiteral: String

    static func calls(in source: String) -> [JavaScriptToolCall] {
        let characters = Array(source)
        var calls: [JavaScriptToolCall] = []
        var index = 0

        while index < characters.count {
            if let nextIndex = JavaScriptLexing.indexAfterLiteralOrComment(
                at: index,
                in: characters
            ) {
                index = nextIndex
                continue
            }

            guard JavaScriptLexing.matches("tools.", at: index, in: characters),
                  index == 0 || !JavaScriptLexing.isIdentifierCharacter(characters[index - 1])
            else {
                index += 1
                continue
            }

            var nameStart = index + "tools.".count
            var nameEnd = nameStart
            while nameEnd < characters.count,
                  JavaScriptLexing.isIdentifierCharacter(characters[nameEnd]) {
                nameEnd += 1
            }

            guard nameEnd > nameStart else {
                index += 1
                continue
            }

            let name = String(characters[nameStart..<nameEnd])
            nameStart = JavaScriptLexing.skippingWhitespace(from: nameEnd, in: characters)
            guard nameStart < characters.count, characters[nameStart] == "(" else {
                index = nameEnd
                continue
            }

            let objectStart = JavaScriptLexing.skippingWhitespace(
                from: nameStart + 1,
                in: characters
            )
            guard objectStart < characters.count, characters[objectStart] == "{",
                  let objectEnd = JavaScriptLexing.endOfBalancedObject(
                    startingAt: objectStart,
                    in: characters
                  )
            else {
                index = nameEnd
                continue
            }

            calls.append(JavaScriptToolCall(
                name: name,
                objectLiteral: String(characters[objectStart...objectEnd])
            ))
            index = objectEnd + 1
        }

        return calls
    }
}

private enum JavaScriptObject {
    static func stringValue(forKey expectedKey: String, in objectLiteral: String) -> String? {
        let characters = Array(objectLiteral)
        var index = 0

        while index < characters.count {
            if JavaScriptLexing.isQuote(characters[index]),
               let parsedKey = JavaScriptLexing.parseString(startingAt: index, in: characters) {
                let colonIndex = JavaScriptLexing.skippingWhitespace(
                    from: parsedKey.nextIndex,
                    in: characters
                )
                if parsedKey.value == expectedKey,
                   colonIndex < characters.count,
                   characters[colonIndex] == ":",
                   let value = stringValue(afterColonAt: colonIndex, in: characters) {
                    return value
                }
                index = parsedKey.nextIndex
                continue
            }

            if let nextIndex = JavaScriptLexing.indexAfterLiteralOrComment(
                at: index,
                in: characters
            ) {
                index = nextIndex
                continue
            }

            guard JavaScriptLexing.isIdentifierStart(characters[index]) else {
                index += 1
                continue
            }

            let keyStart = index
            index += 1
            while index < characters.count,
                  JavaScriptLexing.isIdentifierCharacter(characters[index]) {
                index += 1
            }
            let key = String(characters[keyStart..<index])
            let colonIndex = JavaScriptLexing.skippingWhitespace(from: index, in: characters)
            if key == expectedKey,
               colonIndex < characters.count,
               characters[colonIndex] == ":",
               let value = stringValue(afterColonAt: colonIndex, in: characters) {
                return value
            }
        }

        return nil
    }

    private static func stringValue(afterColonAt colonIndex: Int, in characters: [Character]) -> String? {
        let valueStart = JavaScriptLexing.skippingWhitespace(
            from: colonIndex + 1,
            in: characters
        )
        guard valueStart < characters.count,
              JavaScriptLexing.isQuote(characters[valueStart]),
              let parsedValue = JavaScriptLexing.parseString(
                startingAt: valueStart,
                in: characters
              )
        else {
            return nil
        }
        return parsedValue.value
    }
}

private enum JavaScriptLexing {
    struct ParsedString {
        let value: String
        let nextIndex: Int
    }

    static func matches(_ token: String, at index: Int, in characters: [Character]) -> Bool {
        let tokenCharacters = Array(token)
        guard index + tokenCharacters.count <= characters.count else {
            return false
        }
        return Array(characters[index..<(index + tokenCharacters.count)]) == tokenCharacters
    }

    static func isIdentifierStart(_ character: Character) -> Bool {
        character == "_" || character == "$" || character.isLetter
    }

    static func isIdentifierCharacter(_ character: Character) -> Bool {
        isIdentifierStart(character) || character.isNumber
    }

    static func isQuote(_ character: Character) -> Bool {
        character == "\"" || character == "'" || character == "`"
    }

    static func skippingWhitespace(from start: Int, in characters: [Character]) -> Int {
        var index = start
        while index < characters.count, characters[index].isWhitespace {
            index += 1
        }
        return index
    }

    static func indexAfterLiteralOrComment(at index: Int, in characters: [Character]) -> Int? {
        guard index < characters.count else { return nil }
        if isQuote(characters[index]) {
            return parseString(startingAt: index, in: characters)?.nextIndex ?? characters.count
        }

        guard characters[index] == "/", index + 1 < characters.count else {
            return nil
        }
        if characters[index + 1] == "/" {
            var end = index + 2
            while end < characters.count, characters[end] != "\n" {
                end += 1
            }
            return end
        }
        if characters[index + 1] == "*" {
            var end = index + 2
            while end + 1 < characters.count {
                if characters[end] == "*", characters[end + 1] == "/" {
                    return end + 2
                }
                end += 1
            }
            return characters.count
        }
        return nil
    }

    static func endOfBalancedObject(startingAt start: Int, in characters: [Character]) -> Int? {
        var depth = 0
        var index = start

        while index < characters.count {
            if let nextIndex = indexAfterLiteralOrComment(at: index, in: characters) {
                index = nextIndex
                continue
            }

            if characters[index] == "{" {
                depth += 1
            } else if characters[index] == "}" {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
            index += 1
        }

        return nil
    }

    static func parseString(startingAt start: Int, in characters: [Character]) -> ParsedString? {
        guard start < characters.count, isQuote(characters[start]) else {
            return nil
        }

        let quote = characters[start]
        var value = ""
        var index = start + 1
        while index < characters.count {
            let character = characters[index]
            if character == quote {
                return ParsedString(value: value, nextIndex: index + 1)
            }
            if character == "\\", index + 1 < characters.count {
                let escaped = characters[index + 1]
                switch escaped {
                case "n": value.append("\n")
                case "r": value.append("\r")
                case "t": value.append("\t")
                case "b": value.append("\u{8}")
                case "f": value.append("\u{c}")
                case "v": value.append("\u{b}")
                default: value.append(escaped)
                }
                index += 2
                continue
            }
            value.append(character)
            index += 1
        }

        return nil
    }
}
