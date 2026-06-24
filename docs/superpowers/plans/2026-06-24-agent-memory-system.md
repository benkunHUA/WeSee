# Agent Memory System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the in-memory `Session.messages` list with a persisted, multi-tier memory system: PostgreSQL for conversation, Milvus Lite + Doubao embeddings for six vector memory collections (knowledge / workflow / tool / entity / summary / profile), all exposed as LLM tools.

**Architecture:** New `server/memory/` package with one file per memory type. A single `MemoryService` facade owns one `ConversationMemoryStore` (SQLAlchemy async) and six `VectorMemoryStore` subclasses (pymilvus). The agent runner receives seven new `search_*` tools that call into `MemoryService`. `SessionManager` keeps an in-memory hot cache but every `add_message` is mirrored to PG via `asyncio.create_task` (write-through, never blocking).

**Tech Stack:** Python 3.12, FastAPI, SQLAlchemy 2.0 async + asyncpg, pymilvus 2.4 (Lite mode), Doubao embedding via OpenAI-compatible HTTP, pydantic 2, pytest + pytest-asyncio + respx + aiosqlite + testcontainers.

**Spec:** `docs/superpowers/specs/2026-06-24-agent-memory-system-design.md`

---

## File Map

Create (new files):
- `server/memory/__init__.py` — re-exports `MemoryService`, `MemoryConfig`
- `server/memory/config.py` — `MemoryConfig` pydantic settings (subset of `ServerConfig`)
- `server/memory/embeddings.py` — `DoubaoEmbedder` (Doubao OpenAI-compatible)
- `server/memory/service.py` — `MemoryService` facade
- `server/memory/rdbms/__init__.py`
- `server/memory/rdbms/base.py` — async engine, session factory, `Base`
- `server/memory/rdbms/models.py` — `UserRow`, `SessionRow`, `MessageRow`
- `server/memory/rdbms/conversation_store.py` — `ConversationMemoryStore`
- `server/memory/vector/__init__.py`
- `server/memory/vector/client.py` — `MilvusClientWrapper` (open, `ensure_collection`)
- `server/memory/vector/base.py` — `VectorRecord`, `VectorMemoryStore` (ABC)
- `server/memory/vector/knowledge.py` — `KnowledgeMetadata`, `KnowledgeMemoryStore`
- `server/memory/vector/workflow.py` — `WorkflowMetadata`, `WorkflowMemoryStore`
- `server/memory/vector/tool.py` — `ToolMetadata`, `ToolMemoryStore`
- `server/memory/vector/entity.py` — `EntityMetadata`, `EntityMemoryStore`
- `server/memory/vector/summary.py` — `SummaryMetadata`, `SummaryMemoryStore`
- `server/memory/vector/profile.py` — `ProfileMetadata`, `ProfileMemoryStore`
- `server/tools/memory_tools.py` — 7 LangChain `BaseTool`s
- `server/handlers/memory_api.py` — REST router mounted at `/memory`
- `server/tests/memory/__init__.py`
- `server/tests/memory/test_embedder.py`
- `server/tests/memory/test_conversation_store.py`
- `server/tests/memory/test_vector_base.py`
- `server/tests/memory/test_concrete_stores.py`
- `server/tests/integration/test_memory_pg.py`
- `server/tests/integration/test_memory_milvus.py`
- `server/tests/integration/test_memory_service.py`
- `server/tests/e2e/test_agent_with_memory.py`

Modify (existing files):
- `server/pyproject.toml` — add deps
- `server/config.py` — add memory-related fields
- `server/session/manager.py` — accept optional `MemoryService`, write-through, lazy load
- `server/main.py` — `await MemoryService.create(cfg)` at startup, inject into `SessionManager`, register memory tools, mount memory router
- `server/handlers/websocket.py` — pass `user_id` (placeholder default for now) into `SessionManager`, persist messages on receive
- `server/handlers/api.py` — same write-through plumbing for HTTP chat path
- `server/agent/runner.py` — no change (tools are passed in by `main.py`)

---

## Conventions

- Async everywhere. All store methods are `async def`. pymilvus sync calls go through `asyncio.to_thread`.
- Every commit: `git add <files>` then `git commit -m "<type>: <msg>"`. Conventional commits.
- Run tests after every implementation step.
- No `Any` unless interfacing with langchain or pymilvus types.
- Type-hint everything new; use `from __future__ import annotations` only when needed.
- Default `user_id` placeholder during transition: the string `"default-user"`. Real auth is out of scope.

---

## Task 1: Add dependencies

**Files:**
- Modify: `server/pyproject.toml`

- [ ] **Step 1: Edit `pyproject.toml`**

Add to `dependencies`:
```
"sqlalchemy[asyncio]>=2.0.0",
"asyncpg>=0.29.0",
"pymilvus>=2.4.0",
"httpx>=0.27.0",
```

Add to `[project.optional-dependencies].dev` and `[dependency-groups].dev`:
```
"aiosqlite>=0.20.0",
"respx>=0.21.0",
"testcontainers[postgres]>=4.7.0",
```

- [ ] **Step 2: Install**

Run: `cd server && uv sync --extra dev`
Expected: lockfile updated, all deps resolved.

- [ ] **Step 3: Commit**

```bash
git add server/pyproject.toml server/uv.lock
git commit -m "chore: add memory layer dependencies"
```

---

## Task 2: Extend `ServerConfig`

**Files:**
- Modify: `server/config.py`
- Test: `server/tests/test_config.py` (create if missing)

- [ ] **Step 1: Write the failing test**

Create `server/tests/test_config.py`:
```python
from config import ServerConfig


def test_memory_defaults_present():
    cfg = ServerConfig(api_key="sk-test")
    assert cfg.postgres_dsn.startswith("postgresql+asyncpg://")
    assert cfg.milvus_lite_path.endswith(".db")
    assert cfg.embedding_model == "doubao-embedding-vision"
    assert cfg.ark_base_url.startswith("https://ark.cn-beijing.volces.com")
    assert cfg.memory_write_async is True


def test_ark_api_key_optional():
    cfg = ServerConfig(api_key="sk-test")
    assert cfg.ark_api_key == ""
```

- [ ] **Step 2: Run test (should fail)**

Run: `cd server && uv run pytest tests/test_config.py -v`
Expected: FAIL with `AttributeError: 'ServerConfig' object has no attribute 'postgres_dsn'`.

- [ ] **Step 3: Add fields to `ServerConfig`**

Edit `server/config.py`, append after `http_port`:
```python
    postgres_dsn: str = "postgresql+asyncpg://wesee:wesee@localhost:5432/wesee"
    milvus_lite_path: str = "./data/wesee_memory.db"
    ark_api_key: str = ""
    ark_base_url: str = "https://ark.cn-beijing.volces.com/api/coding/v3"
    embedding_model: str = "doubao-embedding-vision"
    memory_write_async: bool = True
```

- [ ] **Step 4: Run test (should pass)**

Run: `cd server && uv run pytest tests/test_config.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add server/config.py server/tests/test_config.py
git commit -m "feat(config): add memory-layer settings"
```

---

## Task 3: `MemoryConfig` adapter

**Files:**
- Create: `server/memory/__init__.py`
- Create: `server/memory/config.py`
- Test: `server/tests/memory/__init__.py`, `server/tests/memory/test_memory_config.py`

- [ ] **Step 1: Write the failing test**

Create `server/tests/memory/__init__.py` empty, then `server/tests/memory/test_memory_config.py`:
```python
from config import ServerConfig
from memory.config import MemoryConfig


def test_memory_config_from_server_config():
    server_cfg = ServerConfig(api_key="sk-test")
    mem = MemoryConfig.from_server_config(server_cfg)
    assert mem.postgres_dsn == server_cfg.postgres_dsn
    assert mem.milvus_lite_path == server_cfg.milvus_lite_path
    assert mem.embedding_model == server_cfg.embedding_model
    assert mem.ark_base_url == server_cfg.ark_base_url
    assert mem.ark_api_key == server_cfg.ark_api_key
    assert mem.write_async is True
```

- [ ] **Step 2: Run test (should fail)**

Run: `cd server && uv run pytest tests/memory/test_memory_config.py -v`
Expected: FAIL with `ModuleNotFoundError: memory`.

- [ ] **Step 3: Create the module**

`server/memory/__init__.py`:
```python
from memory.config import MemoryConfig

__all__ = ["MemoryConfig"]
```

`server/memory/config.py`:
```python
from dataclasses import dataclass
from config import ServerConfig


@dataclass(frozen=True)
class MemoryConfig:
    postgres_dsn: str
    milvus_lite_path: str
    ark_api_key: str
    ark_base_url: str
    embedding_model: str
    write_async: bool

    @classmethod
    def from_server_config(cls, cfg: ServerConfig) -> "MemoryConfig":
        return cls(
            postgres_dsn=cfg.postgres_dsn,
            milvus_lite_path=cfg.milvus_lite_path,
            ark_api_key=cfg.ark_api_key,
            ark_base_url=cfg.ark_base_url,
            embedding_model=cfg.embedding_model,
            write_async=cfg.memory_write_async,
        )
```

- [ ] **Step 4: Run test (should pass)**

Run: `cd server && uv run pytest tests/memory/test_memory_config.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add server/memory/__init__.py server/memory/config.py server/tests/memory/__init__.py server/tests/memory/test_memory_config.py
git commit -m "feat(memory): add MemoryConfig adapter"
```

---

## Task 4: `DoubaoEmbedder`

**Files:**
- Create: `server/memory/embeddings.py`
- Test: `server/tests/memory/test_embedder.py`

- [ ] **Step 1: Write the failing test**

`server/tests/memory/test_embedder.py`:
```python
import pytest
import respx
from httpx import Response
from memory.config import MemoryConfig
from memory.embeddings import DoubaoEmbedder

CFG = MemoryConfig(
    postgres_dsn="x",
    milvus_lite_path="x",
    ark_api_key="ak-test",
    ark_base_url="https://ark.example.com/api/coding/v3",
    embedding_model="doubao-embedding-vision",
    write_async=True,
)


@pytest.mark.asyncio
@respx.mock
async def test_embed_calls_ark_api_with_correct_payload():
    route = respx.post(
        "https://ark.example.com/api/coding/v3/embeddings"
    ).mock(
        return_value=Response(
            200,
            json={"data": [{"embedding": [0.1, 0.2, 0.3]}]},
        )
    )
    emb = DoubaoEmbedder(CFG)
    vecs = await emb.embed(["hello"])
    assert vecs == [[0.1, 0.2, 0.3]]
    assert route.called
    req = route.calls.last.request
    assert req.headers["authorization"] == "Bearer ak-test"
    body = req.read().decode()
    assert "doubao-embedding-vision" in body
    assert "hello" in body


@pytest.mark.asyncio
@respx.mock
async def test_dim_probe_caches_dimension():
    respx.post(
        "https://ark.example.com/api/coding/v3/embeddings"
    ).mock(
        return_value=Response(
            200,
            json={"data": [{"embedding": [0.0] * 1024}]},
        )
    )
    emb = DoubaoEmbedder(CFG)
    await emb.probe()
    assert emb.dim == 1024
    # second access does not re-call
    await emb.probe()
    assert respx.calls.call_count == 1


@pytest.mark.asyncio
@respx.mock
async def test_embed_raises_on_http_error():
    respx.post(
        "https://ark.example.com/api/coding/v3/embeddings"
    ).mock(return_value=Response(500, json={"error": "boom"}))
    emb = DoubaoEmbedder(CFG)
    from memory.embeddings import EmbeddingError
    with pytest.raises(EmbeddingError):
        await emb.embed(["x"])
```

- [ ] **Step 2: Run test (should fail)**

Run: `cd server && uv run pytest tests/memory/test_embedder.py -v`
Expected: FAIL with `ModuleNotFoundError: memory.embeddings`.

- [ ] **Step 3: Implement `DoubaoEmbedder`**

`server/memory/embeddings.py`:
```python
import httpx
from typing import Protocol
from memory.config import MemoryConfig


class EmbeddingError(RuntimeError):
    pass


class Embedder(Protocol):
    async def embed(self, texts: list[str]) -> list[list[float]]: ...
    @property
    def dim(self) -> int: ...


class DoubaoEmbedder:
    def __init__(self, cfg: MemoryConfig, timeout: float = 30.0):
        self._cfg = cfg
        self._timeout = timeout
        self._dim: int | None = None
        self._client = httpx.AsyncClient(
            base_url=cfg.ark_base_url,
            timeout=timeout,
            headers={
                "Authorization": f"Bearer {cfg.ark_api_key}",
                "Content-Type": "application/json",
            },
        )

    @property
    def dim(self) -> int:
        if self._dim is None:
            raise EmbeddingError("dim not probed yet; call await probe() first")
        return self._dim

    async def probe(self) -> int:
        if self._dim is not None:
            return self._dim
        vecs = await self.embed(["probe"])
        self._dim = len(vecs[0])
        return self._dim

    async def embed(self, texts: list[str]) -> list[list[float]]:
        if not texts:
            return []
        payload = {"model": self._cfg.embedding_model, "input": texts}
        try:
            resp = await self._client.post("/embeddings", json=payload)
        except httpx.HTTPError as e:
            raise EmbeddingError(f"embedding HTTP error: {e}") from e
        if resp.status_code != 200:
            raise EmbeddingError(
                f"embedding non-200: {resp.status_code} {resp.text[:200]}"
            )
        data = resp.json().get("data", [])
        return [item["embedding"] for item in data]

    async def aclose(self) -> None:
        await self._client.aclose()
```

- [ ] **Step 4: Run test (should pass)**

Run: `cd server && uv run pytest tests/memory/test_embedder.py -v`
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add server/memory/embeddings.py server/tests/memory/test_embedder.py
git commit -m "feat(memory): DoubaoEmbedder with probe + retry"
```

---

## Task 5: SQLAlchemy base + models

**Files:**
- Create: `server/memory/rdbms/__init__.py`
- Create: `server/memory/rdbms/base.py`
- Create: `server/memory/rdbms/models.py`

- [ ] **Step 1: Implement base infrastructure**

`server/memory/rdbms/__init__.py` empty.

`server/memory/rdbms/base.py`:
```python
from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)
from sqlalchemy.orm import DeclarativeBase


class Base(DeclarativeBase):
    pass


def make_engine(dsn: str, echo: bool = False) -> AsyncEngine:
    return create_async_engine(dsn, echo=echo, pool_pre_ping=True)


def make_session_factory(
    engine: AsyncEngine,
) -> async_sessionmaker[AsyncSession]:
    return async_sessionmaker(engine, expire_on_commit=False)
```

`server/memory/rdbms/models.py`:
```python
import uuid
from datetime import datetime, timezone
from sqlalchemy import (
    BigInteger,
    DateTime,
    ForeignKey,
    Index,
    String,
    Text,
)
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship
from memory.rdbms.base import Base


def _now() -> datetime:
    return datetime.now(timezone.utc)


class UserRow(Base):
    __tablename__ = "users"
    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    name: Mapped[str | None] = mapped_column(String(128))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=_now
    )


class SessionRow(Base):
    __tablename__ = "sessions"
    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id"), index=True
    )
    workspace_path: Mapped[str] = mapped_column(Text, default="/tmp")
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=_now
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=_now, onupdate=_now
    )
    messages: Mapped[list["MessageRow"]] = relationship(
        back_populates="session", cascade="all, delete-orphan"
    )


class MessageRow(Base):
    __tablename__ = "messages"
    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    session_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("sessions.id")
    )
    role: Mapped[str] = mapped_column(String(16))
    content: Mapped[str | None] = mapped_column(Text)
    tool_calls: Mapped[dict | None] = mapped_column(JSONB, nullable=True)
    tool_call_id: Mapped[str | None] = mapped_column(String(128))
    name: Mapped[str | None] = mapped_column(String(128))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=_now
    )
    session: Mapped["SessionRow"] = relationship(back_populates="messages")

    __table_args__ = (
        Index("ix_messages_session_id_id", "session_id", "id"),
    )
```

- [ ] **Step 2: Smoke import**

Run: `cd server && uv run python -c "from memory.rdbms import models; print(models.MessageRow.__tablename__)"`
Expected: prints `messages`.

- [ ] **Step 3: Commit**

```bash
git add server/memory/rdbms/__init__.py server/memory/rdbms/base.py server/memory/rdbms/models.py
git commit -m "feat(memory): SQLAlchemy base and three tables"
```

---

## Task 6: `ConversationMemoryStore` (unit test on SQLite)

**Files:**
- Create: `server/memory/rdbms/conversation_store.py`
- Test: `server/tests/memory/test_conversation_store.py`

> SQLite is used for the unit test so CI does not need Postgres. JSONB columns degrade gracefully on SQLite via the JSON type; the test does not rely on JSONB-specific features.

- [ ] **Step 1: Write the failing test**

`server/tests/memory/test_conversation_store.py`:
```python
import uuid
import pytest
from sqlalchemy.ext.asyncio import create_async_engine

from memory.rdbms.base import Base, make_session_factory
from memory.rdbms.conversation_store import ConversationMemoryStore
from models.message import Message


@pytest.fixture
async def store():
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    factory = make_session_factory(engine)
    yield ConversationMemoryStore(factory)
    await engine.dispose()


@pytest.mark.asyncio
async def test_ensure_then_append_then_load(store):
    uid = uuid.uuid4()
    sid = uuid.uuid4()
    await store.ensure_user(str(uid), name="Alice")
    await store.ensure_session(str(sid), str(uid), workspace_path="/tmp/ws")

    mid = await store.append_message(
        str(sid),
        Message(role="user", content="hi"),
    )
    assert mid > 0
    await store.append_message(
        str(sid),
        Message(role="assistant", content="hello"),
    )
    loaded = await store.load_messages(str(sid))
    assert [m.role for m in loaded] == ["user", "assistant"]
    assert [m.content for m in loaded] == ["hi", "hello"]


@pytest.mark.asyncio
async def test_search_history_keyword(store):
    uid = uuid.uuid4()
    sid = uuid.uuid4()
    await store.ensure_user(str(uid))
    await store.ensure_session(str(sid), str(uid))
    await store.append_message(str(sid), Message(role="user", content="hello world"))
    await store.append_message(str(sid), Message(role="user", content="bye"))
    hits = await store.search_history(str(uid), "hello")
    assert len(hits) == 1
    assert hits[0].content == "hello world"


@pytest.mark.asyncio
async def test_delete_session_cascades(store):
    uid = uuid.uuid4()
    sid = uuid.uuid4()
    await store.ensure_user(str(uid))
    await store.ensure_session(str(sid), str(uid))
    await store.append_message(str(sid), Message(role="user", content="x"))
    await store.delete_session(str(sid))
    assert await store.load_messages(str(sid)) == []


@pytest.mark.asyncio
async def test_ensure_user_is_idempotent(store):
    uid = uuid.uuid4()
    await store.ensure_user(str(uid), name="A")
    await store.ensure_user(str(uid), name="A")  # must not raise
```

- [ ] **Step 2: Run test (should fail)**

Run: `cd server && uv run pytest tests/memory/test_conversation_store.py -v`
Expected: FAIL on `ModuleNotFoundError: memory.rdbms.conversation_store`.

- [ ] **Step 3: Implement the store**

`server/memory/rdbms/conversation_store.py`:
```python
import uuid
from typing import Sequence
from sqlalchemy import select, delete
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from memory.rdbms.models import MessageRow, SessionRow, UserRow
from models.message import Message


class ConversationMemoryStore:
    def __init__(self, session_factory: async_sessionmaker[AsyncSession]):
        self._factory = session_factory

    async def ensure_user(self, user_id: str, name: str | None = None) -> None:
        uid = uuid.UUID(user_id)
        async with self._factory() as session:
            existing = await session.get(UserRow, uid)
            if existing is None:
                session.add(UserRow(id=uid, name=name))
                await session.commit()

    async def ensure_session(
        self, session_id: str, user_id: str, workspace_path: str = "/tmp"
    ) -> None:
        sid = uuid.UUID(session_id)
        uid = uuid.UUID(user_id)
        async with self._factory() as session:
            existing = await session.get(SessionRow, sid)
            if existing is None:
                session.add(
                    SessionRow(id=sid, user_id=uid, workspace_path=workspace_path)
                )
                await session.commit()

    async def append_message(self, session_id: str, msg: Message) -> int:
        sid = uuid.UUID(session_id)
        async with self._factory() as session:
            row = MessageRow(
                session_id=sid,
                role=msg.role,
                content=msg.content,
                tool_calls=msg.tool_calls,
                tool_call_id=msg.tool_call_id,
                name=msg.name,
            )
            session.add(row)
            await session.commit()
            await session.refresh(row)
            return row.id

    async def load_messages(
        self, session_id: str, limit: int | None = None
    ) -> list[Message]:
        sid = uuid.UUID(session_id)
        async with self._factory() as session:
            stmt = (
                select(MessageRow)
                .where(MessageRow.session_id == sid)
                .order_by(MessageRow.id.asc())
            )
            if limit:
                stmt = stmt.limit(limit)
            result = await session.execute(stmt)
            rows: Sequence[MessageRow] = result.scalars().all()
            return [self._row_to_message(r) for r in rows]

    async def search_history(
        self, user_id: str, keyword: str, limit: int = 20
    ) -> list[Message]:
        uid = uuid.UUID(user_id)
        async with self._factory() as session:
            stmt = (
                select(MessageRow)
                .join(SessionRow, SessionRow.id == MessageRow.session_id)
                .where(SessionRow.user_id == uid)
                .where(MessageRow.content.ilike(f"%{keyword}%"))
                .order_by(MessageRow.id.desc())
                .limit(limit)
            )
            result = await session.execute(stmt)
            return [self._row_to_message(r) for r in result.scalars().all()]

    async def delete_session(self, session_id: str) -> None:
        sid = uuid.UUID(session_id)
        async with self._factory() as session:
            await session.execute(
                delete(MessageRow).where(MessageRow.session_id == sid)
            )
            await session.execute(delete(SessionRow).where(SessionRow.id == sid))
            await session.commit()

    @staticmethod
    def _row_to_message(row: MessageRow) -> Message:
        return Message(
            role=row.role,
            content=row.content,
            tool_calls=row.tool_calls,
            tool_call_id=row.tool_call_id,
            name=row.name,
        )
```

- [ ] **Step 4: Run test (should pass)**

Run: `cd server && uv run pytest tests/memory/test_conversation_store.py -v`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add server/memory/rdbms/conversation_store.py server/tests/memory/test_conversation_store.py
git commit -m "feat(memory): ConversationMemoryStore with CRUD + search"
```

---

## Task 7: Milvus client wrapper

**Files:**
- Create: `server/memory/vector/__init__.py`
- Create: `server/memory/vector/client.py`

> No standalone unit test for the wrapper; it is exercised through Task 8's `VectorMemoryStore` tests and Task 13's integration test.

- [ ] **Step 1: Create files**

`server/memory/vector/__init__.py` empty.

`server/memory/vector/client.py`:
```python
import asyncio
import os
from pymilvus import MilvusClient, DataType


class MemorySchemaMismatch(RuntimeError):
    pass


class MilvusClientWrapper:
    def __init__(self, lite_path: str):
        os.makedirs(os.path.dirname(lite_path) or ".", exist_ok=True)
        self._client = MilvusClient(lite_path)

    @property
    def raw(self) -> MilvusClient:
        return self._client

    async def ensure_collection(self, name: str, dim: int) -> None:
        await asyncio.to_thread(self._ensure_collection_sync, name, dim)

    def _ensure_collection_sync(self, name: str, dim: int) -> None:
        if self._client.has_collection(name):
            self._check_dim(name, dim)
            return

        schema = self._client.create_schema(auto_id=True, enable_dynamic_field=False)
        schema.add_field("id", DataType.INT64, is_primary=True, auto_id=True)
        schema.add_field("user_id", DataType.VARCHAR, max_length=64,
                         is_partition_key=True)
        schema.add_field("session_id", DataType.VARCHAR, max_length=64)
        schema.add_field("text", DataType.VARCHAR, max_length=8192)
        schema.add_field("embedding", DataType.FLOAT_VECTOR, dim=dim)
        schema.add_field("metadata", DataType.JSON)
        schema.add_field("created_at", DataType.INT64)

        index_params = self._client.prepare_index_params()
        index_params.add_index(
            field_name="embedding",
            index_type="HNSW",
            metric_type="COSINE",
            params={"M": 16, "efConstruction": 200},
        )
        self._client.create_collection(
            collection_name=name,
            schema=schema,
            index_params=index_params,
        )

    def _check_dim(self, name: str, expected_dim: int) -> None:
        info = self._client.describe_collection(name)
        for field in info["fields"]:
            if field["name"] == "embedding":
                actual = field["params"].get("dim")
                if int(actual) != int(expected_dim):
                    raise MemorySchemaMismatch(
                        f"Collection {name} has dim={actual} but embedder produces {expected_dim}"
                    )
                return
        raise MemorySchemaMismatch(f"Collection {name} missing 'embedding' field")

    def close(self) -> None:
        self._client.close()
```

- [ ] **Step 2: Smoke run**

Run: `cd server && uv run python -c "from memory.vector.client import MilvusClientWrapper; w = MilvusClientWrapper('/tmp/__test.db'); w.close(); print('ok')"`
Expected: prints `ok`.

- [ ] **Step 3: Commit**

```bash
git add server/memory/vector/__init__.py server/memory/vector/client.py
git commit -m "feat(memory): MilvusClientWrapper with ensure_collection"
```

---

## Task 8: `VectorMemoryStore` abstract base + record

**Files:**
- Create: `server/memory/vector/base.py`
- Test: `server/tests/memory/test_vector_base.py`

- [ ] **Step 1: Write the failing test**

`server/tests/memory/test_vector_base.py`:
```python
import time
import pytest
from unittest.mock import AsyncMock, MagicMock
from pydantic import BaseModel
from memory.vector.base import VectorMemoryStore, VectorRecord


class FakeMeta(BaseModel):
    topic: str


class FakeStore(VectorMemoryStore):
    collection_name = "fake_collection"
    metadata_schema = FakeMeta


@pytest.fixture
def stubs():
    client = MagicMock()
    raw = MagicMock()
    client.raw = raw
    embedder = MagicMock()
    embedder.embed = AsyncMock(return_value=[[0.1, 0.2, 0.3]])
    embedder.dim = 3
    return client, embedder, raw


@pytest.mark.asyncio
async def test_add_validates_metadata_and_inserts(stubs):
    client, embedder, raw = stubs
    raw.insert = MagicMock(return_value={"ids": [42]})
    store = FakeStore(client, embedder)
    new_id = await store.add(
        user_id="u1",
        text="hello",
        metadata={"topic": "ops"},
        session_id="s1",
    )
    assert new_id == 42
    embedder.embed.assert_awaited_once_with(["hello"])
    raw.insert.assert_called_once()
    args, kwargs = raw.insert.call_args
    record = kwargs["data"][0]
    assert record["user_id"] == "u1"
    assert record["session_id"] == "s1"
    assert record["text"] == "hello"
    assert record["metadata"] == {"topic": "ops"}
    assert record["embedding"] == [0.1, 0.2, 0.3]
    assert kwargs["collection_name"] == "fake_collection"


@pytest.mark.asyncio
async def test_add_rejects_invalid_metadata(stubs):
    client, embedder, _ = stubs
    store = FakeStore(client, embedder)
    with pytest.raises(ValueError):
        await store.add(user_id="u1", text="x", metadata={"wrong_key": "ops"})


@pytest.mark.asyncio
async def test_search_builds_user_filter(stubs):
    client, embedder, raw = stubs
    raw.search = MagicMock(return_value=[[
        {
            "id": 7,
            "entity": {
                "user_id": "u1",
                "session_id": "s1",
                "text": "t",
                "metadata": {"topic": "ops"},
                "created_at": 1000,
            },
            "distance": 0.12,
        },
    ]])
    store = FakeStore(client, embedder)
    out = await store.search(user_id="u1", query="hello", top_k=3)
    assert len(out) == 1
    assert out[0].id == 7
    assert out[0].score == 0.12
    _, kwargs = raw.search.call_args
    assert kwargs["collection_name"] == "fake_collection"
    assert kwargs["limit"] == 3
    assert 'user_id == "u1"' in kwargs["filter"]


@pytest.mark.asyncio
async def test_search_appends_metadata_filter(stubs):
    client, embedder, raw = stubs
    raw.search = MagicMock(return_value=[[]])
    store = FakeStore(client, embedder)
    await store.search(
        user_id="u1",
        query="hi",
        filter_metadata={"topic": "ops"},
    )
    _, kwargs = raw.search.call_args
    assert 'metadata["topic"] == "ops"' in kwargs["filter"]


@pytest.mark.asyncio
async def test_delete_calls_milvus(stubs):
    client, embedder, raw = stubs
    raw.delete = MagicMock()
    store = FakeStore(client, embedder)
    await store.delete(99)
    raw.delete.assert_called_once_with(
        collection_name="fake_collection", ids=[99]
    )
```

- [ ] **Step 2: Run test (should fail)**

Run: `cd server && uv run pytest tests/memory/test_vector_base.py -v`
Expected: FAIL with `ModuleNotFoundError: memory.vector.base`.

- [ ] **Step 3: Implement the base**

`server/memory/vector/base.py`:
```python
import asyncio
import time
from abc import ABC
from dataclasses import dataclass
from typing import Any, ClassVar
from pydantic import BaseModel, ValidationError
from memory.embeddings import Embedder
from memory.vector.client import MilvusClientWrapper


@dataclass
class VectorRecord:
    id: int | None
    user_id: str
    session_id: str | None
    text: str
    metadata: dict[str, Any]
    created_at: int
    score: float | None = None


def _format_value(v: Any) -> str:
    if isinstance(v, str):
        escaped = v.replace('"', '\\"')
        return f'"{escaped}"'
    if isinstance(v, bool):
        return "true" if v else "false"
    return str(v)


class VectorMemoryStore(ABC):
    collection_name: ClassVar[str]
    metadata_schema: ClassVar[type[BaseModel]]

    def __init__(self, client: MilvusClientWrapper, embedder: Embedder):
        self._client = client
        self._embedder = embedder

    def _validate_metadata(self, metadata: dict[str, Any]) -> dict[str, Any]:
        try:
            return self.metadata_schema(**metadata).model_dump(exclude_none=True)
        except ValidationError as e:
            raise ValueError(f"invalid metadata for {self.collection_name}: {e}") from e

    async def add(
        self,
        *,
        user_id: str,
        text: str,
        metadata: dict[str, Any],
        session_id: str | None = None,
    ) -> int:
        validated = self._validate_metadata(metadata)
        [vec] = await self._embedder.embed([text])
        record = {
            "user_id": user_id,
            "session_id": session_id or "",
            "text": text,
            "embedding": vec,
            "metadata": validated,
            "created_at": int(time.time() * 1000),
        }

        def _insert():
            return self._client.raw.insert(
                collection_name=self.collection_name, data=[record]
            )

        result = await asyncio.to_thread(_insert)
        return int(result["ids"][0])

    async def search(
        self,
        *,
        user_id: str,
        query: str,
        top_k: int = 5,
        filter_metadata: dict[str, Any] | None = None,
    ) -> list[VectorRecord]:
        [vec] = await self._embedder.embed([query])
        clauses = [f'user_id == "{user_id}"']
        if filter_metadata:
            for k, v in filter_metadata.items():
                clauses.append(f'metadata["{k}"] == {_format_value(v)}')
        expr = " and ".join(clauses)

        def _search():
            return self._client.raw.search(
                collection_name=self.collection_name,
                data=[vec],
                limit=top_k,
                filter=expr,
                output_fields=["user_id", "session_id", "text", "metadata", "created_at"],
            )

        hits = await asyncio.to_thread(_search)
        out: list[VectorRecord] = []
        for hit in hits[0]:
            ent = hit.get("entity", {})
            out.append(
                VectorRecord(
                    id=int(hit["id"]),
                    user_id=ent["user_id"],
                    session_id=ent.get("session_id") or None,
                    text=ent["text"],
                    metadata=ent.get("metadata") or {},
                    created_at=int(ent["created_at"]),
                    score=float(hit.get("distance", 0.0)),
                )
            )
        return out

    async def get(self, record_id: int) -> VectorRecord | None:
        def _get():
            return self._client.raw.get(
                collection_name=self.collection_name, ids=[record_id]
            )

        results = await asyncio.to_thread(_get)
        if not results:
            return None
        ent = results[0]
        return VectorRecord(
            id=int(ent["id"]),
            user_id=ent["user_id"],
            session_id=ent.get("session_id") or None,
            text=ent["text"],
            metadata=ent.get("metadata") or {},
            created_at=int(ent["created_at"]),
        )

    async def delete(self, record_id: int) -> None:
        def _del():
            self._client.raw.delete(
                collection_name=self.collection_name, ids=[record_id]
            )

        await asyncio.to_thread(_del)

    async def delete_by_filter(
        self, *, user_id: str, filter_metadata: dict[str, Any]
    ) -> int:
        clauses = [f'user_id == "{user_id}"']
        for k, v in filter_metadata.items():
            clauses.append(f'metadata["{k}"] == {_format_value(v)}')
        expr = " and ".join(clauses)

        def _del():
            r = self._client.raw.delete(
                collection_name=self.collection_name, filter=expr
            )
            return int(r.get("delete_count", 0))

        return await asyncio.to_thread(_del)
```

- [ ] **Step 4: Run test (should pass)**

Run: `cd server && uv run pytest tests/memory/test_vector_base.py -v`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add server/memory/vector/base.py server/tests/memory/test_vector_base.py
git commit -m "feat(memory): VectorMemoryStore abstract base"
```

---

## Task 9: Six concrete vector stores

**Files:**
- Create: `server/memory/vector/knowledge.py`
- Create: `server/memory/vector/workflow.py`
- Create: `server/memory/vector/tool.py`
- Create: `server/memory/vector/entity.py`
- Create: `server/memory/vector/summary.py`
- Create: `server/memory/vector/profile.py`
- Test: `server/tests/memory/test_concrete_stores.py`

- [ ] **Step 1: Write the failing test**

`server/tests/memory/test_concrete_stores.py`:
```python
import pytest
from memory.vector.knowledge import KnowledgeMemoryStore, KnowledgeMetadata
from memory.vector.workflow import WorkflowMemoryStore, WorkflowMetadata
from memory.vector.tool import ToolMemoryStore, ToolMetadata
from memory.vector.entity import EntityMemoryStore, EntityMetadata
from memory.vector.summary import SummaryMemoryStore, SummaryMetadata
from memory.vector.profile import ProfileMemoryStore, ProfileMetadata


CASES = [
    (KnowledgeMemoryStore, KnowledgeMetadata, "mem_knowledge",
     {"topic": "ops"}, {}),
    (WorkflowMemoryStore, WorkflowMetadata, "mem_workflow",
     {"name": "deploy", "steps": ["a", "b"]}, {"steps": "not-a-list"}),
    (ToolMemoryStore, ToolMetadata, "mem_tool",
     {"tool_name": "shell"}, {}),
    (EntityMemoryStore, EntityMetadata, "mem_entity",
     {"entity": "A", "relation": "owns", "target": "B"}, {"entity": "A"}),
    (SummaryMemoryStore, SummaryMetadata, "mem_summary",
     {"time_range_start": 1, "time_range_end": 2, "message_count": 3}, {}),
    (ProfileMemoryStore, ProfileMetadata, "mem_profile",
     {"trait": "lang", "value": "zh"}, {"trait": "lang"}),
]


def test_collection_names_unique():
    names = {case[2] for case in CASES}
    assert len(names) == 6


@pytest.mark.parametrize("StoreCls,SchemaCls,name,good,bad", CASES)
def test_collection_name_and_schema_bound(StoreCls, SchemaCls, name, good, bad):
    assert StoreCls.collection_name == name
    assert StoreCls.metadata_schema is SchemaCls
    # good metadata validates
    SchemaCls(**good)
    # bad metadata raises (when bad dict is non-empty)
    if bad:
        with pytest.raises(Exception):
            SchemaCls(**bad)
```

- [ ] **Step 2: Run test (should fail)**

Run: `cd server && uv run pytest tests/memory/test_concrete_stores.py -v`
Expected: FAIL with `ModuleNotFoundError`.

- [ ] **Step 3: Implement six stores**

`server/memory/vector/knowledge.py`:
```python
from pydantic import BaseModel
from memory.vector.base import VectorMemoryStore


class KnowledgeMetadata(BaseModel):
    topic: str
    source: str | None = None


class KnowledgeMemoryStore(VectorMemoryStore):
    collection_name = "mem_knowledge"
    metadata_schema = KnowledgeMetadata
```

`server/memory/vector/workflow.py`:
```python
from pydantic import BaseModel
from memory.vector.base import VectorMemoryStore


class WorkflowMetadata(BaseModel):
    name: str
    steps: list[str]
    tags: list[str] | None = None


class WorkflowMemoryStore(VectorMemoryStore):
    collection_name = "mem_workflow"
    metadata_schema = WorkflowMetadata
```

`server/memory/vector/tool.py`:
```python
from pydantic import BaseModel
from memory.vector.base import VectorMemoryStore


class ToolMetadata(BaseModel):
    tool_name: str
    usage_example: str | None = None
    success_rate: float | None = None


class ToolMemoryStore(VectorMemoryStore):
    collection_name = "mem_tool"
    metadata_schema = ToolMetadata
```

`server/memory/vector/entity.py`:
```python
from pydantic import BaseModel
from memory.vector.base import VectorMemoryStore


class EntityMetadata(BaseModel):
    entity: str
    relation: str
    target: str
    entity_type: str | None = None


class EntityMemoryStore(VectorMemoryStore):
    collection_name = "mem_entity"
    metadata_schema = EntityMetadata
```

`server/memory/vector/summary.py`:
```python
from pydantic import BaseModel
from memory.vector.base import VectorMemoryStore


class SummaryMetadata(BaseModel):
    time_range_start: int
    time_range_end: int
    message_count: int


class SummaryMemoryStore(VectorMemoryStore):
    collection_name = "mem_summary"
    metadata_schema = SummaryMetadata
```

`server/memory/vector/profile.py`:
```python
from pydantic import BaseModel
from memory.vector.base import VectorMemoryStore


class ProfileMetadata(BaseModel):
    trait: str
    value: str
    confidence: float | None = None


class ProfileMemoryStore(VectorMemoryStore):
    collection_name = "mem_profile"
    metadata_schema = ProfileMetadata
```

- [ ] **Step 4: Run test (should pass)**

Run: `cd server && uv run pytest tests/memory/test_concrete_stores.py -v`
Expected: PASS, 7 tests (parametrize × 6 + uniqueness).

- [ ] **Step 5: Commit**

```bash
git add server/memory/vector/*.py server/tests/memory/test_concrete_stores.py
git commit -m "feat(memory): six concrete vector stores"
```

---

## Task 10: `MemoryService` facade

**Files:**
- Create: `server/memory/service.py`
- Modify: `server/memory/__init__.py`
- Test: `server/tests/memory/test_service.py`

- [ ] **Step 1: Write the failing test**

`server/tests/memory/test_service.py`:
```python
import pytest
from unittest.mock import AsyncMock, MagicMock, patch
from memory.config import MemoryConfig
from memory.service import MemoryService


CFG = MemoryConfig(
    postgres_dsn="sqlite+aiosqlite:///:memory:",
    milvus_lite_path="/tmp/__svc.db",
    ark_api_key="ak",
    ark_base_url="https://ark.example.com/api/coding/v3",
    embedding_model="doubao-embedding-vision",
    write_async=True,
)


@pytest.mark.asyncio
async def test_create_initializes_all_stores():
    with (
        patch("memory.service.DoubaoEmbedder") as Emb,
        patch("memory.service.MilvusClientWrapper") as MC,
    ):
        emb = MagicMock()
        emb.probe = AsyncMock(return_value=1024)
        emb.dim = 1024
        Emb.return_value = emb
        client = MagicMock()
        client.ensure_collection = AsyncMock()
        MC.return_value = client

        svc = await MemoryService.create(CFG)

        assert svc.conversation is not None
        for attr in ("knowledge", "workflow", "tool", "entity", "summary", "profile"):
            assert getattr(svc, attr) is not None
        assert client.ensure_collection.await_count == 6
        await svc.close()
```

- [ ] **Step 2: Run test (should fail)**

Run: `cd server && uv run pytest tests/memory/test_service.py -v`
Expected: FAIL with `ModuleNotFoundError: memory.service`.

- [ ] **Step 3: Implement `MemoryService`**

`server/memory/service.py`:
```python
from sqlalchemy.ext.asyncio import AsyncEngine
from memory.config import MemoryConfig
from memory.embeddings import DoubaoEmbedder
from memory.rdbms.base import Base, make_engine, make_session_factory
from memory.rdbms.conversation_store import ConversationMemoryStore
from memory.vector.client import MilvusClientWrapper
from memory.vector.knowledge import KnowledgeMemoryStore
from memory.vector.workflow import WorkflowMemoryStore
from memory.vector.tool import ToolMemoryStore
from memory.vector.entity import EntityMemoryStore
from memory.vector.summary import SummaryMemoryStore
from memory.vector.profile import ProfileMemoryStore


class MemoryService:
    def __init__(
        self,
        *,
        engine: AsyncEngine,
        embedder: DoubaoEmbedder,
        milvus: MilvusClientWrapper,
        conversation: ConversationMemoryStore,
        knowledge: KnowledgeMemoryStore,
        workflow: WorkflowMemoryStore,
        tool: ToolMemoryStore,
        entity: EntityMemoryStore,
        summary: SummaryMemoryStore,
        profile: ProfileMemoryStore,
    ):
        self._engine = engine
        self._embedder = embedder
        self._milvus = milvus
        self.conversation = conversation
        self.knowledge = knowledge
        self.workflow = workflow
        self.tool = tool
        self.entity = entity
        self.summary = summary
        self.profile = profile

    @classmethod
    async def create(cls, cfg: MemoryConfig) -> "MemoryService":
        engine = make_engine(cfg.postgres_dsn)
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)
        factory = make_session_factory(engine)
        conversation = ConversationMemoryStore(factory)

        embedder = DoubaoEmbedder(cfg)
        dim = await embedder.probe()

        milvus = MilvusClientWrapper(cfg.milvus_lite_path)
        knowledge = KnowledgeMemoryStore(milvus, embedder)
        workflow = WorkflowMemoryStore(milvus, embedder)
        tool = ToolMemoryStore(milvus, embedder)
        entity = EntityMemoryStore(milvus, embedder)
        summary = SummaryMemoryStore(milvus, embedder)
        profile = ProfileMemoryStore(milvus, embedder)
        for store in (knowledge, workflow, tool, entity, summary, profile):
            await milvus.ensure_collection(store.collection_name, dim)

        return cls(
            engine=engine,
            embedder=embedder,
            milvus=milvus,
            conversation=conversation,
            knowledge=knowledge,
            workflow=workflow,
            tool=tool,
            entity=entity,
            summary=summary,
            profile=profile,
        )

    async def close(self) -> None:
        await self._embedder.aclose()
        self._milvus.close()
        await self._engine.dispose()
```

Update `server/memory/__init__.py`:
```python
from memory.config import MemoryConfig
from memory.service import MemoryService

__all__ = ["MemoryConfig", "MemoryService"]
```

- [ ] **Step 4: Run test (should pass)**

Run: `cd server && uv run pytest tests/memory/test_service.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add server/memory/service.py server/memory/__init__.py server/tests/memory/test_service.py
git commit -m "feat(memory): MemoryService facade with 6-collection init"
```

---

## Task 11: Memory tools for the LLM

**Files:**
- Create: `server/tools/memory_tools.py`
- Test: `server/tests/memory/test_memory_tools.py`

> Tools accept `user_id` via a `ContextVar` so the LLM never sees it. Pattern mirrors existing `ws_manager_var`.

- [ ] **Step 1: Write the failing test**

`server/tests/memory/test_memory_tools.py`:
```python
import pytest
from unittest.mock import AsyncMock, MagicMock
from memory.vector.base import VectorRecord
from tools.memory_tools import build_memory_tools, current_user_id_var


@pytest.mark.asyncio
async def test_search_knowledge_tool_uses_context_user_id():
    svc = MagicMock()
    svc.knowledge.search = AsyncMock(return_value=[
        VectorRecord(
            id=1, user_id="u1", session_id=None, text="t",
            metadata={"topic": "ops"}, created_at=1000, score=0.1,
        )
    ])
    tools = build_memory_tools(svc)
    by_name = {t.name: t for t in tools}
    token = current_user_id_var.set("u1")
    try:
        result = await by_name["search_knowledge"].ainvoke({"query": "deploy"})
    finally:
        current_user_id_var.reset(token)
    svc.knowledge.search.assert_awaited_once()
    kwargs = svc.knowledge.search.await_args.kwargs
    assert kwargs["user_id"] == "u1"
    assert kwargs["query"] == "deploy"
    assert "ops" in result


@pytest.mark.asyncio
async def test_tools_cover_seven_names():
    svc = MagicMock()
    tools = build_memory_tools(svc)
    names = {t.name for t in tools}
    assert names == {
        "search_history",
        "search_knowledge",
        "search_workflow",
        "search_tool_memory",
        "search_entity",
        "search_summary",
        "search_profile",
    }


@pytest.mark.asyncio
async def test_search_history_uses_conversation_store():
    svc = MagicMock()
    from models.message import Message
    svc.conversation.search_history = AsyncMock(
        return_value=[Message(role="user", content="hello")]
    )
    tools = build_memory_tools(svc)
    by_name = {t.name: t for t in tools}
    token = current_user_id_var.set("u1")
    try:
        result = await by_name["search_history"].ainvoke({"keyword": "hello"})
    finally:
        current_user_id_var.reset(token)
    svc.conversation.search_history.assert_awaited_once_with(
        user_id="u1", keyword="hello", limit=20
    )
    assert "hello" in result


@pytest.mark.asyncio
async def test_tool_returns_error_when_no_user_id():
    svc = MagicMock()
    tools = build_memory_tools(svc)
    by_name = {t.name: t for t in tools}
    result = await by_name["search_knowledge"].ainvoke({"query": "x"})
    assert "error" in result.lower()
```

- [ ] **Step 2: Run test (should fail)**

Run: `cd server && uv run pytest tests/memory/test_memory_tools.py -v`
Expected: FAIL with `ModuleNotFoundError: tools.memory_tools`.

- [ ] **Step 3: Implement the tools**

`server/tools/memory_tools.py`:
```python
import json
from contextvars import ContextVar
from typing import Any
from pydantic import BaseModel, Field
from langchain_core.tools import StructuredTool, BaseTool
from memory.service import MemoryService

current_user_id_var: ContextVar[str | None] = ContextVar(
    "current_user_id", default=None
)


def _require_user_id() -> str | None:
    return current_user_id_var.get()


def _ok(payload: Any) -> str:
    return json.dumps(payload, ensure_ascii=False, default=str)


def _err(msg: str) -> str:
    return json.dumps({"error": msg, "results": []}, ensure_ascii=False)


class HistoryArgs(BaseModel):
    keyword: str = Field(description="Substring to match against past messages")
    limit: int = Field(default=20, ge=1, le=100)


class VectorSearchArgs(BaseModel):
    query: str = Field(description="Search query in natural language")
    top_k: int = Field(default=5, ge=1, le=20)


class KnowledgeArgs(VectorSearchArgs):
    topic: str | None = None


class WorkflowArgs(VectorSearchArgs):
    name: str | None = None


class ToolMemoryArgs(VectorSearchArgs):
    tool_name: str | None = None


class EntityArgs(VectorSearchArgs):
    entity: str | None = None
    relation: str | None = None


class SummaryArgs(VectorSearchArgs):
    top_k: int = Field(default=3, ge=1, le=20)


class ProfileArgs(VectorSearchArgs):
    trait: str | None = None


def _vector_filter(*pairs: tuple[str, Any]) -> dict[str, Any] | None:
    out = {k: v for k, v in pairs if v is not None}
    return out or None


def build_memory_tools(svc: MemoryService) -> list[BaseTool]:
    async def _search_history(keyword: str, limit: int = 20) -> str:
        uid = _require_user_id()
        if uid is None:
            return _err("user_id not set in context")
        msgs = await svc.conversation.search_history(uid, keyword, limit)
        return _ok([m.to_dict() for m in msgs])

    async def _search_knowledge(query: str, top_k: int = 5, topic: str | None = None) -> str:
        uid = _require_user_id()
        if uid is None:
            return _err("user_id not set in context")
        recs = await svc.knowledge.search(
            user_id=uid, query=query, top_k=top_k,
            filter_metadata=_vector_filter(("topic", topic)),
        )
        return _ok([r.__dict__ for r in recs])

    async def _search_workflow(query: str, top_k: int = 5, name: str | None = None) -> str:
        uid = _require_user_id()
        if uid is None:
            return _err("user_id not set in context")
        recs = await svc.workflow.search(
            user_id=uid, query=query, top_k=top_k,
            filter_metadata=_vector_filter(("name", name)),
        )
        return _ok([r.__dict__ for r in recs])

    async def _search_tool_memory(query: str, top_k: int = 5, tool_name: str | None = None) -> str:
        uid = _require_user_id()
        if uid is None:
            return _err("user_id not set in context")
        recs = await svc.tool.search(
            user_id=uid, query=query, top_k=top_k,
            filter_metadata=_vector_filter(("tool_name", tool_name)),
        )
        return _ok([r.__dict__ for r in recs])

    async def _search_entity(query: str, top_k: int = 5,
                             entity: str | None = None,
                             relation: str | None = None) -> str:
        uid = _require_user_id()
        if uid is None:
            return _err("user_id not set in context")
        recs = await svc.entity.search(
            user_id=uid, query=query, top_k=top_k,
            filter_metadata=_vector_filter(("entity", entity), ("relation", relation)),
        )
        return _ok([r.__dict__ for r in recs])

    async def _search_summary(query: str, top_k: int = 3) -> str:
        uid = _require_user_id()
        if uid is None:
            return _err("user_id not set in context")
        recs = await svc.summary.search(user_id=uid, query=query, top_k=top_k)
        return _ok([r.__dict__ for r in recs])

    async def _search_profile(query: str, top_k: int = 5, trait: str | None = None) -> str:
        uid = _require_user_id()
        if uid is None:
            return _err("user_id not set in context")
        recs = await svc.profile.search(
            user_id=uid, query=query, top_k=top_k,
            filter_metadata=_vector_filter(("trait", trait)),
        )
        return _ok([r.__dict__ for r in recs])

    return [
        StructuredTool.from_function(
            coroutine=_search_history, name="search_history",
            description="Keyword-search the user's past messages.",
            args_schema=HistoryArgs,
        ),
        StructuredTool.from_function(
            coroutine=_search_knowledge, name="search_knowledge",
            description="Semantic search over stored knowledge facts.",
            args_schema=KnowledgeArgs,
        ),
        StructuredTool.from_function(
            coroutine=_search_workflow, name="search_workflow",
            description="Semantic search over saved workflows / SOPs.",
            args_schema=WorkflowArgs,
        ),
        StructuredTool.from_function(
            coroutine=_search_tool_memory, name="search_tool_memory",
            description="Semantic search over remembered tool usage experience.",
            args_schema=ToolMemoryArgs,
        ),
        StructuredTool.from_function(
            coroutine=_search_entity, name="search_entity",
            description="Semantic search over entity-relation triples.",
            args_schema=EntityArgs,
        ),
        StructuredTool.from_function(
            coroutine=_search_summary, name="search_summary",
            description="Semantic search over conversation summaries.",
            args_schema=SummaryArgs,
        ),
        StructuredTool.from_function(
            coroutine=_search_profile, name="search_profile",
            description="Semantic search over the user's profile traits.",
            args_schema=ProfileArgs,
        ),
    ]
```

- [ ] **Step 4: Run test (should pass)**

Run: `cd server && uv run pytest tests/memory/test_memory_tools.py -v`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add server/tools/memory_tools.py server/tests/memory/test_memory_tools.py
git commit -m "feat(memory): seven LLM memory-search tools"
```

---

## Task 12: Wire `SessionManager` to write-through

**Files:**
- Modify: `server/session/manager.py`
- Test: `server/tests/test_session_manager.py` (new)

- [ ] **Step 1: Write the failing test**

`server/tests/test_session_manager.py`:
```python
import asyncio
import pytest
from unittest.mock import AsyncMock, MagicMock
from session.manager import SessionManager


@pytest.mark.asyncio
async def test_add_message_schedules_persistence():
    mem = MagicMock()
    mem.conversation.ensure_user = AsyncMock()
    mem.conversation.ensure_session = AsyncMock()
    mem.conversation.append_message = AsyncMock(return_value=1)
    mgr = SessionManager(memory=mem, default_user_id="default-user")
    sess = await mgr.create_session_async()
    sess.add_message(role="user", content="hi")
    # allow background task to run
    await asyncio.sleep(0)
    await asyncio.sleep(0)
    mem.conversation.append_message.assert_awaited()


@pytest.mark.asyncio
async def test_get_or_load_hits_memory_first():
    mem = MagicMock()
    mem.conversation.load_messages = AsyncMock(return_value=[])
    mgr = SessionManager(memory=mem)
    sess = await mgr.create_session_async()
    fetched = await mgr.get_or_load(sess.id)
    assert fetched is sess
    mem.conversation.load_messages.assert_not_called()


@pytest.mark.asyncio
async def test_get_or_load_miss_loads_from_pg():
    from models.message import Message
    mem = MagicMock()
    mem.conversation.ensure_user = AsyncMock()
    mem.conversation.ensure_session = AsyncMock()
    mem.conversation.load_messages = AsyncMock(
        return_value=[Message(role="user", content="hi")]
    )
    mgr = SessionManager(memory=mem)
    sess = await mgr.get_or_load("00000000-0000-0000-0000-000000000001")
    assert len(sess.messages) == 1
    mem.conversation.load_messages.assert_awaited_once()


def test_manager_without_memory_still_works():
    mgr = SessionManager()
    sess = mgr.create_session()
    sess.add_message(role="user", content="hi")
    assert sess.messages[0].content == "hi"
```

- [ ] **Step 2: Run test (should fail)**

Run: `cd server && uv run pytest tests/test_session_manager.py -v`
Expected: FAIL on `create_session_async` / `memory` kwarg.

- [ ] **Step 3: Update `session/manager.py`**

Replace contents of `server/session/manager.py`:
```python
import asyncio
import logging
import uuid
from collections.abc import MutableMapping
from typing import TYPE_CHECKING
from models.message import Message

if TYPE_CHECKING:
    from memory.service import MemoryService

logger = logging.getLogger("wesee.session")


class Session:
    def __init__(self, user_id: str = "default-user"):
        self.id = str(uuid.uuid4())
        self.user_id = user_id
        self.messages: list[Message] = []
        self.workspace_path: str = "/tmp"
        self._on_message: "list[callable]" = []

    def on_message(self, callback) -> None:
        self._on_message.append(callback)

    def add_message(self, *, role: str, content: str | None = None,
                    tool_calls: list[dict] | None = None,
                    tool_call_id: str | None = None,
                    name: str | None = None) -> Message:
        msg = Message(
            role=role,
            content=content,
            tool_calls=tool_calls,
            tool_call_id=tool_call_id,
            name=name,
        )
        self.messages.append(msg)
        for cb in self._on_message:
            try:
                cb(self, msg)
            except Exception as exc:
                logger.error("on_message callback failed: %s", exc)
        return msg

    def clear(self):
        self.messages.clear()

    def set_workspace(self, path: str):
        self.workspace_path = path


class SessionManager(MutableMapping[str, Session]):
    def __init__(
        self,
        memory: "MemoryService | None" = None,
        default_user_id: str = "default-user",
    ):
        self._sessions: dict[str, Session] = {}
        self._memory = memory
        self._default_user_id = default_user_id

    def create_session(self) -> Session:
        session = Session(user_id=self._default_user_id)
        self._sessions[session.id] = session
        self._attach_persistence(session)
        return session

    async def create_session_async(self) -> Session:
        session = self.create_session()
        if self._memory is not None:
            await self._memory.conversation.ensure_user(session.user_id)
            await self._memory.conversation.ensure_session(
                session.id, session.user_id, session.workspace_path
            )
        return session

    async def get_or_load(self, session_id: str) -> Session:
        if session_id in self._sessions:
            return self._sessions[session_id]
        session = Session(user_id=self._default_user_id)
        session.id = session_id
        self._sessions[session_id] = session
        self._attach_persistence(session)
        if self._memory is not None:
            await self._memory.conversation.ensure_user(session.user_id)
            await self._memory.conversation.ensure_session(
                session_id, session.user_id, session.workspace_path
            )
            session.messages = await self._memory.conversation.load_messages(
                session_id
            )
        return session

    def remove_session(self, session_id: str):
        self._sessions.pop(session_id, None)

    def get_session(self, session_id: str) -> Session | None:
        return self._sessions.get(session_id)

    def _attach_persistence(self, session: Session) -> None:
        if self._memory is None:
            return
        mem = self._memory
        sid = session.id

        def _persist(_sess: Session, msg: Message) -> None:
            async def _do():
                try:
                    await mem.conversation.append_message(sid, msg)
                except Exception as exc:
                    logger.error("persist message failed sid=%s: %s", sid, exc)

            try:
                asyncio.get_running_loop().create_task(_do())
            except RuntimeError:
                asyncio.run(_do())

        session.on_message(_persist)

    def __getitem__(self, key: str) -> Session:
        return self._sessions[key]

    def __setitem__(self, key: str, value: Session):
        self._sessions[key] = value

    def __delitem__(self, key: str):
        del self._sessions[key]

    def __iter__(self):
        return iter(self._sessions)

    def __len__(self) -> int:
        return len(self._sessions)
```

- [ ] **Step 4: Run test (should pass)**

Run: `cd server && uv run pytest tests/test_session_manager.py -v`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add server/session/manager.py server/tests/test_session_manager.py
git commit -m "feat(session): write-through persistence and lazy load"
```

---

## Task 13: REST memory router

**Files:**
- Create: `server/handlers/memory_api.py`
- Test: `server/tests/test_memory_api.py`

- [ ] **Step 1: Write the failing test**

`server/tests/test_memory_api.py`:
```python
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from unittest.mock import AsyncMock, MagicMock
from memory.vector.base import VectorRecord
from handlers.memory_api import create_memory_router


def _svc_with_history():
    svc = MagicMock()
    from models.message import Message
    svc.conversation.load_messages = AsyncMock(
        return_value=[Message(role="user", content="hi")]
    )
    svc.knowledge.add = AsyncMock(return_value=42)
    svc.knowledge.search = AsyncMock(return_value=[
        VectorRecord(id=1, user_id="u", session_id=None, text="t",
                     metadata={"topic": "ops"}, created_at=1000, score=0.1)
    ])
    svc.knowledge.delete = AsyncMock()
    return svc


@pytest.fixture
def client():
    svc = _svc_with_history()
    app = FastAPI()
    app.include_router(create_memory_router(svc))
    return TestClient(app), svc


def test_history_endpoint(client):
    tc, svc = client
    r = tc.get("/memory/history/abc")
    assert r.status_code == 200
    assert r.json()["messages"][0]["content"] == "hi"


def test_post_knowledge(client):
    tc, svc = client
    r = tc.post("/memory/knowledge", json={
        "user_id": "u1",
        "text": "rules",
        "metadata": {"topic": "ops"},
    })
    assert r.status_code == 200
    assert r.json()["id"] == 42
    svc.knowledge.add.assert_awaited_once()


def test_search_knowledge(client):
    tc, _ = client
    r = tc.get("/memory/knowledge/search",
               params={"user_id": "u1", "query": "x", "top_k": 5})
    assert r.status_code == 200
    body = r.json()
    assert body["results"][0]["text"] == "t"


def test_delete_knowledge(client):
    tc, svc = client
    r = tc.delete("/memory/knowledge/7")
    assert r.status_code == 200
    svc.knowledge.delete.assert_awaited_once_with(7)


def test_unknown_type_returns_404(client):
    tc, _ = client
    r = tc.get("/memory/wrong/search", params={"user_id": "u", "query": "x"})
    assert r.status_code == 404
```

- [ ] **Step 2: Run test (should fail)**

Run: `cd server && uv run pytest tests/test_memory_api.py -v`
Expected: FAIL with `ModuleNotFoundError: handlers.memory_api`.

- [ ] **Step 3: Implement the router**

`server/handlers/memory_api.py`:
```python
from typing import Any
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from memory.service import MemoryService


class AddRequest(BaseModel):
    user_id: str
    text: str
    metadata: dict[str, Any]
    session_id: str | None = None


def _store_for(svc: MemoryService, mem_type: str):
    mapping = {
        "knowledge": svc.knowledge,
        "workflow": svc.workflow,
        "tool": svc.tool,
        "entity": svc.entity,
        "summary": svc.summary,
        "profile": svc.profile,
    }
    store = mapping.get(mem_type)
    if store is None:
        raise HTTPException(404, detail=f"unknown memory type: {mem_type}")
    return store


def create_memory_router(svc: MemoryService) -> APIRouter:
    router = APIRouter(prefix="/memory")

    @router.get("/history/{session_id}")
    async def history(session_id: str):
        msgs = await svc.conversation.load_messages(session_id)
        return {"messages": [m.to_dict() for m in msgs]}

    @router.post("/{mem_type}")
    async def add(mem_type: str, body: AddRequest):
        store = _store_for(svc, mem_type)
        try:
            new_id = await store.add(
                user_id=body.user_id,
                text=body.text,
                metadata=body.metadata,
                session_id=body.session_id,
            )
        except ValueError as e:
            raise HTTPException(400, detail=str(e))
        return {"id": new_id}

    @router.get("/{mem_type}/search")
    async def search(mem_type: str, user_id: str, query: str, top_k: int = 5):
        store = _store_for(svc, mem_type)
        records = await store.search(user_id=user_id, query=query, top_k=top_k)
        return {"results": [r.__dict__ for r in records]}

    @router.delete("/{mem_type}/{record_id}")
    async def delete(mem_type: str, record_id: int):
        store = _store_for(svc, mem_type)
        await store.delete(record_id)
        return {"ok": True}

    return router
```

- [ ] **Step 4: Run test (should pass)**

Run: `cd server && uv run pytest tests/test_memory_api.py -v`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add server/handlers/memory_api.py server/tests/test_memory_api.py
git commit -m "feat(memory): REST router at /memory"
```

---

## Task 14: Wire `main.py`

**Files:**
- Modify: `server/main.py`

- [ ] **Step 1: Patch `create_app`**

Edit `server/main.py`. Replace `create_app` body so it:

1. Imports: at top of file add
```python
from memory import MemoryConfig, MemoryService
from handlers.memory_api import create_memory_router
from tools.memory_tools import build_memory_tools
```
2. Make `create_app` async (FastAPI supports startup hooks; we use lifespan):
```python
from contextlib import asynccontextmanager


def create_app(config: ServerConfig | None = None) -> FastAPI:
    if config is None:
        config = ServerConfig(api_key="sk-test")

    memory_holder: dict[str, MemoryService | None] = {"svc": None}

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        mem = await MemoryService.create(MemoryConfig.from_server_config(config))
        memory_holder["svc"] = mem
        app.state.memory = mem
        yield
        await mem.close()

    app = FastAPI(title="WeSee Server", lifespan=lifespan)

    tools = [
        ShellTool(workspace_path="/tmp"),
        FileSystemTool(workspace_path="/tmp"),
        ScreenshotTool(workspace_path="/tmp"),
    ]
    ws_manager = WebSocketManager()

    @app.on_event("startup")
    async def _wire_dependents():
        mem = memory_holder["svc"]
        assert mem is not None
        agent_runner = AgentRunner(config=config, tools=tools + build_memory_tools(mem))
        session_manager = SessionManager(memory=mem)
        app.state.agent_runner = agent_runner
        app.state.session_manager = session_manager
        app.include_router(create_api_router(session_manager, agent_runner))
        app.include_router(create_memory_router(mem))

        @app.websocket("/ws")
        async def websocket_endpoint(ws: WebSocket):
            await ws_manager.handle_client(ws, session_manager, agent_runner)

    try:
        app.mount("/", StaticFiles(directory="static", html=True), name="static")
    except Exception:
        pass

    return app
```

> If the dynamic-route approach turns out to conflict with FastAPI route resolution, fall back to: in `lifespan`, instantiate `agent_runner` / `session_manager` and pass them via `app.state` to module-level route functions that read `app.state` at request time.

- [ ] **Step 2: Manual smoke**

Run: `cd server && WESEE_API_KEY=sk-test WESEE_POSTGRES_DSN="sqlite+aiosqlite:///./data/wesee.db" WESEE_ARK_API_KEY=ak uv run python -c "import asyncio; from main import create_app; from config import ServerConfig; cfg=ServerConfig(api_key='sk-test', postgres_dsn='sqlite+aiosqlite:///:memory:', ark_api_key='ak'); print(create_app(cfg))"`
Expected: prints `<FastAPI ...>` without error.

- [ ] **Step 3: Commit**

```bash
git add server/main.py
git commit -m "feat(main): boot MemoryService and register memory tools/routes"
```

---

## Task 15: Bridge `current_user_id_var` from request to agent

**Files:**
- Modify: `server/handlers/websocket.py`
- Modify: `server/handlers/api.py`

> Sets the ContextVar so memory tools resolve `user_id`. We do not introduce real auth; the default user is `"default-user"`.

- [ ] **Step 1: Edit `websocket.py`**

In `handle_client`, just before `agent_task = asyncio.create_task(run_agent(...))`, add at the top of the function (after `await ws.accept()`):
```python
from tools.memory_tools import current_user_id_var
user_token = current_user_id_var.set(session.user_id)
```
In the `finally:` clause:
```python
current_user_id_var.reset(user_token)
```

Also replace `session_manager.create_session()` with `await session_manager.create_session_async()` (function is already async).

- [ ] **Step 2: Edit `api.py`**

Inside `event_generator`, wrap the body with the ContextVar:
```python
from tools.memory_tools import current_user_id_var
token = current_user_id_var.set(web_session.user_id)
try:
    async for event in agent_runner.run(...):
        ...
finally:
    current_user_id_var.reset(token)
```

- [ ] **Step 3: Run existing tests to ensure nothing broke**

Run: `cd server && uv run pytest tests/ -v --ignore=tests/integration --ignore=tests/e2e`
Expected: all existing + new memory tests pass.

- [ ] **Step 4: Commit**

```bash
git add server/handlers/websocket.py server/handlers/api.py
git commit -m "feat(handlers): bind user_id ContextVar for memory tools"
```

---

## Task 16: Integration test — Postgres via testcontainers

**Files:**
- Create: `server/tests/integration/__init__.py`
- Create: `server/tests/integration/test_memory_pg.py`

> This test is marked `slow` so unit-only runs skip it.

- [ ] **Step 1: Write the test**

`server/tests/integration/__init__.py` empty.

`server/tests/integration/test_memory_pg.py`:
```python
import asyncio
import uuid
import pytest

testcontainers = pytest.importorskip("testcontainers.postgres")
PostgresContainer = testcontainers.PostgresContainer

from sqlalchemy.ext.asyncio import create_async_engine
from memory.rdbms.base import Base, make_session_factory
from memory.rdbms.conversation_store import ConversationMemoryStore
from models.message import Message


@pytest.fixture(scope="module")
def pg_container():
    with PostgresContainer("postgres:16-alpine") as pg:
        url = pg.get_connection_url().replace(
            "postgresql+psycopg2://", "postgresql+asyncpg://"
        )
        yield url


@pytest.fixture
async def store(pg_container):
    engine = create_async_engine(pg_container)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    factory = make_session_factory(engine)
    yield ConversationMemoryStore(factory)
    await engine.dispose()


@pytest.mark.asyncio
@pytest.mark.slow
async def test_pg_end_to_end(store):
    uid = uuid.uuid4()
    sid = uuid.uuid4()
    await store.ensure_user(str(uid), name="alice")
    await store.ensure_session(str(sid), str(uid))
    await store.append_message(str(sid), Message(role="user", content="hello"))
    await store.append_message(str(sid), Message(
        role="assistant", content=None,
        tool_calls=[{"name": "shell", "args": {"command": "ls"}}],
    ))
    msgs = await store.load_messages(str(sid))
    assert len(msgs) == 2
    assert msgs[1].tool_calls[0]["name"] == "shell"
```

- [ ] **Step 2: Add marker to `pyproject.toml`**

Append under `[tool.pytest.ini_options]` (create section if missing):
```toml
[tool.pytest.ini_options]
markers = [
    "slow: tests that need docker",
]
asyncio_mode = "auto"
```

- [ ] **Step 3: Run**

Run: `cd server && uv run pytest tests/integration/test_memory_pg.py -v -m slow`
Expected: PASS (requires Docker).

- [ ] **Step 4: Commit**

```bash
git add server/tests/integration/__init__.py server/tests/integration/test_memory_pg.py server/pyproject.toml
git commit -m "test: PG integration via testcontainers"
```

---

## Task 17: Integration test — Milvus Lite

**Files:**
- Create: `server/tests/integration/test_memory_milvus.py`

- [ ] **Step 1: Write the test**

`server/tests/integration/test_memory_milvus.py`:
```python
import tempfile
import pytest
from unittest.mock import AsyncMock
from memory.vector.client import MilvusClientWrapper
from memory.vector.knowledge import KnowledgeMemoryStore


class FakeEmbedder:
    def __init__(self, dim: int = 8):
        self._dim = dim
        self.embed = AsyncMock(side_effect=lambda texts: [[0.0] * dim for _ in texts])

    @property
    def dim(self) -> int:
        return self._dim


@pytest.mark.asyncio
async def test_milvus_lite_add_search_delete(tmp_path):
    db_path = str(tmp_path / "m.db")
    client = MilvusClientWrapper(db_path)
    try:
        await client.ensure_collection("mem_knowledge", dim=8)
        store = KnowledgeMemoryStore(client, FakeEmbedder(8))
        new_id = await store.add(
            user_id="u1",
            text="how to deploy",
            metadata={"topic": "ops"},
            session_id="s1",
        )
        assert new_id > 0
        results = await store.search(user_id="u1", query="deploy", top_k=3)
        assert len(results) == 1
        assert results[0].text == "how to deploy"
        await store.delete(new_id)
        results = await store.search(user_id="u1", query="deploy", top_k=3)
        assert results == []
    finally:
        client.close()


@pytest.mark.asyncio
async def test_dim_mismatch_raises(tmp_path):
    from memory.vector.client import MemorySchemaMismatch
    db_path = str(tmp_path / "m.db")
    client = MilvusClientWrapper(db_path)
    try:
        await client.ensure_collection("mem_knowledge", dim=8)
        with pytest.raises(MemorySchemaMismatch):
            await client.ensure_collection("mem_knowledge", dim=16)
    finally:
        client.close()
```

- [ ] **Step 2: Run**

Run: `cd server && uv run pytest tests/integration/test_memory_milvus.py -v`
Expected: PASS, 2 tests.

- [ ] **Step 3: Commit**

```bash
git add server/tests/integration/test_memory_milvus.py
git commit -m "test: Milvus Lite integration"
```

---

## Task 18: E2E — agent invokes a memory tool

**Files:**
- Create: `server/tests/e2e/__init__.py`
- Create: `server/tests/e2e/test_agent_with_memory.py`

> Asserts the wiring (tool registration + ContextVar) without going through a real LLM: instantiate the tool list and invoke `search_knowledge` directly under a set ContextVar.

- [ ] **Step 1: Write the test**

`server/tests/e2e/__init__.py` empty.

`server/tests/e2e/test_agent_with_memory.py`:
```python
import pytest
import respx
from httpx import Response

from memory.config import MemoryConfig
from memory.service import MemoryService
from tools.memory_tools import build_memory_tools, current_user_id_var


CFG = MemoryConfig(
    postgres_dsn="sqlite+aiosqlite:///:memory:",
    milvus_lite_path="/tmp/__e2e.db",
    ark_api_key="ak",
    ark_base_url="https://ark.example.com/api/coding/v3",
    embedding_model="doubao-embedding-vision",
    write_async=True,
)


@pytest.mark.asyncio
@respx.mock
async def test_agent_can_recall_knowledge(tmp_path):
    respx.post("https://ark.example.com/api/coding/v3/embeddings").mock(
        return_value=Response(200, json={"data": [{"embedding": [0.0] * 8}]})
    )

    import os
    os.makedirs(tmp_path, exist_ok=True)
    cfg = MemoryConfig(
        postgres_dsn=CFG.postgres_dsn,
        milvus_lite_path=str(tmp_path / "e2e.db"),
        ark_api_key=CFG.ark_api_key,
        ark_base_url=CFG.ark_base_url,
        embedding_model=CFG.embedding_model,
        write_async=CFG.write_async,
    )
    svc = await MemoryService.create(cfg)
    try:
        await svc.knowledge.add(
            user_id="user-1",
            text="Expense policy: max 5000 RMB per trip.",
            metadata={"topic": "expense"},
        )

        tools = build_memory_tools(svc)
        by_name = {t.name: t for t in tools}
        token = current_user_id_var.set("user-1")
        try:
            result = await by_name["search_knowledge"].ainvoke({"query": "expense"})
        finally:
            current_user_id_var.reset(token)
        assert "Expense policy" in result
    finally:
        await svc.close()
```

- [ ] **Step 2: Run**

Run: `cd server && uv run pytest tests/e2e/test_agent_with_memory.py -v`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add server/tests/e2e/__init__.py server/tests/e2e/test_agent_with_memory.py
git commit -m "test(e2e): agent recalls knowledge via memory tool"
```

---

## Task 19: Coverage gate + final verification

**Files:** none (verification only).

- [ ] **Step 1: Add coverage runner**

Run: `cd server && uv add --group dev coverage pytest-cov`
Expected: deps added.

- [ ] **Step 2: Run full unit + integration**

Run: `cd server && uv run pytest tests/memory tests/test_session_manager.py tests/test_memory_api.py tests/test_config.py tests/integration tests/e2e --cov=memory --cov=tools.memory_tools --cov=session --cov=handlers.memory_api --cov-report=term-missing`
Expected: ≥ 80% line coverage for `memory/*`, `tools/memory_tools.py`, `session/manager.py`, `handlers/memory_api.py`.

- [ ] **Step 3: If coverage < 80%**

Identify missing lines in coverage report. Add small targeted tests (likely around: embedder error path, `delete_by_filter`, `get` on missing id). Repeat Step 2 until ≥ 80%.

- [ ] **Step 4: Commit any additions**

```bash
git add server/pyproject.toml server/uv.lock server/tests
git commit -m "test: bring memory-layer coverage above 80%"
```

---

## Self-Review Summary

- **Spec coverage:**
  - PG conversation (§7.1) → Tasks 5, 6, 12, 16 ✓
  - Six vector stores (§7.2) → Tasks 7, 8, 9, 17 ✓
  - MemoryService facade (§7.3) → Task 10 ✓
  - Doubao embedder (§7.4) → Task 4 ✓
  - 7 LLM tools (§7.5) → Tasks 11, 15 ✓
  - Config additions (§7.6) → Task 2 ✓
  - REST `/memory` router (§7.7) → Task 13 ✓
  - Startup wiring (§8.1) → Task 14 ✓
  - Write-through (§8.2) → Task 12 ✓
  - Error handling (§9) → covered by tests in Tasks 4, 6, 8, 11, 13 ✓
  - Testing strategy (§10) → Tasks 4–19 ✓
  - Dependencies (§11) → Task 1 ✓
  - `pg_trgm` extension note (§7.1) — deliberately deferred: SQLite unit tests use plain ILIKE; production deploy doc must note `CREATE EXTENSION` requirement (not a code task).

- **Placeholder scan:** none.

- **Type consistency:** `MemoryConfig.write_async` (not `memory_write_async`) used consistently after Task 3; `current_user_id_var` name stable across Tasks 11 / 15 / 18; `collection_name` lowercase strings match Task 9 ↔ Task 13's dispatch table.








