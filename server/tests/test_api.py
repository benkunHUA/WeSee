import pytest
from httpx import AsyncClient, ASGITransport


@pytest.mark.asyncio
async def test_new_conversation_returns_session_id(app):
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        resp = await client.post("/api/new-conversation")
        assert resp.status_code == 200
        data = resp.json()
        assert data["ok"] is True
        assert isinstance(data["session_id"], str)
        assert data["session_id"]


@pytest.mark.asyncio
async def test_get_messages_empty(app):
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        resp = await client.get("/api/messages")
        assert resp.status_code == 200
        data = resp.json()
        assert data == {"messages": []}


@pytest.mark.asyncio
async def test_chat_missing_content(app):
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        resp = await client.post("/api/chat", json={})
        assert resp.status_code == 400


@pytest.mark.asyncio
async def test_chat_stream_persists_user_and_assistant_messages(app):
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        async with client.stream(
            "POST",
            "/api/chat",
            json={"content": "hello"},
        ) as response:
            assert response.status_code == 200
            full = ""
            async for chunk in response.aiter_text():
                full += chunk
        assert "data: " in full

        resp = await client.get("/api/messages")
        assert resp.status_code == 200
        messages = resp.json()["messages"]
        assert [message["content"] for message in messages] == [
            "hello",
            "fake response",
        ]
        assert [message["isFromMe"] for message in messages] == [True, False]
