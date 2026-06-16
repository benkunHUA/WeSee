# server/tests/test_api.py
import pytest
from httpx import AsyncClient, ASGITransport
from main import create_app
from config import ServerConfig


@pytest.fixture
def app():
    config = ServerConfig(api_key="sk-test")
    return create_app(config)


@pytest.mark.asyncio
async def test_new_conversation(app):
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        resp = await client.post("/api/new-conversation")
        assert resp.status_code == 200
        data = resp.json()
        assert data["ok"] is True


@pytest.mark.asyncio
async def test_get_messages_empty(app):
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        resp = await client.get("/api/messages")
        assert resp.status_code == 200
        data = resp.json()
        assert "messages" in data
        assert data["messages"] == []


@pytest.mark.asyncio
async def test_chat_missing_content(app):
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        resp = await client.post("/api/chat", json={})
        assert resp.status_code == 400


@pytest.mark.asyncio
async def test_chat_stream(app):
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        async with client.stream(
            "POST",
            "/api/chat",
            json={"content": "hello"},
        ) as response:
            assert response.status_code == 200
            chunks = []
            async for chunk in response.aiter_text():
                chunks.append(chunk)
                if len(chunks) > 50:
                    break
            full = "".join(chunks)
            assert "data: " in full
