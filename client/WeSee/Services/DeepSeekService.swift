import Foundation

class DeepSeekService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func streamChat(
        messages: [[String: Any]],
        config: ClientConfig,
        tools: [[String: Any]] = [],
        systemPrompt: String? = nil
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let request = buildRequest(
                        messages: messages,
                        config: config,
                        tools: tools,
                        systemPrompt: systemPrompt
                    )

                    if let bodyData = request.httpBody, let bodyStr = String(data: bodyData, encoding: .utf8) {
                        WeSeeLog.info("LLM request body:\n\(bodyStr)")
                    }
                    WeSeeLog.info("LLM request: model=\(config.model) url=\(config.baseURL) messages=\(messages.count) tools=\(tools.count)")

                    let (bytes, response) = try await self.session.bytes(for: request)
                    if let httpResponse = response as? HTTPURLResponse {
                        WeSeeLog.info("LLM response status: \(httpResponse.statusCode)")
                        guard httpResponse.statusCode == 200 else {
                            var errorBody = ""
                            for try await line in bytes.lines.prefix(50) {
                                errorBody += line
                            }
                            WeSeeLog.error("LLM HTTP error: \(httpResponse.statusCode), body: \(errorBody)")
                            continuation.finish(
                                throwing: NSError(
                                    domain: "DeepSeekService",
                                    code: httpResponse.statusCode,
                                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode): \(errorBody)"]
                                )
                            )
                            return
                        }
                    }

                    var lineCount = 0
                    for try await line in bytes.lines {
                        lineCount += 1
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonStr = String(line.dropFirst(6))

                        guard jsonStr != "[DONE]" else {
                            WeSeeLog.debug("LLM stream [DONE], total lines: \(lineCount)")
                            continuation.finish()
                            return
                        }

                        if let delta = parseContentDelta(jsonStr) {
                            continuation.yield(.token(delta))
                        }
                        if let thinking = parseThinkingDelta(jsonStr) {
                            continuation.yield(.thinking(thinking))
                        }
                        if let tcDelta = parseToolCallDelta(jsonStr) {
                            WeSeeLog.debug("LLM tool call delta: index=\(tcDelta.index) name=\(tcDelta.name ?? "nil")")
                            continuation.yield(.toolCallDelta(tcDelta))
                        }
                        if let reason = parseFinishReason(jsonStr) {
                            WeSeeLog.info("LLM finish reason: \(reason)")
                            continuation.yield(.finishReason(reason))
                            if reason == "stop" {
                                continuation.finish()
                                return
                            }
                        }
                    }
                    WeSeeLog.info("LLM stream ended (EOF), total lines: \(lineCount)")
                    continuation.finish()
                } catch {
                    WeSeeLog.error("LLM stream error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func buildRequest(
        messages: [[String: Any]],
        config: ClientConfig,
        tools: [[String: Any]] = [],
        systemPrompt: String? = nil
    ) -> URLRequest {
        guard let url = URL(string: config.baseURL + "/v1/chat/completions") else {
            fatalError("Invalid baseURL in config: \(config.baseURL)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        var allMessages: [[String: Any]] = []
        if let systemPrompt {
            allMessages.append(["role": "system", "content": systemPrompt])
        }
        allMessages.append(contentsOf: messages)

        var body: [String: Any] = [
            "model": config.model,
            "messages": allMessages,
            "stream": true,
        ]
        if !tools.isEmpty {
            body["tools"] = tools
            WeSeeLog.debug("LLM request includes \(tools.count) tools")
        }
        if let httpBody = try? JSONSerialization.data(withJSONObject: body) {
            request.httpBody = httpBody
            WeSeeLog.debug("LLM request body size: \(httpBody.count) bytes")
        } else {
            WeSeeLog.error("LLM request body JSON serialization failed")
        }
        return request
    }

    func parseContentDelta(_ jsonStr: String) -> String? {
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any],
              let content = delta["content"] as? String
        else { return nil }
        return content
    }

    func parseThinkingDelta(_ jsonStr: String) -> String? {
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any],
              let thinking = delta["reasoning_content"] as? String
        else { return nil }
        return thinking
    }

    func parseToolCallDelta(_ jsonStr: String) -> ToolCallDelta? {
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any],
              let toolCalls = delta["tool_calls"] as? [[String: Any]],
              let tc = toolCalls.first
        else { return nil }

        let index = tc["index"] as? Int ?? 0
        let id = tc["id"] as? String
        let function = tc["function"] as? [String: Any]
        let name = function?["name"] as? String
        let arguments = function?["arguments"] as? String ?? ""

        return ToolCallDelta(index: index, id: id, name: name, arguments: arguments)
    }

    func parseFinishReason(_ jsonStr: String) -> String? {
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let reason = first["finish_reason"] as? String
        else { return nil }
        return reason
    }
}
