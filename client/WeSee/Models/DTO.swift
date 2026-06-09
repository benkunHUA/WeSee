import Foundation

struct MessageDTO: Codable, Identifiable {
    let id: String
    let content: String
    let timestamp: Date
    let isFromMe: Bool
    let isBookmarked: Bool
    let tags: [TagDTO]
}

struct TagDTO: Codable, Identifiable {
    let id: String
    let name: String
    let colorHex: String
}

struct ConversationDTO: Codable, Identifiable {
    let id: String
    let title: String
    let createdAt: Date
}

struct TaskDTO: Codable, Identifiable {
    let id: String
    let type: String
    let title: String
    let cronExpression: String
    let isEnabled: Bool
    let nextFireDate: Date?
}

struct CreateTagRequest: Encodable {
    let name: String
    let colorHex: String
}

struct CreateTaskRequest: Encodable {
    let type: String
    let title: String
    let cronExpression: String
}

struct ChatRequest: Encodable {
    let content: String
    let conversationId: String?
}

enum ChatEvent {
    case start(conversationId: String)
    case token(String)
    case done
    case error(String)
}
