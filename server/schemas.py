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
    conversation_id: Optional[str] = Field(None, validation_alias="conversationId")


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
