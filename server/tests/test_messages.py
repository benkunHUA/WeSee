import pytest


@pytest.mark.asyncio
async def test_list_messages_empty(client):
    r = await client.get("/api/messages?conversationId=nonexistent")
    assert r.status_code == 200
    assert r.json() == []


@pytest.mark.asyncio
async def test_toggle_bookmark_not_found(client):
    r = await client.patch("/api/messages/nonexistent/bookmark")
    assert r.status_code == 404
