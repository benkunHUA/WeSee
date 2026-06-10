import Foundation

struct ClientConfig: Codable {
    let apiKey: String
    let baseURL: String
    let model: String
    let enableThinking: Bool
    let reasoningEffort: String?

    static let `default` = ClientConfig(
        apiKey: "",
        baseURL: "https://api.deepseek.com",
        model: "deepseek-v4-pro",
        enableThinking: true,
        reasoningEffort: nil
    )

    enum CodingKeys: String, CodingKey {
        case apiKey
        case baseURL
        case model
        case enableThinking
        case reasoningEffort
    }

    init(
        apiKey: String,
        baseURL: String = "https://api.deepseek.com",
        model: String = "deepseek-v4-pro",
        enableThinking: Bool = true,
        reasoningEffort: String? = nil
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.enableThinking = enableThinking
        self.reasoningEffort = reasoningEffort
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apiKey = try container.decode(String.self, forKey: .apiKey)
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? "https://api.deepseek.com"
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? "deepseek-v4-pro"
        enableThinking = try container.decodeIfPresent(Bool.self, forKey: .enableThinking) ?? true
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
    }
}

enum ConfigError: LocalizedError {
    case fileNotFound(path: String)
    case invalidJSON(Error)
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "未找到配置文件 \(path)"
        case .invalidJSON(let error):
            return "配置文件格式错误: \(error.localizedDescription)"
        case .missingAPIKey:
            return "配置文件中缺少 apiKey"
        }
    }
}

struct ConfigLoader {
    static func load() throws -> ClientConfig {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configURL = home
            .appendingPathComponent(".config/wesee/config.json")

        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw ConfigError.fileNotFound(path: configURL.path)
        }

        let data: Data
        do {
            data = try Data(contentsOf: configURL)
        } catch {
            throw ConfigError.fileNotFound(path: configURL.path)
        }

        let config: ClientConfig
        do {
            config = try JSONDecoder().decode(ClientConfig.self, from: data)
        } catch {
            throw ConfigError.invalidJSON(error)
        }

        guard !config.apiKey.isEmpty else {
            throw ConfigError.missingAPIKey
        }

        return config
    }

    static func validate(_ config: ClientConfig) throws -> ClientConfig {
        guard !config.apiKey.isEmpty else {
            throw ConfigError.missingAPIKey
        }
        return config
    }
}
