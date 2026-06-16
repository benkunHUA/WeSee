# WeSee FastAPI 服务端设计

**日期**: 2026-06-16
**状态**: 设计中

## 目标

将 macOS SwiftUI 客户端中的大模型调用、Agent 循环逻辑迁移到 Python FastAPI 服务端，客户端只保留 UI 和本地工具执行。

## 架构概览

```
┌─────────────────────────┐      WebSocket        ┌──────────────────────────────────┐
│   macOS SwiftUI App      │◄────────────────────►│   Python FastAPI Server          │
│                          │   token/thinking/done │                                  │
│  - SwiftUI Views         │   tool_call/tool_res  │  LangChain/LangGraph Stack:      │
│  - ChatViewModel (精简)  │                       │  ├─ ChatOpenAI → DeepSeek API    │
│  - Shell/File/Screenshot │                       │  ├─ create_react_agent           │
│    Tool 本地执行          │                       │  ├─ BaseTool (Shell/FS/Shot)     │
└─────────────────────────┘                       │  └─ astream_events (流式)        │
                                                   │                                  │
                                                   │  HTTP + SSE                      │
                                                   │  ├─ POST /api/chat               │
                                                   │  ├─ GET /api/messages            │
                                                   │  └─ Static / (index.html)        │
                                                   └──────────────────────────────────┘
                                                               │
                                                       HTTP + SSE
                                                               │
                                                      ┌────────┴──────────┐
                                                      │  Mobile Browser    │
                                                      └───────────────────┘
```

## 通信协议

### WebSocket（macOS 客户端 ↔ 服务端）

客户端 → 服务端:
```json
{"type": "chat", "content": "用户消息"}
{"type": "new_conversation"}
{"type": "tool_result", "id": "call_1", "name": "shell", "result": "ls output"}
{"type": "update_workspace", "path": "/Users/xxx/projects"}
```

> 注意：API Key、model 等 LLM 配置由服务端管理，客户端无需携带。客户端仅发送工作目录路径用于工具执行。

服务端 → 客户端:
```json
{"type": "token", "data": "Hello"}
{"type": "thinking", "data": "思考内容..."}
{"type": "tool_call", "id": "call_1", "name": "shell", "arguments": {"command": "ls"}}
{"type": "done"}
{"type": "error", "data": "错误信息"}
```

### HTTP + SSE（Web UI）

- `POST /api/chat` — 发送消息，SSE 流式返回
- `GET /api/messages` — 获取消息历史
- `POST /api/new-conversation` — 新建对话
- `GET /` — Web UI 静态页面

## 技术栈

| 层 | 技术 |
|---|---|
| Web 框架 | FastAPI |
| 异步服务器 | uvicorn |
| LLM 调用 | langchain-openai (ChatOpenAI, base_url 指向 DeepSeek) |
| Agent 循环 | langgraph (create_react_agent + astream_events) |
| 工具定义 | langchain_core.tools.BaseTool |
| 实时通信 | WebSocket (FastAPI 内置) |
| 流式响应 | SSE (sse-starlette 或手动实现) |
| 包管理 | uv |
| 数据校验 | pydantic v2 |
| 测试 | pytest + pytest-asyncio |

## 关键依赖

```
fastapi>=0.115.0
uvicorn[standard]>=0.30.0
langchain>=0.3.0
langchain-openai>=0.2.0
langgraph>=0.2.0
pydantic>=2.0.0
pydantic-settings>=2.0.0
```

## 项目结构

```
server/
├── main.py                    # FastAPI 入口，路由注册，生命周期管理
├── pyproject.toml             # uv 项目配置 + 依赖
├── config.py                  # 配置管理（读取服务端 .env 或 config.json）
├── models/
│   ├── __init__.py
│   ├── events.py              # WebSocket/SSE 事件模型
│   └── message.py             # 消息模型
├── agent/
│   ├── __init__.py
│   ├── runner.py              # LangGraph Agent 封装（create_react_agent）
│   ├── llm.py                 # ChatOpenAI 工厂函数
│   └── prompt.py              # System prompt 构建
├── tools/
│   ├── __init__.py
│   ├── base.py                # 工具基类（支持 WebSocket 转发 + 本地执行）
│   ├── shell.py               # Shell 命令工具
│   ├── filesystem.py          # 文件系统工具
│   └── screenshot.py          # 截图工具（仅 macOS）
├── handlers/
│   ├── __init__.py
│   ├── websocket.py           # WebSocket 端点 + 连接管理
│   └── api.py                 # REST API + SSE 端点
├── session/
│   ├── __init__.py
│   └── manager.py             # 会话管理器（内存存储）
├── static/                    # Web UI 静态资源
│   ├── index.html
│   └── app.js
└── tests/
    ├── __init__.py
    ├── conftest.py
    ├── test_agent.py
    ├── test_tools.py
    ├── test_api.py
    └── test_websocket.py
```

## 核心模块设计

### 1. LLM 工厂 (`agent/llm.py`)

```python
from langchain_openai import ChatOpenAI

def create_llm(config: ServerConfig) -> ChatOpenAI:
    return ChatOpenAI(
        model=config.model,
        base_url=f"{config.base_url}/v1",
        api_key=config.api_key,
        streaming=True,
        temperature=0.7,
    )
```

### 1.5 服务端配置 (`config.py`)

配置来源优先级：环境变量 > `.env` 文件 > 默认值

```python
from pydantic_settings import BaseSettings

class ServerConfig(BaseSettings):
    api_key: str
    base_url: str = "https://api.deepseek.com"
    model: str = "deepseek-v4-pro"
    enable_thinking: bool = True
    reasoning_effort: str | None = None
    http_port: int = 8080

    model_config = {"env_prefix": "WESEE_", "env_file": ".env"}
```

服务端 `.env` 示例：
```env
WESEE_API_KEY=sk-xxxxx
WESEE_BASE_URL=https://api.deepseek.com
WESEE_MODEL=deepseek-v4-pro
WESEE_HTTP_PORT=8080
```

### 2. Agent 运行器 (`agent/runner.py`)

使用 LangGraph `create_react_agent`，通过 `astream_events` 获取细粒度流式事件：

- `on_chat_model_stream` → yield token/thinking
- `on_tool_start` → yield tool_call（转发到 WebSocket 客户端）
- `on_tool_end` → yield tool_result
- 完成时 → yield done

Agent 运行在独立协程中，通过 asyncio.Queue 将事件推送给 WebSocket/SSE。

### 3. 工具基类 (`tools/base.py`)

工具分两种执行路径：

- **macOS 客户端在线时**：工具调用通过 WebSocket 转发到客户端执行
- **Web UI / 客户端离线时**：工具在服务端本地执行（截图工具在此模式下不可用）

```python
class ClientForwardTool(BaseTool):
    """需要转发到客户端执行的工具基类"""
    ws_manager: WebSocketManager | None = None

    async def _arun(self, **kwargs) -> str:
        if self.ws_manager and self.ws_manager.is_connected:
            return await self.ws_manager.send_tool_call_and_wait(
                name=self.name, arguments=kwargs
            )
        return self._run_local(**kwargs)

    def _run_local(self, **kwargs) -> str:
        """本地执行回退"""
        raise NotImplementedError
```

### 4. WebSocket 处理器 (`handlers/websocket.py`)

- 管理单个 macOS 客户端连接
- 接收：chat、new_conversation、tool_result、update_workspace
- 发送：token、thinking、tool_call、done、error
- 使用 asyncio.Event 实现工具调用的请求-响应同步

### 5. 会话管理 (`session/manager.py`)

- 每个会话关联：消息历史、Agent 实例、工具状态
- WebSocket 连接与会话一对一绑定
- Web UI 使用 session ID（Cookie/Query 参数）关联会话
- 存储：内存（后续可升级为 SQLite/Redis）

### 6. API 端点 (`handlers/api.py`)

- `POST /api/chat` — 接收消息，返回 SSE 流
- `GET /api/messages` — 返回 JSON 消息列表
- `POST /api/new-conversation` — 清除当前会话

## 客户端改动

macOS 客户端需要：

1. **删除**：`DeepSeekService.swift`、`AgentRunner.swift`、`SystemPromptBuilder.swift`、`ToolRegistry`（AgentTool.swift 中）、`Config.swift` 中 LLM 相关字段（apiKey/baseURL/model/enableThinking/reasoningEffort）
2. **保留**：ShellTool、FileSystemTool、ScreenshotTool（本地执行），`WorkspaceManager`、`ConfigLoader`（仅保留 workspace 路径、screenshotsPath、httpPort 等非 LLM 配置）
3. **新增**：`WebSocketClient.swift`（连接服务端 WebSocket）
4. **精简**：`ChatViewModel.swift`（发送消息改为 WebSocket 调用，接收流式事件）
5. **保留不变**：所有 SwiftUI Views、Message 模型、WorkspaceManager
6. **改造**：HttpServer.swift 不再调用 ChatSession，改为反向代理到 FastAPI 服务端（或直接去掉，由服务端直接提供 Web UI）

## 错误处理

- LLM API 调用失败 → `{type: "error", data: "message"}` 推送给客户端
- WebSocket 连接断开 → Agent 终止当前运行，客户端自动重连
- 工具执行超时（30s）→ 返回超时错误信息
- 配置加载失败 → 服务端启动时报错退出

## 测试策略

| 测试类型 | 范围 | 工具 |
|---|---|---|
| 单元测试 | LLM 工厂、配置解析、消息模型、工具逻辑 | pytest |
| 集成测试 | Agent 运行器（mock LLM）、WebSocket 端点 | pytest-asyncio |
| 端到端 | 完整流程：发送消息 → Agent 循环 → 工具调用 → 返回结果 | pytest + FastAPI TestClient |

测试覆盖率目标：80%+

## 安全考虑

- API Key 仅存储在服务端 `.env` 文件中，不提交到版本控制
- macOS 客户端不持有任何密钥，仅连接 localhost WebSocket
- Shell 工具：命令白名单 + 禁用管道/重定向/命令替换（与现有客户端逻辑一致）
- 文件系统工具：路径沙箱限制在工作目录内
- WebSocket：仅本地连接（localhost）
- Web UI：CORS 限制

## 与现有系统的兼容

- 配置文件迁移到服务端：用 `.env` 或 `config.json` 管理 LLM 配置
- macOS 客户端不再读取 `~/.config/wesee/config.json` 中的 API Key
- Web UI 的 `app.js` 可复用，只需修改连接地址
- macOS 客户端的 Message SwiftData 模型保留，本地存储逻辑不变
