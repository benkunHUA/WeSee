# Agent Memory System — Design Spec

- **Date:** 2026-06-24
- **Status:** Draft, awaiting user approval
- **Scope:** Storage layer for a 7-type memory system. Extraction/distillation policy is explicitly out of scope.

## 1. Background

`server/session/manager.py` currently keeps all conversation state in a process-local `dict[str, Session]` with messages as a plain `list[Message]`. Nothing is persisted; restarting the FastAPI process wipes every conversation. The agent has no long-term memory beyond the current session and cannot recall prior facts, workflows, tool experience, entities, summaries, or user profile.

## 2. Goals

1. Persist conversation messages to a relational database so sessions survive restarts.
2. Provide six vector-backed memory collections (knowledge / workflow / tool / entity-relation / summary / profile), each isolated by user, queryable from the LLM as tools.
3. Keep storage-layer concerns separate from extraction concerns — this spec is purely about *where memory lives and how to read/write it*.

## 3. Non-goals (YAGNI)

1. Automatic distillation of conversations into the six vector collections (future spec).
2. Multi-provider embedding switching; one provider only (Doubao).
3. Memory TTL, ageing, compression, conflict resolution, confidence updates.
4. Cross-user public knowledge bases.
5. Cascade-delete from session → vector memory.
6. Schema migrations framework (Alembic). Initial release uses `Base.metadata.create_all`.

## 4. Decisions (locked)

| Topic | Decision |
|---|---|
| RDBMS | PostgreSQL via SQLAlchemy 2.0 async (`asyncpg`) |
| Vector DB | Milvus Lite (local file mode via `pymilvus.MilvusClient`) |
| Embedding provider | Doubao `doubao-embedding-vision`, base `https://ark.cn-beijing.volces.com/api/coding/v3` (OpenAI-compatible) |
| Embedding dim | Detected at startup, not hard-coded |
| Isolation | `user_id` is required; `session_id` is required for conversation, optional for vector memory. Milvus `user_id` is the partition key. |
| Distillation | **Out of scope.** Storage layer only. |
| Agent integration | Each memory type is exposed to the LLM as a `search_*` tool. No prompt injection from runner. |
| Module layout | New `server/memory/` package, one file per memory type. |

## 5. Architecture

```
┌───────────────────────────────────────────────────────┐
│ AgentRunner (existing)                                │
│   tools: shell, fs, screenshot,                       │
│          + 7 memory tools (NEW)                       │
└───────────────────────────────────────────────────────┘
             │ tool invocation
             ▼
┌───────────────────────────────────────────────────────┐
│ MemoryService (facade)                                │
│   .conversation   .knowledge   .workflow   .tool      │
│   .entity         .summary     .profile               │
└─────────┬─────────────────────────────────────┬───────┘
          │                                     │
          ▼                                     ▼
   ConversationMemoryStore             VectorMemoryStore × 6
        (SQLAlchemy async)                 (Milvus Lite)
          │                                     │
          ▼                                     ▼
   PostgreSQL                            ./data/wesee_memory.db
                                                ▲
                                                │
                                       DoubaoEmbedder
                                       (Ark Beijing, OpenAI-compatible)
```

### 5.1 Package layout

```
server/memory/
  __init__.py
  config.py              # MemoryConfig (subset of ServerConfig)
  embeddings.py          # DoubaoEmbedder
  service.py             # MemoryService facade
  rdbms/
    __init__.py
    base.py              # async engine + session factory
    models.py            # SQLAlchemy: User, Session, Message
    conversation_store.py
  vector/
    __init__.py
    client.py            # MilvusClient singleton + ensure_collection
    base.py              # VectorMemoryStore[Schema], VectorRecord
    knowledge.py
    workflow.py
    tool.py
    entity.py
    summary.py
    profile.py

server/tools/memory_tools.py   # 7 search tools for the LLM
server/handlers/memory_api.py  # REST router mounted at /memory
```

Constraints:
- `MemoryService` is the only surface the rest of the app touches.
- All six vector stores share one abstract `VectorMemoryStore` base; concrete subclasses are ~30 lines (set `collection_name` and `metadata_schema` only).
- Embedding actual dim is probed on `MemoryService.create()`; Milvus schemas built from that value, never hard-coded.

## 6. Data model

### 6.1 Relational (PostgreSQL)

**`users`**
| Column | Type | Notes |
|---|---|---|
| `id` | UUID PK | |
| `name` | VARCHAR(128) | nullable |
| `created_at` | TIMESTAMPTZ | default now() |

**`sessions`**
| Column | Type | Notes |
|---|---|---|
| `id` | UUID PK | matches existing `Session.id` |
| `user_id` | UUID FK→users.id | indexed |
| `workspace_path` | TEXT | replaces in-memory field |
| `created_at` | TIMESTAMPTZ | |
| `updated_at` | TIMESTAMPTZ | onupdate |

**`messages`**
| Column | Type | Notes |
|---|---|---|
| `id` | BIGSERIAL PK | monotonic ordering |
| `session_id` | UUID FK→sessions.id | composite index `(session_id, id)` |
| `role` | VARCHAR(16) | system/user/assistant/tool |
| `content` | TEXT | nullable (tool_calls path) |
| `tool_calls` | JSONB | nullable |
| `tool_call_id` | VARCHAR(128) | nullable |
| `name` | VARCHAR(128) | nullable |
| `created_at` | TIMESTAMPTZ | |

Field set is a 1-to-1 superset of `models/message.py::Message`; `Message.to_dict()` is reused for serialization.

### 6.2 Vector (Milvus Lite)

Every collection has identical structural fields; type-specific data lives in the `metadata` JSON column.

| Field | Type | Role |
|---|---|---|
| `id` | INT64 auto_id PK | |
| `user_id` | VARCHAR(64) | **partition key** |
| `session_id` | VARCHAR(64) | scalar, nullable allowed via empty string |
| `text` | VARCHAR(8192) | raw text, used for display and re-embedding if needed |
| `embedding` | FLOAT_VECTOR(dim) | index: HNSW (M=16, efConstruction=200), metric COSINE; fallback IVF_FLAT if HNSW unavailable in Lite |
| `metadata` | JSON | type-specific, validated by per-store pydantic schema |
| `created_at` | INT64 | unix ms |

**Collections & metadata schemas**

| Collection | metadata keys |
|---|---|
| `mem_knowledge` | `topic`, `source?` |
| `mem_workflow` | `name`, `steps[]`, `tags[]?` |
| `mem_tool` | `tool_name`, `usage_example?`, `success_rate?` |
| `mem_entity` | `entity`, `relation`, `target`, `entity_type?` |
| `mem_summary` | `time_range_start`, `time_range_end`, `message_count` |
| `mem_profile` | `trait`, `value`, `confidence?` |

## 7. Interfaces

### 7.1 ConversationMemoryStore

```python
class ConversationMemoryStore:
    async def ensure_user(self, user_id: str, name: str | None = None) -> None
    async def ensure_session(self, session_id: str, user_id: str,
                             workspace_path: str = "/tmp") -> None
    async def append_message(self, session_id: str, msg: Message) -> int
    async def load_messages(self, session_id: str,
                            limit: int | None = None) -> list[Message]
    async def search_history(self, user_id: str, keyword: str,
                             limit: int = 20) -> list[Message]
    async def delete_session(self, session_id: str) -> None
```

`search_history` is keyword/ILIKE-based, accelerated by a `pg_trgm` GIN index on `messages.content`. The `pg_trgm` extension is created idempotently during `MemoryService.create()` via `CREATE EXTENSION IF NOT EXISTS pg_trgm;` (requires the DB role to have permission; documented as a deploy prerequisite). Semantic search over old conversations is the job of `mem_summary`, not this method.

### 7.2 VectorMemoryStore base + concrete stores

```python
@dataclass
class VectorRecord:
    id: int | None
    user_id: str
    session_id: str | None
    text: str
    metadata: dict[str, Any]
    created_at: int
    score: float | None = None

class VectorMemoryStore(ABC):
    collection_name: str
    metadata_schema: type[BaseModel]

    async def add(self, *, user_id: str, text: str,
                  metadata: dict, session_id: str | None = None) -> int
    async def search(self, *, user_id: str, query: str, top_k: int = 5,
                     filter_metadata: dict | None = None) -> list[VectorRecord]
    async def get(self, record_id: int) -> VectorRecord | None
    async def delete(self, record_id: int) -> None
    async def delete_by_filter(self, *, user_id: str,
                               filter_metadata: dict) -> int
```

Concrete subclasses (knowledge/workflow/tool/entity/summary/profile) set only `collection_name` and `metadata_schema`.

`filter_metadata` is translated into Milvus boolean expressions on the JSON column.

### 7.3 MemoryService facade

```python
class MemoryService:
    conversation: ConversationMemoryStore
    knowledge: KnowledgeMemoryStore
    workflow:  WorkflowMemoryStore
    tool:      ToolMemoryStore
    entity:    EntityMemoryStore
    summary:   SummaryMemoryStore
    profile:   ProfileMemoryStore

    @classmethod
    async def create(cls, cfg: MemoryConfig) -> "MemoryService"
    async def close(self) -> None
```

`create()` performs (in order): SQLA engine init → `Base.metadata.create_all` → MilvusClient open → embedder probe → 6 × ensure_collection.

### 7.4 Embedder

```python
class Embedder(Protocol):
    async def embed(self, texts: list[str]) -> list[list[float]]
    @property
    def dim(self) -> int

class DoubaoEmbedder(Embedder):
    """OpenAI-compatible client; base_url + ARK_API_KEY + model=doubao-embedding-vision."""
```

Dim is determined by a single `embed(["probe"])` at startup and cached.

### 7.5 LLM tools

`server/tools/memory_tools.py` produces seven tool instances conforming to the existing `Tool` base.

| Tool name | LLM-visible args |
|---|---|
| `search_history` | `keyword: str`, `limit: int = 20` |
| `search_knowledge` | `query: str`, `topic?: str`, `top_k: int = 5` |
| `search_workflow` | `query: str`, `name?: str`, `top_k: int = 5` |
| `search_tool_memory` | `query: str`, `tool_name?: str`, `top_k: int = 5` |
| `search_entity` | `query: str`, `entity?: str`, `relation?: str`, `top_k: int = 5` |
| `search_summary` | `query: str`, `top_k: int = 3` |
| `search_profile` | `query: str`, `trait?: str`, `top_k: int = 5` |

`user_id` is injected from the agent context, **never** in the LLM-visible signature.

### 7.6 Config additions (`server/config.py`)

```python
postgres_dsn: str = "postgresql+asyncpg://wesee:wesee@localhost:5432/wesee"
milvus_lite_path: str = "./data/wesee_memory.db"
ark_api_key: str = ""
ark_base_url: str = "https://ark.cn-beijing.volces.com/api/coding/v3"
embedding_model: str = "doubao-embedding-vision"
memory_write_async: bool = True
```

Env prefix `WESEE_` is preserved. All new fields have safe defaults so existing tests continue to construct `ServerConfig(api_key="sk-test")`.

### 7.7 REST API additions

A new router `handlers/memory_api.py` mounted at `/memory`:

| Method | Path | Purpose |
|---|---|---|
| GET | `/memory/history/{session_id}` | Replay conversation |
| POST | `/memory/{type}` | Insert a vector record (`type` ∈ knowledge, workflow, tool, entity, summary, profile) |
| GET | `/memory/{type}/search` | Query vector records |
| DELETE | `/memory/{type}/{id}` | Delete by record id |

## 8. Data flow

### 8.1 Startup
```
main.create_app()
  └─ MemoryService.create(cfg)
       ├─ SQLA engine + create_all
       ├─ MilvusClient(milvus_lite_path)
       ├─ DoubaoEmbedder.probe()         # determine dim
       └─ ensure_collection × 6          # dim mismatch ⇒ raise
  └─ SessionManager(memory=memory_service)
  └─ AgentRunner(tools=tools + memory_tools(memory_service))
  └─ WebSocketManager(memory=memory_service)
  └─ APIRouter(/memory, ...)
```
Startup failures abort the process (fail-fast).

### 8.2 Conversation write path
```
WS receives user msg
  ↓
WebSocketManager.handle_client
  ├─ Session.add_message(...)                              # in-memory append
  └─ asyncio.create_task(
        memory.conversation.append_message(sid, msg))      # write-through
  ↓
AgentRunner.run(session)                                   # does not await PG
  ├─ LLM streams → assistant / tool_call / tool messages
  └─ Each message: add_message + create_task(append)
```
PG is the source of truth; in-memory is the hot cache. Background write errors are logged but never block user response.

### 8.3 Vector write path (this release: API-only, no automatic distillation)
```
LLM calls search_xxx → MemoryService.<type>.search

REST POST /memory/knowledge
  └─ KnowledgeMemoryStore.add()
       ├─ pydantic validate(metadata)
       ├─ await embedder.embed([text])
       └─ await asyncio.to_thread(MilvusClient.insert, ...)
```
pymilvus Lite is synchronous; all calls wrapped in `asyncio.to_thread`.

### 8.4 Conversation read path
```
WS reconnect with session_id
  ↓
SessionManager.get_or_load(sid)
  ├─ in-memory hit  → return
  └─ in-memory miss → memory.conversation.load_messages(sid)
                       → rehydrate Message[] into Session.messages
```

### 8.5 Tool call flow inside agent
```
LLM picks search_knowledge(query="A 公司报销规则")
  ↓
AgentRunner.run_tool_call(tool_call)
  ├─ pull user_id from SessionContext
  ├─ memory.knowledge.search(user_id, query, top_k=5)
  └─ JSON-serialize VectorRecord[] → tool message
  ↓
next LLM turn
```

## 9. Error handling

| Scenario | Behaviour |
|---|---|
| Startup: PG unreachable | raise, process exits |
| Startup: Milvus Lite file corrupt | raise, process exits |
| Startup: embedding dim mismatches an existing collection | raise `MemorySchemaMismatch`; user must migrate manually (no silent rebuild) |
| Runtime: PG write fails | log.error; in-memory not rolled back; next session load shows the gap |
| Runtime: Milvus search fails | tool returns `{"error": "...", "results": []}`; LLM decides next step |
| Runtime: embedder timeout | retry once with exponential backoff; final failure raises `EmbeddingError` |
| metadata pydantic validation fails | REST: HTTP 400; tool: `{"error": "invalid metadata"}` |
| `user_id` missing in tool call | reject + log — programming error, not runtime |

Never silent: every failure path either raises or returns a structured `error` field. Empty result lists must never mask exceptions.

## 10. Testing strategy

### 10.1 Unit (majority)
- `tests/memory/test_embedder.py` — mock httpx; assert URL/header/body; dim cache
- `tests/memory/test_conversation_store.py` — `aiosqlite` ephemeral DB; CRUD only (JSONB-specific paths covered in integration)
- `tests/memory/test_vector_base.py` — mock MilvusClient; assert call params, filter expr building, metadata validation
- One minimal schema test per concrete vector store (guards against metadata drift)

### 10.2 Integration
- `tests/integration/test_memory_pg.py` — real Postgres via testcontainers-python; full ensure_user → append → load → search loop
- `tests/integration/test_memory_milvus.py` — Milvus Lite in temp dir; ensure_collection → add → search → delete
- `tests/integration/test_memory_service.py` — MemoryService end-to-end; verify 7 stores coexist and `user_id` partitioning isolates records

### 10.3 End-to-end
- `tests/e2e/test_agent_with_memory.py` — boot FastAPI; pre-seed a knowledge record; simulate an LLM tool call to `search_knowledge`; assert recall
- Use `respx` to mock Doubao embedding HTTP — no external network in CI

### 10.4 Acceptance gates
- Coverage ≥ 80% (project rule)
- Every new async store method has both happy-path and error-path tests
- Unit layer runs without PG/Milvus services on a clean dev box; only the integration layer requires Docker

## 11. Dependencies to add (`server/pyproject.toml`)

- `sqlalchemy[asyncio]>=2.0`
- `asyncpg>=0.29`
- `pymilvus>=2.4` (Lite-capable)
- `httpx>=0.27` (already pulled by fastapi but pin explicitly for embedder)
- Dev: `aiosqlite`, `testcontainers[postgres]`, `respx`

## 12. Open questions

None at spec-approval time. Distillation strategy, automatic memory writes, ageing, and conflict resolution will each get their own follow-up spec.
