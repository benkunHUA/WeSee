import Foundation

class AgentRunner {
    private let deepSeekService: DeepSeekService
    private let toolRegistry: ToolRegistry
    private let maxRounds: Int
    let workspaceManager: WorkspaceManager

    init(
        deepSeekService: DeepSeekService = DeepSeekService(),
        toolRegistry: ToolRegistry = ToolRegistry(),
        maxRounds: Int = 30,
        workspaceManager: WorkspaceManager = WorkspaceManager()
    ) {
        self.deepSeekService = deepSeekService
        self.toolRegistry = toolRegistry
        self.maxRounds = maxRounds
        self.workspaceManager = workspaceManager
        registerDefaultTools()
    }

    private func registerDefaultTools() {
        toolRegistry.register(ShellTool(workspaceManager: workspaceManager))
        toolRegistry.register(FileSystemTool(workspaceManager: workspaceManager))
        toolRegistry.register(ScreenshotTool(workspaceManager: workspaceManager))
        WeSeeLog.info("AgentRunner registered \(toolRegistry.allTools.count) tools")
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

                WeSeeLog.info("AgentRunner start: rounds=\(self.maxRounds) messages=\(messages.count) tools=\(tools.count)")

                while round < self.maxRounds {
                    round += 1
                    WeSeeLog.info("AgentRunner round \(round)/\(self.maxRounds) start")
                    var toolCallAggregator: [Int: (id: String, name: String, arguments: String)] = [:]
                    var hasToolCalls = false
                    var tokenCount = 0

                    do {
                        let stream = self.deepSeekService.streamChat(
                            messages: messages,
                            config: config,
                            tools: tools,
                            systemPrompt: systemPrompt
                        )

                        for try await event in stream {
                            switch event {
                            case .token(let text):
                                tokenCount += 1
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

                            case .finishReason(let reason):
                                WeSeeLog.debug("AgentRunner finish reason: \(reason ?? "nil")")
                            }
                        }
                        WeSeeLog.info("AgentRunner stream ended: round=\(round) tokens=\(tokenCount) hasToolCalls=\(hasToolCalls)")
                    } catch {
                        WeSeeLog.error("AgentRunner stream error: \(error.localizedDescription)")
                        continuation.yield(.error(error.localizedDescription))
                        continuation.finish()
                        return
                    }

                    if !hasToolCalls {
                        WeSeeLog.info("AgentRunner done: no tool calls, finishing")
                        continuation.yield(.done)
                        continuation.finish()
                        return
                    }

                    // Execute tools
                    let sortedKeys = toolCallAggregator.keys.sorted()
                    var toolCallDicts: [[String: Any]] = []
                    var toolResultMessages: [[String: Any]] = []

                    for key in sortedKeys {
                        guard let tc = toolCallAggregator[key],
                              !tc.id.isEmpty,
                              !tc.name.isEmpty else { continue }

                        let argsDict = Self.parseJSONArgs(tc.arguments) ?? [:]
                        WeSeeLog.info("AgentRunner executing tool: name=\(tc.name) args=\(argsDict)")

                        continuation.yield(
                            .toolCallStart(id: tc.id, name: tc.name, arguments: argsDict)
                        )

                        let result: String
                        if let tool = self.toolRegistry.get(name: tc.name) {
                            do {
                                result = try await tool.execute(arguments: argsDict)
                                WeSeeLog.info("AgentRunner tool result: name=\(tc.name) resultLen=\(result.count)")
                            } catch {
                                result = "Tool execution error: \(error.localizedDescription)"
                                WeSeeLog.error("AgentRunner tool error: name=\(tc.name) error=\(error.localizedDescription)")
                            }
                        } else {
                            result = "Error: unknown tool '\(tc.name)'"
                            WeSeeLog.error("AgentRunner unknown tool: \(tc.name)")
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

                        toolResultMessages.append([
                            "role": "tool",
                            "tool_call_id": tc.id,
                            "content": result,
                        ])
                    }

                    // Assistant tool_calls message MUST come before tool result messages
                    messages.append([
                        "role": "assistant",
                        "content": NSNull(),
                        "tool_calls": toolCallDicts,
                    ])
                    messages.append(contentsOf: toolResultMessages)

                    WeSeeLog.info("AgentRunner round \(round) complete, messages=\(messages.count), looping back")
                if round >= self.maxRounds / 2 {
                    WeSeeLog.error("AgentRunner WARNING: round \(round)/\(self.maxRounds) — possible infinite loop, messages count: \(messages.count)")
                }
                }

                WeSeeLog.error("AgentRunner max rounds reached: \(self.maxRounds)")
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
