import Foundation
import Observation
import SwiftData

@Observable
final class ChatViewModel {
    var messages: [Message] = []
    var conversations: [ConversationDTO] = []
    var selectedTag: Tag?
    var isSendingDisabled: Bool = false
    var errorMessage: String?
    var streamingContent: String = ""
    var isStreaming: Bool = false
    var conversationId: String?

    private var modelContext: ModelContext?
    private let remoteClient: RemoteClient

    init(remoteClient: RemoteClient = NoOpRemoteClient()) {
        self.remoteClient = remoteClient
    }

    func configure(with context: ModelContext) {
        self.modelContext = context
        fetchMessages()
        Task { await loadConversations() }
    }

    // MARK: - Conversations

    func loadConversations() async {
        do {
            conversations = try await remoteClient.fetchConversations()
            if conversationId == nil, let first = conversations.first {
                conversationId = first.id
                fetchMessages()
            }
        } catch {
            errorMessage = "加载对话列表失败"
        }
    }

    func selectConversation(_ id: String) {
        conversationId = id
        fetchMessages()
    }

    // MARK: - Messages

    func fetchMessages() {
        guard let context = modelContext else { return }
        var descriptor = FetchDescriptor<Message>(sortBy: [SortDescriptor(\.timestamp)])
        if let tag = selectedTag {
            descriptor.predicate = #Predicate { $0.tags.contains(where: { $0.id == tag.id }) }
        }
        do {
            messages = try context.fetch(descriptor)
        } catch {
            errorMessage = "加载消息失败"
        }
    }

    func addMessage(content: String, isFromMe: Bool, tags: [Tag] = []) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 5000 else { return }

        guard let context = modelContext else {
            let msg = Message(content: trimmed, isFromMe: isFromMe, tags: tags)
            messages.append(msg)
            return
        }

        let msg = Message(content: trimmed, isFromMe: isFromMe, tags: tags)
        context.insert(msg)
        try? context.save()
        fetchMessages()
    }

    // MARK: - Send with streaming

    func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 5000 else { return }

        // Add user message locally
        addMessage(content: trimmed, isFromMe: true)
        isSendingDisabled = true
        isStreaming = true
        streamingContent = ""

        Task {
            do {
                for try await event in remoteClient.sendMessage(
                    content: trimmed,
                    conversationId: conversationId
                ) {
                    await MainActor.run {
                        switch event {
                        case .start(let cid):
                            self.conversationId = cid
                        case .token(let token):
                            self.streamingContent += token
                        case .done:
                            self.addMessage(content: self.streamingContent, isFromMe: false)
                            self.streamingContent = ""
                            self.isStreaming = false
                            self.isSendingDisabled = false
                            Task { await self.loadConversations() }
                        case .error(let msg):
                            self.errorMessage = msg
                            self.isStreaming = false
                            self.isSendingDisabled = false
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isStreaming = false
                    self.isSendingDisabled = false
                }
            }
        }
    }

    func toggleBookmark(_ message: Message) {
        guard let context = modelContext else { return }
        message.isBookmarked.toggle()
        try? context.save()
        fetchMessages()
    }

    func filterByTag(_ tag: Tag?) {
        selectedTag = tag
        fetchMessages()
    }

    func clearError() {
        errorMessage = nil
    }
}
