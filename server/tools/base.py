# server/tools/base.py
import asyncio
import uuid
from abc import abstractmethod
from typing import Any
from langchain_core.tools import BaseTool
from contextvars import ContextVar


ws_manager_var: ContextVar[Any | None] = ContextVar("ws_manager", default=None)


class ClientForwardTool(BaseTool):
    """Tool that can forward to macOS client or execute locally."""

    workspace_path: str = "/tmp"
    tool_call_timeout: float = 60.0

    def _run(self, *args: Any, **kwargs: Any) -> str:
        return self._run_local(**kwargs)

    async def _arun(self, *args: Any, **kwargs: Any) -> str:
        ws_manager = ws_manager_var.get()
        if ws_manager is not None and ws_manager.has_client():
            call_id = str(uuid.uuid4())
            result_event = asyncio.Event()
            result_container: dict[str, str] = {}

            ws_manager.register_pending_call(
                call_id, result_event, result_container
            )
            await ws_manager.send_event_to_client(
                "tool_call", id=call_id, name=self.name, arguments=kwargs
            )
            try:
                await asyncio.wait_for(
                    result_event.wait(), timeout=self.tool_call_timeout
                )
                return result_container.get("result", "Error: no result from client")
            except asyncio.TimeoutError:
                ws_manager.remove_pending_call(call_id)
                return f"Error: tool '{self.name}' timed out waiting for client"

        return self._run_local(**kwargs)

    @abstractmethod
    def _run_local(self, **kwargs: Any) -> str:
        ...
