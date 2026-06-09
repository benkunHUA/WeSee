import Foundation
import Observation
import SwiftData

@Observable
final class ChatViewModel {
    var messages: [Message] = []
    var isSendingDisabled: Bool = false
    var errorMessage: String?
    var streamingContent: String = ""
    var isStreaming: Bool = false
    var toolCallResults: [(id: String, name: String, arguments: [String: Any], result: String?)] = []

    private var modelContext: ModelContext?
    private let agentRunner: AgentRunner

    init(agentRunner: AgentRunner = AgentRunner()) {
        self.agentRunner = agentRunner
    }

    func configure(with context: ModelContext) {
        self.modelContext = context
    }

    func fetchMessages() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<Message>(sortBy: [SortDescriptor(\.timestamp)])
        do {
            messages = try context.fetch(descriptor)
        } catch {
            errorMessage = "加载消息失败"
        }
    }

    func addMessage(content: String, isFromMe: Bool) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 5000 else { return }

        let msg = Message(content: trimmed, isFromMe: isFromMe)
        messages.append(msg)

        guard let context = modelContext else { return }
        context.insert(msg)
        try? context.save()
    }

    func newConversation() {
        messages = []
        streamingContent = ""
        isStreaming = false
        toolCallResults = []
    }

    func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 5000 else { return }

        addMessage(content: trimmed, isFromMe: true)
        isSendingDisabled = true
        isStreaming = true
        streamingContent = ""
        toolCallResults = []

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
                for try await event in agentRunner.run(
                    history: messages,
                    config: config
                ) {
                    await MainActor.run {
                        switch event {
                        case .token(let token):
                            self.streamingContent += token
                        case .thinking(let text):
                            self.streamingContent += text
                        case .toolCallStart(let id, let name, let arguments):
                            self.toolCallResults.append(
                                (id: id, name: name, arguments: arguments, result: nil)
                            )
                        case .toolCallResult(let id, let name, let result):
                            if let index = self.toolCallResults.firstIndex(where: { $0.id == id }) {
                                self.toolCallResults[index].result = result
                            }
                        case .done:
                            let finalContent = self.streamingContent
                            if !finalContent.isEmpty {
                                self.addMessage(content: finalContent, isFromMe: false)
                            }
                            self.streamingContent = ""
                            self.toolCallResults = []
                            self.isStreaming = false
                            self.isSendingDisabled = false
                        case .error(let msg):
                            self.errorMessage = msg
                            self.isStreaming = false
                            self.toolCallResults = []
                            self.isSendingDisabled = false
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isStreaming = false
                    self.toolCallResults = []
                    self.isSendingDisabled = false
                }
            }
        }
    }

    func clearError() {
        errorMessage = nil
    }
}
