# server/tests/test_models.py
import json
from models.events import (
    ClientMessage,
    ServerEvent,
)
from models.message import Message


class TestClientMessage:
    def test_chat_message(self):
        msg = ClientMessage(type="chat", content="hello")
        data = json.loads(msg.model_dump_json())
        assert data == {"type": "chat", "content": "hello"}

    def test_new_conversation(self):
        msg = ClientMessage(type="new_conversation")
        data = json.loads(msg.model_dump_json())
        assert data == {"type": "new_conversation"}

    def test_tool_result(self):
        msg = ClientMessage(
            type="tool_result",
            id="call_1",
            name="shell",
            result="file1.txt\nfile2.txt",
        )
        data = json.loads(msg.model_dump_json())
        assert data["type"] == "tool_result"
        assert data["id"] == "call_1"
        assert data["name"] == "shell"

    def test_update_workspace(self):
        msg = ClientMessage(
            type="update_workspace",
            path="/Users/test/projects",
        )
        data = json.loads(msg.model_dump_json())
        assert data["path"] == "/Users/test/projects"


class TestServerEvent:
    def test_token_event(self):
        event = ServerEvent(type="token", data="hello")
        data = json.loads(event.model_dump_json())
        assert data == {"type": "token", "data": "hello"}

    def test_tool_call_event(self):
        event = ServerEvent(
            type="tool_call",
            id="call_1",
            name="shell",
            arguments={"command": "ls"},
        )
        data = json.loads(event.model_dump_json())
        assert data["type"] == "tool_call"
        assert data["arguments"] == {"command": "ls"}

    def test_done_event(self):
        event = ServerEvent(type="done")
        data = json.loads(event.model_dump_json())
        assert data["type"] == "done"

    def test_error_event(self):
        event = ServerEvent(type="error", data="something went wrong")
        data = json.loads(event.model_dump_json())
        assert data["data"] == "something went wrong"


class TestMessage:
    def test_message_creation(self):
        msg = Message(role="user", content="hello")
        assert msg.role == "user"
        assert msg.content == "hello"
        assert msg.tool_calls is None
        assert msg.tool_call_id is None

    def test_tool_message(self):
        msg = Message(
            role="tool",
            content="result",
            tool_call_id="call_1",
        )
        assert msg.tool_call_id == "call_1"

    def test_to_dict(self):
        msg = Message(role="user", content="hello")
        d = msg.to_dict()
        assert d == {"role": "user", "content": "hello"}

    def test_to_dict_tool_message(self):
        msg = Message(role="tool", content="output", tool_call_id="call_1")
        d = msg.to_dict()
        assert d == {
            "role": "tool",
            "content": "output",
            "tool_call_id": "call_1",
        }

    def test_to_dict_assistant_with_tool_calls(self):
        msg = Message(
            role="assistant",
            content=None,
            tool_calls=[
                {
                    "id": "call_1",
                    "type": "function",
                    "function": {
                        "name": "shell",
                        "arguments": '{"command":"ls"}',
                    },
                }
            ],
        )
        d = msg.to_dict()
        assert d["role"] == "assistant"
        assert d["content"] is None
        assert len(d["tool_calls"]) == 1
