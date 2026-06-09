import Testing
import Foundation
@testable import WeSee

final class MockDeepSeekService: DeepSeekService {
    var events: [LLMStreamEvent] = []

    override func streamChat(
        messages: [[String: Any]],
        config: ClientConfig,
        tools: [[String: Any]] = [],
        systemPrompt: String? = nil
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let currentEvents = self.events
        self.events = []
        return AsyncThrowingStream { continuation in
            for event in currentEvents {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

struct FakeEchoTool: AgentTool {
    let name = "echo"
    let description = "Echoes input"
    let parameters = JSONSchema(
        type: "object",
        properties: ["text": JSONSchema.PropertyDef(type: "string", description: "Text to echo")],
        required: ["text"]
    )
    func execute(arguments: [String: Any]) async throws -> String {
        let text = arguments["text"] as? String ?? ""
        return "echo: \(text)"
    }
}

struct AgentRunnerTests {
    @Test func singleRoundNoToolCallsEmitsTokensAndDone() async throws {
        let registry = ToolRegistry()
        let mockService = MockDeepSeekService()
        mockService.events = [
            .token("Hello"),
            .token(" world"),
            .finishReason("stop"),
        ]
        let runner = AgentRunner(
            deepSeekService: mockService,
            toolRegistry: registry,
            maxRounds: 10
        )
        let history = [Message(content: "hi", isFromMe: true)]

        var tokens = ""
        var doneReceived = false

        for try await event in runner.run(history: history, config: .default) {
            switch event {
            case .token(let t): tokens += t
            case .done: doneReceived = true
            default: break
            }
        }

        #expect(tokens == "Hello world")
        #expect(doneReceived)
    }

    @Test func toolCallLoopExecutesAndContinues() async throws {
        let registry = ToolRegistry()
        registry.register(FakeEchoTool())

        let mockService = MockDeepSeekService()
        mockService.events = [
            .toolCallDelta(ToolCallDelta(index: 0, id: "call_1", name: "echo", arguments: #"{"text":"test"}"#)),
            .finishReason("tool_calls"),
        ]

        let runner = AgentRunner(
            deepSeekService: mockService,
            toolRegistry: registry,
            maxRounds: 10
        )
        let history = [Message(content: "echo test", isFromMe: true)]

        var toolStarts: [(String, String)] = []
        var toolResults: [(String, String)] = []

        for try await event in runner.run(history: history, config: .default) {
            switch event {
            case .toolCallStart(let id, let name, _):
                toolStarts.append((id, name))
            case .toolCallResult(let id, let name, let result):
                toolResults.append((id, name))
                #expect(result == "echo: test")
            case .error(let msg):
                #expect(msg == "Max rounds reached")
            default: break
            }
        }

        #expect(toolStarts.count == 1)
        #expect(toolResults.count == 1)
        #expect(toolStarts[0].0 == "call_1")
        #expect(toolStarts[0].1 == "echo")
    }

    @Test func unknownToolReturnsErrorResult() async throws {
        let registry = ToolRegistry()

        let mockService = MockDeepSeekService()
        mockService.events = [
            .toolCallDelta(ToolCallDelta(
                index: 0, id: "call_1", name: "unknown_tool",
                arguments: #"{"key":"val"}"#
            )),
            .finishReason("tool_calls"),
        ]

        let runner = AgentRunner(
            deepSeekService: mockService,
            toolRegistry: registry,
            maxRounds: 10
        )
        let history = [Message(content: "use tool", isFromMe: true)]

        var toolResult = ""
        for try await event in runner.run(history: history, config: .default) {
            if case .toolCallResult(_, _, let result) = event {
                toolResult = result
            }
        }

        #expect(toolResult.hasPrefix("Error: unknown tool"))
    }

    @Test func parseJSONArgsParsesValidJSON() {
        let result = AgentRunner.parseJSONArgs(#"{"key": "value", "num": 42}"#)
        #expect(result?["key"] as? String == "value")
        #expect(result?["num"] as? Int == 42)
    }

    @Test func parseJSONArgsReturnsNilForInvalidJSON() {
        let result = AgentRunner.parseJSONArgs("not json")
        #expect(result == nil)
    }

    @Test func encodeJSONArgsProducesJSONString() {
        let result = AgentRunner.encodeJSONArgs(["key": "value"])
        #expect(result.contains("\"key\""))
        #expect(result.contains("\"value\""))
    }
}
