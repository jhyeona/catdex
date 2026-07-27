import Foundation

public struct CatdexSettings: Decodable, Sendable {
    public var codexDefaultPrompt: String?

    enum CodingKeys: String, CodingKey {
        case codexDefaultPrompt
        case codexInitialPrompt
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        codexDefaultPrompt = try container.decodeIfPresent(String.self, forKey: .codexDefaultPrompt)
            ?? container.decodeIfPresent(String.self, forKey: .codexInitialPrompt)
    }
}

public struct CatdexSettingsReader: Sendable {
    public let paths: CatdexPaths
    private let decoder = JSONDecoder()

    public init(paths: CatdexPaths = CatdexPaths()) {
        self.paths = paths
    }

    public func codexDefaultPrompt() -> String? {
        guard let prompt = load().codexDefaultPrompt?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !prompt.isEmpty
        else {
            return nil
        }
        return prompt
    }

    private func load() -> CatdexSettings {
        let url = paths.root.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: url),
              let settings = try? decoder.decode(CatdexSettings.self, from: data)
        else {
            return CatdexSettings()
        }
        return settings
    }
}
