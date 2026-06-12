# Mobile Access Design

> **Goal:** Enable mobile phone access to the desktop agent via Tailscale VPN + embedded HTTP server with SSE streaming. The phone acts as a remote display/input for the same agent running on the Mac, sharing the same conversation state.

**Architecture:** Tailscale WireGuard VPN creates a secure virtual network between phone and Mac. An embedded HTTP server (Network.framework, zero-dependency) listens on `127.0.0.1` and serves a web-based chat UI. Phone connects via Tailscale virtual IP and chats through the browser.

**Tech Stack:** Swift (Network.framework), HTML/CSS/JS (vanilla, no framework), Tailscale (external VPN)

---

## Architecture

```
Phone Browser ──HTTP──→ Tailscale VPN ──→ 127.0.0.1:8080 (Mac) ──→ ChatSession ──→ AgentRunner ──→ DeepSeek API
                                                    │
                                          Desktop SwiftUI UI (same ChatSession)
```

Key design decisions:

- **Same ChatSession instance** shared between local SwiftUI and remote HTTP — both see the same conversation
- **Tailscale over Cloudflare Tunnel** — zero ports exposed to internet, WireGuard encryption, virtual IP addressing
- **SSE not WebSocket** — Chat is request-response + streaming reply; SSE is simpler, aligns with existing LLM streaming patterns
- **Network.framework not Vapor/SwiftNIO** — zero external dependencies, lightweight, sufficient for single-user HTTP

---

## Design Patterns

| Pattern | Application |
|---------|------------|
| **Mediator** | `ChatSession` is the single source of truth for chat state, mediating between UI layers and AgentRunner |
| **Observer** | `ChatSession.events` is an `AsyncStream<SessionEvent>` shared by all consumers |
| **Adapter** | `HttpServer` adapts ChatSession events to SSE format; `ChatViewModel` adapts them to `@Observable` state |
| **Dependency Inversion** | `ChatSession` depends on `AgentRunnerProtocol`, not concrete AgentRunner |
| **Strategy** | Each tool implements `AgentTool` protocol — unchanged, but ChatSession now owns ToolRegistry |

---

## Component Design

### New Files

```
client/WeSee/
├── Services/
│   ├── ChatSession.swift       # 新建：聊天核心 Mediator
│   └── HttpServer.swift         # 新建：HTTP 服务器 + SSEAdapter
├── Web/                         # 新建：手机端 Web UI
│   ├── index.html
│   └── app.js
```

### Modified Files

| File | Change |
|------|--------|
| `ChatViewModel.swift` | Remove business logic, become thin `@Observable` wrapper around ChatSession |
| `WeSeeApp.swift` | Create ChatSession, start HttpServer on launch |
| `ContentView.swift` | Pass ChatSession (via Environment or init) instead of creating WorkspaceManager directly |

### 1. ChatSession (Mediator) — `Services/ChatSession.swift`

Extracts chat business logic from ChatViewModel. Framework-agnostic — no SwiftUI, no SwiftData imports.

```swift
protocol ChatSessionProtocol {
    var messages: [Message] { get }
    var streamingContent: String { get }
    var thinkingContent: String { get }
    var isStreaming: Bool { get }
    var toolCallResults: [(id: String, name: String, args: [String: Any], result: String?)] { get }
    var events: AsyncStream<SessionEvent> { get }

    func send(_ text: String) async
    func newConversation()
    func configure(with modelContext: ModelContext)
    func fetchMessages()
}

enum SessionEvent {
    case token(String)
    case thinking(String)
    case toolCallStart(id: String, name: String, arguments: [String: Any])
    case toolCallResult(id: String, name: String, result: String)
    case done
    case error(String)
}
```

Implementation (`ChatSessionImpl`):
- Holds `AgentRunner`, `SystemPromptBuilder`, `ConfigLoader` references
- `send()`: adds user message → calls `agentRunner.run()` → yields SessionEvents via AsyncStream continuation → adds AI message on `.done`
- `newConversation()`: clears in-memory messages
- All state mutations are serialized to `@MainActor` (all consumers are on main actor)
- `events` is a multicasted AsyncStream using `AsyncStream.makeStream()` + `continuation.yield()`

### 2. HttpServer (Adapter) — `Services/HttpServer.swift`

Uses `NWListener` from Network.framework. Zero external dependencies.

```swift
final class HttpServer {
    init(port: UInt16, chatSession: ChatSessionProtocol)
    func start() throws
    func stop()
}
```

**Endpoints:**

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | Serve `index.html` (static file) |
| GET | `/app.js` | Serve JavaScript client |
| GET | `/api/messages` | Return `{ "messages": [...] }` JSON |
| POST | `/api/chat` | SSE stream — body `{"content":"..."}` → AgentEvent → SSE text |
| POST | `/api/new-conversation` | Clear conversation |

**SSE format (`/api/chat`):**

```
data: {"type":"token","data":"你"}

data: {"type":"thinking","data":"让我想想..."}

data: {"type":"toolCall","id":"call_1","name":"shell","arguments":{...}}

data: {"type":"toolResult","id":"call_1","name":"shell","result":"..."}

data: {"type":"done"}

data: {"type":"error","data":"错误信息"}
```

**Implementation notes:**
- Simple HTTP/1.1 parser for request line + headers (no URL parsing library needed — routes are fixed)
- Content-Type header routing: `text/event-stream` for SSE, `application/json` for REST
- Connection: keep-alive for SSE, close for static/REST
- Port config in `~/.config/wesee/config.json` under `httpPort`, default `8080`
- Only binds to `127.0.0.1` — NOT `0.0.0.0` — so only local and Tailscale VPN can reach it

### 3. ChatViewModel Changes

ChatViewModel becomes a thin SwiftUI adapter:

```swift
@Observable
final class ChatViewModel {
    // @Observable state for SwiftUI binding
    var messages: [Message] = []
    var streamingContent: String = ""
    var thinkingContent: String = ""
    var isStreaming: Bool = false
    var isSendingDisabled: Bool = false
    var errorMessage: String?
    var toolCallResults: [(id: String, name: String, arguments: [String: Any], result: String?)] = []

    private let session: ChatSessionProtocol
    private var eventTask: Task<Void, Never>?

    init(session: ChatSessionProtocol) {
        self.session = session
        observeEvents()
    }

    // Mirror session state to @Observable properties
    private func observeEvents() { ... }

    func sendMessage(_ text: String) { Task { await session.send(text) } }
    func newConversation() { session.newConversation() }
    func fetchMessages() { session.fetchMessages() }
}
```

### 4. Web UI — `Web/`

Vanilla JS, no framework. Single file for HTML, single file for JS.

**index.html** — Minimal responsive layout:
- Chat message list (scrollable)
- Streaming message bubble (updates in real-time via EventSource)
- Thinking/reasoning collapsible block
- Tool call status indicators
- Input bar with send button
- New conversation button
- Error banner

**app.js** — Core logic:
- `EventSource` for SSE consumption
- `fetch()` for POST to `/api/chat`, `/api/new-conversation`
- DOM manipulation for message rendering (no virtual DOM needed for this scale)
- Auto-scroll to bottom on new messages
- Mobile-friendly: viewport meta, touch-optimized input, safe area insets

### 5. WeSeeApp Changes

```swift
@main
struct WeSeeApp: App {
    let container: ModelContainer
    let chatSession: ChatSessionImpl
    let httpServer: HttpServer

    init() {
        // ... create ModelContainer ...
        let config = (try? ConfigLoader.load()) ?? ClientConfig.default
        let wm = WorkspaceManager()
        chatSession = ChatSessionImpl(workspaceManager: wm, config: config)
        httpServer = HttpServer(port: config.httpPort, chatSession: chatSession)
        try? httpServer.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(chatSession: chatSession)
        }
        .modelContainer(container)
    }
}
```

---

## Data Flow

### Local Chat (refactored)

```
User input → ChatView → ChatViewModel.sendMessage()
  → ChatSession.send() → AgentRunner.run()
  → AgentEvent stream → ChatSession multicasts SessionEvent
  → ChatViewModel.observeEvents() updates @Observable state
  → SwiftUI re-renders
```

### Remote Chat (new)

```
Phone browser:
  1. Page load → GET / → index.html + app.js
  2. Init → GET /api/messages → render history
  3. User types → POST /api/chat {"content":"..."}
     → HttpServer calls chatSession.send()
     → ChatSession multicasts SessionEvent
     → SSEAdapter converts to SSE text
     → HTTP response body (chunked, text/event-stream)
     → phone EventSource parses → DOM updates

  4. New conversation → POST /api/new-conversation
     → chatSession.newConversation() → clears state
```

### Key flow: Local + Remote Sharing Same State

```
Time  T0: Phone sends "列出当前目录文件" → POST /api/chat
          ChatSession.send() → streamingContent = "", isStreaming = true
          Desktop UI re-renders (shows streaming)
          Phone shows streaming via SSE

Time  T1: Agent calls shell tool "ls"
          ChatSession yields .toolCallStart → .toolCallResult
          Desktop: inline tool call UI updates
          Phone: SSE "toolCall" + "toolResult" events → UI updates

Time  T2: Agent streams reply tokens
          ChatSession yields .token("当前目录包含...")
          Desktop: message bubble streams
          Phone: SSE "token" events → live text rendering

Time  T3: Agent done
          ChatSession yields .done, saves AI message
          Desktop: final message, isStreaming = false
          Phone: SSE "done" → finalize message, enable input
```

---

## Configuration

`~/.config/wesee/config.json` new field:

```json
{
    "apiKey": "sk-xxx",
    "baseURL": "https://api.deepseek.com",
    "model": "deepseek-v4-pro",
    "enableThinking": true,
    "httpPort": 8080
}
```

| Field | Default | Description |
|-------|---------|-------------|
| `httpPort` | `8080` | HTTP server port on 127.0.0.1 |

---

## Error Handling

| Scenario | Desktop Behavior | Phone Behavior |
|----------|-----------------|---------------|
| Config missing | ChatViewModel.errorMessage (existing) | SSE `{"type":"error","data":"..."}` |
| DeepSeek API error | AgentEvent.error → ChatViewModel.errorMessage | SSE error → show banner |
| HTTP port in use | HttpServer.start() logs error, app continues (desktop works) | Phone can't connect → browser shows connection error |
| Tool execution error | AgentEvent.toolCallResult with error text (existing) | SSE toolResult with error → show inline |
| Phone disconnects mid-stream | SSE response is cancelled; ChatSession continues processing; desktop UI unaffected | Browser reconnects, GET /api/messages to catch up |
| Tailscale disconnected | N/A (Mac side unaffected) | Browser shows connection error until VPN reconnects |
| Phone sends empty/oversized message | HttpServer validates: max 5000 chars, non-empty | 400 Bad Request JSON |

---

## Testing Strategy

### Unit Tests

- `ChatSessionTests`: Test send(), newConversation(), event yielding with mock AgentRunner
- `HttpServerTests`: Start server on random port, test each endpoint with URLSession
- `SSEAdapterTests`: Verify AgentEvent → SSE text conversion
- `ChatViewModelTests`: Update to use ChatSessionProtocol mock

### Integration Tests

- Full flow: HttpServer + ChatSession + AgentRunner (mock DeepSeekService) → SSE stream verification
- Config.json httpPort parsing test

### Manual Testing

- Tailscale install + connect on both devices
- Phone browser → `http://<mac-tailscale-ip>:8080` → full chat flow
- Desktop + phone simultaneous: verify state sync

---

## Out of Scope

- Multi-user support (single-user personal tool)
- Authentication (Tailscale provides network-level security; no auth layer needed)
- WebSockets (SSE covers streaming; REST covers actions)
- Native mobile app (web is sufficient for V1; native app can be added later)
- HTTPS/TLS (Tailscale WireGuard already encrypts all traffic; plain HTTP on 127.0.0.1 is safe)
- Push notifications (phone is active-use only)
- File/image upload from phone (Mac-side file operations are agent-driven)
