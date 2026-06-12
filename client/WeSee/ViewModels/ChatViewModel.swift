import Foundation
import Observation
import SwiftData

@Observable
final class ChatViewModel {
    var messages: [Message] = []
    var isSendingDisabled: Bool = false
    var errorMessage: String?
    var streamingContent: String = ""
    var thinkingContent: String = ""
    var isStreaming: Bool = false
    var toolCallResults: [(id: String, name: String, arguments: [String: Any], result: String?)] = []

    private let session: ChatSessionProtocol

    init(session: ChatSessionProtocol) {
        self.session = session
    }

    func configure(with context: ModelContext) {
        session.configure(with: context)
    }

    func fetchMessages() {
        session.fetchMessages()
        syncState()
    }

    func newConversation() {
        session.newConversation()
        syncState()
    }

    func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 5000 else { return }

        isSendingDisabled = true

        Task {
            await session.send(text)
            await MainActor.run {
                syncState()
                isSendingDisabled = false
            }
        }
    }

    func clearError() {
        errorMessage = nil
        session.clearError()
    }

    private func syncState() {
        messages = session.messages
        streamingContent = session.streamingContent
        thinkingContent = session.thinkingContent
        isStreaming = session.isStreaming
        toolCallResults = session.toolCallResults
    }
}
