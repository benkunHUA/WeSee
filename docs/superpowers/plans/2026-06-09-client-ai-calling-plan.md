# Client-Side AI Calling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move DeepSeek API calls from Python server to Swift client, remove server entirely.

**Architecture:** New DeepSeekService reads config from `~/.config/wesee/config.json` and calls DeepSeek API directly via URLSession SSE. Remove RemoteClient protocol/LiveRemoteClient/DTO.swift/server/. ChatViewModel and SidebarViewModel operate on local SwiftData only.

**Tech Stack:** Swift, SwiftUI, SwiftData, URLSession

---

### Task 1: ClientConfig Model

**Files:**
- Create: `WeSee/Models/Config.swift`
- Modify: `WeSee.xcodeproj` (auto-discovered by PBXFileSystemSynchronizedRootGroup)

- [ ] **Step 1: Create ClientConfig model**

```swift
import Foundation

struct ClientConfig: Codable {
    let apiKey: String
    let baseURL: String
    let model: String

    static let `default` = ClientConfig(
        apiKey: "",
        baseURL: "https://api.deepseek.com",
        model: "deepseek-chat"
    )
}

enum ConfigError: LocalizedError {
    case fileNotFound(path: String)
    case invalidJSON(Error)
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "未找到配置文件 \(path)"
        case .invalidJSON(let error):
            return "配置文件格式错误: \(error.localizedDescription)"
        case .missingAPIKey:
            return "配置文件中缺少 apiKey"
        }
    }
}

struct ConfigLoader {
    static func load() throws -> ClientConfig {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configURL = home
            .appendingPathComponent(".config/wesee/config.json")

        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw ConfigError.fileNotFound(path: configURL.path)
        }

        let data: Data
        do {
            data = try Data(contentsOf: configURL)
        } catch {
            throw ConfigError.fileNotFound(path: configURL.path)
        }

        let config: ClientConfig
        do {
            config = try JSONDecoder().decode(ClientConfig.self, from: data)
        } catch {
            throw ConfigError.invalidJSON(error)
        }

        guard !config.apiKey.isEmpty else {
            throw ConfigError.missingAPIKey
        }

        return config
    }
}
```

- [ ] **Step 2: Write ConfigLoader tests**

Create `WeSeeTests/ConfigLoaderTests.swift`:

```swift
import Testing
@testable import WeSee
import Foundation

struct ConfigLoaderTests {

    @Test func decodeValidConfig() throws {
        let json = """
        {"apiKey": "sk-test", "baseURL": "https://api.deepseek.com", "model": "deepseek-chat"}
        """
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(ClientConfig.self, from: data)
        #expect(config.apiKey == "sk-test")
        #expect(config.baseURL == "https://api.deepseek.com")
        #expect(config.model == "deepseek-chat")
    }

    @Test func decodeConfigWithDefaults() throws {
        let json = """
        {"apiKey": "sk-test"}
        """
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(ClientConfig.self, from: data)
        #expect(config.apiKey == "sk-test")
    }

    @Test func missingAPIKeyThrows() {
        let config = ClientConfig(apiKey: "", baseURL: "", model: "")
        do {
            _ = try ConfigLoader.validate(config)
        } catch {
            #expect(error is ConfigError)
        }
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug test 2>&1 | tail -20`
Expected: FAIL (ConfigLoaderTests will have compile errors - no `validate` method yet)

- [ ] **Step 4: Add validate method, run tests**

Add to `ConfigLoader`:
```swift
static func validate(_ config: ClientConfig) throws -> ClientConfig {
    guard !config.apiKey.isEmpty else {
        throw ConfigError.missingAPIKey
    }
    return config
}
```

Run: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug test 2>&1 | tail -20`
Expected: PASS (tests compile and pass)

- [ ] **Step 5: Commit**

```bash
git add WeSee/Models/Config.swift WeSeeTests/ConfigLoaderTests.swift
git commit -m "feat: add ClientConfig model and ConfigLoader with tests"
```

---

### Task 2: DeepSeekService

**Files:**
- Create: `WeSee/Services/DeepSeekService.swift`

- [ ] **Step 1: Write DeepSeekService tests**

Create `WeSeeTests/DeepSeekServiceTests.swift`:

```swift
import Testing
@testable import WeSee
import Foundation

struct DeepSeekServiceTests {

    @Test func buildRequestReturnsValidRequest() throws {
        let config = ClientConfig(apiKey: "sk-test", baseURL: "https://api.deepseek.com", model: "deepseek-chat")
        let service = DeepSeekService()
        let history: [Message] = [
            Message(content: "Hello", isFromMe: true),
            Message(content: "Hi there!", isFromMe: false),
        ]
        let request = service.buildRequest(history: history, config: config)

        #expect(request.url?.absoluteString == "https://api.deepseek.com/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        #expect(body["model"] as? String == "deepseek-chat")
        #expect(body["stream"] as? Bool == true)
        let messages = body["messages"] as! [[String: Any]]
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "user")
        #expect(messages[0]["content"] as? String == "Hello")
        #expect(messages[1]["role"] as? String == "assistant")
        #expect(messages[1]["content"] as? String == "Hi there!")
    }

    @Test func parseTokenDeltaReturnsContent() {
        let service = DeepSeekService()
        let json = """
        {"choices":[{"delta":{"content":"Hello"}}]}
        """
        let result = service.parseDelta(json)
        #expect(result == "Hello")
    }

    @Test func parseDeltaWithEmptyChoicesReturnsNil() {
        let service = DeepSeekService()
        let json = """
        {"choices":[]}
        """
        let result = service.parseDelta(json)
        #expect(result == nil)
    }

    @Test func parseDeltaWithMalformedJSONReturnsNil() {
        let service = DeepSeekService()
        let result = service.parseDelta("not json")
        #expect(result == nil)
    }

    @Test func parseFinishReasonReturnsStop() {
        let service = DeepSeekService()
        let json = """
        {"choices":[{"finish_reason":"stop"}]}
        """
        let result = service.parseFinishReason(json)
        #expect(result == "stop")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug test 2>&1 | tail -20`
Expected: FAIL with "DeepSeekService not found"

- [ ] **Step 3: Write DeepSeekService implementation**

```swift
import Foundation

enum ChatEvent {
    case token(String)
    case done
    case error(String)
}

final class DeepSeekService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func streamChat(
        history: [Message],
        config: ClientConfig
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let request = buildRequest(history: history, config: config)
                    let (bytes, _) = try await session.bytes(for: request)
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonStr = String(line.dropFirst(6))
                        guard jsonStr != "[DONE]" else {
                            continuation.yield(.done)
                            continuation.finish()
                            return
                        }
                        if let delta = parseDelta(jsonStr) {
                            continuation.yield(.token(delta))
                        }
                        if let finishReason = parseFinishReason(jsonStr), finishReason == "stop" {
                            continuation.yield(.done)
                            continuation.finish()
                            return
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.yield(.error(error.localizedDescription))
                    continuation.finish()
                }
            }
        }
    }

    func buildRequest(history: [Message], config: ClientConfig) -> URLRequest {
        let url = URL(string: config.baseURL + "/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        let messages = history.map { msg -> [String: String] in
            ["role": msg.isFromMe ? "user" : "assistant", "content": msg.content]
        }

        let body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "stream": true,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    func parseDelta(_ jsonStr: String) -> String? {
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any],
              let content = delta["content"] as? String
        else { return nil }
        return content
    }

    func parseFinishReason(_ jsonStr: String) -> String? {
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let finishReason = first["finish_reason"] as? String
        else { return nil }
        return finishReason
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug test 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add WeSee/Services/DeepSeekService.swift WeSeeTests/DeepSeekServiceTests.swift
git commit -m "feat: add DeepSeekService with streaming support and tests"
```

---

### Task 3: Integrate DeepSeekService into ChatViewModel

**Files:**
- Modify: `WeSee/ViewModels/ChatViewModel.swift` (full rewrite)
- Modify: `WeSeeTests/ChatViewModelTests.swift` (add streaming tests)

- [ ] **Step 1: Rewrite ChatViewModel**

Replace entire content of `ChatViewModel.swift`:

```swift
import Foundation
import Observation
import SwiftData

@Observable
final class ChatViewModel {
    var messages: [Message] = []
    var selectedTag: Tag?
    var isSendingDisabled: Bool = false
    var errorMessage: String?
    var streamingContent: String = ""
    var isStreaming: Bool = false

    private var modelContext: ModelContext?
    private let deepSeekService: DeepSeekService

    init(deepSeekService: DeepSeekService = DeepSeekService()) {
        self.deepSeekService = deepSeekService
    }

    func configure(with context: ModelContext) {
        self.modelContext = context
        fetchMessages()
    }

    // MARK: - Messages

    func fetchMessages() {
        guard let context = modelContext else { return }
        var descriptor = FetchDescriptor<Message>(sortBy: [SortDescriptor(\.timestamp)])
        do {
            let fetched = try context.fetch(descriptor)
            if let tag = selectedTag {
                messages = fetched.filter { $0.tags.contains(where: { $0.id == tag.id }) }
            } else {
                messages = fetched
            }
        } catch {
            errorMessage = "加载消息失败"
        }
    }

    func addMessage(content: String, isFromMe: Bool, tags: [Tag] = []) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 5000 else { return }

        guard let context = modelContext else {
            let msg = Message(content: trimmed, isFromMe: isFromMe, tags: tags)
            messages.append(msg)
            return
        }

        let msg = Message(content: trimmed, isFromMe: isFromMe, tags: tags)
        context.insert(msg)
        try? context.save()
        fetchMessages()
    }

    // MARK: - Send with streaming

    func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 5000 else { return }

        addMessage(content: trimmed, isFromMe: true)
        isSendingDisabled = true
        isStreaming = true
        streamingContent = ""

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
                for try await event in deepSeekService.streamChat(
                    history: messages,
                    config: config
                ) {
                    await MainActor.run {
                        switch event {
                        case .token(let token):
                            self.streamingContent += token
                        case .done:
                            self.addMessage(content: self.streamingContent, isFromMe: false)
                            self.streamingContent = ""
                            self.isStreaming = false
                            self.isSendingDisabled = false
                        case .error(let msg):
                            self.errorMessage = msg
                            self.isStreaming = false
                            self.isSendingDisabled = false
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isStreaming = false
                    self.isSendingDisabled = false
                }
            }
        }
    }

    func toggleBookmark(_ message: Message) {
        guard let context = modelContext else { return }
        message.isBookmarked.toggle()
        try? context.save()
        fetchMessages()
    }

    func filterByTag(_ tag: Tag?) {
        selectedTag = tag
        fetchMessages()
    }

    func clearError() {
        errorMessage = nil
    }
}
```

- [ ] **Step 2: Update ChatViewModelTests**

Replace entire content of `ChatViewModelTests.swift`:

```swift
import Testing
@testable import WeSee

struct ChatViewModelTests {

    @Test func addMessageAppendsToMessages() {
        let viewModel = ChatViewModel()
        viewModel.addMessage(content: "Hello", isFromMe: true)
        #expect(viewModel.messages.count == 1)
        #expect(viewModel.messages.first?.content == "Hello")
    }

    @Test func addEmptyMessageIsIgnored() {
        let viewModel = ChatViewModel()
        viewModel.addMessage(content: "", isFromMe: true)
        viewModel.addMessage(content: "   ", isFromMe: true)
        #expect(viewModel.messages.isEmpty)
    }

    @Test func addWhitespaceOnlyMessageIsIgnored() {
        let viewModel = ChatViewModel()
        viewModel.addMessage(content: "\n\n", isFromMe: true)
        #expect(viewModel.messages.isEmpty)
    }

    @Test func isSendingDisabledBlocksRapidSend() {
        let viewModel = ChatViewModel()
        viewModel.sendMessage("msg1")
        #expect(viewModel.isSendingDisabled == true)
    }

    @Test func filterByTagUpdatesSelectedTag() {
        let viewModel = ChatViewModel()
        viewModel.filterByTag(nil)
        #expect(viewModel.selectedTag == nil)
    }

    @Test func clearErrorSetsErrorMessageToNil() {
        let viewModel = ChatViewModel()
        viewModel.errorMessage = "test error"
        viewModel.clearError()
        #expect(viewModel.errorMessage == nil)
    }

    @Test func sendMessageSetsStreamingContent() {
        let viewModel = ChatViewModel()
        viewModel.sendMessage("Hello")
        #expect(viewModel.isStreaming == true)
        #expect(viewModel.streamingContent == "")
    }

    @Test func sendMessageAppendsUserMessage() {
        let viewModel = ChatViewModel()
        viewModel.sendMessage("Hello")
        #expect(viewModel.messages.count == 1)
        #expect(viewModel.messages.first?.isFromMe == true)
        #expect(viewModel.messages.first?.content == "Hello")
    }
}
```

- [ ] **Step 3: Run tests to verify**

Run: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug test 2>&1 | tail -20`
Expected: ChatViewModelTests pass

- [ ] **Step 4: Commit**

```bash
git add WeSee/ViewModels/ChatViewModel.swift WeSeeTests/ChatViewModelTests.swift
git commit -m "feat: integrate DeepSeekService into ChatViewModel"
```

---

### Task 4: Simplify SidebarViewModel (remove remote client)

**Files:**
- Modify: `WeSee/ViewModels/SidebarViewModel.swift`

- [ ] **Step 1: Rewrite SidebarViewModel**

Replace entire content of `SidebarViewModel.swift`:

```swift
import Foundation
import Observation
import SwiftData

@Observable
final class SidebarViewModel {
    var tags: [Tag] = []
    var scheduledTasks: [ScheduledTask] = []

    private var modelContext: ModelContext?

    init() {}

    func configure(with context: ModelContext) {
        self.modelContext = context
        fetchTags()
        fetchScheduledTasks()
    }

    func fetchTags() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<Tag>(sortBy: [SortDescriptor(\.name)])
        tags = (try? context.fetch(descriptor)) ?? []
    }

    func fetchScheduledTasks() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<ScheduledTask>(sortBy: [SortDescriptor(\.title)])
        scheduledTasks = (try? context.fetch(descriptor)) ?? []
    }

    func createTag(name: String, colorHex: String = "#007AFF") {
        guard let context = modelContext else { return }
        let tag = Tag(name: name, colorHex: colorHex)
        context.insert(tag)
        try? context.save()
        fetchTags()
    }

    func toggleTask(_ task: ScheduledTask) {
        task.isEnabled.toggle()
        try? modelContext?.save()
        fetchScheduledTasks()
    }

    func createTask(type: TaskType, title: String, cronExpression: String) {
        guard let context = modelContext else { return }
        let task = ScheduledTask(type: type, title: title, cronExpression: cronExpression)
        context.insert(task)
        try? context.save()
        fetchScheduledTasks()
    }
}
```

- [ ] **Step 2: Commmit**

```bash
git add WeSee/ViewModels/SidebarViewModel.swift
git commit -m "refactor: remove RemoteClient dependency from SidebarViewModel"
```

---

### Task 5: Simplify ContentView (remove LiveRemoteClient)

**Files:**
- Modify: `WeSee/ContentView.swift`

- [ ] **Step 1: Rewrite ContentView**

Replace entire content of `ContentView.swift`:

```swift
import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var chatViewModel = ChatViewModel()
    @State private var sidebarViewModel = SidebarViewModel()

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

- [ ] **Step 2: Commit**

```bash
git add WeSee/ContentView.swift
git commit -m "refactor: remove LiveRemoteClient from ContentView"
```

---

### Task 6: Remove server and unused client files

**Files:**
- Remove: `../server/` (entire directory)
- Remove: `WeSee/Services/RemoteClient.swift`
- Remove: `WeSee/Services/LiveRemoteClient.swift`
- Remove: `WeSee/Models/DTO.swift`

- [ ] **Step 1: Remove files and commit**

```bash
cd /Users/haobenkun/Documents/workSpace/WeSee
rm -rf server/
cd client
rm WeSee/Services/RemoteClient.swift
rm WeSee/Services/LiveRemoteClient.swift
rm WeSee/Models/DTO.swift
git add -A
git commit -m "chore: remove server and unused client files (RemoteClient, LiveRemoteClient, DTO)"
```

---

### Task 7: Verify full build and tests

**Files:**
- No file changes, verification only

- [ ] **Step 1: Build client**

Run: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug build 2>&1 | tail -5`
Expected: ** BUILD SUCCEEDED **

- [ ] **Step 2: Run client tests**

Run: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug test 2>&1 | tail -20`
Expected: All tests pass
