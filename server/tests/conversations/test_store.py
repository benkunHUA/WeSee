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
