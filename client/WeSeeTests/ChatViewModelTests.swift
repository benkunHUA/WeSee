import Foundation
import Testing
import SwiftData
@testable import WeSee

final class MockSession: ChatSessionProtocol {
    var messages: [Message] = []
    var streamingContent: String = ""
    var thinkingContent: String = ""
    var isStreaming: Bool = false
    var toolCallResults: [(id: String, name: String, arguments: [String: Any], result: String?)] = []
    var eventStream: AsyncStream<SessionEvent> {
        AsyncStream { $0.finish() }
    }

    var sendCalled = false
    var sendText: String?

    func send(_ text: String) async {
        sendCalled = true
        sendText = text
    }

    func newConversation() {
        messages = []
        toolCallResults = []
        isStreaming = false
        streamingContent = ""
        thinkingContent = ""
    }

    func configure(with modelContext: ModelContext) {}
    func fetchMessages() {}
    func clearError() {}
}

struct ChatViewModelTests {

    private func makeViewModel() -> (ChatViewModel, MockSession) {
        let session = MockSession()
        let vm = ChatViewModel(session: session)
        return (vm, session)
    }

    @Test func isSendingDisabledBlocksRapidSend() async {
        let (viewModel, session) = makeViewModel()
        session.messages = [Message(content: "reply", isFromMe: false)]
        viewModel.sendMessage("msg1")
        #expect(viewModel.isSendingDisabled == true)
    }

    @Test func clearErrorSetsErrorMessageToNil() {
        let (viewModel, _) = makeViewModel()
        viewModel.errorMessage = "test error"
        viewModel.clearError()
        #expect(viewModel.errorMessage == nil)
    }

    @Test func sendMessageDelegatesToSession() {
        let (viewModel, session) = makeViewModel()
        viewModel.sendMessage("Hello")
        #expect(session.sendCalled == true)
        #expect(session.sendText == "Hello")
    }

    @Test func newConversationDelegatesToSession() {
        let (viewModel, session) = makeViewModel()
        session.messages = [Message(content: "msg1", isFromMe: true)]
        viewModel.newConversation()
        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.isStreaming == false)
    }

    @Test func newConversationClearsToolCallResults() {
        let (viewModel, _) = makeViewModel()
        viewModel.toolCallResults = [
            (id: "1", name: "echo", arguments: [:], result: nil),
        ]
        viewModel.newConversation()
        #expect(viewModel.toolCallResults.isEmpty)
    }

    @Test func syncStateCopiesSessionProperties() {
        let (viewModel, session) = makeViewModel()
        let msg = Message(content: "test", isFromMe: true)
        session.messages = [msg]
        session.streamingContent = "streaming..."
        session.isStreaming = true
        viewModel.fetchMessages()
        #expect(viewModel.messages.count == 1)
        #expect(viewModel.streamingContent == "streaming...")
        #expect(viewModel.isStreaming == true)
    }
}
