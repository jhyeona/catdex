import XCTest
@testable import CatdexCore

final class CatdexSettingsReaderTests: XCTestCase {
    func testCodexDefaultPromptReadsTrimmedValueFromSettings() throws {
        let root = try temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let settings = root.appendingPathComponent("settings.json")
        try Data("""
        {
          "codexDefaultPrompt" : "  AGENTS 확인하여 룰 확인  ",
          "iconEmojis" : {
            "waiting" : "cat"
          }
        }
        """.utf8).write(to: settings)

        let reader = CatdexSettingsReader(paths: CatdexPaths(root: root))

        XCTAssertEqual(reader.codexDefaultPrompt(), "AGENTS 확인하여 룰 확인")
    }

    func testCodexDefaultPromptIgnoresBlankValue() throws {
        let root = try temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let settings = root.appendingPathComponent("settings.json")
        try Data("""
        {
          "codexDefaultPrompt" : "   "
        }
        """.utf8).write(to: settings)

        let reader = CatdexSettingsReader(paths: CatdexPaths(root: root))

        XCTAssertNil(reader.codexDefaultPrompt())
    }

    func testCodexDefaultPromptReadsLegacyInitialPromptKey() throws {
        let root = try temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let settings = root.appendingPathComponent("settings.json")
        try Data("""
        {
          "codexInitialPrompt" : "AGENTS 확인하여 룰 확인"
        }
        """.utf8).write(to: settings)

        let reader = CatdexSettingsReader(paths: CatdexPaths(root: root))

        XCTAssertEqual(reader.codexDefaultPrompt(), "AGENTS 확인하여 룰 확인")
    }

    private func temporaryRoot() throws -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("catdex-settings-tests-\(UUID().uuidString)", isDirectory: true)
    }
}
