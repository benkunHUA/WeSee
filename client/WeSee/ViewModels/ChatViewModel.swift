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
    private var pendingImagePaths: [String] = []

    private var modelContext: ModelContext?
    private let agentRunner: AgentRunner
    private let systemPromptBuilder: SystemPromptBuilder

    init(workspaceManager: WorkspaceManager) {
        self.systemPromptBuilder = SystemPromptBuilder(workspaceManager: workspaceManager)
        self.agentRunner = AgentRunner(workspaceManager: workspaceManager)
    }

    func configure(with context: ModelContext) {
        self.modelContext = context
        WeSeeLog.info("ChatViewModel configured with ModelContext")
    }

    func fetchMessages() {
        guard let context = modelContext else {
            WeSeeLog.error("ChatViewModel.fetchMessages: modelContext is nil")
            return
        }
        let descriptor = FetchDescriptor<Message>(sortBy: [SortDescriptor(\.timestamp)])
        do {
            messages = try context.fetch(descriptor)
            WeSeeLog.info("ChatViewModel fetched \(messages.count) messages")
        } catch {
            errorMessage = "加载消息失败"
            WeSeeLog.error("ChatViewModel fetchMessages error: \(error.localizedDescription)")
        }
    }

    func addMessage(
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
        do {
            try context.save()
        } catch {
            WeSeeLog.error("ChatViewModel.addMessage save error: \(error.localizedDescription)")
        }
    }

    func newConversation() {
        messages = []
        streamingContent = ""
        thinkingContent = ""
        isStreaming = false
        toolCallResults = []
        pendingImagePaths = []
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

        WeSeeLog.info("ChatViewModel sending message, history count: \(messages.count)")

        Task {
            let config: ClientConfig
            do {
                config = try ConfigLoader.load()
                WeSeeLog.info("ChatViewModel config loaded: model=\(config.model) baseURL=\(config.baseURL)")
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isStreaming = false
                    self.isSendingDisabled = false
                    WeSeeLog.error("ChatViewModel config load error: \(error.localizedDescription)")
                }
                return
            }

            do {
                for try await event in agentRunner.run(
                    history: messages,
                    config: config,
                    systemPrompt: systemPromptBuilder.build()
                ) {
                    await MainActor.run {
                        switch event {
                        case .token(let token):
                            self.streamingContent += token
                        case .thinking(let text):
                            self.thinkingContent += text
                        case .toolCallStart(let id, let name, let arguments):
                            WeSeeLog.info("ChatViewModel toolCallStart: id=\(id) name=\(name)")
                            self.toolCallResults.append(
                                (id: id, name: name, arguments: arguments, result: nil)
                            )
                        case .toolCallResult(let id, let name, let result):
                            WeSeeLog.info("ChatViewModel toolCallResult: id=\(id) name=\(name)")
                            if let index = self.toolCallResults.firstIndex(where: { $0.id == id }) {
                                self.toolCallResults[index].result = result
                            }
                            if name == "screenshot" && FileManager.default.fileExists(atPath: result) {
                                self.pendingImagePaths.append(result)
                            }
                        case .done:
                            WeSeeLog.info("ChatViewModel done, finalLen=\(self.streamingContent.count) thinkingLen=\(self.thinkingContent.count) images=\(self.pendingImagePaths.count)")
                            let finalContent = self.streamingContent
                            let thinking = self.thinkingContent.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !finalContent.isEmpty {
                                self.addMessage(
                                    content: finalContent,
                                    thinkingContent: thinking.isEmpty ? nil : thinking,
                                    attachmentPaths: self.pendingImagePaths,
                                    isFromMe: false
                                )
                            }
                            self.streamingContent = ""
                            self.thinkingContent = ""
                            self.toolCallResults = []
                            self.pendingImagePaths = []
                            self.isStreaming = false
                            self.isSendingDisabled = false
                        case .error(let msg):
                            WeSeeLog.error("ChatViewModel error: \(msg)")
                            self.errorMessage = msg
                            self.isStreaming = false
                            self.thinkingContent = ""
                            self.toolCallResults = []
                            self.pendingImagePaths = []
                            self.isSendingDisabled = false
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    WeSeeLog.error("ChatViewModel outer error: \(error.localizedDescription)")
                    self.errorMessage = error.localizedDescription
                    self.isStreaming = false
                    self.thinkingContent = ""
                    self.toolCallResults = []
                    self.pendingImagePaths = []
                    self.isSendingDisabled = false
                }
            }
        }
    }

    func clearError() {
        errorMessage = nil
    }
}
