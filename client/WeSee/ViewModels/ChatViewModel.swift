// client/WeSee/ViewModels/ChatViewModel.swift
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

    private let wsClient: WebSocketClient
    private let workspaceManager: WorkspaceManager
    private var modelContext: ModelContext?
    private var pendingImagePaths: [String] = []

    init(wsClient: WebSocketClient, workspaceManager: WorkspaceManager) {
        self.wsClient = wsClient
        self.workspaceManager = workspaceManager
    }

    func connect(serverURL: URL) async {
        await wsClient.connect(url: serverURL)
        await wsClient.listen { [weak self] event in
            Task { @MainActor in self?.handleServerEvent(event) }
        }
        await wsClient.send(ClientMessage(
            type: .updateWorkspace,
            path: workspaceManager.currentURL.path
        ))
    }

    func configure(with context: ModelContext) {
        self.modelContext = context
    }

    func fetchMessages() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<Message>(sortBy: [SortDescriptor(\.timestamp)])
        messages = (try? context.fetch(descriptor)) ?? []
    }

    func newConversation() {
        messages = []
        streamingContent = ""
        thinkingContent = ""
        isStreaming = false
        toolCallResults = []
        pendingImagePaths = []
        Task { await wsClient.send(ClientMessage(type: .newConversation)) }
    }

    func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 5000 else { return }

        addMessage(content: trimmed, isFromMe: true)
        isSendingDisabled = true
        isStreaming = true
        streamingContent = ""
        thinkingContent = ""
        toolCallResults = []
        pendingImagePaths = []

        Task {
            await wsClient.send(ClientMessage(type: .chat, content: trimmed))
        }
    }

    func clearError() {
        errorMessage = nil
    }

    // MARK: - Server event handling

    private func handleServerEvent(_ event: ServerEvent) {
        switch event.type {
        case .token:
            streamingContent += event.data ?? ""
        case .thinking:
            thinkingContent += event.data ?? ""
        case .toolCall:
            if let id = event.id, let name = event.name {
                let args = event.arguments?.mapValues { $0.value } ?? [:]
                toolCallResults.append((id: id, name: name, arguments: args, result: nil))
            }
        case .done:
            let finalContent = streamingContent
            let thinking = thinkingContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !finalContent.isEmpty {
                addMessage(
                    content: finalContent,
                    thinkingContent: thinking.isEmpty ? nil : thinking,
                    attachmentPaths: pendingImagePaths,
                    isFromMe: false
                )
            }
            streamingContent = ""
            thinkingContent = ""
            toolCallResults = []
            pendingImagePaths = []
            isStreaming = false
            isSendingDisabled = false
        case .error:
            errorMessage = event.data ?? "Unknown error"
            streamingContent = ""
            thinkingContent = ""
            isStreaming = false
            isSendingDisabled = false
        }
    }

    private func addMessage(
        content: String,
        thinkingContent: String? = nil,
        attachmentPaths: [String] = [],
        isFromMe: Bool
    ) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 5000 else { return }
        let msg = Message(
            content: trimmed,
            thinkingContent: thinkingContent,
            attachmentPaths: attachmentPaths,
            isFromMe: isFromMe
        )
        messages.append(msg)
        guard let context = modelContext else { return }
        context.insert(msg)
        try? context.save()
    }
}
