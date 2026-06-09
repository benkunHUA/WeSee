# WeSee Server Design

## Overview

为 macOS 桌面聊天客户端 WeSee 构建 Python FastAPI 服务端，集成 DeepSeek 大模型，支持多轮对话（SSE 流式响应）、标签分类、书签收藏、定时任务。

## Key Decisions

| 决策 | 选择 | 理由 |
|------|------|------|
| 数据库 | SQLite (aiosqlite) | 个人桌面工具，零配置，Python 内置，无需安装外部服务 |
| DeepSeek 模型 | deepseek-chat | 通用对话，速度快、成本低 |
| 流式方式 | SSE (Server-Sent Events) | 打字机效果，用户体验好 |
| ORM | SQLAlchemy 2.0 async | 成熟稳定，支持异步，与 FastAPI 生态集成好 |
| HTTP 客户端 | httpx | 轻量异步，DeepSeek API 调用 |
| AI SDK | 无，httpx 直调 | DeepSeek API 完全兼容 OpenAI 格式，减少依赖 |

## Project Structure

```
WeSee/server/
├── main.py              # FastAPI 入口，CORS，生命周期
├── config.py            # 配置：DeepSeek API Key, DB path 等
├── requirements.txt     # fastapi, uvicorn, httpx, sqlalchemy, aiosqlite
├── database.py          # SQLAlchemy async engine + session 工厂
├── models.py            # ORM 模型
├── schemas.py           # Pydantic 请求/响应 schema
├── routers/
│   ├── __init__.py
│   ├── chat.py          # POST /api/chat (SSE 流式)
│   ├── conversations.py # GET 对话列表
│   ├── messages.py      # GET 消息列表, PATCH 切换书签
│   ├── tags.py          # CRUD 标签
│   └── tasks.py         # CRUD 定时任务
├── services/
│   ├── __init__.py
│   └── deepseek.py      # DeepSeek API 调用 (httpx + SSE)
└── tests/
    ├── __init__.py
    ├── conftest.py       # pytest fixtures (async client, test db)
    ├── test_chat.py
    ├── test_messages.py
    └── test_tags.py
```

## Data Models

### conversations
| Column | Type | Notes |
|--------|------|-------|
| id | UUID PK | 默认 uuid4 |
| title | String | 对话标题 |
| created_at | DateTime | 默认 utcnow |

### messages
| Column | Type | Notes |
|--------|------|-------|
| id | UUID PK | 默认 uuid4 |
| content | Text | 消息内容 |
| timestamp | DateTime | 默认 utcnow |
| is_from_me | Boolean | 用户发送=true, AI 回复=false |
| is_bookmarked | Boolean | 默认 false |
| conversation_id | UUID FK | → conversations.id |

### tags
| Column | Type | Notes |
|--------|------|-------|
| id | UUID PK | 默认 uuid4 |
| name | String | 标签名 |
| color_hex | String | 默认 "#007AFF" |

### message_tags (M2M join)
| Column | Type | Notes |
|--------|------|-------|
| message_id | UUID FK | → messages.id |
| tag_id | UUID FK | → tags.id |

Composite PK: (message_id, tag_id)

### scheduled_tasks
| Column | Type | Notes |
|--------|------|-------|
| id | UUID PK | 默认 uuid4 |
| type | String | sendMessage/syncStatus/reminder |
| title | String | 任务名 |
| cron_expression | String | 5-field cron |
| is_enabled | Boolean | 默认 true |
| next_fire_date | DateTime? | nullable |

## API Endpoints

所有端点前缀 `/api`。JSON 使用 camelCase（与客户端对应）。

### GET /api/conversations
- **Response**: `{ "conversations": [{"id": "uuid", "title": "...", "createdAt": "iso8601"}, ...] }`
- 按 created_at 倒序，最新对话在前

### POST /api/chat
- **Content-Type**: application/json
- **Response**: text/event-stream (SSE)
- **Request Body**: `{ "content": "你好", "conversationId": "uuid-or-null" }`
- **SSE Events**:
  1. `data: {"type":"start","conversationId":"uuid"}\n\n` — 首条 event 携带对话 ID
  2. 每个 token: `data: {"type":"token","data":"你"}\n\n`
  3. 流正常结束: `data: {"type":"done"}\n\n`
  4. 异常: `data: {"type":"error","data":"错误信息"}\n\n`
- **Flow**:
  1. 无 conversationId 则创建新 Conversation（title 取用户消息前 30 字）
  2. 保存用户消息 (isFromMe=true)
  3. 查询最近 20 条历史消息拼接上下文
  4. 调用 DeepSeek API (stream=true)
  5. SSE 推送各 event
  6. 流正常结束后，保存完整 AI 回复 (isFromMe=false)

### GET /api/messages
- **Query**: `?conversationId=uuid&tagId=uuid`
- **Response**: `{ "messages": [...] }`

### PATCH /api/messages/{id}/bookmark
- **Response**: `{ "message": {...} }` 或 404

### GET /api/tags
- **Response**: `{ "tags": [...] }`

### POST /api/tags
- **Request**: `{ "name": "工作", "colorHex": "#FF0000" }`
- **Response**: `{ "tag": {...} }`

### GET /api/tasks
- **Response**: `{ "tasks": [...] }`

### POST /api/tasks
- **Request**: `{ "type": "reminder", "title": "每日总结", "cronExpression": "0 18 * * *" }`
- **Response**: `{ "task": {...} }`

### PATCH /api/tasks/{id}/toggle
- **Response**: `{ "task": {...} }` 或 404

## Response Formats

### Message (in JSON arrays)
```json
{
  "id": "uuid",
  "content": "消息文本",
  "timestamp": "2026-06-09T12:00:00Z",
  "isFromMe": true,
  "isBookmarked": false,
  "tags": [{"id": "uuid", "name": "工作", "colorHex": "#FF0000"}]
}
```

### SSE Stream
```
data: {"type":"start","conversationId":"uuid"}\n\n
data: {"type":"token","data":"你"}\n\n
data: {"type":"done"}\n\n
```

## Client Changes

### RemoteClient 协议更新

移除旧的 3 方法协议，新协议覆盖全部功能：

- `fetchConversations() async throws -> [ConversationDTO]`
- `sendMessage(_ content: String, conversationId: UUID?) -> AsyncThrowingStream<ChatEvent, Error>`
- `fetchMessages(conversationId: UUID, tagId: UUID?) async throws -> [MessageDTO]`
- `toggleBookmark(_ messageId: UUID) async throws`
- `createTag(name: String, colorHex: String) async throws -> Tag`
- `fetchTags() async throws -> [Tag]`
- `fetchTasks() async throws -> [ScheduledTask]`
- `createTask(...) async throws`
- `toggleTask(_ id: UUID) async throws`

### LiveRemoteClient

新建 `LiveRemoteClient` 类，使用 URLSession 实现：
- `sendMessage` 使用 `URLSession.bytes(from:)` 消费 SSE 流，返回 `AsyncThrowingStream`
- 其他方法使用标准 `URLSession.data(for:)` + JSONDecoder

### ChatViewModel 改动

- 新增 `conversationId: UUID?` 属性
- `addMessage` 改为异步：先显示用户消息，调用 `sendMessage` 获取流，逐 token 构建 AI 消息气泡
- 新增 streaming AI 消息的中间状态管理

### 新增 DTO (Data Transfer Objects)

Codable 结构体用于 JSON 序列化，与 SwiftData Model 类分离：
- `MessageDTO`, `TagDTO`, `ConversationDTO`, `TaskDTO`
- `ChatEvent` enum 表示 SSE 事件：`.start(conversationId)`, `.token(String)`, `.done`, `.error(String)`
- 对应服务端 JSON schemas

## Configuration

通过环境变量配置（server/config.py 读取）：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| DEEPSEEK_API_KEY | (required) | DeepSeek API 密钥 |
| DEEPSEEK_BASE_URL | https://api.deepseek.com/v1 | API 地址 |
| DATABASE_URL | sqlite+aiosqlite:///./weseed.db | DB 连接串 |
| SERVER_PORT | 8000 | 服务端口 |

## Error Handling

- 服务端: 统一 JSON error response `{ "error": "message" }`
- SSE 流内错误: `data: {"type":"error","data":"..."}\n\n`
- 客户端: ChatViewModel.errorMessage 显示错误（已有此机制）
- DeepSeek API 超时: 30s 连接超时, 60s 读取超时

## Testing Strategy

- pytest + httpx AsyncClient (FastAPI TestClient 异步版)
- 每个 router 一个 test 文件
- 使用内存 SQLite (aiosqlite:///:memory:) 避免落盘
- Mock DeepSeek API 避免外部依赖

## Out of Scope

- 用户认证（个人桌面工具）
- WebSocket 实时推送（SSE 已覆盖聊天流）
- 定时任务执行引擎（客户端本地执行 cron）
