import pytest


@pytest.mark.asyncio
async def test_list_conversations_empty(client):
    response = await client.get("/api/conversations")
    assert response.status_code == 200
    assert response.json() == []
