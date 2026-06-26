# server/agent/runner.py
import logging
from typing import AsyncIterator, Any
from langchain.agents import create_agent
from langchain_core.tools import BaseTool
from config import ServerConfig
from agent.llm import create_llm
from agent.prompt import build_system_prompt
from models.message import Message
from models.events import ServerEvent

logger = logging.getLogger("wesee.agent")


class AgentRunner:
    def __init__(
        self,
        config: ServerConfig,
        tools: list[BaseTool],
        *,
        tool_index: Any | None = None,
        whitelist: set[str] | None = None,
    ):
        self.config = config
        self.all_tools = tools
        self._tool_index = tool_index
        self._whitelist = whitelist or set()

    async def run(
        self,
        history: list[Message],
        workspace_path: str,
        *,
        stream_tool_events: bool = True,
        user_query: str = "",
    ) -> AsyncIterator[ServerEvent]:
        try:
            logger.info(
                "Creating LLM: model=%s, base_url=%s",
                self.config.model,
                self.config.base_url,
            )
            llm = create_llm(self.config)
            resolved_tools = await self._resolve_tools(user_query)
            agent = self._create_agent(llm, build_system_prompt(workspace_path), resolved_tools)
            messages = self._build_messages(history)
            logger.info(
                "Starting agent stream, history_len=%d, tools=%d",
                len(history), len(resolved_tools),
            )

            async for stream_event in agent.astream_events(
                {"messages": messages},
                version="v2",
            ):
                event_type = stream_event.get("event", "")
                logger.debug("LangGraph event: %s", event_type)

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

                elif event_type == "on_tool_start" and stream_tool_events:
                    name = stream_event.get("name", "")
                    tool_input = stream_event["data"].get("input", {})
                    run_id = stream_event.get("run_id", "")
                    logger.info("Tool start: name=%s, id=%s", name, run_id)
                    yield ServerEvent(
                        type="tool_call",
                        id=run_id,
                        name=name,
                        arguments=tool_input,
                    )

                elif event_type == "on_tool_end" and stream_tool_events:
                    output = stream_event["data"].get("output", "")
                    name = stream_event.get("name", "")
                    run_id = stream_event.get("run_id", "")
                    output_text = getattr(output, "content", str(output))
                    logger.info(
                        "Tool end: name=%s, output=%s",
                        name,
                        str(output_text)[:100],
                    )
                    yield ServerEvent(
                        type="tool_result",
                        id=run_id,
                        name=name,
                        data=str(output_text),
                    )

            logger.info("Agent stream complete, yielding done")
            yield ServerEvent(type="done")

        except Exception as e:
            logger.error("Agent error: %s", e, exc_info=True)
            yield ServerEvent(type="error", data=str(e))

    async def _resolve_tools(self, user_query: str) -> list[BaseTool]:
        if self._tool_index is None:
            logger.debug("Tool resolution: tool_index=None, using all %d tools", len(self.all_tools))
            return list(self.all_tools)

        if len(self.all_tools) <= len(self._whitelist):
            logger.debug(
                "Tool resolution: all_tools(%d) <= whitelist(%d), skipping RAG",
                len(self.all_tools), len(self._whitelist),
            )
            return list(self.all_tools)

        try:
            rag_tools = await self._tool_index.search(user_query, k=2)
        except Exception:
            logger.warning("Tool RAG search failed; falling back to all tools")
            return list(self.all_tools)

        rag_names = {t.name for t in rag_tools}
        selected = set(self._whitelist) | rag_names
        resolved = [t for t in self.all_tools if t.name in selected]
        logger.info(
            "Tool resolution: query='%s' whitelist=%s rag=%s → tools=%s",
            user_query[:80],
            self._whitelist,
            rag_names,
            [t.name for t in resolved],
        )
        return resolved

    def _create_agent(self, llm: Any, system_prompt: str, tools: list[BaseTool]) -> Any:
        return create_agent(llm, tools, system_prompt=system_prompt)

    def _build_messages(
        self, history: list[Message]
    ) -> list[dict[str, Any]]:
        result: list[dict[str, Any]] = []
        for msg in history:
            result.append(msg.to_dict())
        return result
