# server/tests/test_agent.py
import pytest
from unittest.mock import MagicMock, patch
from agent.runner import AgentRunner
from config import ServerConfig
from models.message import Message


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
            async def mock_stream(*args, **kwargs):
                yield {
                    "event": "on_chat_model_stream",
                    "data": {"chunk": mock_chunk},
                }

            mock_agent.astream_events = mock_stream
            mock_create_agent.return_value = mock_agent

            events = []
            async for event in agent_runner.run(
                history=[Message(role="user", content="hi")],
                workspace_path="/tmp",
            ):
                events.append(event)

            mock_create_agent.assert_called_once()
            args = mock_create_agent.call_args.args
            assert len(args) == 3
            _, system_prompt, resolved_tools = args
            assert "/tmp" in system_prompt

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
        messages = runner._build_messages(history)
        assert messages == [
            {"role": "user", "content": "hello"},
            {"role": "assistant", "content": "hi there"},
        ]

    def test_build_messages_empty_history(self, test_config):
        runner = AgentRunner(config=test_config, tools=[])
        messages = runner._build_messages([])
        assert messages == []


from unittest.mock import AsyncMock


class TestAgentRunnerToolResolution:
    @pytest.mark.asyncio
    async def test_full_tools_when_no_tool_index(self, test_config):
        """Without tool_index, all tools are returned."""
        tools = [MagicMock(), MagicMock()]
        tools[0].name = "shell"
        tools[1].name = "file_system"
        runner = AgentRunner(config=test_config, tools=tools)
        resolved = await runner._resolve_tools("any query")
        assert len(resolved) == 2

    @pytest.mark.asyncio
    async def test_whitelist_plus_rag_merge(self, test_config):
        """Whitelist tools are always included alongside RAG results."""
        mock_index = AsyncMock()
        mock_tool = MagicMock()
        mock_tool.name = "screenshot"
        mock_index.search.return_value = [mock_tool]

        shell = MagicMock()
        shell.name = "shell"
        fs = MagicMock()
        fs.name = "file_system"
        all_tools = [shell, fs, mock_tool]
        runner = AgentRunner(
            config=test_config,
            tools=all_tools,
            tool_index=mock_index,
            whitelist={"shell", "file_system"},
        )
        resolved = await runner._resolve_tools("screenshot query")
        names = {t.name for t in resolved}
        assert names == {"shell", "file_system", "screenshot"}

    @pytest.mark.asyncio
    async def test_fallback_to_all_tools_on_search_failure(self, test_config):
        """When RAG search fails, fall back to all tools."""
        mock_index = AsyncMock()
        mock_index.search.side_effect = RuntimeError("Milvus down")

        tools = [MagicMock(), MagicMock(), MagicMock()]
        tools[0].name = "shell"
        tools[1].name = "file_system"
        tools[2].name = "screenshot"
        runner = AgentRunner(
            config=test_config,
            tools=tools,
            tool_index=mock_index,
            whitelist={"shell"},
        )
        resolved = await runner._resolve_tools("query")
        assert len(resolved) == 3  # fallback: all tools
