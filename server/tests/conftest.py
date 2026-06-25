import pytest
import pytest_asyncio
from fastapi.testclient import TestClient

from conversations.testing import create_sqlite_store
from main import create_app
from config import ServerConfig
from models.events import ServerEvent


class FakeAgentRunner:
    async def run(self, history, workspace_path, stream_tool_events=True):
        yield ServerEvent(type="token", data="fake response")
        yield ServerEvent(type="done")


@pytest_asyncio.fixture
async def conversation_store():
    store, engine = await create_sqlite_store()
    try:
        await store.ensure_default_user()
        yield store
    finally:
        await engine.dispose()


@pytest.fixture
def test_config():
    return ServerConfig(api_key="sk-test")


@pytest.fixture
def fake_agent_runner():
    return FakeAgentRunner()


@pytest.fixture
def app(test_config, conversation_store, fake_agent_runner):
    return create_app(
        test_config,
        conversation_store=conversation_store,
        agent_runner=fake_agent_runner,
    )


@pytest.fixture
def test_client(app):
    return TestClient(app)
