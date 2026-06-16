# server/tests/test_agent.py
import asyncio
import pytest
from unittest.mock import AsyncMock, MagicMock, patch
from agent.runner import AgentRunner
from config import ServerConfig
from models.message import Message
from models.events import ServerEvent


@pytest.fixture
def test_config():
    return ServerConfig(api_key="sk-test")


@pytest.fixture
def agent_runner(test_config):
    tools = []
    return AgentRunner(config=test_config, tools=tools)


class TestAgentRunnerRun:
    @pytest.mark.asyncio
    async def test_run_simple_no_tools(self, agent_runner):
        """Agent should stream token events for a simple query."""
        mock_chunk = MagicMock()
        mock_chunk.content = "Hello, world!"
        mock_chunk.additional_kwargs = {}

        with patch.object(agent_runner, "_create_agent") as mock_create_agent:
            mock_agent = MagicMock()
            mock_agent.astream_events = MagicMock()

            async def mock_stream(*args, **kwargs):
                yield {
                    "event": "on_chat_model_stream",
                    "data": {"chunk": mock_chunk},
                }

            mock_agent.astream_events.side_effect = mock_stream
            mock_create_agent.return_value = mock_agent

            events = []
            async for event in agent_runner.run(
                history=[Message(role="user", content="hi")],
                workspace_path="/tmp",
            ):
                events.append(event)

            tokens = [e for e in events if e.type == "token"]
            assert len(tokens) == 1
            assert tokens[0].data == "Hello, world!"


class TestAgentRunnerBuildMessages:
    def test_build_messages_with_history(self, test_config):
        runner = AgentRunner(config=test_config, tools=[])
        history = [
            Message(role="user", content="hello"),
            Message(role="assistant", content="hi there"),
        ]
        messages = runner._build_messages(history, "/tmp")
        assert len(messages) == 3  # system + user + assistant
        assert messages[0]["role"] == "system"
        assert messages[1]["role"] == "user"
        assert messages[2]["role"] == "assistant"
        assert "/tmp" in messages[0]["content"]

    def test_build_messages_empty_history(self, test_config):
        runner = AgentRunner(config=test_config, tools=[])
        messages = runner._build_messages([], "/tmp")
        assert len(messages) == 1  # only system prompt
        assert messages[0]["role"] == "system"
