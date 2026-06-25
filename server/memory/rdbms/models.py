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
