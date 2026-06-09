import Foundation
import Observation
import SwiftData

@Observable
final class ChatViewModel {
    var messages: [Message] = []
    var selectedTag: Tag?
    var isSendingDisabled: Bool = false
    var errorMessage: String?
    var streamingContent: String = ""
    var isStreaming: Bool = false

    private var modelContext: ModelContext?
    private let deepSeekService: DeepSeekService

    init(deepSeekService: DeepSeekService = DeepSeekService()) {
        self.deepSeekService = deepSeekService
    }

    func configure(with context: ModelContext) {
        self.modelContext = context
    }

    // MARK: - Messages

    func fetchMessages() {
        guard let context = modelContext else { return }
        var descriptor = FetchDescriptor<Message>(sortBy: [SortDescriptor(\.timestamp)])
        do {
            let fetched = try context.fetch(descriptor)
            if let tag = selectedTag {
                messages = fetched.filter { $0.tags.contains(where: { $0.id == tag.id }) }
            } else {
                messages = fetched
            }
        } catch {
            errorMessage = "加载消息失败"
        }
    }

    func addMessage(content: String, isFromMe: Bool, tags: [Tag] = []) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 5000 else { return }

        let msg = Message(content: trimmed, isFromMe: isFromMe, tags: tags)
        messages.append(msg)

        guard let context = modelContext else { return }
        context.insert(msg)
        try? context.save()
    }

    func newConversation() {
        messages = []
        selectedTag = nil
        streamingContent = ""
        isStreaming = false
    }

    // MARK: - Send with streaming

    func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 5000 else { return }

        addMessage(content: trimmed, isFromMe: true)
        isSendingDisabled = true
        isStreaming = true
        streamingContent = ""

        Task {
            let config: ClientConfig
            do {
                config = try ConfigLoader.load()
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isStreaming = false
                    self.isSendingDisabled = false
                }
                return
            }

            do {
                for try await event in deepSeekService.streamChat(
                    history: messages,
                    config: config
                ) {
                    await MainActor.run {
                        switch event {
                        case .token(let token):
                            self.streamingContent += token
                        case .done:
                            self.addMessage(content: self.streamingContent, isFromMe: false)
                            self.streamingContent = ""
                            self.isStreaming = false
                            self.isSendingDisabled = false
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
