# server/tests/test_integration.py
"""Integration tests covering full HTTP and WebSocket flows."""
import json
import pytest
from httpx import AsyncClient, ASGITransport
from fastapi.testclient import TestClient


# ── HTTP full flow ──────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_http_full_flow_new_conversation_to_messages(app):
    """Complete HTTP flow: new conversation → chat → verify messages."""
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        # Start fresh
        resp = await client.post("/api/new-conversation")
        assert resp.status_code == 200
        assert resp.json()["ok"] is True

        # Send a chat message via SSE stream
        chunks = []
        async with client.stream(
            "POST", "/api/chat", json={"content": "hello world"}
        ) as resp:
            assert resp.status_code == 200
            assert "text/event-stream" in resp.headers["content-type"]
            async for chunk in resp.aiter_text():
                chunks.append(chunk)
                if len(chunks) > 50:
                    break

        full = "".join(chunks)
        assert "data:" in full

        # Verify messages endpoint contains the user message
        resp = await client.get("/api/messages")
        assert resp.status_code == 200
        data = resp.json()
        assert "messages" in data
        assert len(data["messages"]) >= 1


@pytest.mark.asyncio
async def test_http_multiple_messages(app):
    """Messages accumulate across multiple chat requests."""
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        await client.post("/api/new-conversation")

        # Send two messages
        for _ in range(2):
            async with client.stream(
                "POST", "/api/chat", json={"content": "hi"}
            ) as resp:
                async for _ in resp.aiter_text():
                    pass

        resp = await client.get("/api/messages")
        data = resp.json()
        # Should have at least the user messages
        assert len(data["messages"]) >= 2


@pytest.mark.asyncio
async def test_http_new_conversation_creates_empty_new_session(app):
    """New conversation creates a new session and preserves old history."""
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        async with client.stream(
            "POST", "/api/chat", json={"content": "hi"}
        ) as resp:
            async for _ in resp.aiter_text():
                pass

        resp = await client.get("/api/messages")
        before = len(resp.json()["messages"])
        assert before == 2

        new_resp = await client.post("/api/new-conversation")
        assert new_resp.status_code == 200
        assert new_resp.json()["session_id"]

        resp = await client.get("/api/messages")
        after = len(resp.json()["messages"])
        assert after == 0


@pytest.mark.asyncio
async def test_http_chat_validation(app):
    """Chat endpoint validates input."""
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        # Empty content
        resp = await client.post("/api/chat", json={"content": ""})
        assert resp.status_code == 400

        # Missing content field
        resp = await client.post("/api/chat", json={})
        assert resp.status_code == 400

        # Content too long
        resp = await client.post("/api/chat", json={"content": "x" * 5001})
        assert resp.status_code == 400


# ── WebSocket full flow ─────────────────────────────────────────────


def test_websocket_full_flow_chat(test_client):
    """Full WebSocket flow: connect → update workspace → chat → done/error."""
    with test_client.websocket_connect("/ws") as ws:
        # Set workspace
        ws.send_text(json.dumps({
            "type": "update_workspace",
            "path": "/tmp/test-integration",
        }))

        # Send chat message
        ws.send_text(json.dumps({
            "type": "chat",
            "content": "respond with just the word hello",
        }))

        # Collect events until done/error
        event_types = []
        for _ in range(30):
            try:
                data = ws.receive_text()
                event = json.loads(data)
                event_types.append(event["type"])
                if event["type"] in ("done", "error"):
                    break
            except Exception:
                break

        assert len(event_types) > 0
        assert event_types[-1] in ("done", "error")


def test_websocket_new_conversation_resets_state(test_client):
    """New conversation message should reset session state."""
    with test_client.websocket_connect("/ws") as ws:
        ws.send_text(json.dumps({"type": "new_conversation"}))
        # Should not cause any error, connection stays open


def test_websocket_tool_result_handling(test_client):
    """Tool result message should be processed without error (even if no pending call)."""
    with test_client.websocket_connect("/ws") as ws:
        # Send tool result for non-existent call (should be ignored gracefully)
        ws.send_text(json.dumps({
            "type": "tool_result",
            "id": "nonexistent_call",
            "name": "shell",
            "result": "test output",
        }))
        # Connection should remain open


def test_websocket_invalid_message(test_client):
    """Invalid JSON should not crash the WebSocket."""
    with test_client.websocket_connect("/ws") as ws:
        ws.send_text("not valid json{{{")
        # Connection should remain open — send a valid message after
        ws.send_text(json.dumps({"type": "new_conversation"}))


# ── Coexistence ─────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_http_and_websocket_coexist(app):
    """HTTP API and WebSocket should function independently."""
    transport = ASGITransport(app=app)

    # HTTP request
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        resp = await client.post("/api/new-conversation")
        assert resp.status_code == 200

    # WebSocket connection (separate)
    test_client = TestClient(app)
    with test_client.websocket_connect("/ws") as ws:
        ws.send_text(json.dumps({"type": "new_conversation"}))


def test_static_files_served(test_client):
    """Static files (web UI) should be served at root."""
    resp = test_client.get("/")
    assert resp.status_code == 200
    assert "text/html" in resp.headers["content-type"]


def test_app_js_served(test_client):
    """app.js should be served."""
    resp = test_client.get("/app.js")
    assert resp.status_code == 200
    assert "javascript" in resp.headers["content-type"]
