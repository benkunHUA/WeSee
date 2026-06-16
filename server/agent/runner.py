# server/agent/runner.py
from typing import AsyncIterator, Any
from langgraph.prebuilt import create_react_agent
from langchain_core.tools import BaseTool
from config import ServerConfig
from agent.llm import create_llm
from agent.prompt import build_system_prompt
from models.message import Message
from models.events import ServerEvent


class AgentRunner:
    def __init__(self, config: ServerConfig, tools: list[BaseTool]):
        self.config = config
        self.tools = tools

    async def run(
        self,
        history: list[Message],
        workspace_path: str,
    ) -> AsyncIterator[ServerEvent]:
        try:
            llm = create_llm(self.config)
            agent = self._create_agent(llm)
            messages = self._build_messages(history, workspace_path)

            async for stream_event in agent.astream_events(
                {"messages": messages},
                version="v2",
            ):
                event_type = stream_event.get("event", "")

                if event_type == "on_chat_model_stream":
                    chunk = stream_event["data"]["chunk"]
                    if chunk.content:
                        yield ServerEvent(type="token", data=chunk.content)
                    if hasattr(chunk, "additional_kwargs"):
                        reasoning = chunk.additional_kwargs.get(
                            "reasoning_content"
                        )
                        if reasoning:
                            yield ServerEvent(
                                type="thinking", data=reasoning
                            )

                elif event_type == "on_tool_start":
                    name = stream_event.get("name", "")
                    tool_input = stream_event["data"].get("input", {})
                    run_id = stream_event.get("run_id", "")
                    yield ServerEvent(
                        type="tool_call",
                        id=run_id,
                        name=name,
                        arguments=tool_input,
                    )

                elif event_type == "on_tool_end":
                    output = stream_event["data"].get("output", "")
                    name = stream_event.get("name", "")
                    run_id = stream_event.get("run_id", "")
                    yield ServerEvent(
                        type="tool_result",
                        id=run_id,
                        name=name,
                        data=str(output),
                    )

            yield ServerEvent(type="done")

        except Exception as e:
            yield ServerEvent(type="error", data=str(e))

    def _create_agent(self, llm: Any) -> Any:
        return create_react_agent(llm, self.tools)

    def _build_messages(
        self, history: list[Message], workspace_path: str
    ) -> list[dict[str, Any]]:
        result: list[dict[str, Any]] = []
        prompt = build_system_prompt(workspace_path)
        result.append({"role": "system", "content": prompt})
        for msg in history:
            result.append(msg.to_dict())
        return result
