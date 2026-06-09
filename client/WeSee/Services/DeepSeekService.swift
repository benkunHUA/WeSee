import Foundation

enum ChatEvent {
    case token(String)
    case done
    case error(String)
}

final class DeepSeekService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func streamChat(
        history: [Message],
        config: ClientConfig
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let request = buildRequest(history: history, config: config)
                    let (bytes, _) = try await session.bytes(for: request)
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonStr = String(line.dropFirst(6))
                        guard jsonStr != "[DONE]" else {
                            continuation.yield(.done)
                            continuation.finish()
                            return
                        }
                        if let delta = parseDelta(jsonStr) {
                            continuation.yield(.token(delta))
                        }
                        if let finishReason = parseFinishReason(jsonStr), finishReason == "stop" {
                            continuation.yield(.done)
                            continuation.finish()
                            return
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.yield(.error(error.localizedDescription))
                    continuation.finish()
                }
            }
        }
    }

    func buildRequest(history: [Message], config: ClientConfig) -> URLRequest {
        let url = URL(string: config.baseURL + "/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        let messages = history.map { msg -> [String: String] in
            ["role": msg.isFromMe ? "user" : "assistant", "content": msg.content]
        }

        let body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "stream": true,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    func parseDelta(_ jsonStr: String) -> String? {
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any],
              let content = delta["content"] as? String
        else { return nil }
        return content
    }

    func parseFinishReason(_ jsonStr: String) -> String? {
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let finishReason = first["finish_reason"] as? String
        else { return nil }
        return finishReason
    }
}
