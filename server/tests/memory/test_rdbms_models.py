from datetime import UTC

import pytest
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from memory.rdbms.base import Base
from memory.rdbms.models import SessionRow, UserRow


@pytest.mark.asyncio
async def test_sqlite_round_trip_preserves_utc_tzinfo():
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    try:
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)

        session_factory = async_sessionmaker(engine, expire_on_commit=False)
        async with session_factory() as session:
            user = UserRow(id="user-1")
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
