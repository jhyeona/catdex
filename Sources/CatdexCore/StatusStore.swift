import Foundation

public struct StatusStore: Sendable {
    public let paths: CatdexPaths
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(paths: CatdexPaths = CatdexPaths()) {
        self.paths = paths
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func prepareDirectories() throws {
        try FileManager.default.createDirectory(
            at: paths.sessionsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: paths.logsDirectory,
            withIntermediateDirectories: true
        )
    }

    public func sessionURL(for id: String) -> URL {
        paths.sessionsDirectory.appendingPathComponent("\(id).json")
    }

    public func logURL(for id: String) -> URL {
        paths.logsDirectory.appendingPathComponent("\(id).log")
    }

    public func loadSession(id: String) -> CatdexSession? {
        let url = sessionURL(for: id)
        guard let data = try? Data(contentsOf: url),
              let session = try? decoder.decode(CatdexSession.self, from: data)
        else {
            return nil
        }
        return session
    }

    public func save(_ session: CatdexSession) throws {
        try prepareDirectories()
        let target = sessionURL(for: session.id)
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).tmp-\(UUID().uuidString)")
        let data = try encoder.encode(session)
        try data.write(to: temporary, options: [.atomic])
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: target)
        }
    }

    public func updateSession(id: String, mutate: (inout CatdexSession) -> Void) throws {
        guard var session = loadSession(id: id) else { return }
        mutate(&session)
        try save(session)
    }

    public func loadSessions(now: Date = Date(), staleAfter: TimeInterval = 120) -> [CatdexSession] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: paths.sessionsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      var session = try? decoder.decode(CatdexSession.self, from: data)
                else {
                    return nil
                }

                if session.state.isActive,
                   now.timeIntervalSince(session.updatedAt) > staleAfter {
                    session.state = .stale
                    session.lastMessage = "No heartbeat since \(session.updatedAt.formatted())"
                    try? save(session)
                }

                return session
            }
            .sorted(by: CatdexSession.sortForDisplay)
    }

    public func removeSession(id: String, removeLog: Bool = true) throws {
        let session = sessionURL(for: id)
        if FileManager.default.fileExists(atPath: session.path) {
            try FileManager.default.removeItem(at: session)
        }

        guard removeLog else { return }
        let log = logURL(for: id)
        if FileManager.default.fileExists(atPath: log.path) {
            try FileManager.default.removeItem(at: log)
        }
    }

    @discardableResult
    public func pruneFinished(olderThan interval: TimeInterval, now: Date = Date()) throws -> Int {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: paths.sessionsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return 0
        }

        var removed = 0
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let session = try? decoder.decode(CatdexSession.self, from: data),
                  session.state.isFinished,
                  now.timeIntervalSince(session.updatedAt) > interval
            else {
                continue
            }

            try removeSession(id: session.id)
            removed += 1
        }

        return removed
    }
}

public extension CatdexSession {
    static func sortForDisplay(_ lhs: CatdexSession, _ rhs: CatdexSession) -> Bool {
        let priority: [CatdexState: Int] = [
            .review: 0,
            .failed: 1,
            .responding: 2,
            .starting: 3,
            .waiting: 4,
            .running: 5,
            .stale: 6,
            .done: 7
        ]

        let left = priority[lhs.state, default: 99]
        let right = priority[rhs.state, default: 99]
        if left != right {
            return left < right
        }

        return lhs.updatedAt > rhs.updatedAt
    }
}
