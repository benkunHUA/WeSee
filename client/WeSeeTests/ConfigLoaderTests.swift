import Testing
@testable import WeSee
import Foundation

struct ConfigLoaderTests {

    @Test func decodeValidConfig() throws {
        let json = """
        {"apiKey": "sk-test", "baseURL": "https://api.deepseek.com", "model": "deepseek-chat"}
        """
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(ClientConfig.self, from: data)
        #expect(config.apiKey == "sk-test")
        #expect(config.baseURL == "https://api.deepseek.com")
        #expect(config.model == "deepseek-chat")
    }

    @Test func decodeConfigWithDefaults() throws {
        let json = """
        {"apiKey": "sk-test"}
        """
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(ClientConfig.self, from: data)
        #expect(config.apiKey == "sk-test")
    }

    @Test func missingAPIKeyThrows() {
        let config = ClientConfig(apiKey: "", baseURL: "", model: "")
        do {
            _ = try ConfigLoader.validate(config)
        } catch {
            #expect(error is ConfigError)
        }
    }
}
