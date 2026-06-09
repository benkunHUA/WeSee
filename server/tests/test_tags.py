import pytest


@pytest.mark.asyncio
async def test_create_and_list_tags(client):
    r = await client.post("/api/tags", json={"name": "Work", "color_hex": "#FF0000"})
    assert r.status_code == 201
    data = r.json()
    assert data["name"] == "Work"
    assert data["color_hex"] == "#FF0000"

    r = await client.get("/api/tags")
    assert r.status_code == 200
    assert len(r.json()) == 1


@pytest.mark.asyncio
async def test_create_tag_empty_name_fails(client):
    r = await client.post("/api/tags", json={"name": ""})
    assert r.status_code == 422
