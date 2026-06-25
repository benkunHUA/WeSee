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
            session.add(row)
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
