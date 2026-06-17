# server/handlers/websocket.py
import json
import logging
import asyncio
from fastapi import WebSocket, WebSocketDisconnect
from models.events import ClientMessage, ServerEvent
from session.manager import SessionManager, Session
from agent.runner import AgentRunner
from tools.base import ws_manager_var

logger = logging.getLogger("wesee.ws")


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
                payload = json.dumps(event.model_dump(exclude_none=True))
                logger.debug("Sending: %s", payload[:200])
                await self._client_ws.send_text(payload)
            except Exception as exc:
                logger.error("Send failed: %s", exc)

    async def handle_client(
        self,
        ws: WebSocket,
        session_manager: SessionManager,
        agent_runner: AgentRunner,
    ):
        await ws.accept()
        self._client_ws = ws
        session = session_manager.create_session()
        logger.info("Client connected, session=%s", session.id[:8])
        token = ws_manager_var.set(self)
        agent_task: asyncio.Task | None = None
        running = True

        async def run_agent(content: str):
            logger.info("Agent task started, content='%s'", content[:80])
            event_count = 0
            async for event in agent_runner.run(
                history=list(session.messages),
                workspace_path=session.workspace_path,
                stream_tool_events=False,
            ):
                await self._event_queue.put(event)
                event_count += 1
                logger.debug("Agent event #%d: type=%s", event_count, event.type)
                if event.type in ("done", "error"):
                    logger.info(
                        "Agent finished: type=%s, events=%d",
                        event.type,
                        event_count,
                    )
                    return

        try:
            while running:
                # Drain outgoing event queue
                while not self._event_queue.empty():
                    event = await self._event_queue.get()
                    await self._send_raw(event)

                # Receive incoming messages
                try:
                    raw = await asyncio.wait_for(ws.receive_text(), timeout=0.05)
                except asyncio.TimeoutError:
                    continue

                logger.debug("Received raw: %s", raw[:200])

                try:
                    data = json.loads(raw)
                    msg = ClientMessage(**data)
                except Exception as exc:
                    logger.error("Invalid message: %s", exc)
                    await self._send_raw(
                        ServerEvent(type="error", data="Invalid message format")
                    )
                    continue

                logger.info("Message: type=%s", msg.type)

                if msg.type == "chat":
                    if not msg.content:
                        logger.warning("Chat message with empty content")
                        continue
                    session.add_message(role="user", content=msg.content)
                    logger.info("Starting agent for: '%s'", msg.content[:80])
                    if agent_task and not agent_task.done():
                        agent_task.cancel()
                    agent_task = asyncio.create_task(run_agent(msg.content))

                elif msg.type == "new_conversation":
                    logger.info("New conversation, clearing session")
                    session.clear()

                elif msg.type == "tool_result":
                    if msg.id and msg.id in self._pending_tool_calls:
                        logger.info("Tool result: id=%s, result=%s", msg.id, (msg.result or "")[:80])
                        event, container = self._pending_tool_calls.pop(msg.id)
                        container["result"] = msg.result or ""
                        event.set()
                    else:
                        logger.warning("Tool result for unknown call: id=%s", msg.id)

                elif msg.type == "update_workspace":
                    if msg.path:
                        logger.info("Update workspace: %s", msg.path)
                        session.set_workspace(msg.path)

        except WebSocketDisconnect:
            logger.info("Client disconnected")
        finally:
            running = False
            if agent_task and not agent_task.done():
                agent_task.cancel()
            ws_manager_var.reset(token)
            self._client_ws = None
            session_manager.remove_session(session.id)
