import Foundation
import Testing
@testable import WeSee

struct ChatViewModelTests {

    private func makeViewModel() -> ChatViewModel {
        let wsClient = WebSocketClient()
        let wm = WorkspaceManager()
        return ChatViewModel(
            wsClient: wsClient,
            workspaceManager: wm
        )
    }

    @Test func clearErrorSetsErrorMessageToNil() {
        let viewModel = makeViewModel()
        viewModel.errorMessage = "test error"
        viewModel.clearError()
        #expect(viewModel.errorMessage == nil)
    }

    @Test func newConversationClearsMessages() {
        let viewModel = makeViewModel()
        viewModel.messages = [Message(content: "old", isFromMe: true)]
        viewModel.isStreaming = true
        viewModel.streamingContent = "partial"
        viewModel.thinkingContent = "thinking..."
        viewModel.toolCallResults = [
            (id: "1", name: "echo", arguments: [:], result: nil),
        ]
        viewModel.newConversation()
        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.isStreaming == false)
        #expect(viewModel.streamingContent == "")
        #expect(viewModel.thinkingContent == "")
        #expect(viewModel.toolCallResults.isEmpty)
    }

    @Test func sendMessageAddsUserMessage() {
        let viewModel = makeViewModel()
        viewModel.sendMessage("hello")
        #expect(viewModel.messages.count == 1)
        #expect(viewModel.messages.first?.content == "hello")
        #expect(viewModel.messages.first?.isFromMe == true)
    }

    @Test func sendMessageSetsStreamingState() {
        let viewModel = makeViewModel()
        viewModel.sendMessage("test")
        #expect(viewModel.isStreaming == true)
        #expect(viewModel.isSendingDisabled == true)
        #expect(viewModel.streamingContent == "")
        #expect(viewModel.thinkingContent == "")
        #expect(viewModel.toolCallResults.isEmpty)
    }

    @Test func sendMessageTrimsContent() {
        let viewModel = makeViewModel()
        viewModel.sendMessage("  trimmed  ")
        #expect(viewModel.messages.first?.content == "trimmed")
    }

    @Test func sendMessageRejectsEmptyContent() {
        let viewModel = makeViewModel()
        viewModel.sendMessage("   ")
        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.isStreaming == false)
    }

    @Test func sendMessageRejectsOverlyLongContent() {
        let viewModel = makeViewModel()
        let long = String(repeating: "x", count: 5001)
        viewModel.sendMessage(long)
        #expect(viewModel.messages.isEmpty)
    }
}
