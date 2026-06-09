import Foundation

protocol RemoteClient {
    func fetchConversations() async throws -> [ConversationDTO]
    func sendMessage(_ content: String, conversationId: String?) -> AsyncThrowingStream<ChatEvent, Error>
    func fetchMessages(conversationId: String, tagId: String?) async throws -> [MessageDTO]
    func toggleBookmark(_ messageId: String) async throws -> MessageDTO
    func createTag(name: String, colorHex: String) async throws -> TagDTO
    func fetchTags() async throws -> [TagDTO]
    func fetchTasks() async throws -> [TaskDTO]
    func createTask(type: String, title: String, cronExpression: String) async throws -> TaskDTO
    func toggleTask(_ id: String) async throws -> TaskDTO
}

final class NoOpRemoteClient: RemoteClient {
    func fetchConversations() async throws -> [ConversationDTO] { [] }
    func sendMessage(_ content: String, conversationId: String?) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func fetchMessages(conversationId: String, tagId: String?) async throws -> [MessageDTO] { [] }
    func toggleBookmark(_ messageId: String) async throws -> MessageDTO {
        MessageDTO(id: "", content: "", timestamp: Date(), isFromMe: false, isBookmarked: false, tags: [])
    }
    func createTag(name: String, colorHex: String) async throws -> TagDTO {
        TagDTO(id: "", name: "", colorHex: "")
    }
    func fetchTags() async throws -> [TagDTO] { [] }
    func fetchTasks() async throws -> [TaskDTO] { [] }
    func createTask(type: String, title: String, cronExpression: String) async throws -> TaskDTO {
        TaskDTO(id: "", type: "", title: "", cronExpression: "", isEnabled: false, nextFireDate: nil)
    }
    func toggleTask(_ id: String) async throws -> TaskDTO {
        TaskDTO(id: "", type: "", title: "", cronExpression: "", isEnabled: false, nextFireDate: nil)
    }
}
