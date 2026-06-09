# WeSee Server + Client Integration Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Python FastAPI server with DeepSeek AI integration and wire the macOS client's RemoteClient to it with SSE streaming support.

**Architecture:** FastAPI REST server with SQLAlchemy async + SQLite, SSE streaming for chat responses. Client uses URLSession for REST and `URLSession.bytes(for:)` for SSE consumption, with a `ChatEvent` enum to represent stream events.

**Tech Stack:** Python 3.12+, FastAPI, SQLAlchemy 2.0 async, aiosqlite, httpx, uvicorn, Swift 6, SwiftUI, SwiftData

---

## File Structure

```
WeSee/
├── server/                          # NEW: Python service
│   ├── main.py                      # FastAPI app, CORS, lifespan
│   ├── config.py                    # Env-based settings
│   ├── requirements.txt             # Python dependencies
│   ├── database.py                  # Async engine + session factory
│   ├── models.py                    # SQLAlchemy ORM models
│   ├── schemas.py                   # Pydantic request/response schemas
│   ├── routers/
│   │   ├── __init__.py
│   │   ├── chat.py                  # POST /api/chat (SSE)
│   │   ├── conversations.py         # GET /api/conversations
│   │   ├── messages.py              # GET /api/messages, PATCH bookmark
│   │   ├── tags.py                  # GET/POST /api/tags
│   │   └── tasks.py                 # GET/POST /api/tasks, PATCH toggle
│   ├── services/
│   │   ├── __init__.py
│   │   └── deepseek.py              # httpx streaming client
│   └── tests/
│       ├── __init__.py
│       ├── conftest.py
│       ├── test_chat.py
│       ├── test_conversations.py
│       ├── test_messages.py
│       ├── test_tags.py
│       └── test_tasks.py
└── client/                           # EXISTING: macOS app (modified)
    └── WeSee/
        ├── Models/
        │   └── DTO.swift             # NEW: Codable DTOs
        ├── Services/
        │   ├── RemoteClient.swift    # MODIFY: updated protocol
        │   └── LiveRemoteClient.swift # NEW: URLSession implementation
        ├── ViewModels/
        │   ├── ChatViewModel.swift   # MODIFY: streaming + conversationId
        │   └── SidebarViewModel.swift # MODIFY: conversation list
        └── ContentView.swift          # MODIFY: wire LiveRemoteClient
```

---

### Task 1: Server Project Scaffolding

**Files:**
- Create: `server/requirements.txt`
- Create: `server/config.py`
- Create: `server/database.py`

- [ ] **Step 1: Write requirements.txt**

```txt
fastapi>=0.115.0
uvicorn[standard]>=0.30.0
sqlalchemy[asyncio]>=2.0.30
aiosqlite>=0.20.0
httpx>=0.27.0
pytest>=8.0
pytest-asyncio>=0.24.0
httpx-sse>=0.4.0
```

- [ ] **Step 2: Write config.py**

```python
import os
from functools import lru_cache


class Settings:
    deepseek_api_key: str = os.environ.get("DEEPSEEK_API_KEY", "")
    deepseek_base_url: str = os.environ.get(
        "DEEPSEEK_BASE_URL", "https://api.deepseek.com"
    )
    deepseek_model: str = os.environ.get("DEEPSEEK_MODEL", "deepseek-chat")
    database_url: str = os.environ.get(
        "DATABASE_URL", "sqlite+aiosqlite:///./weseed.db"
    )
    server_host: str = os.environ.get("SERVER_HOST", "127.0.0.1")
    server_port: int = int(os.environ.get("SERVER_PORT", "8000"))


@lru_cache()
def get_settings() -> Settings:
    return Settings()
```

- [ ] **Step 3: Write database.py**

```python
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase

from config import get_settings

settings = get_settings()
engine = create_async_engine(settings.database_url, echo=False)
async_session = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)


class Base(DeclarativeBase):
    pass


async def get_db() -> AsyncSession:
    async with async_session() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise


async def init_db():
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
```

- [ ] **Step 4: Commit**

```bash
git add server/requirements.txt server/config.py server/database.py
git commit -m "feat: add server scaffolding - config, database, dependencies"
```

---

### Task 2: SQLAlchemy ORM Models

**Files:**
- Create: `server/models.py`

- [ ] **Step 1: Write models.py**

```python
import uuid
from datetime import datetime, timezone

from sqlalchemy import Boolean, Column, DateTime, ForeignKey, String, Table, Text
from sqlalchemy.dialects.sqlite import CHAR as UUID
from sqlalchemy.orm import relationship

from database import Base


def gen_uuid() -> str:
    return str(uuid.uuid4())


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


message_tag = Table(
    "message_tags",
    Base.metadata,
    Column("message_id", UUID(36), ForeignKey("messages.id"), primary_key=True),
    Column("tag_id", UUID(36), ForeignKey("tags.id"), primary_key=True),
)


class Conversation(Base):
    __tablename__ = "conversations"

    id = Column(UUID(36), primary_key=True, default=gen_uuid)
    title = Column(String(100), nullable=False, default="New Conversation")
    created_at = Column(DateTime, nullable=False, default=utcnow)

    messages = relationship("Message", back_populates="conversation", order_by="Message.timestamp")


class Message(Base):
    __tablename__ = "messages"

    id = Column(UUID(36), primary_key=True, default=gen_uuid)
    content = Column(Text, nullable=False)
    timestamp = Column(DateTime, nullable=False, default=utcnow)
    is_from_me = Column(Boolean, nullable=False, default=True)
    is_bookmarked = Column(Boolean, nullable=False, default=False)
    conversation_id = Column(UUID(36), ForeignKey("conversations.id"), nullable=False)

    conversation = relationship("Conversation", back_populates="messages")
    tags = relationship("Tag", secondary=message_tag, back_populates="messages")


class Tag(Base):
    __tablename__ = "tags"

    id = Column(UUID(36), primary_key=True, default=gen_uuid)
    name = Column(String(50), nullable=False)
    color_hex = Column(String(7), nullable=False, default="#007AFF")

    messages = relationship("Message", secondary=message_tag, back_populates="tags")


class ScheduledTask(Base):
    __tablename__ = "scheduled_tasks"

    id = Column(UUID(36), primary_key=True, default=gen_uuid)
    type = Column(String(20), nullable=False, default="reminder")
    title = Column(String(100), nullable=False)
    cron_expression = Column(String(20), nullable=False, default="0 9 * * *")
    is_enabled = Column(Boolean, nullable=False, default=True)
    next_fire_date = Column(DateTime, nullable=True)
```

- [ ] **Step 2: Verify model imports work**

```bash
cd server && python -c "from models import Conversation, Message, Tag, ScheduledTask; print('Models OK')"
```
Expected: `Models OK`

- [ ] **Step 3: Commit**

```bash
git add server/models.py
git commit -m "feat: add SQLAlchemy ORM models"
```

---

### Task 3: Pydantic Schemas

**Files:**
- Create: `server/schemas.py`

- [ ] **Step 1: Write schemas.py**

```python
import uuid
from datetime import datetime
from typing import Optional

from pydantic import BaseModel, Field


def new_uuid() -> str:
    return str(uuid.uuid4())


def utcnow() -> datetime:
    from datetime import timezone
    return datetime.now(timezone.utc)


# --- Tag ---

class TagCreate(BaseModel):
    name: str = Field(..., min_length=1, max_length=50)
    color_hex: str = Field(default="#007AFF", pattern=r"^#[0-9A-Fa-f]{6}$")


class TagResponse(BaseModel):
    id: str
    name: str
    color_hex: str

    model_config = {"from_attributes": True}


# --- Message ---

class MessageResponse(BaseModel):
    id: str
    content: str
    timestamp: datetime
    is_from_me: bool
    is_bookmarked: bool
    tags: list[TagResponse] = []

    model_config = {"from_attributes": True}


# --- Conversation ---

class ConversationResponse(BaseModel):
    id: str
    title: str
    created_at: datetime

    model_config = {"from_attributes": True}


# --- Chat ---

class ChatRequest(BaseModel):
    content: str = Field(..., min_length=1, max_length=5000)
    conversation_id: Optional[str] = None


# --- Scheduled Task ---

class TaskCreate(BaseModel):
    type: str = Field(default="reminder", pattern=r"^(sendMessage|syncStatus|reminder)$")
    title: str = Field(..., min_length=1, max_length=100)
    cron_expression: str = Field(default="0 9 * * *", min_length=1, max_length=20)


class TaskResponse(BaseModel):
    id: str
    type: str
    title: str
    cron_expression: str
    is_enabled: bool
    next_fire_date: Optional[datetime] = None

    model_config = {"from_attributes": True}
```

- [ ] **Step 2: Verify schemas import**

```bash
cd server && python -c "from schemas import ChatRequest, MessageResponse, TagCreate, TagResponse, TaskCreate, TaskResponse, ConversationResponse; print('Schemas OK')"
```
Expected: `Schemas OK`

- [ ] **Step 3: Commit**

```bash
git add server/schemas.py
git commit -m "feat: add Pydantic request/response schemas"
```

---

### Task 4: DeepSeek Service

**Files:**
- Create: `server/services/__init__.py`
- Create: `server/services/deepseek.py`

- [ ] **Step 1: Write services/__init__.py**

```python
```

- [ ] **Step 2: Write services/deepseek.py**

```python
import json
from typing import AsyncIterator

import httpx

from config import get_settings

settings = get_settings()

SYSTEM_PROMPT = """You are a helpful, friendly AI assistant. Answer concisely and naturally.
Use the conversation history for context. Respond in the same language as the user's most recent message."""


def build_messages(history: list[dict], user_content: str) -> list[dict]:
    messages = [{"role": "system", "content": SYSTEM_PROMPT}]
    for h in history:
        role = "user" if h["is_from_me"] else "assistant"
        messages.append({"role": role, "content": h["content"]})
    messages.append({"role": "user", "content": user_content})
    return messages


async def stream_chat(
    history: list[dict],
    user_content: str,
) -> AsyncIterator[str]:
    """Call DeepSeek API with streaming, yield one token at a time."""
    messages = build_messages(history, user_content)

    async with httpx.AsyncClient(timeout=httpx.Timeout(60.0)) as client:
        async with client.stream(
            "POST",
            f"{settings.deepseek_base_url}/v1/chat/completions",
            headers={
                "Authorization": f"Bearer {settings.deepseek_api_key}",
                "Content-Type": "application/json",
            },
            json={
                "model": settings.deepseek_model,
                "messages": messages,
                "stream": True,
                "temperature": 0.7,
                "max_tokens": 2048,
            },
        ) as response:
            response.raise_for_status()
            async for line in response.aiter_lines():
                if line.startswith("data: "):
                    data_str = line[6:]
                    if data_str == "[DONE]":
                        return
                    try:
                        data = json.loads(data_str)
                        delta = data["choices"][0].get("delta", {})
                        content = delta.get("content", "")
                        if content:
                            yield content
                    except (json.JSONDecodeError, KeyError, IndexError):
                        continue
```

- [ ] **Step 2: Verify service imports**

```bash
cd server && python -c "from services.deepseek import build_messages, stream_chat; print('DeepSeek service OK')"
```
Expected: `DeepSeek service OK`

- [ ] **Step 3: Commit**

```bash
git add server/services/__init__.py server/services/deepseek.py
git commit -m "feat: add DeepSeek streaming chat service"
```

---

### Task 5: Conversations Router

**Files:**
- Create: `server/routers/__init__.py`
- Create: `server/routers/conversations.py`

- [ ] **Step 1: Write routers/__init__.py**

```python
```

- [ ] **Step 2: Write routers/conversations.py**

```python
from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from database import get_db
from models import Conversation
from schemas import ConversationResponse

router = APIRouter(prefix="/api/conversations", tags=["conversations"])


@router.get("", response_model=list[ConversationResponse])
async def list_conversations(db: AsyncSession = Depends(get_db)):
    result = await db.execute(
        select(Conversation).order_by(Conversation.created_at.desc())
    )
    return result.scalars().all()
```

- [ ] **Step 3: Commit**

```bash
git add server/routers/__init__.py server/routers/conversations.py
git commit -m "feat: add conversations list endpoint"
```

---

### Task 6: Tags Router

**Files:**
- Create: `server/routers/tags.py`

- [ ] **Step 1: Write routers/tags.py**

```python
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from database import get_db
from models import Tag
from schemas import TagCreate, TagResponse

router = APIRouter(prefix="/api/tags", tags=["tags"])


@router.get("", response_model=list[TagResponse])
async def list_tags(db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Tag).order_by(Tag.name))
    return result.scalars().all()


@router.post("", response_model=TagResponse, status_code=201)
async def create_tag(body: TagCreate, db: AsyncSession = Depends(get_db)):
    tag = Tag(name=body.name, color_hex=body.color_hex)
    db.add(tag)
    await db.flush()
    await db.refresh(tag)
    return tag
```

- [ ] **Step 2: Commit**

```bash
git add server/routers/tags.py
git commit -m "feat: add tags CRUD endpoints"
```

---

### Task 7: Tasks Router

**Files:**
- Create: `server/routers/tasks.py`

- [ ] **Step 1: Write routers/tasks.py**

```python
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from database import get_db
from models import ScheduledTask
from schemas import TaskCreate, TaskResponse

router = APIRouter(prefix="/api/tasks", tags=["tasks"])


@router.get("", response_model=list[TaskResponse])
async def list_tasks(db: AsyncSession = Depends(get_db)):
    result = await db.execute(
        select(ScheduledTask).order_by(ScheduledTask.title)
    )
    return result.scalars().all()


@router.post("", response_model=TaskResponse, status_code=201)
async def create_task(body: TaskCreate, db: AsyncSession = Depends(get_db)):
    task = ScheduledTask(
        type=body.type,
        title=body.title,
        cron_expression=body.cron_expression,
    )
    db.add(task)
    await db.flush()
    await db.refresh(task)
    return task


@router.patch("/{task_id}/toggle", response_model=TaskResponse)
async def toggle_task(task_id: str, db: AsyncSession = Depends(get_db)):
    result = await db.execute(
        select(ScheduledTask).where(ScheduledTask.id == task_id)
    )
    task = result.scalar_one_or_none()
    if not task:
        raise HTTPException(status_code=404, detail="Task not found")
    task.is_enabled = not task.is_enabled
    await db.flush()
    await db.refresh(task)
    return task
```

- [ ] **Step 2: Commit**

```bash
git add server/routers/tasks.py
git commit -m "feat: add scheduled tasks CRUD endpoints"
```

---

### Task 8: Messages Router

**Files:**
- Create: `server/routers/messages.py`

- [ ] **Step 1: Write routers/messages.py**

```python
from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from database import get_db
from models import Message, message_tag
from schemas import MessageResponse

router = APIRouter(prefix="/api/messages", tags=["messages"])


@router.get("", response_model=list[MessageResponse])
async def list_messages(
    conversation_id: str = Query(..., alias="conversationId"),
    tag_id: str | None = Query(None, alias="tagId"),
    db: AsyncSession = Depends(get_db),
):
    stmt = (
        select(Message)
        .options(selectinload(Message.tags))
        .where(Message.conversation_id == conversation_id)
        .order_by(Message.timestamp)
    )
    result = await db.execute(stmt)
    messages = result.scalars().all()

    if tag_id:
        messages = [m for m in messages if any(t.id == tag_id for t in m.tags)]

    return messages


@router.patch("/{message_id}/bookmark", response_model=MessageResponse)
async def toggle_bookmark(message_id: str, db: AsyncSession = Depends(get_db)):
    result = await db.execute(
        select(Message)
        .options(selectinload(Message.tags))
        .where(Message.id == message_id)
    )
    message = result.scalar_one_or_none()
    if not message:
        raise HTTPException(status_code=404, detail="Message not found")
    message.is_bookmarked = not message.is_bookmarked
    await db.flush()
    await db.refresh(message)
    return message
```

- [ ] **Step 2: Commit**

```bash
git add server/routers/messages.py
git commit -m "feat: add messages list and bookmark toggle endpoints"
```

---

### Task 9: Chat Router (SSE)

**Files:**
- Create: `server/routers/chat.py`

- [ ] **Step 1: Write routers/chat.py**

```python
import json

from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload
from sse_starlette.sse import EventSourceResponse

from database import get_db
from models import Conversation, Message
from schemas import ChatRequest
from services.deepseek import stream_chat

router = APIRouter(prefix="/api", tags=["chat"])


async def sse_generator(body: ChatRequest, db: AsyncSession):
    # 1. Get or create conversation
    if body.conversation_id:
        result = await db.execute(
            select(Conversation).where(Conversation.id == body.conversation_id)
        )
        conversation = result.scalar_one_or_none()
        if not conversation:
            yield {"event": "error", "data": json.dumps({"error": "Conversation not found"})}
            return
    else:
        title = body.content[:30] + ("..." if len(body.content) > 30 else "")
        conversation = Conversation(title=title)
        db.add(conversation)
        await db.flush()

    # Send start event with conversation id
    yield {
        "event": "message",
        "data": json.dumps({"type": "start", "conversationId": conversation.id}),
    }

    # 2. Save user message
    user_msg = Message(
        content=body.content,
        is_from_me=True,
        conversation_id=conversation.id,
    )
    db.add(user_msg)
    await db.flush()

    # 3. Load recent history (last 20 messages)
    result = await db.execute(
        select(Message)
        .options(selectinload(Message.tags))
        .where(Message.conversation_id == conversation.id)
        .order_by(Message.timestamp.desc())
        .limit(20)
    )
    recent = list(result.scalars().all())
    recent.reverse()

    history = [
        {"content": m.content, "is_from_me": m.is_from_me}
        for m in recent
    ]

    # 4. Stream from DeepSeek
    full_reply = ""
    try:
        async for token in stream_chat(history, body.content):
            full_reply += token
            yield {
                "event": "message",
                "data": json.dumps({"type": "token", "data": token}),
            }
    except Exception as e:
        yield {
            "event": "message",
            "data": json.dumps({"type": "error", "data": str(e)}),
        }
        return

    # 5. Save AI reply
    ai_msg = Message(
        content=full_reply,
        is_from_me=False,
        conversation_id=conversation.id,
    )
    db.add(ai_msg)
    await db.flush()

    # 6. Send done
    yield {
        "event": "message",
        "data": json.dumps({"type": "done"}),
    }


@router.post("/chat")
async def chat(body: ChatRequest, db: AsyncSession = Depends(get_db)):
    return EventSourceResponse(sse_generator(body, db))
```

- [ ] **Step 2: Add sse-starlette to requirements**

```bash
cd server && echo "sse-starlette>=2.0" >> requirements.txt
```

- [ ] **Step 3: Commit**

```bash
git add server/routers/chat.py server/requirements.txt
git commit -m "feat: add SSE streaming chat endpoint with DeepSeek"
```

---

### Task 10: FastAPI Main App

**Files:**
- Create: `server/main.py`

- [ ] **Step 1: Write main.py**

```python
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from database import init_db
from routers import chat, conversations, messages, tags, tasks


@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_db()
    yield


app = FastAPI(title="WeSee Server", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(chat.router)
app.include_router(conversations.router)
app.include_router(messages.router)
app.include_router(tags.router)
app.include_router(tasks.router)


@app.get("/health")
async def health():
    return {"status": "ok"}
```

- [ ] **Step 2: Verify the app starts**

```bash
cd server && python -c "from main import app; print(f'App: {app.title}'); print(f'Routes: {len(app.routes)}')"
```
Expected: `App: WeSee Server` with routes count > 5

- [ ] **Step 3: Commit**

```bash
git add server/main.py
git commit -m "feat: add FastAPI main app with CORS and lifespan"
```

---

### Task 11: Server Tests

**Files:**
- Create: `server/tests/__init__.py`
- Create: `server/tests/conftest.py`
- Create: `server/tests/test_conversations.py`
- Create: `server/tests/test_tags.py`
- Create: `server/tests/test_tasks.py`
- Create: `server/tests/test_messages.py`
- Create: `server/tests/test_chat.py`

- [ ] **Step 1: Write tests/__init__.py**

```python
```

- [ ] **Step 2: Write tests/conftest.py**

```python
import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from database import Base, get_db
from main import app

TEST_DB = "sqlite+aiosqlite:///:memory:"


@pytest_asyncio.fixture
async def client():
    engine = create_async_engine(TEST_DB, echo=False)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    test_session = async_sessionmaker(engine, expire_on_commit=False)

    async def override_get_db():
        async with test_session() as session:
            try:
                yield session
                await session.commit()
            except Exception:
                await session.rollback()
                raise

    app.dependency_overrides[get_db] = override_get_db

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac

    app.dependency_overrides.clear()
    await engine.dispose()
```

- [ ] **Step 3: Write tests/test_conversations.py**

```python
import pytest


@pytest.mark.asyncio
async def test_list_conversations_empty(client):
    response = await client.get("/api/conversations")
    assert response.status_code == 200
    assert response.json() == []
```

- [ ] **Step 4: Write tests/test_tags.py**

```python
import pytest


@pytest.mark.asyncio
async def test_create_and_list_tags(client):
    r = await client.post("/api/tags", json={"name": "Work", "colorHex": "#FF0000"})
    assert r.status_code == 201
    data = r.json()
    assert data["name"] == "Work"
    assert data["color_hex"] == "#FF0000"

    r = await client.get("/api/tags")
    assert r.status_code == 200
    assert len(r.json()) == 1


@pytest.mark.asyncio
async def test_create_tag_empty_name_fails(client):
    r = await client.post("/api/tags", json={"name": ""})
    assert r.status_code == 422
```

- [ ] **Step 5: Write tests/test_tasks.py**

```python
import pytest


@pytest.mark.asyncio
async def test_create_and_list_tasks(client):
    r = await client.post(
        "/api/tasks",
        json={"type": "reminder", "title": "Daily Review", "cronExpression": "0 18 * * *"},
    )
    assert r.status_code == 201
    data = r.json()
    assert data["title"] == "Daily Review"
    assert data["is_enabled"] is True

    r = await client.get("/api/tasks")
    assert r.status_code == 200
    assert len(r.json()) == 1


@pytest.mark.asyncio
async def test_toggle_task(client):
    r = await client.post(
        "/api/tasks",
        json={"title": "Test Task", "cronExpression": "0 9 * * *"},
    )
    task_id = r.json()["id"]

    r = await client.patch(f"/api/tasks/{task_id}/toggle")
    assert r.status_code == 200
    assert r.json()["is_enabled"] is False

    r = await client.patch(f"/api/tasks/{task_id}/toggle")
    assert r.status_code == 200
    assert r.json()["is_enabled"] is True
```

- [ ] **Step 6: Write tests/test_messages.py**

```python
import pytest


@pytest.mark.asyncio
async def test_list_messages_empty(client):
    r = await client.get("/api/messages?conversationId=nonexistent")
    assert r.status_code == 200
    assert r.json() == []


@pytest.mark.asyncio
async def test_toggle_bookmark_not_found(client):
    r = await client.patch("/api/messages/nonexistent/bookmark")
    assert r.status_code == 404
```

- [ ] **Step 7: Write tests/test_chat.py**

```python
import json
from unittest.mock import AsyncMock, patch

import pytest


@pytest.mark.asyncio
async def test_chat_creates_conversation_and_streams(client):
    async def mock_stream(history, content):
        yield "Hello"
        yield " world"

    with patch("routers.chat.stream_chat", mock_stream):
        response = await client.post(
            "/api/chat",
            json={"content": "Hi there"},
            headers={"Accept": "text/event-stream"},
        )
        assert response.status_code == 200

        events = []
        for block in response.text.split("\n\n"):
            for line in block.split("\n"):
                line = line.strip()
                if line.startswith("data:"):
                    events.append(json.loads(line[5:].strip()))

        assert len(events) >= 3
        assert events[0]["type"] == "start"
        assert "conversationId" in events[0]
        assert any(e["type"] == "token" for e in events)
        assert events[-1]["type"] == "done"


@pytest.mark.asyncio
async def test_chat_with_invalid_conversation_id(client):
    response = await client.post(
        "/api/chat",
        json={"content": "Hi", "conversationId": "nonexistent"},
        headers={"Accept": "text/event-stream"},
    )
    assert response.status_code == 200
    assert "error" in response.text


@pytest.mark.asyncio
async def test_chat_empty_content_fails(client):
    r = await client.post("/api/chat", json={"content": ""})
    assert r.status_code == 422
```

- [ ] **Step 8: Run tests**

```bash
cd server && python -m pytest tests/ -v
```
Expected: All tests pass

- [ ] **Step 9: Commit**

```bash
git add server/tests/
git commit -m "test: add server test suite for all endpoints"
```

---

### Task 12: Client DTOs (Codable Models)

**Files:**
- Create: `client/WeSee/Models/DTO.swift`

- [ ] **Step 1: Write DTO.swift**

```swift
import Foundation

struct MessageDTO: Codable, Identifiable {
    let id: String
    let content: String
    let timestamp: Date
    let isFromMe: Bool
    let isBookmarked: Bool
    let tags: [TagDTO]
}

struct TagDTO: Codable, Identifiable {
    let id: String
    let name: String
    let colorHex: String
}

struct ConversationDTO: Codable, Identifiable {
    let id: String
    let title: String
    let createdAt: Date
}

struct TaskDTO: Codable, Identifiable {
    let id: String
    let type: String
    let title: String
    let cronExpression: String
    let isEnabled: Bool
    let nextFireDate: Date?
}

struct CreateTagRequest: Encodable {
    let name: String
    let colorHex: String
}

struct CreateTaskRequest: Encodable {
    let type: String
    let title: String
    let cronExpression: String
}

struct ChatRequest: Encodable {
    let content: String
    let conversationId: String?
}

enum ChatEvent {
    case start(conversationId: String)
    case token(String)
    case done
    case error(String)
}
```

- [ ] **Step 2: Commit**

```bash
git add client/WeSee/Models/DTO.swift
git commit -m "feat: add client DTOs for server API communication"
```

---

### Task 13: Updated RemoteClient Protocol + LiveRemoteClient

**Files:**
- Modify: `client/WeSee/Services/RemoteClient.swift`
- Create: `client/WeSee/Services/LiveRemoteClient.swift`

- [ ] **Step 1: Read current RemoteClient.swift**

The current file at `client/WeSee/Services/RemoteClient.swift` contains:

```swift
import Foundation

protocol RemoteClient {
    func sendMessage(_ content: String) async throws
    func fetchMessages() async throws -> [Message]
    func syncStatus() async throws
}

final class NoOpRemoteClient: RemoteClient {
    func sendMessage(_ content: String) async throws {}
    func fetchMessages() async throws -> [Message] { [] }
    func syncStatus() async throws {}
}
```

- [ ] **Step 2: Rewrite RemoteClient.swift with updated protocol + NoOp stub**

```swift
import Foundation

protocol RemoteClient {
    func fetchConversations() async throws -> [ConversationDTO]
    func sendMessage(_ content: String, conversationId: String?) -> AsyncThrowingStream<ChatEvent, Error>
    func fetchMessages(conversationId: String, tagId: String?) async throws -> [MessageDTO]
    func toggleBookmark(_ messageId: String) async throws -> MessageDTO
    func createTag(name: String, colorHex: String) async throws -> TagDTO
    func fetchTags() async throws -> [TagDTO]
    func fetchTasks() async throws -> [TaskDTO]
    func createTask(type: String, title: String, cronExpression: String) async throws -> TaskDTO
    func toggleTask(_ id: String) async throws -> TaskDTO
}

final class NoOpRemoteClient: RemoteClient {
    func fetchConversations() async throws -> [ConversationDTO] { [] }
    func sendMessage(_ content: String, conversationId: String?) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func fetchMessages(conversationId: String, tagId: String?) async throws -> [MessageDTO] { [] }
    func toggleBookmark(_ messageId: String) async throws -> MessageDTO {
        MessageDTO(id: "", content: "", timestamp: Date(), isFromMe: false, isBookmarked: false, tags: [])
    }
    func createTag(name: String, colorHex: String) async throws -> TagDTO {
        TagDTO(id: "", name: "", colorHex: "")
    }
    func fetchTags() async throws -> [TagDTO] { [] }
    func fetchTasks() async throws -> [TaskDTO] { [] }
    func createTask(type: String, title: String, cronExpression: String) async throws -> TaskDTO {
        TaskDTO(id: "", type: "", title: "", cronExpression: "", isEnabled: false, nextFireDate: nil)
    }
    func toggleTask(_ id: String) async throws -> TaskDTO {
        TaskDTO(id: "", type: "", title: "", cronExpression: "", isEnabled: false, nextFireDate: nil)
    }
}
```

- [ ] **Step 3: Write LiveRemoteClient.swift**

```swift
import Foundation

final class LiveRemoteClient: RemoteClient {
    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(baseURL: URL = URL(string: "http://127.0.0.1:8000")!) {
        self.baseURL = baseURL
        self.session = URLSession.shared
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        self.encoder = JSONEncoder()
    }

    // MARK: - Conversations

    func fetchConversations() async throws -> [ConversationDTO] {
        let url = baseURL.appending(path: "api/conversations")
        let (data, _) = try await session.data(from: url)
        return try decoder.decode([ConversationDTO].self, from: data)
    }

    // MARK: - Chat (SSE)

    func sendMessage(_ content: String, conversationId: String?) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let url = baseURL.appending(path: "api/chat")
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    let body = ChatRequest(content: content, conversationId: conversationId)
                    request.httpBody = try encoder.encode(body)

                    let (bytes, _) = try await session.bytes(for: request)
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonStr = String(line.dropFirst(6))
                        guard let jsonData = jsonStr.data(using: .utf8),
                              let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                              let type = dict["type"] as? String
                        else { continue }

                        switch type {
                        case "start":
                            let cid = dict["conversationId"] as? String ?? ""
                            continuation.yield(.start(conversationId: cid))
                        case "token":
                            let token = dict["data"] as? String ?? ""
                            continuation.yield(.token(token))
                        case "done":
                            continuation.yield(.done)
                            continuation.finish()
                            return
                        case "error":
                            let msg = dict["data"] as? String ?? "Unknown error"
                            continuation.yield(.error(msg))
                            continuation.finish()
                            return
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Messages

    func fetchMessages(conversationId: String, tagId: String?) async throws -> [MessageDTO] {
        var components = URLComponents(url: baseURL.appending(path: "api/messages"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "conversationId", value: conversationId)]
        if let tagId {
            components.queryItems?.append(URLQueryItem(name: "tagId", value: tagId))
        }
        let (data, _) = try await session.data(from: components.url!)
        return try decoder.decode([MessageDTO].self, from: data)
    }

    func toggleBookmark(_ messageId: String) async throws -> MessageDTO {
        let url = baseURL.appending(path: "api/messages/\(messageId)/bookmark")
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        let (data, _) = try await session.data(for: request)
        return try decoder.decode(MessageDTO.self, from: data)
    }

    // MARK: - Tags

    func createTag(name: String, colorHex: String) async throws -> TagDTO {
        let url = baseURL.appending(path: "api/tags")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(CreateTagRequest(name: name, colorHex: colorHex))
        let (data, _) = try await session.data(for: request)
        return try decoder.decode(TagDTO.self, from: data)
    }

    func fetchTags() async throws -> [TagDTO] {
        let url = baseURL.appending(path: "api/tags")
        let (data, _) = try await session.data(from: url)
        return try decoder.decode([TagDTO].self, from: data)
    }

    // MARK: - Tasks

    func fetchTasks() async throws -> [TaskDTO] {
        let url = baseURL.appending(path: "api/tasks")
        let (data, _) = try await session.data(from: url)
        return try decoder.decode([TaskDTO].self, from: data)
    }

    func createTask(type: String, title: String, cronExpression: String) async throws -> TaskDTO {
        let url = baseURL.appending(path: "api/tasks")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(CreateTaskRequest(type: type, title: title, cronExpression: cronExpression))
        let (data, _) = try await session.data(for: request)
        return try decoder.decode(TaskDTO.self, from: data)
    }

    func toggleTask(_ id: String) async throws -> TaskDTO {
        let url = baseURL.appending(path: "api/tasks/\(id)/toggle")
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        let (data, _) = try await session.data(for: request)
        return try decoder.decode(TaskDTO.self, from: data)
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add client/WeSee/Services/RemoteClient.swift client/WeSee/Services/LiveRemoteClient.swift
git commit -m "feat: update RemoteClient protocol and add LiveRemoteClient with SSE streaming"
```

---

### Task 14: ChatViewModel Streaming Support

**Files:**
- Modify: `client/WeSee/ViewModels/ChatViewModel.swift`

Current file reference at `client/WeSee/ViewModels/ChatViewModel.swift:1-68`.

- [ ] **Step 1: Update ChatViewModel with conversation + streaming**

Replace the current ChatViewModel with:

```swift
import Foundation
import Observation
import SwiftData

@Observable
final class ChatViewModel {
    var messages: [Message] = []
    var conversations: [ConversationDTO] = []
    var selectedTag: Tag?
    var isSendingDisabled: Bool = false
    var errorMessage: String?
    var streamingContent: String = ""
    var isStreaming: Bool = false
    var conversationId: String?

    private var modelContext: ModelContext?
    private let remoteClient: RemoteClient

    init(remoteClient: RemoteClient = NoOpRemoteClient()) {
        self.remoteClient = remoteClient
    }

    func configure(with context: ModelContext) {
        self.modelContext = context
        fetchMessages()
        Task { await loadConversations() }
    }

    // MARK: - Conversations

    func loadConversations() async {
        do {
            conversations = try await remoteClient.fetchConversations()
            if conversationId == nil, let first = conversations.first {
                conversationId = first.id
                fetchMessages()
            }
        } catch {
            errorMessage = "加载对话列表失败"
        }
    }

    func selectConversation(_ id: String) {
        conversationId = id
        fetchMessages()
    }

    // MARK: - Messages

    func fetchMessages() {
        guard let context = modelContext else { return }
        var descriptor = FetchDescriptor<Message>(sortBy: [SortDescriptor(\.timestamp)])
        if let tag = selectedTag {
            descriptor.predicate = #Predicate { $0.tags.contains(where: { $0.id == tag.id }) }
        }
        do {
            messages = try context.fetch(descriptor)
        } catch {
            errorMessage = "加载消息失败"
        }
    }

    func addMessage(content: String, isFromMe: Bool, tags: [Tag] = []) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 5000 else { return }

        guard let context = modelContext else {
            let msg = Message(content: trimmed, isFromMe: isFromMe, tags: tags)
            messages.append(msg)
            return
        }

        let msg = Message(content: trimmed, isFromMe: isFromMe, tags: tags)
        context.insert(msg)
        try? context.save()
        fetchMessages()
    }

    // MARK: - Send with streaming

    func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 5000 else { return }

        // Add user message locally
        addMessage(content: trimmed, isFromMe: true)
        isSendingDisabled = true
        isStreaming = true
        streamingContent = ""

        Task {
            do {
                for try await event in remoteClient.sendMessage(
                    content: trimmed,
                    conversationId: conversationId
                ) {
                    await MainActor.run {
                        switch event {
                        case .start(let cid):
                            self.conversationId = cid
                        case .token(let token):
                            self.streamingContent += token
                        case .done:
                            self.addMessage(content: self.streamingContent, isFromMe: false)
                            self.streamingContent = ""
                            self.isStreaming = false
                            self.isSendingDisabled = false
                            Task { await self.loadConversations() }
                        case .error(let msg):
                            self.errorMessage = msg
                            self.isStreaming = false
                            self.isSendingDisabled = false
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isStreaming = false
                    self.isSendingDisabled = false
                }
            }
        }
    }

    func toggleBookmark(_ message: Message) {
        guard let context = modelContext else { return }
        message.isBookmarked.toggle()
        try? context.save()
        fetchMessages()
    }

    func filterByTag(_ tag: Tag?) {
        selectedTag = tag
        fetchMessages()
    }

    func clearError() {
        errorMessage = nil
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add client/WeSee/ViewModels/ChatViewModel.swift
git commit -m "feat: add streaming chat and conversation support to ChatViewModel"
```

---

### Task 15: ContentView + SidebarViewModel Integration

**Files:**
- Modify: `client/WeSee/ContentView.swift`
- Modify: `client/WeSee/ViewModels/SidebarViewModel.swift`

- [ ] **Step 1: Update SidebarViewModel with RemoteClient integration**

Read current SidebarViewModel at `client/WeSee/ViewModels/SidebarViewModel.swift:1-52`.

Replace with:

```swift
import Foundation
import Observation
import SwiftData

@Observable
final class SidebarViewModel {
    var tags: [Tag] = []
    var scheduledTasks: [ScheduledTask] = []
    var conversations: [ConversationDTO] = []

    private var modelContext: ModelContext?
    private let remoteClient: RemoteClient

    init(remoteClient: RemoteClient = NoOpRemoteClient()) {
        self.remoteClient = remoteClient
    }

    func configure(with context: ModelContext) {
        self.modelContext = context
        fetchTags()
        fetchScheduledTasks()
        Task { await loadRemoteData() }
    }

    func loadRemoteData() async {
        do {
            conversations = try await remoteClient.fetchConversations()
        } catch {
            // Silently fail; conversations are non-critical
        }
    }

    func fetchTags() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<Tag>(sortBy: [SortDescriptor(\.name)])
        tags = (try? context.fetch(descriptor)) ?? []
    }

    func fetchScheduledTasks() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<ScheduledTask>(sortBy: [SortDescriptor(\.title)])
        scheduledTasks = (try? context.fetch(descriptor)) ?? []
    }

    func createTag(name: String, colorHex: String = "#007AFF") {
        guard let context = modelContext else { return }
        let tag = Tag(name: name, colorHex: colorHex)
        context.insert(tag)
        try? context.save()
        fetchTags()
        Task {
            _ = try? await remoteClient.createTag(name: name, colorHex: colorHex)
        }
    }

    func toggleTask(_ task: ScheduledTask) {
        task.isEnabled.toggle()
        try? modelContext?.save()
        fetchScheduledTasks()
        Task {
            _ = try? await remoteClient.toggleTask(task.id.uuidString)
        }
    }

    func createTask(type: TaskType, title: String, cronExpression: String) {
        guard let context = modelContext else { return }
        let task = ScheduledTask(type: type, title: title, cronExpression: cronExpression)
        context.insert(task)
        try? context.save()
        fetchScheduledTasks()
        Task {
            _ = try? await remoteClient.createTask(
                type: type.rawValue,
                title: title,
                cronExpression: cronExpression
            )
        }
    }
}
```

- [ ] **Step 2: Update ContentView to wire LiveRemoteClient**

Read current ContentView at `client/WeSee/ContentView.swift:1-37`.

Replace with:

```swift
import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var chatViewModel: ChatViewModel
    @State private var sidebarViewModel: SidebarViewModel

    init() {
        let client = LiveRemoteClient()
        _chatViewModel = State(initialValue: ChatViewModel(remoteClient: client))
        _sidebarViewModel = State(initialValue: SidebarViewModel(remoteClient: client))
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

- [ ] **Step 3: Build verification**

```bash
cd client && xcodebuild -project WeSee.xcodeproj -scheme WeSee build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add client/WeSee/ContentView.swift client/WeSee/ViewModels/SidebarViewModel.swift
git commit -m "feat: wire LiveRemoteClient into ViewModels and ContentView"
```

---

### Task 16: Run Full Test Suite

- [ ] **Step 1: Run server tests**

```bash
cd server && python -m pytest tests/ -v
```
Expected: All tests pass.

- [ ] **Step 2: Verify client builds**

```bash
cd client && xcodebuild -project WeSee.xcodeproj -scheme WeSee build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Start server and check health**

```bash
cd server && DEEPSEEK_API_KEY=sk-test python -m uvicorn main:app --host 127.0.0.1 --port 8000 &
sleep 2
curl http://127.0.0.1:8000/health
```
Expected: `{"status":"ok"}`

- [ ] **Step 4: Commit final state**

```bash
git add -A
git commit -m "chore: final integration verification"
```
