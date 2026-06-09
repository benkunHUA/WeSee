import Foundation

final class LiveRemoteClient: RemoteClient {
    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(baseURL: URL = URL(string: "http://127.0.0.1:8023")!) {
        self.baseURL = baseURL
        self.session = URLSession.shared
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        self.encoder = JSONEncoder()
    }

    // MARK: - Conversations

    func fetchConversations() async throws -> [ConversationDTO] {
        let url = baseURL.appending(path: "api/conversations")
        let (data, _) = try await session.data(from: url)
        return try decoder.decode([ConversationDTO].self, from: data)
    }

    // MARK: - Chat (SSE)

    func sendMessage(_ content: String, conversationId: String?) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let url = baseURL.appending(path: "api/chat")
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    let body = ChatRequest(content: content, conversationId: conversationId)
                    request.httpBody = try encoder.encode(body)

                    let (bytes, _) = try await session.bytes(for: request)
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonStr = String(line.dropFirst(6))
                        guard let jsonData = jsonStr.data(using: .utf8),
                              let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                              let type = dict["type"] as? String
                        else { continue }

                        switch type {
                        case "token":
                            let token = dict["data"] as? String ?? ""
                            continuation.yield(.token(token))
                        case "done":
                            continuation.yield(.done)
                            continuation.finish()
                            return
                        case "error":
                            let msg = dict["data"] as? String ?? "Unknown error"
                            continuation.yield(.error(msg))
                            continuation.finish()
                            return
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Messages

    func fetchMessages(conversationId: String, tagId: String?) async throws -> [MessageDTO] {
        var components = URLComponents(url: baseURL.appending(path: "api/messages"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "conversationId", value: conversationId)]
        if let tagId {
            components.queryItems?.append(URLQueryItem(name: "tagId", value: tagId))
        }
        let (data, _) = try await session.data(from: components.url!)
        return try decoder.decode([MessageDTO].self, from: data)
    }

    func toggleBookmark(_ messageId: String) async throws -> MessageDTO {
        let url = baseURL.appending(path: "api/messages/\(messageId)/bookmark")
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        let (data, _) = try await session.data(for: request)
        return try decoder.decode(MessageDTO.self, from: data)
    }

    // MARK: - Tags

    func createTag(name: String, colorHex: String) async throws -> TagDTO {
        let url = baseURL.appending(path: "api/tags")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(CreateTagRequest(name: name, colorHex: colorHex))
        let (data, _) = try await session.data(for: request)
        return try decoder.decode(TagDTO.self, from: data)
    }

    func fetchTags() async throws -> [TagDTO] {
        let url = baseURL.appending(path: "api/tags")
        let (data, _) = try await session.data(from: url)
        return try decoder.decode([TagDTO].self, from: data)
    }

    // MARK: - Tasks

    func fetchTasks() async throws -> [TaskDTO] {
        let url = baseURL.appending(path: "api/tasks")
        let (data, _) = try await session.data(from: url)
        return try decoder.decode([TaskDTO].self, from: data)
    }

    func createTask(type: String, title: String, cronExpression: String) async throws -> TaskDTO {
        let url = baseURL.appending(path: "api/tasks")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(CreateTaskRequest(type: type, title: title, cronExpression: cronExpression))
        let (data, _) = try await session.data(for: request)
        return try decoder.decode(TaskDTO.self, from: data)
    }

    func toggleTask(_ id: String) async throws -> TaskDTO {
        let url = baseURL.appending(path: "api/tasks/\(id)/toggle")
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        let (data, _) = try await session.data(for: request)
        return try decoder.decode(TaskDTO.self, from: data)
    }
}
