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
        # config：服务端配置（模型名、base_url、API key 等，见 server/config.py）
        self.config = config

        # all_tools：Agent 可能用到的“完整工具集合”
        # - 这里不直接叫 tools，是为了区分后面“根据用户问题筛选出来的一小部分 resolved_tools”
        self.all_tools = tools

        # _tool_index：可选的工具向量索引（RAG）
        # - 用来根据 user_query 检索更相关的工具，减少 Agent 可用工具数量，提高可靠性与效率
        self._tool_index = tool_index

        # _whitelist：工具白名单（安全/约束）
        # - 即使 user_query 没匹配到工具，也会强制允许白名单里的工具
        # - 例如 shell/file_system 属于基础能力
        self._whitelist = whitelist or set()

    async def run(
        self,
        history: list[Message],
        workspace_path: str,
        *,
        stream_tool_events: bool = True,
        user_query: str = "",
    ) -> AsyncIterator[ServerEvent]:
        # run：Agent 的核心执行入口，以“事件流”的方式返回执行过程
        # - history：对话历史（你们项目的 Message 类型），会转换成 LangChain 需要的 dict 格式
        # - workspace_path：工作区路径，用于生成系统提示词（让 Agent 知道当前项目/文件位置）
        # - stream_tool_events：是否把工具开始/结束事件也向前端透出
        # - user_query：本轮用户问题文本，用于 Tool RAG 选择更相关的工具（减少工具集合）
        try:
            logger.info(
                "Creating LLM: model=%s, base_url=%s",
                self.config.model,
                self.config.base_url,
            )

            # 1) 创建 LLM（通常会在 create_llm 里绑定 base_url/api_key/模型名等）
            llm = create_llm(self.config)

            # 2) 基于用户问题做工具选择（可能走 RAG + whitelist）
            resolved_tools = await self._resolve_tools(user_query)

            # 3) 创建 Agent（LangChain 的 agent 工厂）
            # - system_prompt 来自 build_system_prompt(workspace_path)
            # - tools 则是筛选后的 resolved_tools
            agent = self._create_agent(llm, build_system_prompt(workspace_path), resolved_tools)

            # 4) 把你们的历史消息转换成 LangChain agent 可消费的消息结构
            # - 注意：system_prompt 已经在 create_agent 时通过 system_prompt 参数注入了
            # - 所以这里 messages 里只放 history（用户/助手消息）
            messages = self._build_messages(history)
            logger.info(
                "Starting agent stream, history_len=%d, tools=%d",
                len(history), len(resolved_tools),
            )

            # 5) 以事件流形式执行 Agent
            # - astream_events 会不断产出事件：模型 token 流、工具开始/结束等
            # - version="v2" 表示采用 v2 事件协议（字段结构更稳定/更丰富）
            async for stream_event in agent.astream_events(
                {"messages": messages},
                version="v2",
            ):
                event_type = stream_event.get("event", "")
                logger.debug("LangGraph event: %s", event_type)

                if event_type == "on_chat_model_stream":
                    # 模型输出 token 的流式事件：
                    # - data.chunk.content 是本次增量 token
                    # - 某些模型会在 additional_kwargs 里带 reasoning_content（思考过程）
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
                    # 工具调用开始事件（让前端知道“正在调用哪个工具、参数是什么”）
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
                    # 工具调用结束事件（把工具输出透出给前端）
                    # - output 可能是 LangChain 的 Message，也可能是普通字符串/对象
                    # - getattr(output, "content", str(output)) 做兼容处理
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
            # 正常结束：发一个 done 事件，告知前端流式输出结束
            yield ServerEvent(type="done")

        except Exception as e:
            # 异常兜底：避免协程直接抛出导致连接断开
            # - 把错误信息包装成 ServerEvent(type="error") 让前端可展示
            logger.error("Agent error: %s", e, exc_info=True)
            yield ServerEvent(type="error", data=str(e))

    async def _resolve_tools(self, user_query: str) -> list[BaseTool]:
        # _resolve_tools：基于 user_query 决定本轮 Agent 可用的工具子集
        # 目标：
        # - 工具越少，模型越不容易“乱选工具/工具名混淆”
        # - 同时保留 whitelist 里的工具以保证基本能力
        if self._tool_index is None:
            logger.debug("Tool resolution: tool_index=None, using all %d tools", len(self.all_tools))
            return list(self.all_tools)

        if len(self.all_tools) <= len(self._whitelist):
            # 如果工具总数本来就不多（甚至不超过白名单数），就没必要做 RAG 检索
            logger.debug(
                "Tool resolution: all_tools(%d) <= whitelist(%d), skipping RAG",
                len(self.all_tools), len(self._whitelist),
            )
            return list(self.all_tools)

        try:
            # 走 Tool RAG：向量检索最相关的 k 个工具（这里 k=2）
            rag_tools = await self._tool_index.search(user_query, k=2)
        except Exception:
            logger.warning("Tool RAG search failed; falling back to all tools")
            return list(self.all_tools)

        # 组合 whitelist 与 RAG 命中的工具集合
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
        # _create_agent：把 LLM + tools + system_prompt 组装成可执行的 Agent
        # - 这里使用 langchain.agents.create_agent（替代早期 langgraph.prebuilt.create_react_agent）
        return create_agent(llm, tools, system_prompt=system_prompt)

    def _build_messages(
        self, history: list[Message]
    ) -> list[dict[str, Any]]:
        # _build_messages：把项目内部 Message 对象转换成 dict
        # - dict 结构通常包含 role/content 等，具体由 Message.to_dict() 定义
        result: list[dict[str, Any]] = []
        for msg in history:
            result.append(msg.to_dict())
        return result
