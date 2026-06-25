# Agent Conversation PostgreSQL Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将智能体对话历史持久化到 PostgreSQL，使服务端可以在重启后加载历史并继续会话。

**Architecture:** 使用 Alembic 管理 `users`、`sessions`、`messages` 三张表；新增 `ConversationStore` 作为唯一持久化边界；HTTP 与 WebSocket handler 通过 store 同步写入 user/final assistant 消息，并从 PostgreSQL 加载历史，内存 `SessionManager` 只保留热缓存。

**Tech Stack:** Python 3.12、FastAPI、SQLAlchemy 2 async、asyncpg、Alembic、pytest、pytest-asyncio、testcontainers PostgreSQL。

---

## 已确认规格

规格文档：`docs/superpowers/specs/2026-06-25-agent-conversation-persistence-design.md`

关键决策：

- 只保存可回放聊天历史，不保存完整运行轨迹。
- 使用默认本地用户 `local-user`。
- `new_conversation` 创建新 session，保留旧历史。
- PostgreSQL 是权威数据源，SwiftData 是客户端缓存。
- 引入 Alembic 管理 schema。
- 用户消息入库后才运行 agent；assistant 只在 `done` 后保存最终聚合内容。

## 文件结构

### 新增文件

- `server/migrations/env.py`：Alembic async migration 环境，加载 SQLAlchemy metadata。
- `server/migrations/script.py.mako`：Alembic revision 模板。
- `server/migrations/versions/20260625_0001_conversation_persistence.py`：初始 conversation persistence 迁移。
- `server/conversations/__init__.py`：conversation package exports。
- `server/conversations/store.py`：`ConversationStore` repository，封装 users/sessions/messages 的数据库操作。
- `server/conversations/testing.py`：测试用 SQLite store 工厂，避免 HTTP/WebSocket 单元测试依赖本地 PostgreSQL。
- `server/tests/memory/test_alembic_migrations.py`：真实 PostgreSQL migration 测试。
- `server/tests/conversations/test_store.py`：store 行为测试。

### 修改文件

- `server/pyproject.toml`：加入 Alembic 依赖。
- `server/.env.example`：补充 `WESEE_POSTGRES_DSN`。
- `server/memory/rdbms/models.py`：更新 SQLAlchemy model，与设计 schema 对齐。
- `server/session/manager.py`：支持用持久化 session id、workspace、messages 创建热缓存 session。
- `server/models/events.py`：WebSocket `ClientMessage` / `ServerEvent` 增加 `session_id` 字段。
- `server/handlers/api.py`：改为通过 `ConversationStore` 写入和读取消息。
- `server/handlers/websocket.py`：连接时创建/恢复 session，聊天时持久化 user/final assistant 消息。
- `server/main.py`：初始化或注入 `ConversationStore`，并将其传给 HTTP/WebSocket handler。
- `server/tests/test_models.py`：补充 `session_id` serialization 测试。
- `server/tests/test_session.py`：补充从持久化数据创建内存 session 的测试。
- `server/tests/test_api.py`：更新 HTTP 持久化行为测试。
- `server/tests/test_websocket.py`：更新 WebSocket session-id 与持久化行为测试。
- `server/tests/test_integration.py`：将“清空历史”断言改为“新 session 为空且旧历史保留”。
- `server/tests/conftest.py`：增加测试 app/store fixtures。

---

### Task 1: 更新 SQLAlchemy models 与基础 schema 测试

**Files:**
- Modify: `server/memory/rdbms/models.py`
- Modify: `server/tests/memory/test_rdbms_models.py`

- [ ] **Step 1: 写失败测试，覆盖 users/sessions/messages 新字段与约束**

在 `server/tests/memory/test_rdbms_models.py` 中追加以下测试：

```python
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from memory.rdbms.models import MessageRow


@pytest.mark.asyncio
async def test_conversation_schema_round_trip():
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    try:
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)

        session_factory = async_sessionmaker(engine, expire_on_commit=False)
        async with session_factory() as session:
            user = UserRow(id="local-user", name="Local User")
            conversation = SessionRow(
                id="session-1",
                user_id="local-user",
                title="hello",
                workspace_path="/tmp/project",
                status="active",
            )
            message = MessageRow(
                session_id="session-1",
                sequence=1,
                role="user",
                content="hello",
                meta={"client": "test"},
            )
            session.add_all([user, conversation, message])
            await session.commit()

        async with session_factory() as session:
            stored = (
                await session.execute(
                    select(MessageRow).where(MessageRow.session_id == "session-1")
                )
            ).scalar_one()

        assert stored.sequence == 1
        assert stored.role == "user"
        assert stored.content == "hello"
        assert stored.meta == {"client": "test"}
        assert stored.session_id == "session-1"
    finally:
        await engine.dispose()


@pytest.mark.asyncio
async def test_message_sequence_is_unique_per_session():
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    try:
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)

        session_factory = async_sessionmaker(engine, expire_on_commit=False)
        async with session_factory() as session:
            session.add(UserRow(id="local-user", name="Local User"))
            session.add(SessionRow(id="session-1", user_id="local-user"))
            session.add_all([
                MessageRow(
                    session_id="session-1",
                    sequence=1,
                    role="user",
                    content="first",
                ),
                MessageRow(
                    session_id="session-1",
                    sequence=1,
                    role="assistant",
                    content="duplicate",
                ),
            ])
            with pytest.raises(IntegrityError):
                await session.commit()
    finally:
        await engine.dispose()
```

- [ ] **Step 2: 运行测试确认失败**

Run:

```bash
cd server && uv run pytest tests/memory/test_rdbms_models.py -v
```

Expected: FAIL，错误中应出现 `title`、`status`、`sequence` 或 `metadata` 字段不存在。

- [ ] **Step 3: 更新 `server/memory/rdbms/models.py`**

将 `server/memory/rdbms/models.py` 替换为以下内容：

```python
from __future__ import annotations

from datetime import UTC, datetime, timezone
from typing import Any

from sqlalchemy import (
    BigInteger,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    JSON,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column, relationship
from sqlalchemy.types import TypeDecorator

from memory.rdbms.base import Base


DEFAULT_SESSION_STATUS = "active"
VALID_MESSAGE_ROLES = ("user", "assistant", "system", "tool")
VALID_SESSION_STATUSES = ("active", "archived")


def _now() -> datetime:
    return datetime.now(UTC)


class UTCDateTime(TypeDecorator[datetime]):
    impl = DateTime(timezone=True)
    cache_ok = True

    def process_bind_param(self, value: datetime | None, dialect: Any) -> datetime | None:
        if value is None:
            return None
        if value.tzinfo is None:
            value = value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc)

    def process_result_value(self, value: datetime | None, dialect: Any) -> datetime | None:
        if value is None:
            return None
        if value.tzinfo is None:
            value = value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc)


json_document_type = JSON().with_variant(JSONB(), "postgresql")


class UserRow(Base):
    __tablename__ = "users"

    id: Mapped[str] = mapped_column(Text, primary_key=True)
    name: Mapped[str] = mapped_column(Text, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        UTCDateTime(),
        default=_now,
        nullable=False,
    )


class SessionRow(Base):
    __tablename__ = "sessions"
    __table_args__ = (
        CheckConstraint(
            "status in ('active', 'archived')",
            name="ck_sessions_status",
        ),
        Index("ix_sessions_user_id_updated_at", "user_id", "updated_at"),
        Index("ix_sessions_status_updated_at", "status", "updated_at"),
    )

    id: Mapped[str] = mapped_column(Text, primary_key=True)
    user_id: Mapped[str] = mapped_column(
        Text,
        ForeignKey("users.id"),
        nullable=False,
    )
    title: Mapped[str | None] = mapped_column(Text, nullable=True)
    workspace_path: Mapped[str] = mapped_column(Text, default="/tmp", nullable=False)
    status: Mapped[str] = mapped_column(
        Text,
        default=DEFAULT_SESSION_STATUS,
        nullable=False,
    )
    created_at: Mapped[datetime] = mapped_column(
        UTCDateTime(),
        default=_now,
        nullable=False,
    )
    updated_at: Mapped[datetime] = mapped_column(
        UTCDateTime(),
        default=_now,
        onupdate=_now,
        nullable=False,
    )
    last_message_at: Mapped[datetime | None] = mapped_column(
        UTCDateTime(),
        nullable=True,
    )

    messages: Mapped[list[MessageRow]] = relationship(
        back_populates="session",
        cascade="all, delete-orphan",
    )


class MessageRow(Base):
    __tablename__ = "messages"
    __table_args__ = (
        CheckConstraint(
            "role in ('user', 'assistant', 'system', 'tool')",
            name="ck_messages_role",
        ),
        UniqueConstraint("session_id", "sequence", name="uq_messages_session_sequence"),
        Index("ix_messages_session_id_sequence", "session_id", "sequence"),
        Index("ix_messages_session_id_id", "session_id", "id"),
    )

    id: Mapped[int] = mapped_column(
        BigInteger().with_variant(Integer(), "sqlite"),
        primary_key=True,
        autoincrement=True,
    )
    session_id: Mapped[str] = mapped_column(
        Text,
        ForeignKey("sessions.id"),
        nullable=False,
    )
    sequence: Mapped[int] = mapped_column(BigInteger, nullable=False)
    role: Mapped[str] = mapped_column(Text, nullable=False)
    content: Mapped[str] = mapped_column(Text, nullable=False)
    tool_calls: Mapped[list[dict[str, Any]] | None] = mapped_column(
        json_document_type,
        nullable=True,
    )
    tool_call_id: Mapped[str | None] = mapped_column(Text, nullable=True)
    name: Mapped[str | None] = mapped_column(Text, nullable=True)
    meta: Mapped[dict[str, Any]] = mapped_column(
        "metadata",
        json_document_type,
        default=dict,
        nullable=False,
    )
    created_at: Mapped[datetime] = mapped_column(
        UTCDateTime(),
        default=_now,
        nullable=False,
    )

    session: Mapped[SessionRow] = relationship(back_populates="messages")
```

- [ ] **Step 4: 运行 schema 测试确认通过**

Run:

```bash
cd server && uv run pytest tests/memory/test_rdbms_models.py -v
```

Expected: PASS。

- [ ] **Step 5: 提交 Task 1**

```bash
git add server/memory/rdbms/models.py server/tests/memory/test_rdbms_models.py
git commit -m "feat: expand conversation database models"
```

---

### Task 2: 引入 Alembic 与初始迁移

**Files:**
- Modify: `server/pyproject.toml`
- Modify: `server/.env.example`
- Create: `server/migrations/env.py`
- Create: `server/migrations/script.py.mako`
- Create: `server/migrations/versions/20260625_0001_conversation_persistence.py`
- Create: `server/tests/memory/test_alembic_migrations.py`

- [ ] **Step 1: 写 PostgreSQL migration 失败测试**

创建 `server/tests/memory/test_alembic_migrations.py`：

```python
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, inspect
from testcontainers.postgres import PostgresContainer


@pytest.mark.integration
def test_initial_alembic_migration_creates_conversation_tables():
    project_root = Path(__file__).resolve().parents[2]
    with PostgresContainer("postgres:16-alpine") as postgres:
        host = postgres.get_container_host_ip()
        port = postgres.get_exposed_port(5432)
        async_url = f"postgresql+asyncpg://test:test@{host}:{port}/test"
        sync_url = f"postgresql://test:test@{host}:{port}/test"

        alembic_cfg = Config(str(project_root / "alembic.ini"))
        alembic_cfg.set_main_option("script_location", str(project_root / "migrations"))
        alembic_cfg.set_main_option("sqlalchemy.url", async_url)
        command.upgrade(alembic_cfg, "head")

        engine = create_engine(sync_url)
        try:
            inspector = inspect(engine)
            assert {"users", "sessions", "messages"}.issubset(
                set(inspector.get_table_names())
            )
            message_columns = {column["name"] for column in inspector.get_columns("messages")}
            assert {
                "id",
                "session_id",
                "sequence",
                "role",
                "content",
                "tool_calls",
                "tool_call_id",
                "name",
                "metadata",
                "created_at",
            }.issubset(message_columns)
        finally:
            engine.dispose()
```

- [ ] **Step 2: 运行 migration 测试确认失败**

Run:

```bash
cd server && uv run pytest tests/memory/test_alembic_migrations.py -v
```

Expected: FAIL，错误应指出 `alembic`、`alembic.ini` 或 migrations 目录不存在。

- [ ] **Step 3: 添加 Alembic 依赖并同步 lockfile**

修改 `server/pyproject.toml`，在 `[project].dependencies` 中加入：

```toml
    "alembic>=1.13.0",
```

在 `[project.optional-dependencies].dev` 和 `[dependency-groups].dev` 中加入同步 PostgreSQL inspection 需要的驱动：

```toml
    "psycopg2-binary>=2.9.9",
```

Run:

```bash
cd server && uv lock
```

Expected: `server/uv.lock` 更新成功。

- [ ] **Step 4: 更新 `.env.example`**

将 `server/.env.example` 更新为包含 PostgreSQL 配置：

```dotenv
WESEE_API_KEY=your-api-key
WESEE_BASE_URL=https://api.deepseek.com
WESEE_MODEL=deepseek-v4-pro
WESEE_HTTP_PORT=8080
WESEE_POSTGRES_DSN=postgresql+asyncpg://wesee:wesee@localhost:5432/wesee
```

- [ ] **Step 5: 创建 Alembic 配置文件**

创建 `server/alembic.ini`：

```ini
[alembic]
script_location = migrations
prepend_sys_path = .
sqlalchemy.url = postgresql+asyncpg://wesee:wesee@localhost:5432/wesee

[loggers]
keys = root,sqlalchemy,alembic

[handlers]
keys = console

[formatters]
keys = generic

[logger_root]
level = WARN
handlers = console
qualname =

[logger_sqlalchemy]
level = WARN
handlers =
qualname = sqlalchemy.engine

[logger_alembic]
level = INFO
handlers =
qualname = alembic

[handler_console]
class = StreamHandler
args = (sys.stderr,)
level = NOTSET
formatter = generic

[formatter_generic]
format = %(levelname)-5.5s [%(name)s] %(message)s
datefmt = %H:%M:%S
```

- [ ] **Step 6: 创建 Alembic env**

创建 `server/migrations/env.py`：

```python
from __future__ import annotations

import asyncio
import os
from logging.config import fileConfig

from alembic import context
from sqlalchemy import pool
from sqlalchemy.engine import Connection
from sqlalchemy.ext.asyncio import async_engine_from_config

from memory.rdbms.base import Base
from memory.rdbms import models  # noqa: F401

config = context.config

if config.config_file_name is not None:
    fileConfig(config.config_file_name)

target_metadata = Base.metadata


def get_database_url() -> str:
    configured_url = config.get_main_option("sqlalchemy.url")
    env_url = os.getenv("WESEE_POSTGRES_DSN")
    if env_url:
        return env_url
    return configured_url


def run_migrations_offline() -> None:
    context.configure(
        url=get_database_url(),
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
    )

    with context.begin_transaction():
        context.run_migrations()


def do_run_migrations(connection: Connection) -> None:
    context.configure(connection=connection, target_metadata=target_metadata)

    with context.begin_transaction():
        context.run_migrations()


async def run_async_migrations() -> None:
    configuration = config.get_section(config.config_ini_section, {})
    configuration = {**configuration, "sqlalchemy.url": get_database_url()}
    connectable = async_engine_from_config(
        configuration,
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )

    async with connectable.connect() as connection:
        await connection.run_sync(do_run_migrations)

    await connectable.dispose()


def run_migrations_online() -> None:
    asyncio.run(run_async_migrations())


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
```

- [ ] **Step 7: 创建 Alembic revision 模板**

创建 `server/migrations/script.py.mako`：

```mako
"""${message}

Revision ID: ${up_revision}
Revises: ${down_revision | comma,n}
Create Date: ${create_date}
"""
from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa
${imports if imports else ""}

revision: str = ${repr(up_revision)}
down_revision: str | None = ${repr(down_revision)}
branch_labels: str | Sequence[str] | None = ${repr(branch_labels)}
depends_on: str | Sequence[str] | None = ${repr(depends_on)}


def upgrade() -> None:
    ${upgrades if upgrades else "pass"}


def downgrade() -> None:
    ${downgrades if downgrades else "pass"}
```

- [ ] **Step 8: 创建初始 migration**

创建 `server/migrations/versions/20260625_0001_conversation_persistence.py`：

```python
"""create conversation persistence tables

Revision ID: 20260625_0001
Revises:
Create Date: 2026-06-25
"""
from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision: str = "20260625_0001"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "users",
        sa.Column("id", sa.Text(), primary_key=True),
        sa.Column("name", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_table(
        "sessions",
        sa.Column("id", sa.Text(), primary_key=True),
        sa.Column("user_id", sa.Text(), nullable=False),
        sa.Column("title", sa.Text(), nullable=True),
        sa.Column("workspace_path", sa.Text(), nullable=False),
        sa.Column("status", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_message_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint("status in ('active', 'archived')", name="ck_sessions_status"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"]),
    )
    op.create_index(
        "ix_sessions_user_id_updated_at",
        "sessions",
        ["user_id", sa.text("updated_at DESC")],
    )
    op.create_index(
        "ix_sessions_status_updated_at",
        "sessions",
        ["status", sa.text("updated_at DESC")],
    )
    op.create_table(
        "messages",
        sa.Column("id", sa.BigInteger(), sa.Identity(), primary_key=True),
        sa.Column("session_id", sa.Text(), nullable=False),
        sa.Column("sequence", sa.BigInteger(), nullable=False),
        sa.Column("role", sa.Text(), nullable=False),
        sa.Column("content", sa.Text(), nullable=False),
        sa.Column("tool_calls", postgresql.JSONB(astext_type=sa.Text()), nullable=True),
        sa.Column("tool_call_id", sa.Text(), nullable=True),
        sa.Column("name", sa.Text(), nullable=True),
        sa.Column(
            "metadata",
            postgresql.JSONB(astext_type=sa.Text()),
            server_default=sa.text("'{}'::jsonb"),
            nullable=False,
        ),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "role in ('user', 'assistant', 'system', 'tool')",
            name="ck_messages_role",
        ),
        sa.ForeignKeyConstraint(["session_id"], ["sessions.id"]),
        sa.UniqueConstraint("session_id", "sequence", name="uq_messages_session_sequence"),
    )
    op.create_index(
        "ix_messages_session_id_sequence",
        "messages",
        ["session_id", "sequence"],
    )
    op.create_index("ix_messages_session_id_id", "messages", ["session_id", "id"])


def downgrade() -> None:
    op.drop_index("ix_messages_session_id_id", table_name="messages")
    op.drop_index("ix_messages_session_id_sequence", table_name="messages")
    op.drop_table("messages")
    op.drop_index("ix_sessions_status_updated_at", table_name="sessions")
    op.drop_index("ix_sessions_user_id_updated_at", table_name="sessions")
    op.drop_table("sessions")
    op.drop_table("users")
```

- [ ] **Step 9: 运行 migration 测试确认通过**

Run:

```bash
cd server && uv run pytest tests/memory/test_alembic_migrations.py -v
```

Expected: PASS。若本机 Docker 未启动，先启动 Docker Desktop 后重跑同一命令。

- [ ] **Step 10: 提交 Task 2**

```bash
git add server/pyproject.toml server/uv.lock server/.env.example server/alembic.ini server/migrations server/tests/memory/test_alembic_migrations.py
git commit -m "feat: add conversation schema migrations"
```

---

### Task 3: 实现 ConversationStore repository

**Files:**
- Create: `server/conversations/__init__.py`
- Create: `server/conversations/store.py`
- Create: `server/conversations/testing.py`
- Create: `server/tests/conversations/test_store.py`

- [ ] **Step 1: 写 store 失败测试**

创建目录 `server/tests/conversations/`，并创建 `server/tests/conversations/test_store.py`：

```python
import pytest

from conversations.store import DEFAULT_USER_ID, ConversationStore
from conversations.testing import create_sqlite_store
from models.message import Message


@pytest.mark.asyncio
async def test_ensure_default_user_is_idempotent():
    store, engine = await create_sqlite_store()
    try:
        first = await store.ensure_default_user()
        second = await store.ensure_default_user()
        assert first.id == DEFAULT_USER_ID
        assert second.id == DEFAULT_USER_ID
        assert first.name == "Local User"
    finally:
        await engine.dispose()


@pytest.mark.asyncio
async def test_create_session_and_load_empty_messages():
    store, engine = await create_sqlite_store()
    try:
        await store.ensure_default_user()
        session = await store.create_session(workspace_path="/tmp/project")
        messages = await store.load_messages(session.id)
        assert session.user_id == DEFAULT_USER_ID
        assert session.workspace_path == "/tmp/project"
        assert session.status == "active"
        assert messages == []
    finally:
        await engine.dispose()


@pytest.mark.asyncio
async def test_append_message_assigns_sequence_and_loads_in_order():
    store, engine = await create_sqlite_store()
    try:
        await store.ensure_default_user()
        session = await store.create_session(workspace_path="/tmp")
        first = await store.append_message(
            session.id,
            Message(role="user", content="hello"),
            meta={"client": "test"},
        )
        second = await store.append_message(
            session.id,
            Message(role="assistant", content="hi"),
        )
        loaded = await store.load_messages(session.id)
        assert first.sequence == 1
        assert second.sequence == 2
        assert [message.role for message in loaded] == ["user", "assistant"]
        assert [message.content for message in loaded] == ["hello", "hi"]
    finally:
        await engine.dispose()


@pytest.mark.asyncio
async def test_new_session_preserves_old_session_messages():
    store, engine = await create_sqlite_store()
    try:
        await store.ensure_default_user()
        old_session = await store.create_session(workspace_path="/tmp")
        await store.append_message(old_session.id, Message(role="user", content="old"))
        new_session = await store.create_session(workspace_path="/tmp")
        old_messages = await store.load_messages(old_session.id)
        new_messages = await store.load_messages(new_session.id)
        assert [message.content for message in old_messages] == ["old"]
        assert new_messages == []
    finally:
        await engine.dispose()


@pytest.mark.asyncio
async def test_get_latest_session_returns_most_recent_active_session():
    store, engine = await create_sqlite_store()
    try:
        await store.ensure_default_user()
        first = await store.create_session(workspace_path="/tmp/first")
        second = await store.create_session(workspace_path="/tmp/second")
        latest = await store.get_latest_session()
        assert latest is not None
        assert latest.workspace_path == "/tmp/second"
    finally:
        await engine.dispose()
```

- [ ] **Step 2: 运行 store 测试确认失败**

Run:

```bash
cd server && uv run pytest tests/conversations/test_store.py -v
```

Expected: FAIL，错误为 `No module named 'conversations'`。

- [ ] **Step 3: 创建 `server/conversations/__init__.py`**

```python
from conversations.store import DEFAULT_USER_ID, ConversationStore

__all__ = ["DEFAULT_USER_ID", "ConversationStore"]
```

- [ ] **Step 4: 创建 `server/conversations/store.py`**

```python
from __future__ import annotations

import uuid
from datetime import UTC, datetime
from typing import Any

from sqlalchemy import Select, func, select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from memory.rdbms.models import MessageRow, SessionRow, UserRow
from models.message import Message

DEFAULT_USER_ID = "local-user"
DEFAULT_USER_NAME = "Local User"
DEFAULT_WORKSPACE_PATH = "/tmp"


def utc_now() -> datetime:
    return datetime.now(UTC)


class ConversationStore:
    def __init__(self, session_factory: async_sessionmaker[AsyncSession]):
        self._session_factory = session_factory

    async def ensure_default_user(self) -> UserRow:
        async with self._session_factory.begin() as session:
            existing = await session.get(UserRow, DEFAULT_USER_ID)
            if existing is not None:
                return existing

            user = UserRow(id=DEFAULT_USER_ID, name=DEFAULT_USER_NAME)
            session.add(user)
            return user

    async def create_session(
        self,
        *,
        user_id: str = DEFAULT_USER_ID,
        workspace_path: str = DEFAULT_WORKSPACE_PATH,
        title: str | None = None,
    ) -> SessionRow:
        async with self._session_factory.begin() as session:
            await self._ensure_user_exists(session, user_id)
            now = utc_now()
            row = SessionRow(
                id=str(uuid.uuid4()),
                user_id=user_id,
                title=title,
                workspace_path=workspace_path,
                status="active",
                created_at=now,
                updated_at=now,
            )
            await session.flush()
            return row

    async def get_session(self, session_id: str) -> SessionRow | None:
        async with self._session_factory() as session:
            return await session.get(SessionRow, session_id)

    async def get_latest_session(
        self,
        *,
        user_id: str = DEFAULT_USER_ID,
    ) -> SessionRow | None:
        async with self._session_factory() as session:
            statement: Select[tuple[SessionRow]] = (
                select(SessionRow)
                .where(SessionRow.user_id == user_id)
                .where(SessionRow.status == "active")
                .order_by(SessionRow.updated_at.desc(), SessionRow.created_at.desc())
                .limit(1)
            )
            return (await session.execute(statement)).scalar_one_or_none()

    async def list_sessions(
        self,
        *,
        user_id: str = DEFAULT_USER_ID,
    ) -> list[SessionRow]:
        async with self._session_factory() as session:
            statement = (
                select(SessionRow)
                .where(SessionRow.user_id == user_id)
                .order_by(SessionRow.updated_at.desc(), SessionRow.created_at.desc())
            )
            return list((await session.execute(statement)).scalars().all())

    async def append_message(
        self,
        session_id: str,
        message: Message,
        *,
        meta: dict[str, Any] | None = None,
    ) -> MessageRow:
        async with self._session_factory.begin() as session:
            conversation = await session.get(
                SessionRow,
                session_id,
                with_for_update=True,
            )
            if conversation is None:
                raise ValueError(f"Session not found: {session_id}")

            sequence_result = await session.execute(
                select(func.coalesce(func.max(MessageRow.sequence), 0)).where(
                    MessageRow.session_id == session_id
                )
            )
            next_sequence = int(sequence_result.scalar_one()) + 1
            now = utc_now()
            row = MessageRow(
                session_id=session_id,
                sequence=next_sequence,
                role=message.role,
                content=message.content or "",
                tool_calls=message.tool_calls,
                tool_call_id=message.tool_call_id,
                name=message.name,
                meta=meta or {},
                created_at=now,
            )
            session.add(row)
            conversation.updated_at = now
            conversation.last_message_at = now
            return row

    async def load_messages(self, session_id: str) -> list[Message]:
        async with self._session_factory() as session:
            statement = (
                select(MessageRow)
                .where(MessageRow.session_id == session_id)
                .order_by(MessageRow.sequence.asc())
            )
            rows = (await session.execute(statement)).scalars().all()
            return [self._row_to_message(row) for row in rows]

    async def update_workspace(self, session_id: str, workspace_path: str) -> SessionRow:
        async with self._session_factory.begin() as session:
            conversation = await session.get(SessionRow, session_id)
            if conversation is None:
                raise ValueError(f"Session not found: {session_id}")
            conversation.workspace_path = workspace_path
            conversation.updated_at = utc_now()
            return conversation

    async def _ensure_user_exists(self, session: AsyncSession, user_id: str) -> None:
        existing = await session.get(UserRow, user_id)
        if existing is not None:
            return
        if user_id != DEFAULT_USER_ID:
            raise ValueError(f"User not found: {user_id}")
        session.add(UserRow(id=DEFAULT_USER_ID, name=DEFAULT_USER_NAME))

    def _row_to_message(self, row: MessageRow) -> Message:
        return Message(
            role=row.role,
            content=row.content,
            tool_calls=row.tool_calls,
            tool_call_id=row.tool_call_id,
            name=row.name,
        )
```

- [ ] **Step 5: 创建 `server/conversations/testing.py`**

```python
from __future__ import annotations

from sqlalchemy.ext.asyncio import AsyncEngine, async_sessionmaker, create_async_engine

from conversations.store import ConversationStore
from memory.rdbms.base import Base


async def create_sqlite_store() -> tuple[ConversationStore, AsyncEngine]:
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    return ConversationStore(session_factory), engine
```

- [ ] **Step 6: 运行 store 测试确认通过**

Run:

```bash
cd server && uv run pytest tests/conversations/test_store.py -v
```

Expected: PASS。

- [ ] **Step 7: 提交 Task 3**

```bash
git add server/conversations server/tests/conversations/test_store.py
git commit -m "feat: add conversation store"
```

---

### Task 4: 扩展内存 SessionManager 以支持持久化 session resume

**Files:**
- Modify: `server/session/manager.py`
- Modify: `server/tests/test_session.py`

- [ ] **Step 1: 写失败测试**

在 `server/tests/test_session.py` 中追加：

```python
from models.message import Message


def test_session_can_be_created_from_persisted_values():
    messages = [Message(role="user", content="hello")]
    session = Session(
        session_id="session-1",
        workspace_path="/tmp/project",
        messages=messages,
    )
    assert session.id == "session-1"
    assert session.workspace_path == "/tmp/project"
    assert session.messages == messages


def test_manager_set_session_registers_existing_session():
    manager = SessionManager()
    session = Session(session_id="session-1")
    manager.set_session(session)
    assert manager.get_session("session-1") is session
```

- [ ] **Step 2: 运行 session 测试确认失败**

Run:

```bash
cd server && uv run pytest tests/test_session.py -v
```

Expected: FAIL，错误指出 `Session.__init__()` 不接受 `session_id` 或 `set_session` 不存在。

- [ ] **Step 3: 更新 `server/session/manager.py`**

将文件替换为：

```python
# server/session/manager.py
import uuid
from collections.abc import MutableMapping
from models.message import Message


class Session:
    def __init__(
        self,
        *,
        session_id: str | None = None,
        workspace_path: str = "/tmp",
        messages: list[Message] | None = None,
    ):
        self.id = session_id or str(uuid.uuid4())
        self.messages: list[Message] = list(messages or [])
        self.workspace_path: str = workspace_path

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
        self.messages = [*self.messages, msg]
        return msg

    def clear(self):
        self.messages = []

    def set_workspace(self, path: str):
        self.workspace_path = path


class SessionManager(MutableMapping[str, Session]):
    def __init__(self):
        self._sessions: dict[str, Session] = {}

    def create_session(
        self,
        *,
        session_id: str | None = None,
        workspace_path: str = "/tmp",
        messages: list[Message] | None = None,
    ) -> Session:
        session = Session(
            session_id=session_id,
            workspace_path=workspace_path,
            messages=messages,
        )
        self._sessions = {**self._sessions, session.id: session}
        return session

    def set_session(self, session: Session) -> None:
        self._sessions = {**self._sessions, session.id: session}

    def get_session(self, session_id: str) -> Session | None:
        return self._sessions.get(session_id)

    def remove_session(self, session_id: str):
        self._sessions = {
            key: value
            for key, value in self._sessions.items()
            if key != session_id
        }

    def __getitem__(self, key: str) -> Session:
        return self._sessions[key]

    def __setitem__(self, key: str, value: Session):
        self._sessions = {**self._sessions, key: value}

    def __delitem__(self, key: str):
        self.remove_session(key)

    def __iter__(self):
        return iter(self._sessions)

    def __len__(self) -> int:
        return len(self._sessions)
```

- [ ] **Step 4: 运行 session 测试确认通过**

Run:

```bash
cd server && uv run pytest tests/test_session.py -v
```

Expected: PASS。

- [ ] **Step 5: 提交 Task 4**

```bash
git add server/session/manager.py server/tests/test_session.py
git commit -m "feat: support persisted runtime sessions"
```

---

### Task 5: 扩展 WebSocket 协议模型支持 session_id

**Files:**
- Modify: `server/models/events.py`
- Modify: `server/tests/test_models.py`

- [ ] **Step 1: 写失败测试**

在 `server/tests/test_models.py` 中追加：

```python

def test_client_message_accepts_session_id():
    msg = ClientMessage(type="chat", content="hello", session_id="session-1")
    data = json.loads(msg.model_dump_json())
    assert data == {
        "type": "chat",
        "content": "hello",
        "session_id": "session-1",
    }


def test_server_event_accepts_session_id():
    event = ServerEvent(type="session", session_id="session-1")
    data = json.loads(event.model_dump_json())
    assert data == {"type": "session", "session_id": "session-1"}
```

- [ ] **Step 2: 运行模型测试确认失败**

Run:

```bash
cd server && uv run pytest tests/test_models.py -v
```

Expected: FAIL，`session_id` 未出现在 JSON 中。

- [ ] **Step 3: 更新 `server/models/events.py`**

将 `ClientMessage` 和 `ServerEvent` 改为：

```python
class ClientMessage(BaseModel):
    """Messages from macOS client to server."""

    type: str  # chat, new_conversation, tool_result, update_workspace
    content: str | None = None
    id: str | None = None
    name: str | None = None
    result: str | None = None
    path: str | None = None
    session_id: str | None = None

    def model_dump_json(self, **kwargs: Any) -> str:
        return super().model_dump_json(exclude_none=True, **kwargs)


class ServerEvent(BaseModel):
    """Events from server to macOS client."""

    type: str  # session, token, thinking, tool_call, tool_result, done, error
    data: str | None = None
    id: str | None = None
    name: str | None = None
    arguments: dict[str, Any] | None = None
    session_id: str | None = None

    def model_dump_json(self, **kwargs: Any) -> str:
        return super().model_dump_json(exclude_none=True, **kwargs)
```

- [ ] **Step 4: 运行模型测试确认通过**

Run:

```bash
cd server && uv run pytest tests/test_models.py -v
```

Expected: PASS。

- [ ] **Step 5: 提交 Task 5**

```bash
git add server/models/events.py server/tests/test_models.py
git commit -m "feat: include session ids in websocket events"
```

---

### Task 6: 将 HTTP API 改为 PostgreSQL 权威历史

**Files:**
- Modify: `server/handlers/api.py`
- Modify: `server/main.py`
- Modify: `server/tests/conftest.py`
- Modify: `server/tests/test_api.py`
- Modify: `server/tests/test_integration.py`

- [ ] **Step 1: 在测试 fixtures 中提供 SQLite store 与 fake agent**

将 `server/tests/conftest.py` 替换为：

```python
import pytest
import pytest_asyncio

from conversations.testing import create_sqlite_store
from main import create_app
from config import ServerConfig
from models.events import ServerEvent


class FakeAgentRunner:
    async def run(self, history, workspace_path, stream_tool_events=True):
        yield ServerEvent(type="token", data="fake response")
        yield ServerEvent(type="done")


@pytest_asyncio.fixture
async def conversation_store():
    store, engine = await create_sqlite_store()
    try:
        await store.ensure_default_user()
        yield store
    finally:
        await engine.dispose()


@pytest.fixture
def test_config():
    return ServerConfig(api_key="sk-test")


@pytest.fixture
def fake_agent_runner():
    return FakeAgentRunner()


@pytest.fixture
def app(test_config, conversation_store, fake_agent_runner):
    return create_app(
        test_config,
        conversation_store=conversation_store,
        agent_runner=fake_agent_runner,
    )
```

- [ ] **Step 2: 更新 HTTP API 测试为持久化语义**

将 `server/tests/test_api.py` 替换为：

```python
import pytest
from httpx import AsyncClient, ASGITransport


@pytest.mark.asyncio
async def test_new_conversation_returns_session_id(app):
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        resp = await client.post("/api/new-conversation")
        assert resp.status_code == 200
        data = resp.json()
        assert data["ok"] is True
        assert isinstance(data["session_id"], str)
        assert data["session_id"]


@pytest.mark.asyncio
async def test_get_messages_empty(app):
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        resp = await client.get("/api/messages")
        assert resp.status_code == 200
        data = resp.json()
        assert data == {"messages": []}


@pytest.mark.asyncio
async def test_chat_missing_content(app):
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        resp = await client.post("/api/chat", json={})
        assert resp.status_code == 400


@pytest.mark.asyncio
async def test_chat_stream_persists_user_and_assistant_messages(app):
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        async with client.stream(
            "POST",
            "/api/chat",
            json={"content": "hello"},
        ) as response:
            assert response.status_code == 200
            full = ""
            async for chunk in response.aiter_text():
                full += chunk
        assert "data: " in full

        resp = await client.get("/api/messages")
        assert resp.status_code == 200
        messages = resp.json()["messages"]
        assert [message["content"] for message in messages] == [
            "hello",
            "fake response",
        ]
        assert [message["isFromMe"] for message in messages] == [True, False]
```

- [ ] **Step 3: 更新 HTTP integration 中 new conversation 语义**

将 `server/tests/test_integration.py` 中 `test_http_new_conversation_clears_messages` 替换为：

```python
@pytest.mark.asyncio
async def test_http_new_conversation_creates_empty_new_session(app):
    """New conversation creates a new session and preserves old history."""
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        async with client.stream(
            "POST", "/api/chat", json={"content": "hi"}
        ) as resp:
            async for _ in resp.aiter_text():
                pass

        resp = await client.get("/api/messages")
        before = len(resp.json()["messages"])
        assert before == 2

        new_resp = await client.post("/api/new-conversation")
        assert new_resp.status_code == 200
        assert new_resp.json()["session_id"]

        resp = await client.get("/api/messages")
        after = len(resp.json()["messages"])
        assert after == 0
```

同时删除该文件顶部本地的 `app` fixture 和 `test_client` fixture，改用 `server/tests/conftest.py` 的共享 fixtures。保留 imports：

```python
"""Integration tests covering full HTTP and WebSocket flows."""
import json
import pytest
from httpx import AsyncClient, ASGITransport
from fastapi.testclient import TestClient
```

- [ ] **Step 4: 运行 HTTP 测试确认失败**

Run:

```bash
cd server && uv run pytest tests/test_api.py tests/test_integration.py -v
```

Expected: FAIL，错误指出 `create_app()` 不接受 `conversation_store` 或 API handler 未使用 store。

- [ ] **Step 5: 更新 `server/main.py` 支持 store 和 runner 注入**

将 `create_app` 函数签名与初始化段改为：

```python
from conversations.store import ConversationStore
from memory.rdbms.base import make_engine, make_session_factory


def create_app(
    config: ServerConfig | None = None,
    *,
    conversation_store: ConversationStore | None = None,
    agent_runner: AgentRunner | None = None,
) -> FastAPI:
    if config is None:
        config = ServerConfig(api_key="sk-test")

    app = FastAPI(title="WeSee Server")

    tools = [
        ShellTool(workspace_path="/tmp"),
        FileSystemTool(workspace_path="/tmp"),
        ScreenshotTool(workspace_path="/tmp"),
    ]
    resolved_agent_runner = agent_runner or AgentRunner(config=config, tools=tools)
    if conversation_store is None:
        engine = make_engine(config.postgres_dsn)
        conversation_store = ConversationStore(make_session_factory(engine))

        @app.on_event("shutdown")
        async def dispose_database_engine():
            await engine.dispose()

    session_manager = SessionManager()
    ws_manager = WebSocketManager()

    api_router = create_api_router(
        session_manager,
        resolved_agent_runner,
        conversation_store,
    )
    app.include_router(api_router)

    @app.websocket("/ws")
    async def websocket_endpoint(ws: WebSocket):
        await ws_manager.handle_client(
            ws,
            session_manager,
            resolved_agent_runner,
            conversation_store,
        )
```

保留 static files 和函数尾部现有逻辑。

- [ ] **Step 6: 更新 `server/handlers/api.py`**

将 `create_api_router` 签名和 handler 替换为：

```python
def create_api_router(
    session_manager: SessionManager,
    agent_runner: AgentRunner,
    conversation_store: ConversationStore,
) -> APIRouter:
    router = APIRouter()
    current_session_id: str | None = None

    async def get_or_create_web_session() -> Session:
        nonlocal current_session_id
        await conversation_store.ensure_default_user()
        stored_session = None
        if current_session_id is not None:
            stored_session = await conversation_store.get_session(current_session_id)
        if stored_session is None:
            stored_session = await conversation_store.get_latest_session()
        if stored_session is None:
            stored_session = await conversation_store.create_session(workspace_path="/tmp")
        current_session_id = stored_session.id

        cached = session_manager.get_session(stored_session.id)
        if cached is not None:
            return cached

        messages = await conversation_store.load_messages(stored_session.id)
        return session_manager.create_session(
            session_id=stored_session.id,
            workspace_path=stored_session.workspace_path,
            messages=messages,
        )

    @router.post("/api/chat")
    async def chat(request: Request):
        try:
            body = await request.json()
        except Exception:
            raise HTTPException(status_code=400, detail="Invalid JSON")

        content = body.get("content", "").strip()
        if not content or len(content) > 5000:
            raise HTTPException(status_code=400, detail="Invalid content")

        web_session = await get_or_create_web_session()
        user_message = web_session.add_message(role="user", content=content)
        try:
            await conversation_store.append_message(web_session.id, user_message)
        except ValueError as exc:
            raise HTTPException(status_code=404, detail=str(exc))

        async def event_generator():
            assistant_content = ""
            tool_calls: list[dict] = []
            try:
                async for event in agent_runner.run(
                    history=list(web_session.messages),
                    workspace_path=web_session.workspace_path,
                ):
                    if event.type == "token" and event.data:
                        assistant_content = f"{assistant_content}{event.data}"
                    elif event.type == "tool_call":
                        tool_calls = [
                            *tool_calls,
                            {
                                "id": event.id,
                                "name": event.name,
                                "arguments": event.arguments or {},
                            },
                        ]

                    data = json.dumps(
                        event.model_dump(exclude_none=True),
                        ensure_ascii=False,
                    )
                    yield {"event": event.type, "data": data}

                    if event.type == "done":
                        assistant_message = web_session.add_message(
                            role="assistant",
                            content=assistant_content,
                            tool_calls=tool_calls or None,
                        )
                        await conversation_store.append_message(
                            web_session.id,
                            assistant_message,
                            meta={"source": "http"},
                        )
                    elif event.type == "error":
                        break
            except Exception as e:
                error_data = json.dumps({"type": "error", "data": str(e)})
                yield {"event": "error", "data": error_data}

        return EventSourceResponse(event_generator())

    @router.get("/api/messages")
    async def get_messages():
        web_session = await get_or_create_web_session()
        messages = await conversation_store.load_messages(web_session.id)
        return JSONResponse({
            "messages": [
                {
                    "id": str(i),
                    "content": msg.content or "",
                    "isFromMe": msg.role == "user",
                }
                for i, msg in enumerate(messages)
            ]
        })

    @router.post("/api/new-conversation")
    async def new_conversation():
        nonlocal current_session_id
        previous_session = await get_or_create_web_session()
        stored_session = await conversation_store.create_session(
            workspace_path=previous_session.workspace_path,
        )
        current_session_id = stored_session.id
        session_manager.create_session(
            session_id=stored_session.id,
            workspace_path=stored_session.workspace_path,
            messages=[],
        )
        return JSONResponse({"ok": True, "session_id": stored_session.id})
```

在文件顶部补充 imports：

```python
from conversations.store import ConversationStore
```

保留 `serve_screenshot`，但将其中使用的 `web_session` 改为：

```python
        web_session = await get_or_create_web_session()
        screenshots_dir = os.path.join(web_session.workspace_path, "screenshots")
```

- [ ] **Step 7: 运行 HTTP 测试确认通过**

Run:

```bash
cd server && uv run pytest tests/test_api.py tests/test_integration.py -v
```

Expected: PASS。

- [ ] **Step 8: 提交 Task 6**

```bash
git add server/main.py server/handlers/api.py server/tests/conftest.py server/tests/test_api.py server/tests/test_integration.py
git commit -m "feat: persist http conversations"
```

---

### Task 7: 将 WebSocket 改为可创建/恢复持久化 session

**Files:**
- Modify: `server/handlers/websocket.py`
- Modify: `server/tests/test_websocket.py`
- Modify: `server/tests/test_integration.py`

- [ ] **Step 1: 更新 WebSocket 测试为 session_id 与持久化语义**

将 `server/tests/test_websocket.py` 替换为：

```python
import json
from fastapi.testclient import TestClient


def test_websocket_connect_sends_session_id(app):
    client = TestClient(app)
    with client.websocket_connect("/ws") as ws:
        event = json.loads(ws.receive_text())
        assert event["type"] == "session"
        assert event["session_id"]


def test_websocket_chat_flow(app):
    client = TestClient(app)
    with client.websocket_connect("/ws") as ws:
        session_event = json.loads(ws.receive_text())
        assert session_event["type"] == "session"
        ws.send_text(json.dumps({"type": "chat", "content": "hello"}))

        events = []
        for _ in range(30):
            data = ws.receive_text()
            event = json.loads(data)
            events.append(event)
            if event["type"] in ("done", "error"):
                break

        assert len(events) > 0
        assert events[-1]["type"] == "done"


def test_websocket_new_conversation_returns_new_session_id(app):
    client = TestClient(app)
    with client.websocket_connect("/ws") as ws:
        first = json.loads(ws.receive_text())
        ws.send_text(json.dumps({"type": "new_conversation"}))
        second = json.loads(ws.receive_text())
        assert second["type"] == "session"
        assert second["session_id"] != first["session_id"]


def test_websocket_update_workspace(app):
    client = TestClient(app)
    with client.websocket_connect("/ws") as ws:
        json.loads(ws.receive_text())
        ws.send_text(json.dumps({"type": "update_workspace", "path": "/tmp/custom"}))
        ws.send_text(json.dumps({"type": "chat", "content": "pwd"}))
        events = []
        for _ in range(30):
            data = ws.receive_text()
            event = json.loads(data)
            events.append(event)
            if event["type"] in ("done", "error"):
                break
        assert events[-1]["type"] == "done"
```

- [ ] **Step 2: 在 integration 中更新 WebSocket fixture 使用方式**

将 `server/tests/test_integration.py` 中所有 `test_client` 参数替换为在测试内部创建：

```python
client = TestClient(app)
```

例如 `test_websocket_full_flow_chat` 变为：

```python
def test_websocket_full_flow_chat(app):
    """Full WebSocket flow: connect → update workspace → chat → done/error."""
    client = TestClient(app)
    with client.websocket_connect("/ws") as ws:
        session_event = json.loads(ws.receive_text())
        assert session_event["type"] == "session"

        ws.send_text(json.dumps({
            "type": "update_workspace",
            "path": "/tmp/test-integration",
        }))
        ws.send_text(json.dumps({
            "type": "chat",
            "content": "respond with just the word hello",
        }))

        event_types = []
        for _ in range(30):
            data = ws.receive_text()
            event = json.loads(data)
            event_types.append(event["type"])
            if event["type"] in ("done", "error"):
                break

        assert event_types[-1] == "done"
```

- [ ] **Step 3: 运行 WebSocket 测试确认失败**

Run:

```bash
cd server && uv run pytest tests/test_websocket.py tests/test_integration.py -v
```

Expected: FAIL，WebSocket handler 还未发送 `session` event 或未接收 `conversation_store` 参数。

- [ ] **Step 4: 更新 `server/handlers/websocket.py` 的 handle_client 签名与 session 初始化**

在文件顶部加入：

```python
from conversations.store import ConversationStore
from models.message import Message
```

将 `handle_client` 签名改为：

```python
    async def handle_client(
        self,
        ws: WebSocket,
        session_manager: SessionManager,
        agent_runner: AgentRunner,
        conversation_store: ConversationStore,
    ):
```

在 `handle_client` 内，用以下代码替换原来的 `session = session_manager.create_session()` 初始化：

```python
        await ws.accept()
        self._client_ws = ws
        await conversation_store.ensure_default_user()
        stored_session = await conversation_store.create_session(workspace_path="/tmp")
        session = session_manager.create_session(
            session_id=stored_session.id,
            workspace_path=stored_session.workspace_path,
            messages=[],
        )
        await self._send_raw(ServerEvent(type="session", session_id=session.id))
        logger.info("Client connected, session=%s", session.id[:8])
```

- [ ] **Step 5: 更新 run_agent 聚合 assistant 内容并持久化**

将 `run_agent` 替换为：

```python
        async def run_agent(content: str):
            logger.info("Agent task started, content='%s'", content[:80])
            event_count = 0
            assistant_content = ""
            tool_calls: list[dict] = []
            async for event in agent_runner.run(
                history=list(session.messages),
                workspace_path=session.workspace_path,
                stream_tool_events=False,
            ):
                if event.type == "token" and event.data:
                    assistant_content = f"{assistant_content}{event.data}"
                elif event.type == "tool_call":
                    tool_calls = [
                        *tool_calls,
                        {
                            "id": event.id,
                            "name": event.name,
                            "arguments": event.arguments or {},
                        },
                    ]

                await self._event_queue.put(event)
                event_count += 1
                logger.debug("Agent event #%d: type=%s", event_count, event.type)
                if event.type == "done":
                    assistant_message = session.add_message(
                        role="assistant",
                        content=assistant_content,
                        tool_calls=tool_calls or None,
                    )
                    await conversation_store.append_message(
                        session.id,
                        assistant_message,
                        meta={"source": "websocket"},
                    )
                    logger.info("Agent finished: type=done, events=%d", event_count)
                    return
                if event.type == "error":
                    logger.info("Agent finished: type=error, events=%d", event_count)
                    return
```

- [ ] **Step 6: 更新 message 分支处理 chat/new_conversation/update_workspace**

在 `if msg.type == "chat":` 分支中，用以下代码替换添加用户消息的部分：

```python
                    user_message = session.add_message(role="user", content=msg.content)
                    try:
                        await conversation_store.append_message(session.id, user_message)
                    except ValueError as exc:
                        await self._send_raw(ServerEvent(type="error", data=str(exc)))
                        continue
                    logger.info("Starting agent for: '%s'", msg.content[:80])
```

将 `new_conversation` 分支替换为：

```python
                elif msg.type == "new_conversation":
                    logger.info("New conversation, creating persisted session")
                    stored_session = await conversation_store.create_session(
                        workspace_path=session.workspace_path,
                    )
                    session_manager.remove_session(session.id)
                    session = session_manager.create_session(
                        session_id=stored_session.id,
                        workspace_path=stored_session.workspace_path,
                        messages=[],
                    )
                    await self._send_raw(ServerEvent(type="session", session_id=session.id))
```

将 `update_workspace` 分支替换为：

```python
                elif msg.type == "update_workspace":
                    if msg.path:
                        logger.info("Update workspace: %s", msg.path)
                        session.set_workspace(msg.path)
                        try:
                            await conversation_store.update_workspace(session.id, msg.path)
                        except ValueError as exc:
                            await self._send_raw(ServerEvent(type="error", data=str(exc)))
```

- [ ] **Step 7: 添加客户端带 session_id 恢复逻辑**

在解析 `ClientMessage` 后、具体分支前加入：

```python
                if msg.session_id and msg.session_id != session.id:
                    stored_session = await conversation_store.get_session(msg.session_id)
                    if stored_session is None:
                        await self._send_raw(
                            ServerEvent(type="error", data="Invalid session_id")
                        )
                        continue
                    loaded_messages = await conversation_store.load_messages(stored_session.id)
                    session_manager.remove_session(session.id)
                    session = session_manager.create_session(
                        session_id=stored_session.id,
                        workspace_path=stored_session.workspace_path,
                        messages=loaded_messages,
                    )
                    await self._send_raw(ServerEvent(type="session", session_id=session.id))
```

- [ ] **Step 8: 运行 WebSocket 测试确认通过**

Run:

```bash
cd server && uv run pytest tests/test_websocket.py tests/test_integration.py -v
```

Expected: PASS。

- [ ] **Step 9: 提交 Task 7**

```bash
git add server/handlers/websocket.py server/tests/test_websocket.py server/tests/test_integration.py
git commit -m "feat: persist websocket conversations"
```

---

### Task 8: 增加应用启动检查与配置测试

**Files:**
- Modify: `server/main.py`
- Modify: `server/tests/test_config.py`
- Modify: `server/tests/test_integration.py`

- [ ] **Step 1: 写配置与启动行为测试**

在 `server/tests/test_config.py` 中追加：

```python

def test_postgres_dsn_can_be_overridden(monkeypatch):
    monkeypatch.setenv(
        "WESEE_POSTGRES_DSN",
        "postgresql+asyncpg://user:pass@localhost:5432/custom",
    )
    cfg = ServerConfig(api_key="sk-test")
    assert cfg.postgres_dsn == "postgresql+asyncpg://user:pass@localhost:5432/custom"
```

在 `server/tests/test_integration.py` 中追加：

```python
@pytest.mark.asyncio
async def test_app_uses_injected_conversation_store(app):
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.get("/api/messages")
        assert response.status_code == 200
        assert response.json() == {"messages": []}
```

- [ ] **Step 2: 运行测试确认当前行为**

Run:

```bash
cd server && uv run pytest tests/test_config.py tests/test_integration.py -v
```

Expected: PASS。如果 `test_app_uses_injected_conversation_store` 失败，先修复 Task 6 的 app 注入逻辑。

- [ ] **Step 3: 在 app startup 确认默认用户存在**

在 `server/main.py` 中 `conversation_store` 初始化后加入：

```python
    @app.on_event("startup")
    async def ensure_database_ready():
        await conversation_store.ensure_default_user()
```

这会让未注入测试 store 的真实应用在启动时连接 PostgreSQL；连接失败会阻止应用启动，不会静默退回内存模式。

- [ ] **Step 4: 运行配置与 integration 测试**

Run:

```bash
cd server && uv run pytest tests/test_config.py tests/test_integration.py -v
```

Expected: PASS。

- [ ] **Step 5: 提交 Task 8**

```bash
git add server/main.py server/tests/test_config.py server/tests/test_integration.py
git commit -m "feat: verify conversation database on startup"
```

---

### Task 9: 全量验证、修复回归并请求代码审查

**Files:**
- Modify as needed: files touched by Tasks 1-8

- [ ] **Step 1: 运行 Python 单元与集成测试**

Run:

```bash
cd server && uv run pytest tests -v
```

Expected: PASS。

- [ ] **Step 2: 运行 Alembic migration 测试**

Run:

```bash
cd server && uv run pytest tests/memory/test_alembic_migrations.py -v
```

Expected: PASS。

- [ ] **Step 3: 如果测试失败，使用 build-error-resolver 或 tdd-guide 修复**

当失败是 import、类型、迁移或测试环境错误时，启动 build-error-resolver：

```text
Use build-error-resolver to fix the failing server test/build errors with minimal diffs. Include the failing command and full error output.
```

当失败是行为与测试不一致时，启动 tdd-guide：

```text
Use tdd-guide to inspect the failing conversation persistence test and recommend the smallest implementation change that satisfies the approved spec without weakening the test.
```

- [ ] **Step 4: 运行代码审查 agent**

Use code-reviewer with this prompt:

```text
Review the PostgreSQL conversation persistence implementation. Focus on correctness, async SQLAlchemy usage, transaction boundaries, message ordering, Alembic migration consistency, FastAPI lifecycle, and security/error handling. Treat the approved spec at docs/superpowers/specs/2026-06-25-agent-conversation-persistence-design.md as the source of truth.
```

Expected: reviewer returns no CRITICAL or HIGH issues. Fix every CRITICAL/HIGH issue. Fix MEDIUM issues when the change is low-risk and aligned with the spec.

- [ ] **Step 5: 运行数据库专项审查 agent**

Use database-reviewer with this prompt:

```text
Review the users/sessions/messages PostgreSQL schema, Alembic migration, indexes, JSONB usage, constraints, and ConversationStore transaction patterns. Confirm whether sequence allocation and session row locking are safe enough for this phase.
```

Expected: reviewer returns no blocking schema or transaction issues. Fix blocking issues before finishing.

- [ ] **Step 6: 查看最终 diff**

Run:

```bash
git status --short
git diff --stat
git diff -- server/memory/rdbms/models.py server/conversations server/handlers server/main.py server/models/events.py server/session/manager.py server/tests
```

Expected: diff 只包含 conversation persistence 相关文件。

- [ ] **Step 7: 最终提交**

如果前面任务已逐步提交，这一步只提交审查修复：

```bash
git add server
git commit -m "fix: address conversation persistence review feedback"
```

如果没有额外修复，跳过提交并记录“no changes after review”。

---

## 自检结果

- Spec coverage: 本计划覆盖 schema、Alembic、default local user、new conversation 创建新 session、PostgreSQL 权威历史、HTTP/WebSocket 持久化、assistant token 聚合、同步写入、错误处理、测试与审查。
- Placeholder scan: 计划中没有 TBD/TODO/占位实现；每个新增文件和关键修改都有具体路径、代码或命令。
- Type consistency: `ConversationStore`、`SessionManager`、`ClientMessage.session_id`、`ServerEvent.session_id`、`MessageRow.sequence`、`MessageRow.metadata` 在各任务中的命名保持一致。
