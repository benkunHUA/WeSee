import Foundation

final class AgentRunner {
    private let deepSeekService: DeepSeekService
    private let toolRegistry: ToolRegistry
    private let maxRounds: Int

    init(
        deepSeekService: DeepSeekService = DeepSeekService(),
        toolRegistry: ToolRegistry = ToolRegistry(),
        maxRounds: Int = 10
    ) {
        self.deepSeekService = deepSeekService
        self.toolRegistry = toolRegistry
        self.maxRounds = maxRounds
    }

    func run(
        history: [Message],
        config: ClientConfig,
        systemPrompt: String? = nil
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                var messages: [[String: Any]] = history.map { msg in
                    ["role": msg.isFromMe ? "user" : "assistant", "content": msg.content]
                }
                let tools = self.toolRegistry.encodeToAPIParams()
                var round = 0

                while round < self.maxRounds {
                    round += 1
                    var toolCallAggregator: [Int: (id: String, name: String, arguments: String)] = [:]
                    var hasToolCalls = false

                    do {
                        let stream = self.deepSeekService.streamChat(
                            messages: messages,
                            config: config,
                            tools: tools,
                            systemPrompt: round == 1 ? systemPrompt : nil
                        )

                        for try await event in stream {
                            switch event {
                            case .token(let text):
                                continuation.yield(.token(text))

                            case .thinking(let text):
                                continuation.yield(.thinking(text))

                            case .toolCallDelta(let delta):
                                hasToolCalls = true
                                var current = toolCallAggregator[delta.index]
                                    ?? ("", "", "")
                                if let id = delta.id { current.id = id }
                                if let name = delta.name { current.name = name }
                                current.arguments += delta.arguments
                                toolCallAggregator[delta.index] = current

                            case .finishReason:
                                break
                            }
                        }
                    } catch {
                        continuation.yield(.error(error.localizedDescription))
                        continuation.finish()
                        return
                    }

                    if !hasToolCalls {
                        continuation.yield(.done)
                        continuation.finish()
                        return
                    }

                    // Execute tools
                    let sortedKeys = toolCallAggregator.keys.sorted()
                    var toolCallDicts: [[String: Any]] = []

                    for key in sortedKeys {
                        let tc = toolCallAggregator[key]!
                        guard !tc.id.isEmpty, !tc.name.isEmpty else { continue }

                        let argsDict = Self.parseJSONArgs(tc.arguments) ?? [:]

                        continuation.yield(
                            .toolCallStart(id: tc.id, name: tc.name, arguments: argsDict)
                        )

                        let result: String
                        if let tool = self.toolRegistry.get(name: tc.name) {
                            do {
                                result = try await tool.execute(arguments: argsDict)
                            } catch {
                                result = "Tool execution error: \(error.localizedDescription)"
                            }
                        } else {
                            result = "Error: unknown tool '\(tc.name)'"
                        }

                        continuation.yield(
                            .toolCallResult(id: tc.id, name: tc.name, result: result)
                        )

                        let argsJSON = Self.encodeJSONArgs(argsDict)
                        toolCallDicts.append([
                            "id": tc.id,
                            "type": "function",
                            "function": [
                                "name": tc.name,
                                "arguments": argsJSON,
                            ],
                        ])

                        messages.append([
                            "role": "tool",
                            "tool_call_id": tc.id,
                            "content": result,
                        ])
                    }

                    messages.append([
                        "role": "assistant",
                        "content": NSNull(),
                        "tool_calls": toolCallDicts,
                    ])
                }

                continuation.yield(.error("Max rounds reached"))
                continuation.finish()
            }
        }
    }

    static func parseJSONArgs(_ jsonStr: String) -> [String: Any]? {
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    static func encodeJSONArgs(_ args: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: args),
              let str = String(data: data, encoding: .utf8)
        else { return "{}" }
        return str
    }
}
