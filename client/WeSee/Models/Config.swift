// client/WeSee/Models/Config.swift
import Foundation

struct ClientConfig: Codable {
    let httpPort: UInt16

    static let `default` = ClientConfig(httpPort: 8080)

    enum CodingKeys: String, CodingKey {
        case httpPort
    }

    init(httpPort: UInt16 = 8080) {
        self.httpPort = httpPort
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        httpPort = try container.decodeIfPresent(UInt16.self, forKey: .httpPort) ?? 8080
    }
}

enum ConfigError: LocalizedError {
    case fileNotFound(path: String)
    case invalidJSON(Error)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "配置文件未找到 \(path)"
        case .invalidJSON(let error):
            return "配置文件格式错误: \(error.localizedDescription)"
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

        return config
    }
}
