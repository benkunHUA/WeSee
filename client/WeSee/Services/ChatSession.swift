import Foundation
import SwiftData

// MARK: - Protocol

protocol ChatSessionProtocol: AnyObject {
    var messages: [Message] { get }
    var streamingContent: String { get }
    var thinkingContent: String { get }
    var isStreaming: Bool { get }
    var toolCallResults: [(id: String, name: String, arguments: [String: Any], result: String?)] { get }

    func send(_ text: String) async
    func newConversation()
    func configure(with modelContext: ModelContext)
    func fetchMessages()
    var eventStream: AsyncStream<SessionEvent> { get }
    func clearError()
}

// MARK: - Implementation

@MainActor
final class ChatSessionImpl: ChatSessionProtocol {
    private(set) var messages: [Message] = []
    private(set) var streamingContent: String = ""
    private(set) var thinkingContent: String = ""
    private(set) var isStreaming: Bool = false
    private(set) var toolCallResults: [(id: String, name: String, arguments: [String: Any], result: String?)] = []

    private var modelContext: ModelContext?
    private let agentRunner: AgentRunner
    let workspaceManager: WorkspaceManager
    private let systemPromptBuilder: SystemPromptBuilder
    private var pendingImagePaths: [String] = []
    private var eventContinuation: AsyncStream<SessionEvent>.Continuation?
    private(set) lazy var eventStream: AsyncStream<SessionEvent> = {
        AsyncStream { continuation in
            self.eventContinuation = continuation
        }
    }()

    init(
        agentRunner: AgentRunner,
        workspaceManager: WorkspaceManager,
        systemPromptBuilder: SystemPromptBuilder
    ) {
        self.agentRunner = agentRunner
        self.workspaceManager = workspaceManager
        self.systemPromptBuilder = systemPromptBuilder
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
        streamingContent = ""
        thinkingContent = ""
        isStreaming = false
        toolCallResults = []
        pendingImagePaths = []
    }

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 5000 else { return }

        addMessage(content: trimmed, isFromMe: true)
        isStreaming = true
        streamingContent = ""
        thinkingContent = ""
        toolCallResults = []
        pendingImagePaths = []

        let config: ClientConfig
        do {
            config = try ConfigLoader.load()
        } catch {
            streamingContent = ""
            isStreaming = false
            return
        }

        do {
            for try await event in agentRunner.run(
                history: messages,
                config: config,
                systemPrompt: systemPromptBuilder.build()
            ) {
                switch event {
                case .token(let token):
                    streamingContent += token
                    eventContinuation?.yield(.token(token))
                case .thinking(let text):
                    thinkingContent += text
                    eventContinuation?.yield(.thinking(text))
                case .toolCallStart(let id, let name, let arguments):
                    toolCallResults.append(
                        (id: id, name: name, arguments: arguments, result: nil)
                    )
                    eventContinuation?.yield(.toolCallStart(id: id, name: name, arguments: arguments))
                case .toolCallResult(let id, let name, let result):
                    if let index = toolCallResults.firstIndex(where: { $0.id == id }) {
                        toolCallResults[index].result = result
                    }
                    if name == "screenshot" && FileManager.default.fileExists(atPath: result) {
                        pendingImagePaths.append(result)
                    }
                    eventContinuation?.yield(.toolCallResult(id: id, name: name, result: result))
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
                    eventContinuation?.yield(.done)
                case .error(let msg):
                    streamingContent = ""
                    thinkingContent = ""
                    toolCallResults = []
                    pendingImagePaths = []
                    isStreaming = false
                    eventContinuation?.yield(.error(msg))
                }
            }
        } catch {
            streamingContent = ""
            thinkingContent = ""
            toolCallResults = []
            pendingImagePaths = []
            isStreaming = false
        }
    }

    func clearError() {}

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
