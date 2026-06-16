# server/handlers/websocket.py
import json
import asyncio
from fastapi import WebSocket, WebSocketDisconnect
from models.events import ClientMessage, ServerEvent
from session.manager import SessionManager, Session
from agent.runner import AgentRunner
from tools.base import ws_manager_var


class WebSocketManager:
    def __init__(self):
        self._client_ws: WebSocket | None = None
        self._pending_tool_calls: dict[
            str, tuple[asyncio.Event, dict[str, str]]
        ] = {}
        self._event_queue: asyncio.Queue = asyncio.Queue()

    def has_client(self) -> bool:
        return self._client_ws is not None

    def register_pending_call(
        self,
        call_id: str,
        event: asyncio.Event,
        result_container: dict[str, str],
    ):
        self._pending_tool_calls[call_id] = (event, result_container)

    def remove_pending_call(self, call_id: str):
        self._pending_tool_calls.pop(call_id, None)

    async def send_event_to_client(self, event_type: str, **kwargs):
        event = ServerEvent(type=event_type, **kwargs)
        await self._event_queue.put(event)

    async def _send_raw(self, event: ServerEvent):
        if self._client_ws:
            try:
                await self._client_ws.send_text(
                    json.dumps(event.model_dump(exclude_none=True))
                )
            except Exception:
                pass

    async def handle_client(
        self,
        ws: WebSocket,
        session_manager: SessionManager,
        agent_runner: AgentRunner,
    ):
        await ws.accept()
        self._client_ws = ws
        session = session_manager.create_session()
        token = ws_manager_var.set(self)
        agent_task: asyncio.Task | None = None
        running = True

        async def run_agent(content: str):
            async for event in agent_runner.run(
                history=list(session.messages[:-1]),
                workspace_path=session.workspace_path,
            ):
                await self._event_queue.put(event)
                if event.type in ("done", "error"):
                    return

        try:
            while running:
                while not self._event_queue.empty():
                    event = await self._event_queue.get()
                    await self._send_raw(event)

                try:
                    raw = await asyncio.wait_for(ws.receive_text(), timeout=0.05)
                except asyncio.TimeoutError:
                    continue

                try:
                    data = json.loads(raw)
                    msg = ClientMessage(**data)
                except Exception:
                    await self._send_raw(
                        ServerEvent(type="error", data="Invalid message format")
                    )
                    continue

                if msg.type == "chat":
                    if not msg.content:
                        continue
                    session.add_message(role="user", content=msg.content)
                    if agent_task and not agent_task.done():
                        agent_task.cancel()
                    agent_task = asyncio.create_task(run_agent(msg.content))

                elif msg.type == "new_conversation":
                    session.clear()

                elif msg.type == "tool_result":
                    if msg.id and msg.id in self._pending_tool_calls:
                        event, container = self._pending_tool_calls.pop(msg.id)
                        container["result"] = msg.result or ""
                        event.set()

                elif msg.type == "update_workspace":
                    if msg.path:
                        session.set_workspace(msg.path)

        except WebSocketDisconnect:
            pass
        finally:
            running = False
            if agent_task and not agent_task.done():
                agent_task.cancel()
            ws_manager_var.reset(token)
            self._client_ws = None
            session_manager.remove_session(session.id)
