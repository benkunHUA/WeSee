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
    var toolCallResults: [(id: String, name: String, arguments: [String: JSONValue], result: String?)] = []

    private let wsClient: WebSocketClient
    private let workspaceManager: WorkspaceManager
    private let toolRegistry: ToolRegistry
    private var modelContext: ModelContext?
    private var pendingImagePaths: [String] = []

    init(wsClient: WebSocketClient, workspaceManager: WorkspaceManager) {
        self.wsClient = wsClient
        self.workspaceManager = workspaceManager
        let registry = ToolRegistry()
        registry.register(ShellTool(workspaceManager: workspaceManager))
        registry.register(FileSystemTool(workspaceManager: workspaceManager))
        registry.register(ScreenshotTool(workspaceManager: workspaceManager))
        self.toolRegistry = registry
    }

    func connect(serverURL: URL) {
        WeSeeLog.info("[ChatVM] Connecting to \(serverURL.absoluteString)")
        wsClient.listen { [weak self] event in
            Task { @MainActor in self?.handleServerEvent(event) }
        }
        wsClient.connect(url: serverURL)
        wsClient.send(ClientMessage(
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
        isSendingDisabled = false
        errorMessage = nil
        toolCallResults = []
        pendingImagePaths = []
        wsClient.send(ClientMessage(type: .newConversation))
    }

    func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 5000 else { return }

        WeSeeLog.info("[ChatVM] sendMessage: '\(trimmed.prefix(50))'")
        addMessage(content: trimmed, isFromMe: true)
        isSendingDisabled = true
        isStreaming = true
        streamingContent = ""
        thinkingContent = ""
        toolCallResults = []
        pendingImagePaths = []

        wsClient.send(ClientMessage(type: .chat, content: trimmed))
    }

    func clearError() {
        errorMessage = nil
    }

    // MARK: - Tool execution

    private func executeTool(callId: String, name: String, arguments: [String: JSONValue]) {
        guard let tool = toolRegistry.get(name: name) else {
            let errMsg = "Error: unknown tool '\(name)'"
            WeSeeLog.error("[ChatVM] \(errMsg)")
            wsClient.send(ClientMessage(type: .toolResult, id: callId, result: errMsg))
            return
        }
        let args = arguments.mapValues { $0.anyValue }
        Task { [weak self] in
            let result: String
            do {
                result = try await tool.execute(arguments: args)
            } catch {
                result = "Error: \(error.localizedDescription)"
            }
            WeSeeLog.info("[ChatVM] Tool executed: id=\(callId), result=\(result.prefix(100))")
            await MainActor.run {
                if let index = self?.toolCallResults.firstIndex(where: { $0.id == callId }) {
                    self?.toolCallResults[index].result = result
                }
                // Track screenshot paths for attachment display
                if name == "screenshot", result.hasSuffix(".png"),
                   FileManager.default.fileExists(atPath: result) {
                    self?.pendingImagePaths.append(result)
                }
            }
            self?.wsClient.send(ClientMessage(type: .toolResult, id: callId, result: result))
        }
    }

    // MARK: - Server event handling

    private func handleServerEvent(_ event: ServerEvent) {
        WeSeeLog.debug("[ChatVM] handleEvent: type=\(event.type.rawValue)")
        switch event.type {
        case .token:
            streamingContent += event.data ?? ""
        case .thinking:
            thinkingContent += event.data ?? ""
        case .toolCall:
            if let id = event.id, let name = event.name {
                let args = event.arguments ?? [:]
                WeSeeLog.info("[ChatVM] Tool call: id=\(id), name=\(name)")
                toolCallResults.append((id: id, name: name, arguments: args, result: nil))
                executeTool(callId: id, name: name, arguments: args)
            }
        case .toolResult:
            if let id = event.id, let result = event.data {
                WeSeeLog.info("[ChatVM] Tool result: id=\(id), result=\(result.prefix(50))")
                if let index = toolCallResults.firstIndex(where: { $0.id == id }) {
                    toolCallResults[index].result = result
                }
            }
        case .done:
            let finalContent = streamingContent
            WeSeeLog.info("[ChatVM] Done, content length: \(finalContent.count)")
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
            WeSeeLog.error("[ChatVM] Error from server: \(errorMessage ?? "nil")")
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
