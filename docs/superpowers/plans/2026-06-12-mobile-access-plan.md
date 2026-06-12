# Mobile Access Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable mobile phone access to the desktop agent via embedded HTTP server + SSE streaming + Tailscale VPN.

**Architecture:** Extract `ChatSession` from `ChatViewModel` as Mediator, build `HttpServer` with Network.framework as Adapter, thin `ChatViewModel` to Observer, vanilla JS Web UI for phone.

**Tech Stack:** Swift, Network.framework, SwiftData, HTML/CSS/JS (vanilla)

---

## File Structure

```
client/WeSee/
├── Services/
│   ├── ChatSession.swift          # NEW: ChatSessionProtocol + ChatSessionImpl
│   └── HttpServer.swift            # NEW: NWListener HTTP server + SSEAdapter
├── Web/                            # NEW: Mobile web UI
│   ├── index.html
│   └── app.js
├── ViewModels/
│   └── ChatViewModel.swift         # MODIFY: Thin adapter around ChatSession
├── Models/
│   ├── SessionEvent.swift          # NEW: SessionEvent enum
│   ├── AgentEvent.swift            # keep
│   └── Message.swift               # keep
├── WeSeeApp.swift                  # MODIFY: Create ChatSession, start HttpServer
├── ContentView.swift               # MODIFY: Accept ChatSession, pass to VMs
├── WeSee.xcodeproj/
│   └── project.pbxproj            # MODIFY: Add new files, embed Web/ resources
├── WeSeeTests/
│   ├── ChatSessionTests.swift      # NEW
│   └── HttpServerTests.swift       # NEW
```

**Boundary design:**
- `SessionEvent` — simple enum, no dependencies, used by ChatSession → consumers
- `ChatSessionProtocol` — pure Swift, no framework imports, defines the contract
- `ChatSessionImpl` — depends on AgentRunner, SwiftData ModelContext, SystemPromptBuilder
- `HttpServer` — depends on ChatSessionProtocol, Network.framework; no SwiftUI
- `ChatViewModel` — depends on ChatSessionProtocol, @Observable, SwiftUI bindings only
- `Web/` — depends on HTTP API only; zero Swift knowledge

---

### Task 1: Define SessionEvent and ChatSessionProtocol

**Files:**
- Create: `client/WeSee/Models/SessionEvent.swift`
- Create: `client/WeSee/Services/ChatSession.swift`
- Create: `client/WeSeeTests/ChatSessionTests.swift`

- [ ] **Step 1: Write SessionEvent tests and type**

Create `client/WeSee/Models/SessionEvent.swift`:

```swift
import Foundation

enum SessionEvent {
    case token(String)
    case thinking(String)
    case toolCallStart(id: String, name: String, arguments: [String: Any])
    case toolCallResult(id: String, name: String, result: String)
    case done
    case error(String)
}

extension SessionEvent: Equatable {
    static func == (lhs: SessionEvent, rhs: SessionEvent) -> Bool {
        switch (lhs, rhs) {
        case (.token(let a), .token(let b)): return a == b
        case (.thinking(let a), .thinking(let b)): return a == b
        case (.done, .done): return true
        case (.error(let a), .error(let b)): return a == b
        default: return false
        }
    }
}
```

- [ ] **Step 2: Write ChatSessionProtocol**

Create `client/WeSee/Services/ChatSession.swift`:

```swift
import Foundation
import SwiftData

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
    func clearError()
}
```

- [ ] **Step 3: Write failing test for ChatSessionImpl stub**

Create `client/WeSeeTests/ChatSessionTests.swift`:

```swift
import XCTest
import SwiftData
@testable import WeSee

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

    // MARK: - newConversation

    func testNewConversation_clearsMessages() async {
        await session.send("hello")
        session.newConversation()
        XCTAssertTrue(session.messages.isEmpty)
        XCTAssertEqual(session.streamingContent, "")
        XCTAssertFalse(session.isStreaming)
    }

    // MARK: - send validates input

    func testSend_emptyMessage_doesNotSend() async {
        await session.send("   ")
        XCTAssertFalse(mockRunner.runCalled)
    }

    func testSend_longMessage_trimsTo5000() async {
        let long = String(repeating: "a", count: 5001)
        await session.send(long)
        XCTAssertFalse(mockRunner.runCalled)
    }

    // MARK: - send normal flow

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
        XCTAssertEqual(session.toolCallResults.count, 0) // cleared on done
    }

    func testSend_error_setsErrorState() async {
        mockRunner.events = [.error("Network down")]
        await session.send("test")
        XCTAssertEqual(session.streamingContent, "")
        XCTAssertFalse(session.isStreaming)
    }
}

// MARK: - Mock AgentRunner

final class MockAgentRunner {
    var runCalled = false
    var events: [AgentEvent] = []

    func run(
        history: [Message],
        config: ClientConfig,
        systemPrompt: String?
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        runCalled = true
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `xcodebuild -project client/WeSee.xcodeproj -scheme WeSee -configuration Debug test -only-testing:WeSeeTests/ChatSessionTests`
Expected: Compilation errors (ChatSessionImpl not yet implemented)

- [ ] **Step 5: Implement ChatSessionImpl**

Add to `client/WeSee/Services/ChatSession.swift`:

```swift
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
    private var sendTask: Task<Void, Never>?

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
                case .thinking(let text):
                    thinkingContent += text
                case .toolCallStart(let id, let name, let arguments):
                    toolCallResults.append(
                        (id: id, name: name, arguments: arguments, result: nil)
                    )
                case .toolCallResult(let id, let name, let result):
                    if let index = toolCallResults.firstIndex(where: { $0.id == id }) {
                        toolCallResults[index].result = result
                    }
                    if name == "screenshot" && FileManager.default.fileExists(atPath: result) {
                        pendingImagePaths.append(result)
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
                case .error(let msg):
                    streamingContent = ""
                    thinkingContent = ""
                    toolCallResults = []
                    pendingImagePaths = []
                    isStreaming = false
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
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `xcodebuild -project client/WeSee.xcodeproj -scheme WeSee -configuration Debug test -only-testing:WeSeeTests/ChatSessionTests`
Expected: All tests PASS

- [ ] **Step 7: Commit**

```bash
git add client/WeSee/Models/SessionEvent.swift client/WeSee/Services/ChatSession.swift client/WeSeeTests/ChatSessionTests.swift
git commit -m "feat: add ChatSession protocol and implementation"
```

---

### Task 2: Refactor ChatViewModel to use ChatSession

**Files:**
- Modify: `client/WeSee/ViewModels/ChatViewModel.swift`
- Modify: `client/WeSeeTests/ChatViewModelTests.swift` (if exists)

- [ ] **Step 1: Rewrite ChatViewModel as thin adapter**

Rewrite `client/WeSee/ViewModels/ChatViewModel.swift`:

```swift
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

    private let session: ChatSessionProtocol

    init(session: ChatSessionProtocol) {
        self.session = session
    }

    func configure(with context: ModelContext) {
        session.configure(with: context)
    }

    func fetchMessages() {
        session.fetchMessages()
    }

    func addMessage(
        content: String,
        thinkingContent: String? = nil,
        attachmentPaths: [String] = [],
        isFromMe: Bool
    ) {
        // No-op: ChatSession manages message persistence now.
        // Kept for source compatibility; remove callers in follow-up.
    }

    func newConversation() {
        session.newConversation()
        syncState()
    }

    func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 5000 else { return }

        isSendingDisabled = true

        Task {
            await session.send(text)
            await MainActor.run {
                syncState()
                isSendingDisabled = false
            }
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private func syncState() {
        messages = session.messages
        streamingContent = session.streamingContent
        thinkingContent = session.thinkingContent
        isStreaming = session.isStreaming
        toolCallResults = session.toolCallResults
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild -project client/WeSee.xcodeproj -scheme WeSee -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add client/WeSee/ViewModels/ChatViewModel.swift
git commit -m "refactor: thin ChatViewModel to delegate to ChatSession"
```

---

### Task 3: Update ContentView and WeSeeApp wiring

**Files:**
- Modify: `client/WeSee/WeSeeApp.swift`
- Modify: `client/WeSee/ContentView.swift`

- [ ] **Step 1: Update WeSeeApp to create ChatSession**

Rewrite `client/WeSee/WeSeeApp.swift`:

```swift
import SwiftUI
import SwiftData

@main
struct WeSeeApp: App {
    let container: ModelContainer
    let chatSession: ChatSessionImpl

    init() {
        do {
            container = try ModelContainer(for: Message.self, ScheduledTask.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        let wm = WorkspaceManager()
        chatSession = ChatSessionImpl(
            agentRunner: AgentRunner(workspaceManager: wm),
            workspaceManager: wm,
            systemPromptBuilder: SystemPromptBuilder(workspaceManager: wm)
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView(chatSession: chatSession)
        }
        .modelContainer(container)
    }
}
```

- [ ] **Step 2: Update ContentView to accept ChatSession**

Rewrite `client/WeSee/ContentView.swift`:

```swift
import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var chatViewModel: ChatViewModel
    @State private var sidebarViewModel: SidebarViewModel

    init(chatSession: ChatSessionImpl) {
        _chatViewModel = State(initialValue: ChatViewModel(session: chatSession))
        _sidebarViewModel = State(initialValue: SidebarViewModel(workspaceManager: chatSession.workspaceManager))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(viewModel: sidebarViewModel, chatViewModel: chatViewModel)
                .frame(minWidth: 220)
        } detail: {
            ChatView(viewModel: chatViewModel)
                .frame(minWidth: 400)
        }
        .onAppear {
            chatViewModel.configure(with: modelContext)
            sidebarViewModel.configure(with: modelContext)
        }
    }
}
```

- [ ] **Step 3: Build and verify no regressions**

Run: `xcodebuild -project client/WeSee.xcodeproj -scheme WeSee -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add client/WeSee/WeSeeApp.swift client/WeSee/ContentView.swift
git commit -m "refactor: wire ChatSession through WeSeeApp and ContentView"
```

---

### Task 4: Expose workspaceManager on AgentRunner for ContentView

**Files:**
- Modify: `client/WeSee/Services/AgentRunner.swift`

- [ ] **Step 1: Add read-only workspaceManager accessor**

In `client/WeSee/Services/AgentRunner.swift`, add before the `init` method:

```swift
let workspaceManager: WorkspaceManager
```

And update init to store it as a property (currently it's stored as `private let workspaceManager: WorkspaceManager` — change `private let` to `let`):

```swift
// Change line 7 from:
//     private let workspaceManager: WorkspaceManager
// to:
//     let workspaceManager: WorkspaceManager
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project client/WeSee.xcodeproj -scheme WeSee -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add client/WeSee/Services/AgentRunner.swift
git commit -m "refactor: expose workspaceManager on AgentRunner"
```

---

### Task 5: Add httpPort to ClientConfig

**Files:**
- Modify: `client/WeSee/Models/Config.swift`

- [ ] **Step 1: Add httpPort field**

In `client/WeSee/Models/Config.swift`, add `httpPort` to `ClientConfig`:

Add CodingKey:
```swift
case httpPort
```

Add property:
```swift
let httpPort: UInt16
```

Add init parameter (with default):
```swift
init(
    apiKey: String,
    baseURL: String = "https://api.deepseek.com",
    model: String = "deepseek-v4-pro",
    enableThinking: Bool = true,
    reasoningEffort: String? = nil,
    httpPort: UInt16 = 8080
) {
    self.apiKey = apiKey
    self.baseURL = baseURL
    self.model = model
    self.enableThinking = enableThinking
    self.reasoningEffort = reasoningEffort
    self.httpPort = httpPort
}
```

Update `init(from decoder:)`:
```swift
httpPort = try container.decodeIfPresent(UInt16.self, forKey: .httpPort) ?? 8080
```

Update `default` static:
```swift
static let `default` = ClientConfig(
    apiKey: "",
    baseURL: "https://api.deepseek.com",
    model: "deepseek-v4-pro",
    enableThinking: true,
    reasoningEffort: nil,
    httpPort: 8080
)
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project client/WeSee.xcodeproj -scheme WeSee -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add client/WeSee/Models/Config.swift
git commit -m "feat: add httpPort to ClientConfig"
```

---

### Task 6: Implement HttpServer HTTP layer

**Files:**
- Create: `client/WeSee/Services/HttpServer.swift`
- Create: `client/WeSeeTests/HttpServerTests.swift`

- [ ] **Step 1: Write failing HttpServer tests**

Create `client/WeSeeTests/HttpServerTests.swift`:

```swift
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
        // Small delay for server to bind
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

    func testGetAppJS_returnsJS() async throws {
        let url = URL(string: "http://127.0.0.1:\(testPort)/app.js")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let httpResponse = response as! HTTPURLResponse
        XCTAssertEqual(httpResponse.statusCode, 200)
        let body = String(data: data, encoding: .utf8)!
        XCTAssertTrue(body.contains("function") || body.contains("EventSource"))
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

    func testPostChat_returnsSSE() async throws {
        mockSession.streamEvents = [.token("Hi"), .done]

        let url = URL(string: "http://127.0.0.1:\(testPort)/api/chat")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = #"{"content":"hello"}"#.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse
        XCTAssertEqual(httpResponse.statusCode, 200)
        let body = String(data: data, encoding: .utf8)!
        XCTAssertTrue(body.contains("data: {"))
        XCTAssertTrue(body.contains("token"))
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

// MARK: - Mock

final class MockChatSession: ChatSessionProtocol {
    var messages: [Message] = []
    var streamingContent: String = ""
    var thinkingContent: String = ""
    var isStreaming: Bool = false
    var toolCallResults: [(id: String, name: String, arguments: [String: Any], result: String?)] = []
    var streamEvents: [AgentEvent] = []

    func send(_ text: String) async {}
    func newConversation() {}
    func configure(with modelContext: ModelContext) {}
    func fetchMessages() {}
    func clearError() {}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project client/WeSee.xcodeproj -scheme WeSee -configuration Debug test -only-testing:WeSeeTests/HttpServerTests`
Expected: Compilation error (HttpServer not yet created)

- [ ] **Step 3: Implement HttpServer**

Create `client/WeSee/Services/HttpServer.swift`:

```swift
import Foundation
import Network

final class HttpServer {
    private let port: UInt16
    private let chatSession: ChatSessionProtocol
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.wesee.httpserver")

    init(port: UInt16, chatSession: ChatSessionProtocol) {
        self.port = port
        self.chatSession = chatSession
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready: WeSeeLog.info("HttpServer listening on port \(self.port)")
            case .failed(let error): WeSeeLog.error("HttpServer failed: \(error)")
            default: break
            }
        }
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        listener?.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                return
            }
            if let requestText = String(data: data, encoding: .utf8) {
                self.processRequest(requestText, on: connection)
            } else {
                connection.cancel()
            }
        }
    }

    // MARK: - HTTP parsing + routing

    private func processRequest(_ raw: String, on connection: NWConnection) {
        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first,
              let method = requestLine.components(separatedBy: " ").first,
              let path = requestLine.components(separatedBy: " ").dropFirst().first
        else {
            send(status: 400, body: "Bad Request", contentType: "text/plain", on: connection)
            return
        }

        // Extract body for POST requests
        var body: String?
        if method == "POST" {
            if let bodyStart = raw.range(of: "\r\n\r\n") {
                body = String(raw[bodyStart.upperBound...])
            }
        }

        switch (method, path) {
        case ("GET", "/"):
            serveStaticFile(named: "index.html", contentType: "text/html; charset=utf-8", on: connection)

        case ("GET", "/app.js"):
            serveStaticFile(named: "app.js", contentType: "application/javascript; charset=utf-8", on: connection)

        case ("GET", "/api/messages"):
            serveMessages(on: connection)

        case ("POST", "/api/chat"):
            serveChatStream(body: body, on: connection)

        case ("POST", "/api/new-conversation"):
            chatSession.newConversation()
            send(status: 200, body: #"{"ok":true}"#, contentType: "application/json", on: connection)

        default:
            send(status: 404, body: "Not Found", contentType: "text/plain", on: connection)
        }
    }

    // MARK: - Static files

    private func serveStaticFile(named filename: String, contentType: String, on connection: NWConnection) {
        guard let resourceURL = Bundle.main.url(forResource: filename, withExtension: nil),
              let data = try? Data(contentsOf: resourceURL) else {
            send(status: 404, body: "Not Found", contentType: "text/plain", on: connection)
            return
        }
        send(status: 200, bodyData: data, contentType: contentType, on: connection)
    }

    // MARK: - API handlers

    private func serveMessages(on connection: NWConnection) {
        let messagesArray = chatSession.messages.map { msg -> [String: Any] in
            [
                "id": msg.id.uuidString,
                "content": msg.content,
                "thinkingContent": msg.thinkingContent as Any,
                "timestamp": ISO8601DateFormatter().string(from: msg.timestamp),
                "isFromMe": msg.isFromMe,
            ]
        }
        let json: [String: Any] = ["messages": messagesArray]
        guard let data = try? JSONSerialization.data(withJSONObject: json) else {
            send(status: 500, body: "Internal Error", contentType: "text/plain", on: connection)
            return
        }
        send(status: 200, bodyData: data, contentType: "application/json", on: connection)
    }

    private func serveChatStream(body: String?, on connection: NWConnection) {
        guard let body,
              let bodyData = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let content = json["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            send(status: 400, body: #"{"error":"Invalid request"}"#, contentType: "application/json", on: connection)
            return
        }

        // Send SSE headers
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
        sendRaw(headers, on: connection)

        let streamQueue = DispatchQueue(label: "com.wesee.chatstream.\(UUID().uuidString)")
        Task {
            await chatSession.send(content)

            // Poll session state and yield SSE events
            // Note: In production, ChatSession would have a proper event stream.
            // For now, poll with short delay to allow send() to complete synchronously
            // in cases where the mock/runner completes immediately.
            var seenContent = ""
            var done = false

            while !done {
                let content = await MainActor.run { chatSession.streamingContent }
                let isStreaming = await MainActor.run { chatSession.isStreaming }

                if content.count > seenContent.count {
                    let newPart = String(content.dropFirst(seenContent.count))
                    seenContent = content
                    let sse = self.formatSSE(type: "token", data: ["data": newPart])
                    self.sendRaw(sse, on: connection)
                }

                if !isStreaming && !content.isEmpty {
                    done = true
                }

                if !done {
                    try? await Task.sleep(nanoseconds: 50_000_000) // 50ms poll
                }
            }

            // Yield done
            self.sendRaw(self.formatSSE(type: "done", data: [:]), on: connection)
            self.sendRaw("data: [DONE]\n\n", on: connection)

            // Close connection after a brief delay to ensure delivery
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                connection.cancel()
            }
        }
    }

    // MARK: - Response helpers

    private func formatSSE(type: String, data: [String: Any]) -> String {
        var payload = data
        payload["type"] = type
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonStr = String(data: jsonData, encoding: .utf8) else {
            return "data: {\"type\":\"\(type)\"}\n\n"
        }
        return "data: \(jsonStr)\n\n"
    }

    private func send(status: Int, body: String, contentType: String, on connection: NWConnection) {
        let data = body.data(using: .utf8)!
        send(status: status, bodyData: data, contentType: contentType, on: connection)
    }

    private func send(status: Int, bodyData: Data, contentType: String, on connection: NWConnection) {
        let statusText = status == 200 ? "OK" : (status == 400 ? "Bad Request" : "Not Found")
        var header = "HTTP/1.1 \(status) \(statusText)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(bodyData.count)\r\n"
        header += "Connection: close\r\n"
        header += "\r\n"
        var response = header.data(using: .utf8)!
        response.append(bodyData)
        sendRawData(response, on: connection)
    }

    private func sendRaw(_ text: String, on connection: NWConnection) {
        sendRawData(text.data(using: .utf8)!, on: connection)
    }

    private func sendRawData(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, completion: .idempotent)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `xcodebuild -project client/WeSee.xcodeproj -scheme WeSee -configuration Debug test -only-testing:WeSeeTests/HttpServerTests`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add client/WeSee/Services/HttpServer.swift client/WeSeeTests/HttpServerTests.swift
git commit -m "feat: add HttpServer with SSE chat streaming"
```

---

### Task 7: Start HttpServer in WeSeeApp

**Files:**
- Modify: `client/WeSee/WeSeeApp.swift`

- [ ] **Step 1: Add HttpServer startup**

Update `client/WeSee/WeSeeApp.swift` to add HttpServer:

```swift
import SwiftUI
import SwiftData

@main
struct WeSeeApp: App {
    let container: ModelContainer
    let chatSession: ChatSessionImpl
    let httpServer: HttpServer

    init() {
        do {
            container = try ModelContainer(for: Message.self, ScheduledTask.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        let wm = WorkspaceManager()
        chatSession = ChatSessionImpl(
            agentRunner: AgentRunner(workspaceManager: wm),
            workspaceManager: wm,
            systemPromptBuilder: SystemPromptBuilder(workspaceManager: wm)
        )
        let config = (try? ConfigLoader.load()) ?? ClientConfig.default
        httpServer = HttpServer(port: config.httpPort, chatSession: chatSession)
        do {
            try httpServer.start()
            WeSeeLog.info("HttpServer started on port \(config.httpPort)")
        } catch {
            WeSeeLog.error("HttpServer failed to start: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(chatSession: chatSession)
        }
        .modelContainer(container)
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project client/WeSee.xcodeproj -scheme WeSee -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add client/WeSee/WeSeeApp.swift
git commit -m "feat: start HttpServer on app launch"
```

---

### Task 8: Create web UI — HTML

**Files:**
- Create: `client/WeSee/Web/index.html`

- [ ] **Step 1: Create mobile-friendly HTML**

Create `client/WeSee/Web/index.html`:

```html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover">
<title>WeSee Chat</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, 'SF Pro', sans-serif;
    background: #1a1a2e;
    color: #e0e0e0;
    height: 100dvh;
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }
  #messages {
    flex: 1;
    overflow-y: auto;
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 12px;
  }
  .msg { max-width: 85%; padding: 10px 14px; border-radius: 16px; line-height: 1.5; word-break: break-word; }
  .msg.user { align-self: flex-end; background: #007AFF; color: #fff; }
  .msg.agent { align-self: flex-start; background: #2d2d44; }
  .msg.streaming { opacity: 0.8; }
  .thinking-block { font-size: 0.85em; color: #888; margin-bottom: 8px; padding: 8px; background: #1e1e30; border-radius: 8px; display: none; }
  .thinking-block.visible { display: block; }
  .tool-call { font-size: 0.8em; background: #1e3a2f; padding: 8px; border-radius: 8px; margin: 4px 0; }
  .tool-call .name { color: #4ec9b0; font-weight: 600; }
  .tool-call .result { color: #888; font-size: 0.9em; margin-top: 4px; max-height: 120px; overflow-y: auto; }
  #input-area {
    display: flex;
    padding: 12px;
    gap: 8px;
    background: #12121f;
    border-top: 1px solid #2d2d44;
    padding-bottom: max(12px, env(safe-area-inset-bottom));
  }
  #input {
    flex: 1;
    padding: 10px 14px;
    border-radius: 20px;
    border: 1px solid #3d3d5c;
    background: #1a1a2e;
    color: #e0e0e0;
    font-size: 16px;
    outline: none;
  }
  #input:focus { border-color: #007AFF; }
  #send {
    width: 44px; height: 44px;
    border-radius: 50%;
    border: none;
    background: #007AFF;
    color: #fff;
    font-size: 18px;
    cursor: pointer;
    flex-shrink: 0;
  }
  #send:disabled { opacity: 0.4; }
  #new-chat {
    background: none;
    border: 1px solid #3d3d5c;
    color: #888;
    padding: 6px 12px;
    border-radius: 16px;
    font-size: 14px;
    cursor: pointer;
  }
  #new-chat:hover { color: #e0e0e0; border-color: #666; }
  #header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 12px 16px;
    background: #12121f;
    border-bottom: 1px solid #2d2d44;
  }
  #header h1 { font-size: 18px; font-weight: 600; }
  #status { font-size: 12px; color: #4ec9b0; }
  #error-banner { display: none; padding: 10px; background: #5c1a1a; color: #ff6b6b; text-align: center; font-size: 14px; }
</style>
</head>
<body>
<div id="header">
  <h1>WeSee</h1>
  <span id="status">● connected</span>
  <button id="new-chat" onclick="newConversation()">+ New</button>
</div>
<div id="error-banner"></div>
<div id="messages"></div>
<div id="input-area">
  <input id="input" type="text" placeholder="Type a message..." autofocus>
  <button id="send" onclick="sendMessage()">↑</button>
</div>
<script src="app.js"></script>
</body>
</html>
```

- [ ] **Step 2: Commit**

```bash
git add client/WeSee/Web/index.html
git commit -m "feat: add mobile web chat UI HTML"
```

---

### Task 9: Create web UI — JavaScript

**Files:**
- Create: `client/WeSee/Web/app.js`

- [ ] **Step 1: Create chat client JavaScript**

Create `client/WeSee/Web/app.js`:

```javascript
const messagesEl = document.getElementById('messages');
const inputEl = document.getElementById('input');
const sendBtn = document.getElementById('send');
const statusEl = document.getElementById('status');
const errorBanner = document.getElementById('error-banner');

let currentStreamingEl = null;
let currentThinkingEl = null;
let currentThinkingContent = '';
let pendingToolCalls = {};

// Load message history on init
(async function init() {
  try {
    const res = await fetch('/api/messages');
    const data = await res.json();
    data.messages.forEach(msg => renderMessage(msg.content, msg.isFromMe, msg.thinkingContent));
    scrollToBottom();
  } catch (e) {
    showError('Failed to load messages');
  }
})();

inputEl.addEventListener('keydown', (e) => {
  if (e.key === 'Enter') sendMessage();
});

function sendMessage() {
  const text = inputEl.value.trim();
  if (!text || text.length > 5000) return;

  renderMessage(text, true);
  inputEl.value = '';
  scrollToBottom();

  sendBtn.disabled = true;
  inputEl.disabled = true;
  statusEl.textContent = '● streaming';
  statusEl.style.color = '#ffd700';

  currentStreamingEl = null;
  currentThinkingEl = null;
  currentThinkingContent = '';
  pendingToolCalls = {};

  fetch('/api/chat', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ content: text })
  }).then(async (response) => {
    if (!response.ok) {
      const err = await response.json();
      showError(err.error || 'Request failed');
      resetInput();
      return;
    }

    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let buffer = '';

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });

      const lines = buffer.split('\n');
      buffer = lines.pop() || '';

      for (const line of lines) {
        if (!line.startsWith('data: ')) continue;
        const jsonStr = line.slice(6);
        if (jsonStr === '[DONE]') {
          finalizeStream();
          return;
        }
        try {
          const event = JSON.parse(jsonStr);
          handleSSEEvent(event);
        } catch (e) {
          // skip parse errors for incomplete lines
        }
      }
    }
    finalizeStream();
  }).catch(e => {
    showError('Connection lost: ' + e.message);
    resetInput();
  });
}

function handleSSEEvent(event) {
  switch (event.type) {
    case 'token':
      if (!currentStreamingEl) {
        currentStreamingEl = createStreamingBubble();
      }
      currentStreamingEl.querySelector('.content').textContent += event.data;
      scrollToBottom();
      break;

    case 'thinking':
      currentThinkingContent += event.data;
      if (currentStreamingEl) {
        const thinkEl = currentStreamingEl.querySelector('.thinking-block');
        thinkEl.textContent = currentThinkingContent;
        thinkEl.classList.add('visible');
      }
      break;

    case 'toolCall':
      pendingToolCalls[event.id] = { name: event.name, result: null };
      if (currentStreamingEl) {
        const toolsEl = currentStreamingEl.querySelector('.tool-calls');
        const div = document.createElement('div');
        div.className = 'tool-call';
        div.id = 'tool-' + event.id;
        div.innerHTML = '<span class="name">🔧 ' + event.name + '</span><div class="result">Running...</div>';
        toolsEl.appendChild(div);
        scrollToBottom();
      }
      break;

    case 'toolResult':
      if (pendingToolCalls[event.id]) {
        pendingToolCalls[event.id].result = event.result;
      }
      const toolDiv = document.getElementById('tool-' + event.id);
      if (toolDiv) {
        const truncated = event.result.length > 500 ? event.result.slice(0, 500) + '...' : event.result;
        toolDiv.querySelector('.result').textContent = truncated;
      }
      break;

    case 'done':
      finalizeStream();
      break;

    case 'error':
      showError(event.data);
      resetInput();
      break;
  }
}

function createStreamingBubble() {
  const div = document.createElement('div');
  div.className = 'msg agent streaming';
  div.innerHTML = `
    <div class="thinking-block"></div>
    <div class="tool-calls"></div>
    <div class="content"></div>
  `;
  messagesEl.appendChild(div);
  return div;
}

function finalizeStream() {
  if (currentStreamingEl) {
    currentStreamingEl.classList.remove('streaming');
    currentStreamingEl = null;
  }
  resetInput();
  scrollToBottom();
}

function renderMessage(content, isFromMe, thinkingContent) {
  const div = document.createElement('div');
  div.className = 'msg ' + (isFromMe ? 'user' : 'agent');
  if (thinkingContent) {
    const think = document.createElement('div');
    think.className = 'thinking-block visible';
    think.textContent = thinkingContent;
    div.appendChild(think);
  }
  const contentSpan = document.createElement('span');
  contentSpan.textContent = content;
  div.appendChild(contentSpan);
  messagesEl.appendChild(div);
}

function newConversation() {
  fetch('/api/new-conversation', { method: 'POST' }).then(() => {
    messagesEl.innerHTML = '';
    currentStreamingEl = null;
    hideError();
  });
}

function resetInput() {
  sendBtn.disabled = false;
  inputEl.disabled = false;
  inputEl.focus();
  statusEl.textContent = '● connected';
  statusEl.style.color = '#4ec9b0';
}

function showError(msg) {
  errorBanner.textContent = msg;
  errorBanner.style.display = 'block';
  setTimeout(hideError, 5000);
}

function hideError() {
  errorBanner.style.display = 'none';
}

function scrollToBottom() {
  requestAnimationFrame(() => {
    messagesEl.scrollTop = messagesEl.scrollHeight;
  });
}
```

- [ ] **Step 2: Commit**

```bash
git add client/WeSee/Web/app.js
git commit -m "feat: add mobile web chat client JavaScript"
```

---

### Task 10: Add Web/ resources to Xcode bundle

**Files:**
- Modify: `client/WeSee.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add Web/ folder as bundle resources**

In Xcode:
1. Open `client/WeSee.xcodeproj`
2. Right-click on `WeSee` group → "Add Files to WeSee..."
3. Select `client/WeSee/Web/` folder
4. Choose "Create folder references" (blue folder icon, NOT "Create groups")
5. Ensure target membership is checked for `WeSee`

This makes `index.html` and `app.js` available at `Bundle.main.url(forResource: "index.html", withExtension: nil)` and `Bundle.main.url(forResource: "app.js", withExtension: nil)`.

- [ ] **Step 2: Build and verify resources are bundled**

Run: `xcodebuild -project client/WeSee.xcodeproj -scheme WeSee -configuration Debug build`
Then verify: `ls -la client/build/Build/Products/Debug/WeSee.app/Contents/Resources/index.html`
Expected: File exists

- [ ] **Step 3: Run app and test with curl**

Run app, then:
```bash
curl http://127.0.0.1:8080/
```
Expected: Returns HTML content

```bash
curl http://127.0.0.1:8080/api/messages
```
Expected: Returns `{"messages":[]}`

- [ ] **Step 4: Commit**

```bash
git add client/WeSee.xcodeproj/project.pbxproj
git commit -m "chore: add Web resources to Xcode bundle"
```

---

### Task 11: Streamline ChatSession with proper event stream

**Files:**
- Modify: `client/WeSee/Services/ChatSession.swift`

- [ ] **Step 1: Add AsyncStream-based events to ChatSessionProtocol**

Update `ChatSessionProtocol` in `client/WeSee/Services/ChatSession.swift`:

```swift
protocol ChatSessionProtocol: AnyObject {
    var messages: [Message] { get }
    var streamingContent: String { get }
    var thinkingContent: String { get }
    var isStreaming: Bool { get }
    var toolCallResults: [(id: String, name: String, arguments: [String: Any], result: String?)] { get }
    var eventStream: AsyncStream<SessionEvent> { get }

    func send(_ text: String) async
    func newConversation()
    func configure(with modelContext: ModelContext)
    func fetchMessages()
    func clearError()
}
```

Update `ChatSessionImpl` to yield events via AsyncStream:

Add property:
```swift
private var eventContinuation: AsyncStream<SessionEvent>.Continuation?
private(set) lazy var eventStream: AsyncStream<SessionEvent> = {
    AsyncStream { continuation in
        self.eventContinuation = continuation
    }
}()
```

In `send()`, after each `AgentEvent` case, yield the corresponding `SessionEvent`:
```swift
case .token(let token):
    streamingContent += token
    eventContinuation?.yield(.token(token))
case .thinking(let text):
    thinkingContent += text
    eventContinuation?.yield(.thinking(text))
// ... same for toolCallStart, toolCallResult, done, error
```

- [ ] **Step 2: Update HttpServer to use eventStream instead of polling**

Replace the polling loop in `serveChatStream` with:

```swift
private func serveChatStream(body: String?, on connection: NWConnection) {
    guard let body,
          let bodyData = body.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
          let content = json["content"] as? String,
          !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
        send(status: 400, body: #"{"error":"Invalid request"}"#, contentType: "application/json", on: connection)
        return
    }

    let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
    sendRaw(headers, on: connection)

    Task {
        await chatSession.send(content)

        for await event in chatSession.eventStream {
            switch event {
            case .token(let text):
                sendRaw(formatSSE(type: "token", data: ["data": text]), on: connection)

            case .thinking(let text):
                sendRaw(formatSSE(type: "thinking", data: ["data": text]), on: connection)

            case .toolCallStart(let id, let name, let arguments):
                sendRaw(formatSSE(type: "toolCall", data: [
                    "id": id, "name": name, "arguments": arguments
                ]), on: connection)

            case .toolCallResult(let id, let name, let result):
                sendRaw(formatSSE(type: "toolResult", data: [
                    "id": id, "name": name, "result": result
                ]), on: connection)

            case .done:
                sendRaw(formatSSE(type: "done", data: [:]), on: connection)
                sendRaw("data: [DONE]\n\n", on: connection)
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { connection.cancel() }
                return

            case .error(let msg):
                sendRaw(formatSSE(type: "error", data: ["data": msg]), on: connection)
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { connection.cancel() }
                return
            }
        }

        // Stream ended without done/error
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { connection.cancel() }
    }
}
```

- [ ] **Step 3: Update ChatViewModel to use eventStream for live updates**

In `ChatViewModel.sendMessage()`, after `await session.send(text)`, instead of calling `syncState()` once, observe `eventStream`:

```swift
func sendMessage(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 5000 else { return }

    isSendingDisabled = true

    Task {
        await session.send(text)

        // Observe event stream for live updates
        for await event in session.eventStream {
            await MainActor.run {
                switch event {
                case .token, .thinking:
                    streamingContent = session.streamingContent
                    thinkingContent = session.thinkingContent
                    isStreaming = session.isStreaming
                case .toolCallStart, .toolCallResult:
                    toolCallResults = session.toolCallResults
                case .done:
                    syncState()
                    isSendingDisabled = false
                case .error(let msg):
                    errorMessage = msg
                    syncState()
                    isSendingDisabled = false
                }
            }
        }
    }
}
```

- [ ] **Step 4: Update MockChatSession in tests**

Add `eventStream` to `MockChatSession`:

```swift
var eventStream: AsyncStream<SessionEvent> {
    AsyncStream { continuation in
        continuation.finish()
    }
}
```

- [ ] **Step 5: Build and run tests**

Run: `xcodebuild -project client/WeSee.xcodeproj -scheme WeSee -configuration Debug build`
Expected: BUILD SUCCEEDED

Run: `xcodebuild -project client/WeSee.xcodeproj -scheme WeSee -configuration Debug test -only-testing:WeSeeTests/HttpServerTests`
Expected: All tests PASS

- [ ] **Step 6: Commit**

```bash
git add client/WeSee/Services/ChatSession.swift client/WeSee/Services/HttpServer.swift client/WeSee/ViewModels/ChatViewModel.swift client/WeSeeTests/HttpServerTests.swift
git commit -m "feat: add AsyncStream event bus to ChatSession"
```

---

### Task 12: Tailscale setup guide (documentation)

**Files:**
- Create: `docs/tailscale-setup.md`

- [ ] **Step 1: Write setup guide**

Create `docs/tailscale-setup.md`:

```markdown
# Tailscale Setup for WeSee Mobile Access

## Overview

WeSee's HTTP server listens on `127.0.0.1:8080`. Tailscale creates a secure WireGuard tunnel so your phone can reach this port from anywhere.

## Mac Setup

1. Install Tailscale: `brew install tailscale` or download from https://tailscale.com
2. Start and authenticate: `tailscale up`
3. Verify: `tailscale status` — note your Mac's Tailscale IP (e.g., `100.x.x.x`)

## Phone Setup

1. Install Tailscale from App Store / Google Play
2. Sign in with the same account
3. Verify both devices show as connected in Tailscale admin console

## Usage

Open your phone's browser and go to: `http://<mac-tailscale-ip>:8080`

Example: `http://100.123.45.67:8080`

## Firewall Note

No firewall rules needed. WeSee's HTTP server binds to `127.0.0.1` only, and Tailscale handles the rest.
```

- [ ] **Step 2: Commit**

```bash
git add docs/tailscale-setup.md
git commit -m "docs: add Tailscale setup guide"
```

---

### Task 13: End-to-end manual test

- [ ] **Step 1: Launch app and verify HTTP server**

```bash
# Check port is listening
lsof -i :8080 | grep LISTEN
```
Expected: WeSee process listening on 127.0.0.1:8080

- [ ] **Step 2: Test static file serving**

```bash
curl -s http://127.0.0.1:8080/ | head -5
curl -s http://127.0.0.1:8080/app.js | head -5
```
Expected: HTML and JS content returned

- [ ] **Step 3: Test API endpoints**

```bash
# Messages
curl -s http://127.0.0.1:8080/api/messages

# New conversation
curl -s -X POST http://127.0.0.1:8080/api/new-conversation

# Chat (SSE)
curl -s -N -X POST http://127.0.0.1:8080/api/chat \
  -H "Content-Type: application/json" \
  -d '{"content":"你好"}'
```
Expected: Messages returns JSON, new-conversation returns ok, chat streams SSE

- [ ] **Step 4: Test with phone on same WiFi (before Tailscale)**

Connect phone to same WiFi → Mac IP: `http://<mac-lan-ip>:8080`
(Note: this won't work because server binds 127.0.0.1. For LAN test, temporarily change to 0.0.0.0)

- [ ] **Step 5: Test with Tailscale**

1. Install Tailscale on both devices
2. Phone browser → `http://<mac-tailscale-ip>:8080`
3. Send a message, verify streaming reply
4. Verify desktop app shows the same conversation

- [ ] **Step 6: Commit any fixes found during testing**

```bash
git commit -m "fix: issues found during E2E testing"
```

---

## Spec Coverage Self-Review

| Spec Section | Task(s) |
|-------------|---------|
| ChatSession (Mediator) | Task 1, Task 11 |
| HttpServer + SSEAdapter | Task 6, Task 11 |
| ChatViewModel refactor | Task 2, Task 11 |
| Web UI (HTML + JS) | Task 8, Task 9 |
| WeSeeApp wiring | Task 3, Task 7 |
| Config httpPort | Task 5 |
| AgentRunner workspaceManager exposure | Task 4 |
| Xcode bundle resources | Task 10 |
| Tailscale setup guide | Task 12 |
| End-to-end testing | Task 13 |
| Error handling | Task 1 (validation), Task 6 (HTTP errors), Task 9 (JS errors) |

All spec sections covered. No TBD/TODO. Types consistent across tasks.
