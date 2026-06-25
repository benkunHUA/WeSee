# server/handlers/api.py
import json
import os
from fastapi import APIRouter, Request, HTTPException
from fastapi.responses import JSONResponse, FileResponse
from sse_starlette.sse import EventSourceResponse
from session.manager import SessionManager, Session
from agent.runner import AgentRunner
from conversations.store import ConversationStore


def create_api_router(
    session_manager: SessionManager,
    agent_runner: AgentRunner,
    conversation_store: ConversationStore,
) -> APIRouter:
    router = APIRouter()
    current_session_id: str | None = None

    async def get_or_create_web_session() -> Session:
        nonlocal current_session_id
        await conversation_store.ensure_default_user()
        stored_session = None
        if current_session_id is not None:
            stored_session = await conversation_store.get_session(current_session_id)
        if stored_session is None:
            stored_session = await conversation_store.get_latest_session()
        if stored_session is None:
            stored_session = await conversation_store.create_session(workspace_path="/tmp")
        current_session_id = stored_session.id

        cached = session_manager.get_session(stored_session.id)
        if cached is not None:
            return cached

        messages = await conversation_store.load_messages(stored_session.id)
        return session_manager.create_session(
            session_id=stored_session.id,
            workspace_path=stored_session.workspace_path,
            messages=messages,
        )

    @router.post("/api/chat")
    async def chat(request: Request):
        try:
            body = await request.json()
        except Exception:
            raise HTTPException(status_code=400, detail="Invalid JSON")

        content = body.get("content", "").strip()
        if not content or len(content) > 5000:
            raise HTTPException(status_code=400, detail="Invalid content")

        web_session = await get_or_create_web_session()
        user_message = web_session.add_message(role="user", content=content)
        try:
            await conversation_store.append_message(web_session.id, user_message)
        except ValueError as exc:
            raise HTTPException(status_code=404, detail=str(exc))

        async def event_generator():
            assistant_content = ""
            tool_calls: list[dict] = []
            try:
                async for event in agent_runner.run(
                    history=list(web_session.messages),
                    workspace_path=web_session.workspace_path,
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

                    data = json.dumps(
                        event.model_dump(exclude_none=True),
                        ensure_ascii=False,
                    )
                    yield {"event": event.type, "data": data}

                    if event.type == "done":
                        assistant_message = web_session.add_message(
                            role="assistant",
                            content=assistant_content,
                            tool_calls=tool_calls or None,
                        )
                        await conversation_store.append_message(
                            web_session.id,
                            assistant_message,
                            meta={"source": "http"},
                        )
                    elif event.type == "error":
                        break
            except Exception as e:
                error_data = json.dumps({"type": "error", "data": str(e)})
                yield {"event": "error", "data": error_data}

        return EventSourceResponse(event_generator())

    @router.get("/api/messages")
    async def get_messages():
        web_session = await get_or_create_web_session()
        messages = await conversation_store.load_messages(web_session.id)
        return JSONResponse({
            "messages": [
                {
                    "id": str(i),
                    "content": msg.content or "",
                    "isFromMe": msg.role == "user",
                }
                for i, msg in enumerate(messages)
            ]
        })

    @router.post("/api/new-conversation")
    async def new_conversation():
        nonlocal current_session_id
        previous_session = await get_or_create_web_session()
        stored_session = await conversation_store.create_session(
            workspace_path=previous_session.workspace_path,
        )
        current_session_id = stored_session.id
        session_manager.create_session(
            session_id=stored_session.id,
            workspace_path=stored_session.workspace_path,
            messages=[],
        )
        return JSONResponse({"ok": True, "session_id": stored_session.id})

    @router.get("/api/files/screenshots/{filename}")
    async def serve_screenshot(filename: str):
        web_session = await get_or_create_web_session()
        screenshots_dir = os.path.join(web_session.workspace_path, "screenshots")
        safe_path = os.path.realpath(os.path.join(screenshots_dir, filename))
        if not safe_path.startswith(os.path.realpath(screenshots_dir) + os.sep):
            raise HTTPException(status_code=403, detail="Forbidden")
        if not os.path.isfile(safe_path):
            raise HTTPException(status_code=404, detail="Not found")
        return FileResponse(safe_path)

    return router
