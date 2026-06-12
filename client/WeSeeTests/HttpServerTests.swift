import SwiftData
import XCTest
@testable import WeSee

final class HttpServerTests: XCTestCase {
    var server: HttpServer!
    var mockSession: MockChatSession!
    let testPort: UInt16 = 18080

    override func setUp() async throws {
        mockSession = MockChatSession()
        server = HttpServer(port: testPort, chatSession: mockSession)
        try server.start()
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    override func tearDown() {
        server.stop()
    }

    // MARK: - Static files

    func testGetRoot_returnsHTML() async throws {
        let url = URL(string: "http://127.0.0.1:\(testPort)/")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let httpResponse = response as! HTTPURLResponse
        XCTAssertEqual(httpResponse.statusCode, 200)
        let body = String(data: data, encoding: .utf8)!
        XCTAssertTrue(body.contains("<!DOCTYPE html>") || body.contains("<html"))
    }

    // MARK: - API

    func testGetMessages_returnsJSON() async throws {
        let url = URL(string: "http://127.0.0.1:\(testPort)/api/messages")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let httpResponse = response as! HTTPURLResponse
        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(obj["messages"])
    }

    func testNewConversation_returnsOK() async throws {
        let url = URL(string: "http://127.0.0.1:\(testPort)/api/new-conversation")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse
        XCTAssertEqual(httpResponse.statusCode, 200)
    }

    func testPostChat_emptyContent_returns400() async throws {
        let url = URL(string: "http://127.0.0.1:\(testPort)/api/chat")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = #"{"content":"   "}"#.data(using: .utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse
        XCTAssertEqual(httpResponse.statusCode, 400)
    }
}

final class MockChatSession: ChatSessionProtocol {
    var messages: [Message] = []
    var streamingContent: String = ""
    var thinkingContent: String = ""
    var isStreaming: Bool = false
    var toolCallResults: [(id: String, name: String, arguments: [String: Any], result: String?)] = []
    var eventStream: AsyncStream<SessionEvent> {
        AsyncStream { $0.finish() }
    }

    func send(_ text: String) async {}
    func newConversation() {}
    func configure(with modelContext: ModelContext) {}
    func fetchMessages() {}
    func clearError() {}
}
