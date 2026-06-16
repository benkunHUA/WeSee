# server/tests/test_websocket.py
import json
import pytest
from fastapi.testclient import TestClient
from main import create_app
from config import ServerConfig


@pytest.fixture
def client():
    config = ServerConfig(api_key="sk-test")
    return TestClient(create_app(config))


def test_websocket_chat_flow(client):
    with client.websocket_connect("/ws") as ws:
        ws.send_text(json.dumps({
            "type": "chat",
            "content": "hello",
        }))

        events = []
        for _ in range(30):
            try:
                data = ws.receive_text()
                event = json.loads(data)
                events.append(event)
                if event["type"] in ("done", "error"):
                    break
            except Exception:
                break

        assert len(events) > 0
        assert events[-1]["type"] in ("done", "error")


def test_websocket_new_conversation(client):
    with client.websocket_connect("/ws") as ws:
        ws.send_text(json.dumps({"type": "new_conversation"}))


def test_websocket_update_workspace(client):
    with client.websocket_connect("/ws") as ws:
        ws.send_text(json.dumps({
            "type": "update_workspace",
            "path": "/tmp/custom",
        }))
        ws.send_text(json.dumps({
            "type": "chat",
            "content": "pwd",
        }))
