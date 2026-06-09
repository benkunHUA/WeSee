# Client-Side AI Calling Design

> **Goal:** Move DeepSeek API calls from server to client, remove server, support desktop agent tool-calling in future.

**Architecture:** Client calls DeepSeek API directly via URLSession SSE streaming. Config from `~/.config/wesee/config.json`. SwiftData for local persistence. BackgroundTasks for scheduled tasks.

**Tech Stack:** Swift, SwiftUI, SwiftData, URLSession, macOS BackgroundTasks

---

## Architecture

```
~/.config/wesee/config.json  ──→  DeepSeekService  ──→  DeepSeek API
                                      ↑
                                      │
                                 ChatViewModel
                                      │
                              SwiftData (local DB)
```

## Components

### 1. DeepSeekService (new)

Responsible for calling DeepSeek API directly from the client.

- **Config reading:** Reads `~/.config/wesee/config.json` at init, returns `Settings` struct (apiKey, baseURL, model)
- **SSE streaming:** Uses `URLSession.bytes(for:)` to consume stream like current `LiveRemoteClient`
- **History construction:** Converts `[Message]` to `[{role, content}]` format for DeepSeek's chat/completions API
- **Interface:** `func streamChat(messages: [Message], config: Config) -> AsyncThrowingStream<ChatEvent, Error>`

### 2. Config (new model)

```swift
struct ClientConfig: Codable {
    let apiKey: String
    let baseURL: String  // default: https://api.deepseek.com
    let model: String    // default: deepseek-chat
}
```

Config file format (`~/.config/wesee/config.json`):
```json
{
    "apiKey": "sk-xxx",
    "baseURL": "https://api.deepseek.com",
    "model": "deepseek-chat"
}
```

### 3. Remove

| Remove | Reason |
|--------|--------|
| `server/` directory | No longer needed |
| `RemoteClient` protocol | No polymorphic server impls needed |
| `NoOpRemoteClient` | No longer needed |
| `LiveRemoteClient` | Replaced by DeepSeekService |
| `Models/DTO.swift` | DTOs were for server JSON; no server |

### 4. Modify

| File | Change |
|------|--------|
| `ChatViewModel.swift` | Replace `remoteClient.sendMessage()` with `deepSeekService.streamChat()` |
| `ChatViewModel.swift` | Remove conversations loading (local only) |
| `WeSeeApp.swift` | Remove unused server-related init |

### 5. Keep

- SwiftData models: `Message`, `Tag`, `ScheduledTask` — local persistence
- All Views: ChatView, MessageListView, SidebarView, etc. — UI unchanged
- ScheduledTask model + UI — local only, cron scheduling via BackgroundTasks TBD later

## Data Flow

```
User types message
  → ChatViewModel.sendMessage()
    → addMessage (local SwiftData, isFromMe: true)
    → DeepSeekService.streamChat(history, config)
      → POST https://api.deepseek.com/v1/chat/completions (SSE)
        → stream tokens back
    → on .token: update streamingContent
    → on .done: addMessage (local SwiftData, isFromMe: false)
```

## Error Handling

- Config file missing: show "未找到配置文件 ~/.config/wesee/config.json"
- Config invalid JSON: show "配置文件格式错误"
- API key invalid (401): show "API Key 无效"
- Network error: show error.localizedDescription

## Testing

- `DeepSeekServiceTests`: Test config parsing, history construction
- `ChatViewModelTests`: Update for new sendMessage flow (mock DeepSeekService)
