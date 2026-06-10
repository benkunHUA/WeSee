# Agent Loop Design

## Overview

Refactor the current single-shot LLM call in `DeepSeekService.swift` into an agent loop pattern that supports LLM tool calling with iterative execution until completion.

## Architecture

```
client/WeSee/
├── Models/
│   ├── AgentTool.swift        # AgentTool protocol + ToolRegistry
│   └── AgentEvent.swift        # Rich event model for agent loop
├── Services/
│   ├── DeepSeekService.swift   # Pure API layer (supports tools param)
│   ├── AgentRunner.swift       # Agent loop orchestration
│   └── Tools/
│       ├── FileSystemTool.swift
│       └── ShellTool.swift
```

## Component Design

### Layer Responsibilities

- **AgentTool protocol** — Defines tool name, description, parameter JSON Schema, and async `execute` method. New tools require only implementing this protocol and registering with ToolRegistry.
- **AgentEvent** — Covers the full agent loop: `.thinking` (reasoning), `.toolCallStart` / `.toolCallResult` (tool execution), `.token` (streaming text), `.done` / `.error`.
- **DeepSeekService** — Pure HTTP communication. `buildRequest` adds `tools` parameter. Adds `parseToolCalls` to parse streaming tool_calls deltas. No orchestration logic.
- **AgentRunner** — Holds DeepSeekService + ToolRegistry + system prompt. Implements the loop: send request → receive tool_calls → execute tools → feed results back → repeat until LLM returns final text.

### AgentEvent Model

```swift
enum AgentEvent {
    case thinking(String)       // Model reasoning content
    case toolCallStart(id: String, name: String, arguments: [String: Any])
    case toolCallResult(id: String, name: String, result: String)
    case token(String)          // Streaming text token
    case done                   // Turn complete
    case error(String)          // Error occurred
}
```

### Agent Loop Flow

```
1. Send request (messages + tools + system_prompt)
2. Stream and parse response:
   - reasoning_content delta → yield .thinking
   - text content delta → yield .token
   - tool_calls delta → buffer, yield .toolCallStart when complete
3. If finish_reason is "tool_calls":
   - Execute each tool, yield .toolCallResult
   - Append assistant message (with tool_calls) + tool result messages to history
   - Go to step 1
4. If finish_reason is "stop" or no tool calls:
   - yield .done, finish
```

Key constraints:
- Max 10 loop rounds to prevent infinite loops
- `reasoning_content` delta (DeepSeek supports this) maps to `.thinking` event
- Tool execution errors yield `.toolCallResult` with error text, not `.error`

### AgentTool Protocol & ToolRegistry

```swift
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
    }
}

final class ToolRegistry {
    func register(_ tool: AgentTool)
    func get(name: String) -> AgentTool?
    var allTools: [AgentTool] { get }
    func encodeToAPIParams() -> [[String: Any]]
}
```

### Built-in Tools

- **FileSystemTool**: `read_file(path)`, `write_file(path, content)`, `list_directory(path)`
- **ShellTool**: `execute(command, workingDirectory?)`

### Extension Pattern

```swift
let newTool = WebSearchTool(apiKey: ...)
registry.register(newTool)
```

## Data Flow

```
ChatViewModel.sendMessage()
  → AgentRunner.run(history: messages, tools: registry, systemPrompt:)
  → AsyncThrowingStream<AgentEvent, Error>
  → ChatViewModel switches on AgentEvent to update UI
```

ChatViewModel needs to handle the richer AgentEvent type, showing tool call progress inline in the chat.

## Testing Strategy

- `DeepSeekServiceTests`: Test request building with tools, parsing tool_calls deltas
- `AgentRunnerTests`: Test loop logic with mock LLM service and mock tools
- `FileSystemToolTests`: Test file operations
- `ShellToolTests`: Test command execution (sandboxed)
- `ChatViewModelTests`: Update to handle AgentEvent instead of ChatEvent
