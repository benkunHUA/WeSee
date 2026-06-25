# server/tests/test_websocket.py
import json
from fastapi.testclient import TestClient


def test_websocket_connect_sends_session_id(app):
    client = TestClient(app)
    with client.websocket_connect("/ws") as ws:
        event = json.loads(ws.receive_text())
        assert event["type"] == "session"
        assert event["session_id"]


def test_websocket_chat_flow(app):
    client = TestClient(app)
    with client.websocket_connect("/ws") as ws:
        session_event = json.loads(ws.receive_text())
        assert session_event["type"] == "session"
        ws.send_text(json.dumps({"type": "chat", "content": "hello"}))

        events = []
        for _ in range(30):
            data = ws.receive_text()
            event = json.loads(data)
            events.append(event)
            if event["type"] in ("done", "error"):
                break

        assert len(events) > 0
        assert events[-1]["type"] == "done"


def test_websocket_new_conversation_returns_new_session_id(app):
    client = TestClient(app)
    with client.websocket_connect("/ws") as ws:
        first = json.loads(ws.receive_text())
        ws.send_text(json.dumps({"type": "new_conversation"}))
        second = json.loads(ws.receive_text())
        assert second["type"] == "session"
        assert second["session_id"] != first["session_id"]


def test_websocket_update_workspace(app):
    client = TestClient(app)
    with client.websocket_connect("/ws") as ws:
        json.loads(ws.receive_text())
        ws.send_text(json.dumps({"type": "update_workspace", "path": "/tmp/custom"}))
        ws.send_text(json.dumps({"type": "chat", "content": "pwd"}))
        events = []
        for _ in range(30):
            data = ws.receive_text()
            event = json.loads(data)
            events.append(event)
            if event["type"] in ("done", "error"):
                break
        assert events[-1]["type"] == "done"
