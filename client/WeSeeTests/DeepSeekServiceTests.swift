import Testing
import Foundation
@testable import WeSee

struct DeepSeekServiceTests {
    @Test func buildRequestIncludesToolsWhenProvided() {
        let service = DeepSeekService()
        let tools: [[String: Any]] = [[
            "type": "function",
            "function": [
                "name": "read_file",
                "description": "Read a file",
                "parameters": ["type": "object", "properties": [:], "required": []],
            ],
        ]]
        let request = service.buildRequest(
            messages: [["role": "user", "content": "hi"]],
            config: .default,
            tools: tools
        )
        let body = request.httpBody!
        let json = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
        let reqTools = json["tools"] as! [[String: Any]]
        #expect(reqTools.count == 1)
    }

    @Test func buildRequestIncludesSystemPrompt() {
        let service = DeepSeekService()
        let request = service.buildRequest(
            messages: [],
            config: .default,
            systemPrompt: "You are a helpful assistant"
        )
        let body = request.httpBody!
        let json = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
        let messages = json["messages"] as! [[String: Any]]
        #expect(messages.first?["role"] as? String == "system")
        #expect(messages.first?["content"] as? String == "You are a helpful assistant")
    }

    @Test func buildRequestOmitsSystemPromptWhenNil() {
        let service = DeepSeekService()
        let request = service.buildRequest(
            messages: [["role": "user", "content": "hi"]],
            config: .default
        )
        let body = request.httpBody!
        let json = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
        let messages = json["messages"] as! [[String: Any]]
        #expect(messages.first?["role"] as? String == "user")
    }

    @Test func parseContentDeltaReturnsText() {
        let service = DeepSeekService()
        let json = #"{"choices":[{"delta":{"content":"hello"}}]}"#
        #expect(service.parseContentDelta(json) == "hello")
    }

    @Test func parseThinkingDeltaReturnsReasoningContent() {
        let service = DeepSeekService()
        let json = #"{"choices":[{"delta":{"reasoning_content":"thinking..."}}]}"#
        #expect(service.parseThinkingDelta(json) == "thinking...")
    }

    @Test func parseToolCallDeltaFullChunk() {
        let service = DeepSeekService()
        let json = #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read_file","arguments":"{\"path\":\"/tmp/t.txt\"}"}}]}}]}"#
        let result = service.parseToolCallDelta(json)
        #expect(result?.index == 0)
        #expect(result?.id == "call_1")
        #expect(result?.name == "read_file")
        #expect(result?.arguments == #"{"path":"/tmp/t.txt"}"#)
    }

    @Test func parseToolCallDeltaArgsOnlyChunk() {
        let service = DeepSeekService()
        let json = #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"more"}}]}}]}"#
        let result = service.parseToolCallDelta(json)
        #expect(result?.id == nil)
        #expect(result?.name == nil)
        #expect(result?.arguments == "more")
    }

    @Test func parseFinishReasonReturnsStop() {
        let service = DeepSeekService()
        let json = #"{"choices":[{"finish_reason":"stop"}]}"#
        #expect(service.parseFinishReason(json) == "stop")
    }

    @Test func parseFinishReasonReturnsToolCalls() {
        let service = DeepSeekService()
        let json = #"{"choices":[{"finish_reason":"tool_calls"}]}"#
        #expect(service.parseFinishReason(json) == "tool_calls")
    }
}
