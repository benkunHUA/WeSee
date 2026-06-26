# Tool RAG Retrieval Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 工具描述向量化存储到 Milvus，每次用户查询时通过 RAG 检索最相关工具，结合白名单组装后仅传入匹配的工具到大模型，替代全量加载。

**Architecture:** 新增 `ToolIndex` 组件封装 Milvus Lite 读写；`AgentRunner` 增加可选 `tool_index`/`whitelist` 参数和 `_resolve_tools` 方法；`main.py` 在启动时构建索引并注入；HTTP/WebSocket handler 将用户查询传入 agent。

**Tech Stack:** Python 3.12、pymilvus 3.0.0、Milvus Lite、DoubaoEmbedder（Ark API，模型 `doubao-embedding-vision`，维度 1024）。

## Global Constraints

- pymilvus >= 3.0.0（已安装）
- RAG 任何环节失败时降级为全量加载，不阻塞 agent 运行。
- 词嵌入内容：`name + description + args_schema字段名和描述`。
- 白名单当前为 `{"shell", "file_system"}`。
- `tool_index` 默认为 `None` 兼容现有测试。

---

### Task 1: ToolIndex 组件 —— Milvus 向量索引

**Files:**
- Create: `server/tools/index.py`
- Create: `server/tools/schema.py`
- Create: `server/tests/tools/test_index.py`

**Interfaces:**
- Produces: `ToolIndex(embedder, milvus_path)` 类，方法 `build_index(tools) -> None`、`search(query, k) -> list[BaseTool]`

- [ ] **Step 1: 写失败测试**

创建 `server/tests/tools/test_index.py`：

```python
import os
import tempfile
from unittest.mock import AsyncMock, MagicMock

import pytest

from tools.index import ToolIndex


def _fake_embedder(dim: int = 1024):
    async def embed(texts: list[str]) -> list[list[float]]:
        import hashlib
        vectors = []
        for t in texts:
            h = hashlib.sha256(t.encode()).digest()
            seed = int.from_bytes(h[:8], "big")
            rng = __import__("random").Random(seed)
            vectors.append([rng.random() for _ in range(dim)])
        return vectors
    mock = AsyncMock()
    mock.embed = embed
    mock.dim = dim
    return mock


def _make_tool(name: str, description: str):
    from langchain_core.tools import BaseTool
    tool = MagicMock(spec=BaseTool)
    tool.name = name
    tool.description = description
    tool.args_schema = None
    return tool


@pytest.mark.asyncio
async def test_build_index_and_search_round_trip():
    with tempfile.TemporaryDirectory() as tmpdir:
        db_path = os.path.join(tmpdir, "test_milvus.db")
        embedder = _fake_embedder()
        index = ToolIndex(embedder, db_path)

        tools = [
            _make_tool("shell", "Run shell commands safely"),
            _make_tool("file_system", "Read write list files in workspace"),
            _make_tool("screenshot", "Take screenshots on macOS"),
        ]

        await index.build_index(tools)

        # Search for "execute command" — should return shell first
        results = await index.search("execute a command", k=1)
        assert len(results) == 1
        assert results[0].name == "shell"

        # Search for "image capture" — should return screenshot
        results = await index.search("capture the screen", k=1)
        assert len(results) == 1
        assert results[0].name == "screenshot"


@pytest.mark.asyncio
async def test_build_index_upsert_does_not_duplicate():
    with tempfile.TemporaryDirectory() as tmpdir:
        db_path = os.path.join(tmpdir, "test_milvus.db")
        embedder = _fake_embedder()
        index = ToolIndex(embedder, db_path)

        tools = [_make_tool("shell", "Run shell commands safely")]
        await index.build_index(tools)
        await index.build_index(tools)  # upsert, no error

        # collection should have exactly 1 entity
        results = await index.search("command", k=5)
        assert len(results) == 1


@pytest.mark.asyncio
async def test_search_returns_empty_when_index_not_built():
    with tempfile.TemporaryDirectory() as tmpdir:
        db_path = os.path.join(tmpdir, "test_milvus2.db")
        embedder = _fake_embedder()
        index = ToolIndex(embedder, db_path)
        results = await index.search("anything", k=3)
        assert results == []
```

- [ ] **Step 2: 运行测试确认失败**

Run:
```bash
cd server && uv run pytest tests/tools/test_index.py -v
```
Expected: FAIL, `ModuleNotFoundError: No module named 'tools.index'`

- [ ] **Step 3: 创建 `server/tools/schema.py`**

```python
# server/tools/schema.py
TOOL_INDEX_FIELD_ID = "id"
TOOL_INDEX_FIELD_DESC = "description"
TOOL_INDEX_FIELD_VECTOR = "vector"
TOOL_INDEX_DIM = 1024
TOOL_INDEX_COLLECTION = "tool_index"
```

- [ ] **Step 4: 创建 `server/tools/index.py`**

```python
# server/tools/index.py
from __future__ import annotations

import logging
from typing import Any

from langchain_core.tools import BaseTool
from pymilvus import (
    Collection,
    DataType,
    FieldSchema,
    MilvusClient,
    connections,
)

from memory.embeddings import Embedder
from tools.schema import (
    TOOL_INDEX_COLLECTION,
    TOOL_INDEX_DESC,
    TOOL_INDEX_DIM,
    TOOL_INDEX_FIELD_ID,
    TOOL_INDEX_FIELD_VECTOR,
)

logger = logging.getLogger("wesee.tools")


def _build_embedding_text(tool: BaseTool) -> str:
    """Build the text to embed for a tool: name + description + args_schema fields."""
    parts = [f"name: {tool.name}", f"description: {tool.description}"]
    if tool.args_schema is not None:
        try:
            schema = tool.args_schema.model_fields
        except AttributeError:
            schema = {}
        arg_lines = []
        for field_name, field_info in schema.items():
            desc = getattr(field_info, "description", "") or ""
            arg_lines.append(f"{field_name} ({desc})" if desc else field_name)
        if arg_lines:
            parts.append("args: " + ", ".join(arg_lines))
    return "\n".join(parts)


class ToolIndex:
    def __init__(self, embedder: Embedder, milvus_path: str):
        self._embedder = embedder
        self._milvus_path = milvus_path
        self._client: MilvusClient | None = None
        self._tool_map: dict[str, BaseTool] = {}

    def _connect(self) -> MilvusClient:
        if self._client is None:
            connections.connect(uri=self._milvus_path)
            self._client = MilvusClient(uri=self._milvus_path)
        return self._client

    async def build_index(self, tools: list[BaseTool]) -> None:
        client = self._connect()
        self._tool_map = {tool.name: tool for tool in tools}

        if not tools:
            return

        texts = [_build_embedding_text(tool) for tool in tools]
        try:
            vectors = await self._embedder.embed(texts)
        except Exception:
            logger.warning("Failed to embed tool descriptions; skipping index build")
            return

        # Create or recreate collection
        if client.has_collection(TOOL_INDEX_COLLECTION):
            client.drop_collection(TOOL_INDEX_COLLECTION)

        client.create_collection(
            collection_name=TOOL_INDEX_COLLECTION,
            dimension=TOOL_INDEX_DIM,
            metric_type="COSINE",
            auto_id=False,
            primary_field_name=TOOL_INDEX_FIELD_ID,
        )

        data = []
        for tool, vector in zip(tools, vectors):
            data.append({
                TOOL_INDEX_FIELD_ID: tool.name,
                TOOL_INDEX_FIELD_DESC: tool.description,
                TOOL_INDEX_FIELD_VECTOR: vector,
            })

        client.insert(collection_name=TOOL_INDEX_COLLECTION, data=data)
        logger.info("Built tool index with %d tools", len(tools))

    async def search(self, query: str, k: int = 2) -> list[BaseTool]:
        client = self._connect()
        if not client.has_collection(TOOL_INDEX_COLLECTION):
            return []

        try:
            query_vec = (await self._embedder.embed([query]))[0]
        except Exception:
            logger.warning("Failed to embed query; returning empty tools")
            return []

        results = client.search(
            collection_name=TOOL_INDEX_COLLECTION,
            data=[query_vec],
            limit=k,
            output_fields=[TOOL_INDEX_FIELD_ID],
        )

        tool_names: list[str] = []
        for hit in results[0]:
            tool_names.append(hit["entity"][TOOL_INDEX_FIELD_ID])

        return [self._tool_map[name] for name in tool_names if name in self._tool_map]
```

- [ ] **Step 5: 运行 ToolIndex 测试**

Run:
```bash
cd server && uv run pytest tests/tools/test_index.py -v
```
Expected: PASS

- [ ] **Step 6: 提交 Task 1**

```bash
git add server/tools/schema.py server/tools/index.py server/tests/tools/test_index.py
git commit -m "feat: add tool index for RAG retrieval"
```

---

### Task 2: AgentRunner 集成 —— 工具解析与降级

**Files:**
- Modify: `server/agent/runner.py`
- Modify: `server/tests/test_agent.py`

**Interfaces:**
- Consumes: `ToolIndex(embedder, milvus_path)` — `build_index`, `search`
- Produces: `AgentRunner(config, tools, *, tool_index=None, whitelist=None)` 新增可选参数；`_resolve_tools(user_query) -> list[BaseTool]`

- [ ] **Step 1: 写失败测试**

在 `server/tests/test_agent.py` 末尾追加：

```python
from unittest.mock import AsyncMock
from models.message import Message
from models.events import ServerEvent


class TestAgentRunnerToolResolution:
    @pytest.mark.asyncio
    async def test_full_tools_when_no_tool_index(self, test_config):
        """Without tool_index, all tools are returned."""
        runner = AgentRunner(config=test_config, tools=[
            MagicMock(name="shell"),
            MagicMock(name="file_system"),
        ])
        resolved = await runner._resolve_tools("any query")
        assert len(resolved) == 2

    @pytest.mark.asyncio
    async def test_whitelist_plus_rag_merge(self, test_config):
        """Whitelist tools are always included alongside RAG results."""
        mock_index = AsyncMock()
        mock_tool = MagicMock()
        mock_tool.name = "screenshot"
        mock_index.search.return_value = [mock_tool]

        all_tools = [
            MagicMock(name="shell"),
            MagicMock(name="file_system"),
            mock_tool,
        ]
        runner = AgentRunner(
            config=test_config,
            tools=all_tools,
            tool_index=mock_index,
            whitelist={"shell", "file_system"},
        )
        resolved = await runner._resolve_tools("screenshot query")
        names = {t.name for t in resolved}
        assert names == {"shell", "file_system", "screenshot"}

    @pytest.mark.asyncio
    async def test_fallback_to_all_tools_on_search_failure(self, test_config):
        """When RAG search fails, fall back to all tools."""
        mock_index = AsyncMock()
        mock_index.search.side_effect = RuntimeError("Milvus down")

        tools = [
            MagicMock(name="shell"),
            MagicMock(name="file_system"),
            MagicMock(name="screenshot"),
        ]
        runner = AgentRunner(
            config=test_config,
            tools=tools,
            tool_index=mock_index,
            whitelist={"shell"},
        )
        resolved = await runner._resolve_tools("query")
        assert len(resolved) == 3  # fallback: all tools
```

Run:
```bash
cd server && uv run pytest tests/test_agent.py -v
```
Expected: FAIL, `AgentRunner._resolve_tools` 不存在。

- [ ] **Step 2: 修改 `server/agent/runner.py`**

```python
# server/agent/runner.py
import logging
from typing import AsyncIterator, Any
from langchain.agents import create_agent
from langchain_core.tools import BaseTool
from config import ServerConfig
from agent.llm import create_llm
from agent.prompt import build_system_prompt
from models.message import Message
from models.events import ServerEvent

logger = logging.getLogger("wesee.agent")


class AgentRunner:
    def __init__(
        self,
        config: ServerConfig,
        tools: list[BaseTool],
        *,
        tool_index: Any | None = None,
        whitelist: set[str] | None = None,
    ):
        self.config = config
        self.all_tools = tools
        self._tool_index = tool_index
        self._whitelist = whitelist or set()

    async def run(
        self,
        history: list[Message],
        workspace_path: str,
        *,
        stream_tool_events: bool = True,
        user_query: str = "",
    ) -> AsyncIterator[ServerEvent]:
        try:
            logger.info(
                "Creating LLM: model=%s, base_url=%s",
                self.config.model,
                self.config.base_url,
            )
            llm = create_llm(self.config)
            resolved_tools = await self._resolve_tools(user_query)
            agent = self._create_agent(llm, build_system_prompt(workspace_path), resolved_tools)
            messages = self._build_messages(history)
            logger.info(
                "Starting agent stream, history_len=%d, tools=%d",
                len(history), len(resolved_tools),
            )

            async for stream_event in agent.astream_events(
                {"messages": messages},
                version="v2",
            ):
                event_type = stream_event.get("event", "")
                logger.debug("LangGraph event: %s", event_type)

                if event_type == "on_chat_model_stream":
                    chunk = stream_event["data"]["chunk"]
                    if chunk.content:
                        yield ServerEvent(type="token", data=chunk.content)
                    if hasattr(chunk, "additional_kwargs"):
                        reasoning = chunk.additional_kwargs.get(
                            "reasoning_content"
                        )
                        if reasoning:
                            yield ServerEvent(
                                type="thinking", data=reasoning
                            )

                elif event_type == "on_tool_start" and stream_tool_events:
                    name = stream_event.get("name", "")
                    tool_input = stream_event["data"].get("input", {})
                    run_id = stream_event.get("run_id", "")
                    logger.info("Tool start: name=%s, id=%s", name, run_id)
                    yield ServerEvent(
                        type="tool_call",
                        id=run_id,
                        name=name,
                        arguments=tool_input,
                    )

                elif event_type == "on_tool_end" and stream_tool_events:
                    output = stream_event["data"].get("output", "")
                    name = stream_event.get("name", "")
                    run_id = stream_event.get("run_id", "")
                    output_text = getattr(output, "content", str(output))
                    logger.info(
                        "Tool end: name=%s, output=%s",
                        name,
                        str(output_text)[:100],
                    )
                    yield ServerEvent(
                        type="tool_result",
                        id=run_id,
                        name=name,
                        data=str(output_text),
                    )

            logger.info("Agent stream complete, yielding done")
            yield ServerEvent(type="done")

        except Exception as e:
            logger.error("Agent error: %s", e, exc_info=True)
            yield ServerEvent(type="error", data=str(e))

    async def _resolve_tools(self, user_query: str) -> list[BaseTool]:
        if self._tool_index is None:
            return list(self.all_tools)

        if len(self.all_tools) <= len(self._whitelist):
            return list(self.all_tools)

        try:
            rag_tools = await self._tool_index.search(user_query, k=2)
        except Exception:
            logger.warning("Tool RAG search failed; falling back to all tools")
            return list(self.all_tools)

        selected = set(self._whitelist) | {t.name for t in rag_tools}
        return [t for t in self.all_tools if t.name in selected]

    def _create_agent(self, llm: Any, system_prompt: str, tools: list[BaseTool]) -> Any:
        return create_agent(llm, tools, system_prompt=system_prompt)

    def _build_messages(
        self, history: list[Message]
    ) -> list[dict[str, Any]]:
        result: list[dict[str, Any]] = []
        for msg in history:
            result.append(msg.to_dict())
        return result
```

注意：上面的文件是完整替换，展示了变更后的完整内容。

- [ ] **Step 3: 更新旧测试以兼容新签名**

`test_run_simple_no_tools` 中 `_create_agent` 现在接收三个参数，需要更新 mock 断言：

在 `tests/test_agent.py` 中，将 `test_run_simple_no_tools` 的 `_create_agent` mock 调用断言改为：

```python
mock_create_agent.assert_called_once()
assert len(mock_create_agent.call_args.args) == 3
_, system_prompt, resolved_tools = mock_create_agent.call_args.args
assert "/tmp" in system_prompt
```

- [ ] **Step 4: 运行全部测试**

Run:
```bash
cd server && uv run pytest tests/test_agent.py tests/tools/test_index.py -v
```
Expected: 所有 AgentRunner + ToolIndex 测试 PASS

Run:
```bash
cd server && uv run pytest tests --ignore=tests/memory/test_alembic_migrations.py -q
```
Expected: 全部 PASS

- [ ] **Step 5: 提交 Task 2**

```bash
git add server/agent/runner.py server/tests/test_agent.py
git commit -m "feat: add tool resolution with RAG and fallback"
```

---

### Task 3: main.py 启动时索引构建与注入

**Files:**
- Modify: `server/main.py`

**Interfaces:**
- Consumes: `ToolIndex(embedder, milvus_path)`、`AgentRunner(config, tools, *, tool_index, whitelist)`
- Produces: 应用启动时索引构建完成，agent 实例带有 `tool_index`

- [ ] **Step 1: 更新 `server/main.py`**

在 `create_app` 中，工具创建之后、`AgentRunner` 创建之前加入 ToolIndex 初始化：

```python
from tools.index import ToolIndex
from tools.shell import ShellTool
from tools.filesystem import FileSystemTool
from tools.screenshot import ScreenshotTool
from agent.runner import AgentRunner
from session.manager import SessionManager
from handlers.websocket import WebSocketManager
from handlers.api import create_api_router
from conversations.store import ConversationStore
from memory.rdbms.base import make_engine, make_session_factory
from memory.config import MemoryConfig
from memory.embeddings import DoubaoEmbedder

# ... inside create_app:

    tools = [
        ShellTool(workspace_path="/tmp"),
        FileSystemTool(workspace_path="/tmp"),
        ScreenshotTool(workspace_path="/tmp"),
    ]

    # Tool RAG index setup
    tool_index = ToolIndex(
        embedder=DoubaoEmbedder(MemoryConfig.from_server_config(config)),
        milvus_path=config.milvus_lite_path,
    )

    @app.on_event("startup")
    async def build_tool_index():
        await tool_index.build_index(tools)

    whitelist = {"shell", "file_system"}
    resolved_agent_runner = agent_runner or AgentRunner(
        config=config,
        tools=tools,
        tool_index=tool_index,
        whitelist=whitelist,
    )
```

- [ ] **Step 2: 更新 HTTP handler 传入 user_query**

在 `server/handlers/api.py` 的 `chat` 函数中，调用 `agent_runner.run()` 时增加 `user_query=content`：

```python
async for event in agent_runner.run(
    history=list(web_session.messages),
    workspace_path=web_session.workspace_path,
    user_query=content,
):
```

- [ ] **Step 3: 更新 WebSocket handler 传入 user_query**

在 `server/handlers/websocket.py` 的 `run_agent` 函数中，调用 `agent_runner.run()` 时增加 `user_query=content`：

```python
async for event in agent_runner.run(
    history=list(session.messages),
    workspace_path=session.workspace_path,
    stream_tool_events=False,
    user_query=content,
):
```

- [ ] **Step 4: 运行全量测试**

Run:
```bash
cd server && uv run pytest tests --ignore=tests/memory/test_alembic_migrations.py -q
```
Expected: 全部 PASS

- [ ] **Step 5: 提交 Task 3**

```bash
git add server/main.py server/handlers/api.py server/handlers/websocket.py
git commit -m "feat: build tool index on startup and pass query to agent"
```

---

### Task 4: 降级与端到端验证测试

**Files:**
- Modify: `server/tests/conftest.py`
- Modify: `server/tests/test_integration.py`

- [ ] **Step 1: 确认 conftest.py 默认 tool_index=None**

检查 `server/tests/conftest.py` 中 `FakeAgentRunner` 的创建，确保不带 `tool_index`（兼容当前测试）：

```python
class FakeAgentRunner:
    def __init__(self):
        self.tool_index = None
        self.whitelist = set()

    async def run(self, history, workspace_path, stream_tool_events=True, user_query=""):
        yield ServerEvent(type="token", data="fake response")
        yield ServerEvent(type="done")

    async def _resolve_tools(self, user_query=""):
        return []  # not used in fake
```

> 如果当前 `FakeAgentRunner` 不是一个类实例而是直接用 `AgentRunner` mock，则需要确保 `tool_index` 参数不传入。回顾 conftest.py——当前 `FakeAgentRunner` 是自定义类，直接调整即可。

- [ ] **Step 2: 写降级端到端测试**

在 `server/tests/test_integration.py` 中追加：

```python
@pytest.mark.asyncio
async def test_chat_works_without_tool_index(app):
    """Chat should work even when tool_index is not configured."""
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        async with client.stream(
            "POST", "/api/chat", json={"content": "hello"}
        ) as resp:
            assert resp.status_code == 200
            full = ""
            async for chunk in resp.aiter_text():
                full += chunk
        assert "data: " in full
```

- [ ] **Step 3: 运行全量测试**

Run:
```bash
cd server && uv run pytest tests --ignore=tests/memory/test_alembic_migrations.py -q
```
Expected: 全部 PASS

- [ ] **Step 4: 提交 Task 4**

```bash
git add server/tests/conftest.py server/tests/test_integration.py
git commit -m "test: verify tool RAG fallback and integration"
```

---

## 自检结果

- Spec coverage: 
  - `Task 1`：ToolIndex 组件（Milvus collection、build_index、search） ✅
  - `Task 2`：AgentRunner 集成（_resolve_tools、降级、whitelist+RAG 合并） ✅
  - `Task 3`：main.py 启动构建索引、handler 传入 user_query ✅
  - `Task 4`：降级测试、端到端验证 ✅
- Placeholder scan: 无 TBD/TODO/占位实现。
- Type consistency: `ToolIndex`、`AgentRunner._resolve_tools`、`user_query` 参数在各任务中一致。
