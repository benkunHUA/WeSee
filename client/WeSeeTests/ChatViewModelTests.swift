import Foundation
import Testing
@testable import WeSee

struct ChatViewModelTests {

    private func makeViewModel() -> ChatViewModel {
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-cvm-config-\(UUID().uuidString).json")
        let wm = WorkspaceManager(configURL: configURL)
        return ChatViewModel(workspaceManager: wm)
    }

    @Test func addMessageAppendsToMessages() {
        let viewModel = makeViewModel()
        viewModel.addMessage(content: "Hello", isFromMe: true)
        #expect(viewModel.messages.count == 1)
        #expect(viewModel.messages.first?.content == "Hello")
    }

    @Test func addEmptyMessageIsIgnored() {
        let viewModel = makeViewModel()
        viewModel.addMessage(content: "", isFromMe: true)
        viewModel.addMessage(content: "   ", isFromMe: true)
        #expect(viewModel.messages.isEmpty)
    }

    @Test func addWhitespaceOnlyMessageIsIgnored() {
        let viewModel = makeViewModel()
        viewModel.addMessage(content: "\n\n", isFromMe: true)
        #expect(viewModel.messages.isEmpty)
    }

    @Test func isSendingDisabledBlocksRapidSend() {
        let viewModel = makeViewModel()
        viewModel.sendMessage("msg1")
        #expect(viewModel.isSendingDisabled == true)
    }

    @Test func clearErrorSetsErrorMessageToNil() {
        let viewModel = makeViewModel()
        viewModel.errorMessage = "test error"
        viewModel.clearError()
        #expect(viewModel.errorMessage == nil)
    }

    @Test func sendMessageSetsStreamingContent() {
        let viewModel = makeViewModel()
        viewModel.sendMessage("Hello")
        #expect(viewModel.isStreaming == true)
        #expect(viewModel.streamingContent == "")
    }

    @Test func sendMessageAppendsUserMessage() {
        let viewModel = makeViewModel()
        viewModel.sendMessage("Hello")
        #expect(viewModel.messages.count == 1)
        #expect(viewModel.messages.first?.isFromMe == true)
        #expect(viewModel.messages.first?.content == "Hello")
    }

    @Test func newConversationClearsMessages() {
        let viewModel = makeViewModel()
        viewModel.addMessage(content: "msg1", isFromMe: true)
        viewModel.addMessage(content: "msg2", isFromMe: false)
        viewModel.newConversation()
        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.isStreaming == false)
    }

    @Test func newConversationClearsToolCallResults() {
        let viewModel = makeViewModel()
        viewModel.toolCallResults = [
            (id: "1", name: "echo", arguments: [:], result: nil),
        ]
        viewModel.newConversation()
        #expect(viewModel.toolCallResults.isEmpty)
    }
}
