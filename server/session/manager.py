# server/session/manager.py
import uuid
from collections.abc import MutableMapping
from models.message import Message


class Session:
    def __init__(self):
        self.id = str(uuid.uuid4())
        self.messages: list[Message] = []
        self.workspace_path: str = "/tmp"

    def add_message(self, *, role: str, content: str | None = None,
                    tool_calls: list[dict] | None = None,
                    tool_call_id: str | None = None,
                    name: str | None = None) -> Message:
        msg = Message(
            role=role,
            content=content,
            tool_calls=tool_calls,
            tool_call_id=tool_call_id,
            name=name,
        )
        self.messages.append(msg)
        return msg

    def clear(self):
        self.messages.clear()

    def set_workspace(self, path: str):
        self.workspace_path = path


class SessionManager(MutableMapping[str, Session]):
    def __init__(self):
        self._sessions: dict[str, Session] = {}

    def create_session(self) -> Session:
        session = Session()
        self._sessions[session.id] = session
        return session

    def get_session(self, session_id: str) -> Session | None:
        return self._sessions.get(session_id)

    def remove_session(self, session_id: str):
        self._sessions.pop(session_id, None)

    def __getitem__(self, key: str) -> Session:
        return self._sessions[key]

    def __setitem__(self, key: str, value: Session):
        self._sessions[key] = value

    def __delitem__(self, key: str):
        del self._sessions[key]

    def __iter__(self):
        return iter(self._sessions)

    def __len__(self) -> int:
        return len(self._sessions)
