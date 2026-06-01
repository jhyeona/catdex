import Foundation

public struct CatdexPaths: Sendable {
    public let root: URL

    public init(root: URL = CatdexPaths.defaultRoot()) {
        self.root = root
    }

    public var sessionsDirectory: URL {
        root.appendingPathComponent("sessions", isDirectory: true)
    }

    public var logsDirectory: URL {
        root.appendingPathComponent("logs", isDirectory: true)
    }

    public static func defaultRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["CATDEX_STATUS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("cat-status", isDirectory: true)
    }
}
