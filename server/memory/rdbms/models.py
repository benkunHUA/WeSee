from __future__ import annotations

from datetime import UTC, datetime, timezone
from typing import Any

from sqlalchemy import BigInteger, DateTime, ForeignKey, Index, Integer, JSON, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship
from sqlalchemy.types import TypeDecorator

from memory.rdbms.base import Base


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


class UserRow(Base):
    __tablename__ = "users"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    name: Mapped[str | None] = mapped_column(String(128), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        UTCDateTime(),
        default=_now,
        nullable=False,
    )


class SessionRow(Base):
    __tablename__ = "sessions"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    user_id: Mapped[str] = mapped_column(
        String(36),
        ForeignKey("users.id"),
        index=True,
        nullable=False,
    )
    workspace_path: Mapped[str] = mapped_column(Text, default="/tmp", nullable=False)
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

    messages: Mapped[list[MessageRow]] = relationship(
        back_populates="session",
        cascade="all, delete-orphan",
    )


class MessageRow(Base):
    __tablename__ = "messages"
    __table_args__ = (Index("ix_messages_session_id_id", "session_id", "id"),)

    id: Mapped[int] = mapped_column(
        BigInteger().with_variant(Integer(), "sqlite"),
        primary_key=True,
        autoincrement=True,
    )
    session_id: Mapped[str] = mapped_column(
        String(36),
        ForeignKey("sessions.id"),
        nullable=False,
    )
    role: Mapped[str] = mapped_column(String(16), nullable=False)
    content: Mapped[str | None] = mapped_column(Text, nullable=True)
    tool_calls: Mapped[list[dict[str, Any]] | None] = mapped_column(JSON, nullable=True)
    tool_call_id: Mapped[str | None] = mapped_column(String(128), nullable=True)
    name: Mapped[str | None] = mapped_column(String(128), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        UTCDateTime(),
        default=_now,
        nullable=False,
    )

    session: Mapped[SessionRow] = relationship(back_populates="messages")
