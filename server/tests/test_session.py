# server/tests/test_session.py
from session.manager import Session, SessionManager


class TestSession:
    def test_new_session_is_empty(self):
        session = Session()
        assert len(session.messages) == 0
        assert session.workspace_path == "/tmp"

    def test_add_message(self):
        session = Session()
        session.add_message(role="user", content="hello")
        assert len(session.messages) == 1
        assert session.messages[0].role == "user"
        assert session.messages[0].content == "hello"

    def test_clear(self):
        session = Session()
        session.add_message(role="user", content="hello")
        session.add_message(role="assistant", content="hi")
        session.clear()
        assert len(session.messages) == 0

    def test_set_workspace(self):
        session = Session()
        session.set_workspace("/Users/test/projects")
        assert session.workspace_path == "/Users/test/projects"


class TestSessionManager:
    def test_create_session(self):
        manager = SessionManager()
        session = manager.create_session()
        assert session is not None
        assert len(manager) == 1

    def test_get_session(self):
        manager = SessionManager()
        session = manager.create_session()
        retrieved = manager.get_session(session.id)
        assert retrieved is session

    def test_remove_session(self):
        manager = SessionManager()
        session = manager.create_session()
        manager.remove_session(session.id)
        assert manager.get_session(session.id) is None
