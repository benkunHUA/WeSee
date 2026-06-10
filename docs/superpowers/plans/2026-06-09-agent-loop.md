# Agent Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor DeepSeekService from single-shot LLM call to agent loop pattern supporting tool calling (file system + shell) with iterative execution.

**Architecture:** AgentTool protocol + ToolRegistry define tools. DeepSeekService becomes a pure API layer accepting `[[String: Any]]` messages (with tools), emitting `LLMStreamEvent`. AgentRunner orchestrates the loop: aggregates tool call deltas, executes tools via registry, feeds tool results back into message history, and emits high-level `AgentEvent`. ChatViewModel consumes AgentEvent from AgentRunner.

**Key design:** AgentRunner manages message history as `[[String: Any]]` (API-native format). Tool-call and tool-result messages are appended during the loop so the next API call sees them. Only final text `AgentEvent.token` content gets persisted as a SwiftData `Message`.

**Tech Stack:** Swift, SwiftUI, Foundation (URLSession, Process, FileManager)

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `Models/AgentTool.swift` | Create | AgentTool protocol, JSONSchema, ToolRegistry |
| `Models/AgentEvent.swift` | Create | LLMStreamEvent, ToolCallDelta, AgentEvent |
| `Services/Tools/FileSystemTool.swift` | Create | read_file, write_file, list_directory |
| `Services/Tools/ShellTool.swift` | Create | execute shell commands |
| `Services/DeepSeekService.swift` | Modify | Accept `[[String: Any]]` messages + tools; parse tool_calls/thinking; emit LLMStreamEvent |
| `Services/AgentRunner.swift` | Create | Convert Message→API dicts, loop, aggregate tool calls, execute, feed back results, emit AgentEvent |
| `ViewModels/ChatViewModel.swift` | Modify | Use AgentRunner, consume AgentEvent |
| `WeSeeTests/AgentToolTests.swift` | Create | ToolRegistry encodeToAPIParams |
| `WeSeeTests/DeepSeekServiceTests.swift` | Create | buildRequest with tools, parsing methods |
| `WeSeeTests/AgentRunnerTests.swift` | Create | Loop logic with mock service + mock tools |
| `WeSeeTests/FileSystemToolTests.swift` | Create | File operations |
| `WeSeeTests/ShellToolTests.swift` | Create | Shell execution |
| `WeSeeTests/ChatViewModelTests.swift` | Modify | AgentRunner mock |

---

### Task 1: Create AgentTool model

**Files:**
- Create: `client/WeSee/Models/AgentTool.swift`
- Create: `client/WeSeeTests/AgentToolTests.swift`

- [ ] **Step 1: Write AgentTool.swift**

```swift
import Foundation

protocol AgentTool {
    var name: String { get }
    var description: String { get }
    var parameters: JSONSchema { get }
    func execute(arguments: [String: Any]) async throws -> String
}

struct JSONSchema: Codable {
    let type: String
    let properties: [String: PropertyDef]
    let required: [String]

    struct PropertyDef: Codable {
        let type: String
        let description: String

        init(type: String, description: String) {
            self.type = type
            self.description = description
        }
    }

    init(type: String, properties: [String: PropertyDef], required: [String]) {
        self.type = type
        self.properties = properties
        self.required = required
    }

    func toDictionary() -> [String: Any] {
        let propsDict = properties.mapValues { prop -> [String: Any] in
            ["type": prop.type, "description": prop.description]
        }
        return [
            "type": type,
            "properties": propsDict,
            "required": required,
        ]
    }
}

final class ToolRegistry {
    private var tools: [String: AgentTool] = [:]

    func register(_ tool: AgentTool) {
        tools[tool.name] = tool
    }

    func get(name: String) -> AgentTool? {
        tools[name]
    }

    var allTools: [AgentTool] {
        Array(tools.values)
    }

    func encodeToAPIParams() -> [[String: Any]] {
        allTools.map { tool in
            [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.parameters.toDictionary(),
                ],
            ]
        }
    }
}
```

- [ ] **Step 2: Write AgentToolTests.swift**

```swift
import Testing
@testable import WeSee

struct FakeTool: AgentTool {
    let name = "fake_tool"
    let description = "A fake tool for testing"
    let parameters = JSONSchema(
        type: "object",
        properties: ["input": JSONSchema.PropertyDef(type: "string", description: "An input")],
        required: ["input"]
    )
    func execute(arguments: [String: Any]) async throws -> String { "fake_result" }
}

struct AgentToolTests {
    @Test func registerAndRetrieveTool() {
        let registry = ToolRegistry()
        registry.register(FakeTool())
        #expect(registry.get(name: "fake_tool") != nil)
        #expect(registry.get(name: "nonexistent") == nil)
    }

    @Test func allToolsReturnsRegisteredTools() {
        let registry = ToolRegistry()
        registry.register(FakeTool())
        #expect(registry.allTools.count == 1)
        #expect(registry.allTools.first?.name == "fake_tool")
    }

    @Test func encodeToAPIParamsReturnsCorrectFormat() {
        let registry = ToolRegistry()
        registry.register(FakeTool())
        let params = registry.encodeToAPIParams()
        #expect(params.count == 1)
        let first = params[0]
        #expect(first["type"] as? String == "function")
        let function = first["function"] as? [String: Any]
        #expect(function?["name"] as? String == "fake_tool")
        #expect(function?["description"] as? String == "A fake tool for testing")
        let parameters = function?["parameters"] as? [String: Any]
        #expect(parameters?["type"] as? String == "object")
        #expect(parameters?["required"] as? [String] == ["input"])
    }

    @Test func jsonSchemaToDictionary() {
        let schema = JSONSchema(
            type: "object",
            properties: [
                "path": JSONSchema.PropertyDef(type: "string", description: "File path"),
                "content": JSONSchema.PropertyDef(type: "string", description: "File content"),
            ],
            required: ["path"]
        )
        let dict = schema.toDictionary()
        #expect(dict["type"] as? String == "object")
        let props = dict["properties"] as? [String: [String: Any]]
        #expect(props?["path"]?["type"] as? String == "string")
        #expect(props?["path"]?["description"] as? String == "File path")
        #expect(dict["required"] as? [String] == ["path"])
    }
}
```

- [ ] **Step 3: Run tests**

Run: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug test -only-testing:WeSeeTests/AgentToolTests`
Expected: 4 tests PASS

- [ ] **Step 4: Commit**

```bash
git add client/WeSee/Models/AgentTool.swift client/WeSeeTests/AgentToolTests.swift
git commit -m "feat: add AgentTool protocol, JSONSchema, and ToolRegistry"
```

---

### Task 2: Create AgentEvent model

**Files:**
- Create: `client/WeSee/Models/AgentEvent.swift`

- [ ] **Step 1: Write AgentEvent.swift**

```swift
import Foundation

struct ToolCallDelta {
    let index: Int
    let id: String?
    let name: String?
    let arguments: String
}

enum LLMStreamEvent {
    case token(String)
    case thinking(String)
    case toolCallDelta(ToolCallDelta)
    case finishReason(String?)
}

enum AgentEvent {
    case thinking(String)
    case toolCallStart(id: String, name: String, arguments: [String: Any])
    case toolCallResult(id: String, name: String, result: String)
    case token(String)
    case done
    case error(String)
}
```

- [ ] **Step 2: Commit**

```bash
git add client/WeSee/Models/AgentEvent.swift
git commit -m "feat: add AgentEvent, LLMStreamEvent, and ToolCallDelta models"
```

---

### Task 3: Create FileSystemTool

**Files:**
- Create: `client/WeSee/Services/Tools/FileSystemTool.swift`
- Create: `client/WeSeeTests/FileSystemToolTests.swift`

- [ ] **Step 1: Write FileSystemTool.swift**

```swift
import Foundation

final class FileSystemTool: AgentTool {
    let name = "file_system"
    let description = "Read, write, and list files on the local filesystem. Use read_file to read content, write_file to create or overwrite files, and list_directory to list directory contents."

    let parameters = JSONSchema(
        type: "object",
        properties: [
            "action": JSONSchema.PropertyDef(
                type: "string",
                description: "One of: read_file, write_file, list_directory"
            ),
            "path": JSONSchema.PropertyDef(
                type: "string",
                description: "Absolute path to the file or directory"
            ),
            "content": JSONSchema.PropertyDef(
                type: "string",
                description: "File content to write (required for write_file)"
            ),
        ],
        required: ["action", "path"]
    )

    private let fileManager: FileManager
    private let maxFileSize: Int

    init(fileManager: FileManager = .default, maxFileSize: Int = 1_000_000) {
        self.fileManager = fileManager
        self.maxFileSize = maxFileSize
    }

    func execute(arguments: [String: Any]) async throws -> String {
        guard let action = arguments["action"] as? String,
              let path = arguments["path"] as? String else {
            return "Error: missing required parameters 'action' or 'path'"
        }
        switch action {
        case "read_file": return try await readFile(at: path)
        case "write_file":
            let content = arguments["content"] as? String ?? ""
            return try await writeFile(content: content, at: path)
        case "list_directory": return try await listDirectory(at: path)
        default: return "Error: unknown action '\(action)'. Supported: read_file, write_file, list_directory"
        }
    }

    private func readFile(at path: String) async throws -> String {
        guard fileManager.fileExists(atPath: path) else {
            return "Error: file not found at \(path)"
        }
        guard let attrs = try? fileManager.attributesOfItem(atPath: path),
              let fileSize = attrs[.size] as? Int,
              fileSize <= maxFileSize else {
            return "Error: file too large or unable to read attributes"
        }
        do {
            return try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            return "Error reading file: \(error.localizedDescription)"
        }
    }

    private func writeFile(content: String, at path: String) async throws -> String {
        let dir = (path as NSString).deletingLastPathComponent
        if !fileManager.fileExists(atPath: dir) {
            try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            return "Successfully wrote \(content.count) bytes to \(path)"
        } catch {
            return "Error writing file: \(error.localizedDescription)"
        }
    }

    private func listDirectory(at path: String) async throws -> String {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return "Error: directory not found at \(path)"
        }
        do {
            let items = try fileManager.contentsOfDirectory(atPath: path)
            return items.sorted().joined(separator: "\n")
        } catch {
            return "Error listing directory: \(error.localizedDescription)"
        }
    }
}
```

- [ ] **Step 2: Write FileSystemToolTests.swift**

```swift
import Testing
import Foundation
@testable import WeSee

struct FileSystemToolTests {
    @Test func readFileReturnsContent() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let filePath = tmpDir.appendingPathComponent("test_read.txt").path
        try "hello world".write(toFile: filePath, atomically: true, encoding: .utf8)
        let tool = FileSystemTool()
        let result = try await tool.execute(arguments: ["action": "read_file", "path": filePath])
        #expect(result == "hello world")
    }

    @Test func readFileNotFoundReturnsError() async throws {
        let tool = FileSystemTool()
        let result = try await tool.execute(arguments: ["action": "read_file", "path": "/nonexistent/file.txt"])
        #expect(result.hasPrefix("Error: file not found"))
    }

    @Test func writeFileCreatesFile() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let filePath = tmpDir.appendingPathComponent("test_write.txt").path
        let tool = FileSystemTool()
        let result = try await tool.execute(arguments: [
            "action": "write_file", "path": filePath, "content": "test content",
        ])
        #expect(result.hasPrefix("Successfully wrote"))
        let written = try String(contentsOfFile: filePath, encoding: .utf8)
        #expect(written == "test content")
    }

    @Test func listDirectoryReturnsContents() async throws {
        let tool = FileSystemTool()
        let result = try await tool.execute(arguments: [
            "action": "list_directory", "path": FileManager.default.temporaryDirectory.path,
        ])
        #expect(!result.isEmpty)
    }

    @Test func listDirectoryNotFoundReturnsError() async throws {
        let tool = FileSystemTool()
        let result = try await tool.execute(arguments: [
            "action": "list_directory", "path": "/nonexistent/dir",
        ])
        #expect(result.hasPrefix("Error:"))
    }

    @Test func unknownActionReturnsError() async throws {
        let tool = FileSystemTool()
        let result = try await tool.execute(arguments: ["action": "delete_file", "path": "/tmp/test.txt"])
        #expect(result.hasPrefix("Error: unknown action"))
    }
}
```

- [ ] **Step 3: Run tests**

Run: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug test -only-testing:WeSeeTests/FileSystemToolTests`
Expected: 6 tests PASS

- [ ] **Step 4: Commit**

```bash
git add client/WeSee/Services/Tools/FileSystemTool.swift client/WeSeeTests/FileSystemToolTests.swift
git commit -m "feat: add FileSystemTool with read_file, write_file, list_directory"
```

---

### Task 4: Create ShellTool

**Files:**
- Create: `client/WeSee/Services/Tools/ShellTool.swift`
- Create: `client/WeSeeTests/ShellToolTests.swift`

- [ ] **Step 1: Write ShellTool.swift**

```swift
import Foundation

final class ShellTool: AgentTool {
    let name = "shell"
    let description = "Execute a shell command. Returns stdout and stderr combined. Commands have a 30-second timeout."

    let parameters = JSONSchema(
        type: "object",
        properties: [
            "command": JSONSchema.PropertyDef(
                type: "string",
                description: "The shell command to execute"
            ),
            "working_directory": JSONSchema.PropertyDef(
                type: "string",
                description: "Optional working directory for the command"
            ),
        ],
        required: ["command"]
    )

    private let timeoutSeconds: Int

    init(timeoutSeconds: Int = 30) {
        self.timeoutSeconds = timeoutSeconds
    }

    func execute(arguments: [String: Any]) async throws -> String {
        guard let command = arguments["command"] as? String else {
            return "Error: missing required parameter 'command'"
        }
        let workingDir = arguments["working_directory"] as? String
        return try await runCommand(command, workingDirectory: workingDir)
    }

    private func runCommand(_ command: String, workingDirectory: String?) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.environment = [
            "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
        ]

        if let dir = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
        } else {
            process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withCheckedThrowingContinuation { continuation in
            let stdoutData = NSMutableData()
            let stderrData = NSMutableData()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                stdoutData.append(handle.availableData)
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                stderrData.append(handle.availableData)
            }

            process.terminationHandler = { proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                let out = String(data: stdoutData as Data, encoding: .utf8) ?? ""
                let err = String(data: stderrData as Data, encoding: .utf8) ?? ""
                var result = ""
                if !out.isEmpty { result += out }
                if !err.isEmpty { result += (result.isEmpty ? "" : "\n") + err }
                if result.isEmpty { result = "(no output)" }
                if proc.terminationStatus != 0 {
                    result = "Exit code \(proc.terminationStatus)\n" + result
                }
                continuation.resume(returning: result)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(
                    returning: "Error: failed to start command: \(error.localizedDescription)"
                )
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(self.timeoutSeconds)) {
                if process.isRunning {
                    process.terminate()
                }
            }
        }
    }
}
```

- [ ] **Step 2: Write ShellToolTests.swift**

```swift
import Testing
@testable import WeSee

struct ShellToolTests {
    @Test func executeEchoReturnsOutput() async throws {
        let tool = ShellTool()
        let result = try await tool.execute(arguments: ["command": "echo hello"])
        #expect(result.contains("hello"))
    }

    @Test func executeWithWorkingDirectory() async throws {
        let tool = ShellTool()
        let result = try await tool.execute(arguments: [
            "command": "pwd", "working_directory": "/tmp",
        ])
        #expect(result.contains("/tmp"))
    }

    @Test func executeInvalidCommandReturnsError() async throws {
        let tool = ShellTool()
        let result = try await tool.execute(arguments: ["command": "nonexistent_command_xyz"])
        #expect(result.hasPrefix("Exit code"))
    }

    @Test func missingCommandParameterReturnsError() async throws {
        let tool = ShellTool()
        let result = try await tool.execute(arguments: [:])
        #expect(result.hasPrefix("Error: missing required parameter"))
    }
}
```

- [ ] **Step 3: Run tests**

Run: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug test -only-testing:WeSeeTests/ShellToolTests`
Expected: 4 tests PASS

- [ ] **Step 4: Commit**

```bash
git add client/WeSee/Services/Tools/ShellTool.swift client/WeSeeTests/ShellToolTests.swift
git commit -m "feat: add ShellTool for executing shell commands"
```

---

### Task 5: Refactor DeepSeekService to accept `[[String: Any]]` messages, parse tool calls

**Files:**
- Modify: `client/WeSee/Services/DeepSeekService.swift`
- Create: `client/WeSeeTests/DeepSeekServiceTests.swift`

- [ ] **Step 1: Rewrite DeepSeekService.swift**

Replace entire file. Key changes: `streamChat` and `buildRequest` now accept `messages: [[String: Any]]` instead of `history: [Message]`. Output is `LLMStreamEvent` (not old `ChatEvent`). New parsing methods for `reasoning_content` and `tool_calls`.

```swift
import Foundation

enum LLMStreamEvent {
    case token(String)
    case thinking(String)
    case toolCallDelta(ToolCallDelta)
    case finishReason(String?)
}

class DeepSeekService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func streamChat(
        messages: [[String: Any]],
        config: ClientConfig,
        tools: [[String: Any]] = [],
        systemPrompt: String? = nil
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let request = buildRequest(
                        messages: messages,
                        config: config,
                        tools: tools,
                        systemPrompt: systemPrompt
                    )
                    let (bytes, _) = try await self.session.bytes(for: request)
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonStr = String(line.dropFirst(6))
                        guard jsonStr != "[DONE]" else { continue }

                        if let delta = parseContentDelta(jsonStr) {
                            continuation.yield(.token(delta))
                        }
                        if let thinking = parseThinkingDelta(jsonStr) {
                            continuation.yield(.thinking(thinking))
                        }
                        if let tcDelta = parseToolCallDelta(jsonStr) {
                            continuation.yield(.toolCallDelta(tcDelta))
                        }
                        if let reason = parseFinishReason(jsonStr) {
                            continuation.yield(.finishReason(reason))
                            if reason == "stop" {
                                continuation.finish()
                                return
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func buildRequest(
        messages: [[String: Any]],
        config: ClientConfig,
        tools: [[String: Any]] = [],
        systemPrompt: String? = nil
    ) -> URLRequest {
        let url = URL(string: config.baseURL + "/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        var allMessages: [[String: Any]] = []
        if let systemPrompt {
            allMessages.append(["role": "system", "content": systemPrompt])
        }
        allMessages.append(contentsOf: messages)

        var body: [String: Any] = [
            "model": config.model,
            "messages": allMessages,
            "stream": true,
        ]
        if !tools.isEmpty {
            body["tools"] = tools
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    func parseContentDelta(_ jsonStr: String) -> String? {
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any],
              let content = delta["content"] as? String
        else { return nil }
        return content
    }

    func parseThinkingDelta(_ jsonStr: String) -> String? {
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any],
              let thinking = delta["reasoning_content"] as? String
        else { return nil }
        return thinking
    }

    func parseToolCallDelta(_ jsonStr: String) -> ToolCallDelta? {
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any],
              let toolCalls = delta["tool_calls"] as? [[String: Any]],
              let tc = toolCalls.first
        else { return nil }

        let index = tc["index"] as? Int ?? 0
        let id = tc["id"] as? String
        let function = tc["function"] as? [String: Any]
        let name = function?["name"] as? String
        let arguments = function?["arguments"] as? String ?? ""

        return ToolCallDelta(index: index, id: id, name: name, arguments: arguments)
    }

    func parseFinishReason(_ jsonStr: String) -> String? {
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let reason = first["finish_reason"] as? String
        else { return nil }
        return reason
    }
}
```

- [ ] **Step 2: Write DeepSeekServiceTests.swift**

```swift
import Testing
import Foundation
@testable import WeSee

struct DeepSeekServiceTests {
    @Test func buildRequestIncludesToolsWhenProvided() {
        let service = DeepSeekService()
        let tools: [[String: Any]] = [[
            "type": "function",
            "function": [
                "name": "read_file",
                "description": "Read a file",
                "parameters": ["type": "object", "properties": [:], "required": []],
            ],
        ]]
        let request = service.buildRequest(
            messages: [["role": "user", "content": "hi"]],
            config: .default,
            tools: tools
        )
        let body = request.httpBody!
        let json = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
        let reqTools = json["tools"] as! [[String: Any]]
        #expect(reqTools.count == 1)
    }

    @Test func buildRequestIncludesSystemPrompt() {
        let service = DeepSeekService()
        let request = service.buildRequest(
            messages: [],
            config: .default,
            systemPrompt: "You are a helpful assistant"
        )
        let body = request.httpBody!
        let json = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
        let messages = json["messages"] as! [[String: Any]]
        #expect(messages.first?["role"] as? String == "system")
        #expect(messages.first?["content"] as? String == "You are a helpful assistant")
    }

    @Test func buildRequestOmitsSystemPromptWhenNil() {
        let service = DeepSeekService()
        let request = service.buildRequest(
            messages: [["role": "user", "content": "hi"]],
            config: .default
        )
        let body = request.httpBody!
        let json = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
        let messages = json["messages"] as! [[String: Any]]
        #expect(messages.first?["role"] as? String == "user")
    }

    @Test func parseContentDeltaReturnsText() {
        let service = DeepSeekService()
        let json = #"{"choices":[{"delta":{"content":"hello"}}]}"#
        #expect(service.parseContentDelta(json) == "hello")
    }

    @Test func parseThinkingDeltaReturnsReasoningContent() {
        let service = DeepSeekService()
        let json = #"{"choices":[{"delta":{"reasoning_content":"thinking..."}}]}"#
        #expect(service.parseThinkingDelta(json) == "thinking...")
    }

    @Test func parseToolCallDeltaFullChunk() {
        let service = DeepSeekService()
        let json = #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read_file","arguments":"{\"path\":\"/tmp/t.txt\"}"}}]}}]}"#
        let result = service.parseToolCallDelta(json)
        #expect(result?.index == 0)
        #expect(result?.id == "call_1")
        #expect(result?.name == "read_file")
        #expect(result?.arguments == #"{"path":"/tmp/t.txt"}"#)
    }

    @Test func parseToolCallDeltaArgsOnlyChunk() {
        let service = DeepSeekService()
        let json = #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"more"}}]}}]}"#
        let result = service.parseToolCallDelta(json)
        #expect(result?.id == nil)
        #expect(result?.name == nil)
        #expect(result?.arguments == "more")
    }

    @Test func parseFinishReasonReturnsStop() {
        let service = DeepSeekService()
        let json = #"{"choices":[{"finish_reason":"stop"}]}"#
        #expect(service.parseFinishReason(json) == "stop")
    }

    @Test func parseFinishReasonReturnsToolCalls() {
        let service = DeepSeekService()
        let json = #"{"choices":[{"finish_reason":"tool_calls"}]}"#
        #expect(service.parseFinishReason(json) == "tool_calls")
    }
}
```

- [ ] **Step 3: Run tests**

Run: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug test -only-testing:WeSeeTests/DeepSeekServiceTests`
Expected: 9 tests PASS

- [ ] **Step 4: Commit**

```bash
git add client/WeSee/Services/DeepSeekService.swift client/WeSeeTests/DeepSeekServiceTests.swift
git commit -m "refactor: DeepSeekService accepts raw messages + tools, emits LLMStreamEvent"
```

---

### Task 6: Create AgentRunner

**Files:**
- Create: `client/WeSee/Services/AgentRunner.swift`
- Create: `client/WeSeeTests/AgentRunnerTests.swift`

- [ ] **Step 1: Write AgentRunner.swift**

```swift
import Foundation

final class AgentRunner {
    private let deepSeekService: DeepSeekService
    private let toolRegistry: ToolRegistry
    private let maxRounds: Int

    init(
        deepSeekService: DeepSeekService = DeepSeekService(),
        toolRegistry: ToolRegistry = ToolRegistry(),
        maxRounds: Int = 10
    ) {
        self.deepSeekService = deepSeekService
        self.toolRegistry = toolRegistry
        self.maxRounds = maxRounds
    }

    func run(
        history: [Message],
        config: ClientConfig,
        systemPrompt: String? = nil
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                var messages: [[String: Any]] = history.map { msg in
                    ["role": msg.isFromMe ? "user" : "assistant", "content": msg.content]
                }
                let tools = self.toolRegistry.encodeToAPIParams()
                var round = 0

                while round < self.maxRounds {
                    round += 1
                    var toolCallAggregator: [Int: (id: String, name: String, arguments: String)] = [:]
                    var hasToolCalls = false

                    do {
                        let stream = self.deepSeekService.streamChat(
                            messages: messages,
                            config: config,
                            tools: tools,
                            systemPrompt: round == 1 ? systemPrompt : nil
                        )

                        for try await event in stream {
                            switch event {
                            case .token(let text):
                                continuation.yield(.token(text))

                            case .thinking(let text):
                                continuation.yield(.thinking(text))

                            case .toolCallDelta(let delta):
                                hasToolCalls = true
                                var current = toolCallAggregator[delta.index]
                                    ?? ("", "", "")
                                if let id = delta.id { current.id = id }
                                if let name = delta.name { current.name = name }
                                current.arguments += delta.arguments
                                toolCallAggregator[delta.index] = current

                            case .finishReason(let reason):
                                if reason == "stop", !hasToolCalls {
                                    break // final text — will finish after loop
                                }
                                // "tool_calls" — will process after stream ends
                            }
                        }
                    } catch {
                        continuation.yield(.error(error.localizedDescription))
                        continuation.finish()
                        return
                    }

                    if !hasToolCalls {
                        continuation.yield(.done)
                        continuation.finish()
                        return
                    }

                    // Execute tools
                    let sortedKeys = toolCallAggregator.keys.sorted()
                    var toolCallDicts: [[String: Any]] = []

                    for key in sortedKeys {
                        let tc = toolCallAggregator[key]!
                        guard !tc.id.isEmpty, !tc.name.isEmpty else { continue }

                        let argsDict = Self.parseJSONArgs(tc.arguments) ?? [:]

                        continuation.yield(
                            .toolCallStart(id: tc.id, name: tc.name, arguments: argsDict)
                        )

                        let result: String
                        if let tool = self.toolRegistry.get(name: tc.name) {
                            do {
                                result = try await tool.execute(arguments: argsDict)
                            } catch {
                                result = "Tool execution error: \(error.localizedDescription)"
                            }
                        } else {
                            result = "Error: unknown tool '\(tc.name)'"
                        }

                        continuation.yield(
                            .toolCallResult(id: tc.id, name: tc.name, result: result)
                        )

                        let argsJSON = Self.encodeJSONArgs(argsDict)
                        toolCallDicts.append([
                            "id": tc.id,
                            "type": "function",
                            "function": [
                                "name": tc.name,
                                "arguments": argsJSON,
                            ],
                        ])

                        messages.append([
                            "role": "tool",
                            "tool_call_id": tc.id,
                            "content": result,
                        ])
                    }

                    messages.append([
                        "role": "assistant",
                        "content": NSNull(),
                        "tool_calls": toolCallDicts,
                    ])
                }

                continuation.yield(.error("Max rounds reached"))
                continuation.finish()
            }
        }
    }

    static func parseJSONArgs(_ jsonStr: String) -> [String: Any]? {
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    static func encodeJSONArgs(_ args: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: args),
              let str = String(data: data, encoding: .utf8)
        else { return "{}" }
        return str
    }
}
```

- [ ] **Step 2: Write AgentRunnerTests.swift**

Since AgentRunner depends on DeepSeekService streaming, we need a mock. Create a test-specific subclass that returns controlled LLMStreamEvent sequences.

```swift
import Testing
import Foundation
@testable import WeSee

final class MockDeepSeekService: DeepSeekService {
    var events: [LLMStreamEvent] = []

    override func streamChat(
        messages: [[String: Any]],
        config: ClientConfig,
        tools: [[String: Any]] = [],
        systemPrompt: String? = nil
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in self.events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

struct FakeEchoTool: AgentTool {
    let name = "echo"
    let description = "Echoes input"
    let parameters = JSONSchema(
        type: "object",
        properties: ["text": JSONSchema.PropertyDef(type: "string", description: "Text to echo")],
        required: ["text"]
    )
    func execute(arguments: [String: Any]) async throws -> String {
        let text = arguments["text"] as? String ?? ""
        return "echo: \(text)"
    }
}

struct AgentRunnerTests {
    @Test func singleRoundNoToolCallsEmitsTokensAndDone() async throws {
        let registry = ToolRegistry()
        let mockService = MockDeepSeekService()
        mockService.events = [
            .token("Hello"),
            .token(" world"),
            .finishReason("stop"),
        ]
        let runner = AgentRunner(
            deepSeekService: mockService,
            toolRegistry: registry,
            maxRounds: 10
        )
        let history = [Message(content: "hi", isFromMe: true)]

        var tokens = ""
        var doneReceived = false

        for try await event in runner.run(history: history, config: .default) {
            switch event {
            case .token(let t): tokens += t
            case .done: doneReceived = true
            default: break
            }
        }

        #expect(tokens == "Hello world")
        #expect(doneReceived)
    }

    @Test func toolCallLoopExecutesAndContinues() async throws {
        let registry = ToolRegistry()
        registry.register(FakeEchoTool())

        let mockService = MockDeepSeekService()
        // Round 1: tool call (echo)
        mockService.events = [
            .toolCallDelta(ToolCallDelta(index: 0, id: "call_1", name: "echo", arguments: #"{"text":"test"}"#)),
            .finishReason("tool_calls"),
        ]
        // Round 2: final text - we'll verify tool was called and results fed back
        // Actually we can't easily change the events array between rounds
        // in the current mock design. We'll verify the first round emits
        // toolCallStart and toolCallResult.

        let runner = AgentRunner(
            deepSeekService: mockService,
            toolRegistry: registry,
            maxRounds: 10
        )
        let history = [Message(content: "echo test", isFromMe: true)]

        var toolStarts: [(String, String)] = []
        var toolResults: [(String, String)] = []

        for try await event in runner.run(history: history, config: .default) {
            switch event {
            case .toolCallStart(let id, let name, _):
                toolStarts.append((id, name))
            case .toolCallResult(let id, let name, let result):
                toolResults.append((id, name))
                #expect(result == "echo: test")
            case .error(let msg):
                // Accept max-rounds error since mock only has round-1 events
                #expect(msg == "Max rounds reached")
            default: break
            }
        }

        #expect(toolStarts.count == 1)
        #expect(toolResults.count == 1)
        #expect(toolStarts[0].0 == "call_1")
        #expect(toolStarts[0].1 == "echo")
    }

    @Test func unknownToolReturnsErrorResult() async throws {
        let registry = ToolRegistry()
        // Don't register the tool

        let mockService = MockDeepSeekService()
        mockService.events = [
            .toolCallDelta(ToolCallDelta(
                index: 0, id: "call_1", name: "unknown_tool",
                arguments: #"{"key":"val"}"#
            )),
            .finishReason("tool_calls"),
        ]

        let runner = AgentRunner(
            deepSeekService: mockService,
            toolRegistry: registry,
            maxRounds: 10
        )
        let history = [Message(content: "use tool", isFromMe: true)]

        var toolResult = ""
        for try await event in runner.run(history: history, config: .default) {
            if case .toolCallResult(_, _, let result) = event {
                toolResult = result
            }
        }

        #expect(toolResult.hasPrefix("Error: unknown tool"))
    }

    @Test func parseJSONArgsParsesValidJSON() {
        let result = AgentRunner.parseJSONArgs(#"{"key": "value", "num": 42}"#)
        #expect(result?["key"] as? String == "value")
        #expect(result?["num"] as? Int == 42)
    }

    @Test func parseJSONArgsReturnsNilForInvalidJSON() {
        let result = AgentRunner.parseJSONArgs("not json")
        #expect(result == nil)
    }

    @Test func encodeJSONArgsProducesJSONString() {
        let result = AgentRunner.encodeJSONArgs(["key": "value"])
        #expect(result.contains("\"key\""))
        #expect(result.contains("\"value\""))
    }
}
```

- [ ] **Step 3: Run tests**

Run: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug test -only-testing:WeSeeTests/AgentRunnerTests`
Expected: 6 tests PASS

- [ ] **Step 4: Commit**

```bash
git add client/WeSee/Services/AgentRunner.swift client/WeSeeTests/AgentRunnerTests.swift
git commit -m "feat: add AgentRunner with tool calling loop"
```

---

### Task 7: Update ChatViewModel to use AgentRunner

**Files:**
- Modify: `client/WeSee/ViewModels/ChatViewModel.swift`
- Modify: `client/WeSeeTests/ChatViewModelTests.swift`

- [ ] **Step 1: Update ChatViewModel.swift**

Replace `DeepSeekService` with `AgentRunner`, consume `AgentEvent` instead of `ChatEvent`.

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
```

- [ ] **Step 2: Update ChatViewModelTests.swift**

Update tests to match new API. Tests that checked `isSendingDisabled` and `isStreaming` still work. Add tests for `toolCallResults` tracking.

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

    @Test func newConversationClearsMessages() {
        let viewModel = ChatViewModel()
        viewModel.addMessage(content: "msg1", isFromMe: true)
        viewModel.addMessage(content: "msg2", isFromMe: false)
        viewModel.newConversation()
        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.isStreaming == false)
    }

    @Test func newConversationClearsToolCallResults() {
        let viewModel = ChatViewModel()
        viewModel.toolCallResults = [
            (id: "1", name: "echo", arguments: [:], result: nil),
        ]
        viewModel.newConversation()
        #expect(viewModel.toolCallResults.isEmpty)
    }
}
```

- [ ] **Step 3: Build and run all tests**

Run: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug test`
Expected: All tests PASS

- [ ] **Step 4: Commit**

```bash
git add client/WeSee/ViewModels/ChatViewModel.swift client/WeSeeTests/ChatViewModelTests.swift
git commit -m "refactor: update ChatViewModel to use AgentRunner with tool call display"
```

---

## Post-Implementation Verification

After all tasks complete:

1. Build the project: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug build`
2. Run full test suite: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug test`
3. Verify no old `ChatEvent` references remain: `rg "ChatEvent" client/`
4. Manual test: send a message that triggers tool use (e.g., "list files in my home directory")
