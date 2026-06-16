# server/handlers/api.py
import json
from fastapi import APIRouter, Request, HTTPException
from fastapi.responses import JSONResponse
from sse_starlette.sse import EventSourceResponse
from session.manager import SessionManager
from agent.runner import AgentRunner


def create_api_router(
    session_manager: SessionManager,
    agent_runner: AgentRunner,
) -> APIRouter:
    router = APIRouter()
    web_session = session_manager.create_session()

    @router.post("/api/chat")
    async def chat(request: Request):
        try:
            body = await request.json()
        except Exception:
            raise HTTPException(status_code=400, detail="Invalid JSON")

        content = body.get("content", "").strip()
        if not content or len(content) > 5000:
            raise HTTPException(status_code=400, detail="Invalid content")

        web_session.add_message(role="user", content=content)

        async def event_generator():
            try:
                async for event in agent_runner.run(
                    history=list(web_session.messages[:-1]),
                    workspace_path=web_session.workspace_path,
                ):
                    data = json.dumps(
                        event.model_dump(exclude_none=True),
                        ensure_ascii=False,
                    )
                    yield {"event": event.type, "data": data}

                    if event.type == "done":
                        web_session.add_message(role="assistant", content="")
                    elif event.type == "error":
                        break
            except Exception as e:
                error_data = json.dumps({"type": "error", "data": str(e)})
                yield {"event": "error", "data": error_data}

        return EventSourceResponse(event_generator())

    @router.get("/api/messages")
    async def get_messages():
        return JSONResponse({
            "messages": [
                {
                    "id": str(i),
                    "content": msg.content or "",
                    "isFromMe": msg.role == "user",
                }
                for i, msg in enumerate(web_session.messages)
            ]
        })

    @router.post("/api/new-conversation")
    async def new_conversation():
        web_session.clear()
        return JSONResponse({"ok": True})

    return router
