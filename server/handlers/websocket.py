# server/handlers/websocket.py
import json
import logging
import asyncio
from fastapi import WebSocket, WebSocketDisconnect
from models.events import ClientMessage, ServerEvent
from session.manager import SessionManager, Session
from agent.runner import AgentRunner
from conversations.store import ConversationStore
from memory.rdbms.models import SessionRow
from models.message import Message
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
        conversation_store: ConversationStore,
    ):
        await ws.accept()
        self._client_ws = ws
        await conversation_store.ensure_default_user()
        token = ws_manager_var.set(self)
        agent_task: asyncio.Task | None = None
        running = True

        # Always create a new session on connect; the first client
        # message may override this with a session_id for resume.
        stored_session = await conversation_store.create_session(workspace_path="/tmp")
        session = session_manager.create_session(
            session_id=stored_session.id,
            workspace_path=stored_session.workspace_path,
            messages=[],
        )
        await self._send_raw(ServerEvent(type="session", session_id=session.id))
        logger.info("Client connected, session=%s", session.id[:8])

        async def _resume_session(desired_session_id: str) -> Session:
            stored = await conversation_store.get_session(desired_session_id)
            if stored is None:
                await self._send_raw(
                    ServerEvent(type="error", data="Invalid session_id")
                )
                raise ValueError("Invalid session_id")
            loaded_messages = await conversation_store.load_messages(stored.id)
            session_manager.remove_session(session.id)
            new_session = session_manager.create_session(
                session_id=stored.id,
                workspace_path=stored.workspace_path,
                messages=loaded_messages,
            )
            await self._send_raw(ServerEvent(type="session", session_id=new_session.id))
            logger.info("Resumed session=%s", new_session.id[:8])
            return new_session

        async def run_agent(content: str):
            logger.info("Agent task started, content='%s'", content[:80])
            event_count = 0
            assistant_content = ""
            tool_calls: list[dict] = []
            async for event in agent_runner.run(
                history=list(session.messages),
                workspace_path=session.workspace_path,
                stream_tool_events=False,
                user_query=content,
            ):
                if event.type == "token" and event.data:
                    assistant_content = f"{assistant_content}{event.data}"
                elif event.type == "tool_call":
                    tool_calls = [
                        *tool_calls,
                        {
                            "id": event.id,
                            "name": event.name,
                            "arguments": event.arguments or {},
                        },
                    ]

                await self._event_queue.put(event)
                event_count += 1
                logger.debug("Agent event #%d: type=%s", event_count, event.type)
                if event.type == "done":
                    assistant_message = session.add_message(
                        role="assistant",
                        content=assistant_content,
                        tool_calls=tool_calls or None,
                    )
                    await conversation_store.append_message(
                        session.id,
                        assistant_message,
                        meta={"source": "websocket"},
                    )
                    logger.info("Agent finished: type=done, events=%d", event_count)
                    return
                if event.type == "error":
                    logger.info("Agent finished: type=error, events=%d", event_count)
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

                # Resume persisted session when client provides session_id
                if msg.session_id and msg.session_id != session.id:
                    try:
                        session = await _resume_session(msg.session_id)
                    except ValueError:
                        continue

                if msg.type == "chat":
                    if not msg.content:
                        logger.warning("Chat message with empty content")
                        continue
                    user_message = session.add_message(role="user", content=msg.content)
                    try:
                        await conversation_store.append_message(
                            session.id, user_message
                        )
                    except ValueError as exc:
                        await self._send_raw(
                            ServerEvent(type="error", data=str(exc))
                        )
                        continue
                    logger.info("Starting agent for: '%s'", msg.content[:80])
                    if agent_task and not agent_task.done():
                        agent_task.cancel()
                    agent_task = asyncio.create_task(run_agent(msg.content))

                elif msg.type == "new_conversation":
                    logger.info("New conversation, creating persisted session")
                    stored_session = await conversation_store.create_session(
                        workspace_path=session.workspace_path,
                    )
                    session_manager.remove_session(session.id)
                    session = session_manager.create_session(
                        session_id=stored_session.id,
                        workspace_path=stored_session.workspace_path,
                        messages=[],
                    )
                    await self._send_raw(
                        ServerEvent(type="session", session_id=session.id)
                    )

                elif msg.type == "tool_result":
                    if msg.id and msg.id in self._pending_tool_calls:
                        logger.info(
                            "Tool result: id=%s, result=%s",
                            msg.id,
                            (msg.result or "")[:80],
                        )
                        event, container = self._pending_tool_calls.pop(msg.id)
                        container["result"] = msg.result or ""
                        event.set()
                    else:
                        logger.warning(
                            "Tool result for unknown call: id=%s", msg.id
                        )

                elif msg.type == "update_workspace":
                    if msg.path:
                        logger.info("Update workspace: %s", msg.path)
                        session.set_workspace(msg.path)
                        try:
                            await conversation_store.update_workspace(
                                session.id, msg.path
                            )
                        except ValueError as exc:
                            await self._send_raw(
                                ServerEvent(type="error", data=str(exc))
                            )

        except WebSocketDisconnect:
            logger.info("Client disconnected")
        finally:
            running = False
            if agent_task and not agent_task.done():
                agent_task.cancel()
            ws_manager_var.reset(token)
            self._client_ws = None
            session_manager.remove_session(session.id)
