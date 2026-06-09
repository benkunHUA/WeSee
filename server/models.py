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
