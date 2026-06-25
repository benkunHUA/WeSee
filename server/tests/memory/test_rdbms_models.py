from datetime import UTC

import pytest
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from memory.rdbms.base import Base
from memory.rdbms.models import MessageRow, SessionRow, UserRow


@pytest.mark.asyncio
async def test_sqlite_round_trip_preserves_utc_tzinfo():
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    try:
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)

        session_factory = async_sessionmaker(engine, expire_on_commit=False)
        async with session_factory() as session:
            user = UserRow(id="user-1", name="Test User")
            conversation = SessionRow(id="session-1", user_id="user-1")
            session.add_all([user, conversation])
            await session.commit()

        async with session_factory() as session:
            stored_user = await session.get(UserRow, "user-1")
            stored_conversation = await session.get(SessionRow, "session-1")

        assert stored_user is not None
        assert stored_conversation is not None
        assert stored_user.created_at.tzinfo is UTC
        assert stored_conversation.created_at.tzinfo is UTC
        assert stored_conversation.updated_at.tzinfo is UTC
    finally:
        await engine.dispose()


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
