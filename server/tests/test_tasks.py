import pytest


@pytest.mark.asyncio
async def test_create_and_list_tasks(client):
    r = await client.post(
        "/api/tasks",
        json={"type": "reminder", "title": "Daily Review", "cron_expression": "0 18 * * *"},
    )
    assert r.status_code == 201
    data = r.json()
    assert data["title"] == "Daily Review"
    assert data["is_enabled"] is True

    r = await client.get("/api/tasks")
    assert r.status_code == 200
    assert len(r.json()) == 1


@pytest.mark.asyncio
async def test_toggle_task(client):
    r = await client.post(
        "/api/tasks",
        json={"title": "Test Task", "cron_expression": "0 9 * * *"},
    )
    task_id = r.json()["id"]

    r = await client.patch(f"/api/tasks/{task_id}/toggle")
    assert r.status_code == 200
    assert r.json()["is_enabled"] is False

    r = await client.patch(f"/api/tasks/{task_id}/toggle")
    assert r.status_code == 200
    assert r.json()["is_enabled"] is True
