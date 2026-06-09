import json
from unittest.mock import AsyncMock, patch

import pytest


@pytest.mark.asyncio
async def test_chat_creates_conversation_and_streams(client):
    async def mock_stream(history, content):
        yield "Hello"
        yield " world"

    with patch("routers.chat.stream_chat", mock_stream):
        response = await client.post(
            "/api/chat",
            json={"content": "Hi there"},
            headers={"Accept": "text/event-stream"},
        )
        assert response.status_code == 200

        events = []
        for block in response.text.split("\n\n"):
            for line in block.split("\n"):
                line = line.strip()
                if line.startswith("data:"):
                    events.append(json.loads(line[5:].strip()))

        assert len(events) >= 3
        assert events[0]["type"] == "start"
        assert "conversationId" in events[0]
        assert any(e["type"] == "token" for e in events)
        assert events[-1]["type"] == "done"


@pytest.mark.asyncio
async def test_chat_with_invalid_conversation_id(client):
    response = await client.post(
        "/api/chat",
        json={"content": "Hi", "conversationId": "nonexistent"},
        headers={"Accept": "text/event-stream"},
    )
    assert response.status_code == 200
    assert "error" in response.text


@pytest.mark.asyncio
async def test_chat_empty_content_fails(client):
    r = await client.post("/api/chat", json={"content": ""})
    assert r.status_code == 422
