// client/WeSee/Services/ChatSession.swift
import Foundation
import SwiftData

protocol ChatSessionProtocol: AnyObject {
    var messages: [Message] { get }
    func send(_ text: String, onEvent: @escaping (SessionEvent) -> Void) async
    func newConversation()
    func configure(with modelContext: ModelContext)
    func fetchMessages()
    func clearError()
}

@MainActor
final class ChatSessionImpl: ChatSessionProtocol {
    private(set) var messages: [Message] = []
    private var modelContext: ModelContext?
    let workspaceManager: WorkspaceManager
    private let wsClient: WebSocketClient

    init(wsClient: WebSocketClient, workspaceManager: WorkspaceManager) {
        self.wsClient = wsClient
        self.workspaceManager = workspaceManager
    }

    func configure(with modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func fetchMessages() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<Message>(sortBy: [SortDescriptor(\.timestamp)])
        messages = (try? context.fetch(descriptor)) ?? []
    }

    func newConversation() {
        messages = []
        wsClient.send(ClientMessage(type: .newConversation))
    }

    func send(_ text: String, onEvent: @escaping (SessionEvent) -> Void) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 5000 else { return }
        addMessage(content: trimmed, isFromMe: true)
        wsClient.send(ClientMessage(type: .chat, content: trimmed))
    }

    func clearError() {}

    private func addMessage(content: String, isFromMe: Bool) {
        let msg = Message(content: content, isFromMe: isFromMe)
        messages.append(msg)
        guard let context = modelContext else { return }
        context.insert(msg)
        try? context.save()
    }
}
