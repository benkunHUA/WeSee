import Testing
@testable import WeSee
import Foundation

struct DeepSeekServiceTests {

    @Test func buildRequestReturnsValidRequest() throws {
        let config = ClientConfig(apiKey: "sk-test", baseURL: "https://api.deepseek.com", model: "deepseek-chat")
        let service = DeepSeekService()
        let history: [Message] = [
            Message(content: "Hello", isFromMe: true),
            Message(content: "Hi there!", isFromMe: false),
        ]
        let request = service.buildRequest(history: history, config: config)

        #expect(request.url?.absoluteString == "https://api.deepseek.com/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        #expect(body["model"] as? String == "deepseek-chat")
        #expect(body["stream"] as? Bool == true)
        let messages = body["messages"] as! [[String: Any]]
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "user")
        #expect(messages[0]["content"] as? String == "Hello")
        #expect(messages[1]["role"] as? String == "assistant")
        #expect(messages[1]["content"] as? String == "Hi there!")
    }

    @Test func parseTokenDeltaReturnsContent() {
        let service = DeepSeekService()
        let json = """
        {"choices":[{"delta":{"content":"Hello"}}]}
        """
        let result = service.parseDelta(json)
        #expect(result == "Hello")
    }

    @Test func parseDeltaWithEmptyChoicesReturnsNil() {
        let service = DeepSeekService()
        let json = """
        {"choices":[]}
        """
        let result = service.parseDelta(json)
        #expect(result == nil)
    }

    @Test func parseDeltaWithMalformedJSONReturnsNil() {
        let service = DeepSeekService()
        let result = service.parseDelta("not json")
        #expect(result == nil)
    }

    @Test func parseFinishReasonReturnsStop() {
        let service = DeepSeekService()
        let json = """
        {"choices":[{"finish_reason":"stop"}]}
        """
        let result = service.parseFinishReason(json)
        #expect(result == "stop")
    }
}
