import Foundation

public enum CatdexState: String, Codable, CaseIterable, Sendable {
    case starting
    case running
    case responding
    case review
    case waiting
    case done
    case failed
    case stale
}

public extension CatdexState {
    var isActive: Bool {
        [.starting, .running, .responding, .review, .waiting].contains(self)
    }

    var isFinished: Bool {
        [.done, .failed, .stale].contains(self)
    }

    var needsAttention: Bool {
        [.review, .failed, .stale].contains(self)
    }
}

public struct CatdexSession: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var state: CatdexState
    public var task: String
    public var workspace: String
    public var branch: String?
    public var updatedAt: Date
    public var pid: Int32?
    public var lastMessage: String
    public var reviewOptions: [String]?
    public var logPath: String?
    public var codexSessionPath: String?
    public var exitCode: Int32?

    public init(
        id: String,
        state: CatdexState,
        task: String,
        workspace: String,
        branch: String? = nil,
        updatedAt: Date,
        pid: Int32? = nil,
        lastMessage: String,
        reviewOptions: [String]? = nil,
        logPath: String? = nil,
        codexSessionPath: String? = nil,
        exitCode: Int32? = nil
    ) {
        self.id = id
        self.state = state
        self.task = task
        self.workspace = workspace
        self.branch = branch
        self.updatedAt = updatedAt
        self.pid = pid
        self.lastMessage = lastMessage
        self.reviewOptions = reviewOptions
        self.logPath = logPath
        self.codexSessionPath = codexSessionPath
        self.exitCode = exitCode
    }
}

public extension CatdexSession {
    var projectName: String {
        URL(fileURLWithPath: workspace).lastPathComponent
    }

    var displayEmoji: String {
        switch state {
        case .starting: "🐾"
        case .running: "😼"
        case .responding: "✍️"
        case .review: "🐱❓"
        case .waiting: "👀"
        case .done: "😺"
        case .failed: "🙀"
        case .stale: "😿"
        }
    }

    var isActive: Bool {
        state.isActive
    }

    var isFinished: Bool {
        state.isFinished
    }

    var needsAttention: Bool {
        state.needsAttention
    }
}
