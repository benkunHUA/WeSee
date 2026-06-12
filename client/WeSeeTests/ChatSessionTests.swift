import XCTest
import SwiftData
@testable import WeSee

@MainActor
final class ChatSessionTests: XCTestCase {
    var session: ChatSessionImpl!
    var mockRunner: MockAgentRunner!

    override func setUp() {
        mockRunner = MockAgentRunner()
        session = ChatSessionImpl(
            agentRunner: mockRunner,
            workspaceManager: WorkspaceManager(),
            systemPromptBuilder: SystemPromptBuilder(workspaceManager: WorkspaceManager())
        )
    }

    func testNewConversation_clearsMessages() async {
        await session.send("hello")
        session.newConversation()
        XCTAssertTrue(session.messages.isEmpty)
        XCTAssertEqual(session.streamingContent, "")
        XCTAssertFalse(session.isStreaming)
    }

    func testSend_emptyMessage_doesNotSend() async {
        await session.send("   ")
        XCTAssertFalse(mockRunner.runCalled)
    }

    func testSend_longMessage_trimsTo5000() async {
        let long = String(repeating: "a", count: 5001)
        await session.send(long)
        XCTAssertFalse(mockRunner.runCalled)
    }

    func testSend_normalMessage_callsAgentRunner() async {
        mockRunner.events = [.token("Hi"), .done]
        await session.send("hello")
        XCTAssertTrue(mockRunner.runCalled)
        XCTAssertEqual(session.messages.last?.content, "Hi")
    }

    func testSend_streamingContent_updatesDuringStream() async {
        mockRunner.events = [.token("Hello"), .token(" World"), .done]
        await session.send("hi")
        XCTAssertEqual(session.messages.last?.content, "Hello World")
        XCTAssertFalse(session.isStreaming)
    }

    func testSend_toolCalls_tracksResults() async {
        mockRunner.events = [
            .toolCallStart(id: "c1", name: "shell", arguments: ["cmd": "ls"]),
            .toolCallResult(id: "c1", name: "shell", result: "file.txt"),
            .token("Done"),
            .done,
        ]
        await session.send("list files")
        XCTAssertEqual(session.toolCallResults.count, 0)
    }

    func testSend_error_setsErrorState() async {
        mockRunner.events = [.error("Network down")]
        await session.send("test")
        XCTAssertEqual(session.streamingContent, "")
        XCTAssertFalse(session.isStreaming)
    }
}

// MARK: - Mock AgentRunner

final class MockAgentRunner: AgentRunner {
    var runCalled = false
    var events: [AgentEvent] = []

    override func run(
        history: [Message],
        config: ClientConfig,
        systemPrompt: String? = nil
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        runCalled = true
        let currentEvents = events
        events = []
        return AsyncThrowingStream { continuation in
            for event in currentEvents {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}
