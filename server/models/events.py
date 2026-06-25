# server/models/events.py
import json
from typing import Any

from pydantic import BaseModel


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
