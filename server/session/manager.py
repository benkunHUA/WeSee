# server/session/manager.py
import uuid
from collections.abc import MutableMapping
from models.message import Message


class Session:
    def __init__(
        self,
        *,
        session_id: str | None = None,
        workspace_path: str = "/tmp",
        messages: list[Message] | None = None,
    ):
        self.id = session_id or str(uuid.uuid4())
        self.messages: list[Message] = list(messages or [])
        self.workspace_path: str = workspace_path

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
        self.messages = [*self.messages, msg]
        return msg

    def clear(self):
        self.messages = []

    def set_workspace(self, path: str):
        self.workspace_path = path


class SessionManager(MutableMapping[str, Session]):
    def __init__(self):
        self._sessions: dict[str, Session] = {}

    def create_session(
        self,
        *,
        session_id: str | None = None,
        workspace_path: str = "/tmp",
        messages: list[Message] | None = None,
    ) -> Session:
        session = Session(
            session_id=session_id,
            workspace_path=workspace_path,
            messages=messages,
        )
        self._sessions = {**self._sessions, session.id: session}
        return session

    def set_session(self, session: Session) -> None:
        self._sessions = {**self._sessions, session.id: session}

    def get_session(self, session_id: str) -> Session | None:
        return self._sessions.get(session_id)

    def remove_session(self, session_id: str):
        self._sessions = {
            key: value
            for key, value in self._sessions.items()
            if key != session_id
        }

    def __getitem__(self, key: str) -> Session:
        return self._sessions[key]

    def __setitem__(self, key: str, value: Session):
        self._sessions = {**self._sessions, key: value}

    def __delitem__(self, key: str):
        self.remove_session(key)

    def __iter__(self):
        return iter(self._sessions)

    def __len__(self) -> int:
        return len(self._sessions)
