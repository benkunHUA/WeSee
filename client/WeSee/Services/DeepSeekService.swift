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
                    let (bytes, _) = try await self.session.bytes(for: request)
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonStr = String(line.dropFirst(6))
                        guard jsonStr != "[DONE]" else { continue }

                        if let delta = parseContentDelta(jsonStr) {
                            continuation.yield(.token(delta))
                        }
                        if let thinking = parseThinkingDelta(jsonStr) {
                            continuation.yield(.thinking(thinking))
                        }
                        if let tcDelta = parseToolCallDelta(jsonStr) {
                            continuation.yield(.toolCallDelta(tcDelta))
                        }
                        if let reason = parseFinishReason(jsonStr) {
                            continuation.yield(.finishReason(reason))
                            if reason == "stop" {
                                continuation.finish()
                                return
                            }
                        }
                    }
                    continuation.finish()
                } catch {
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
        let url = URL(string: config.baseURL + "/v1/chat/completions")!
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
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
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
