# server/main.py
import logging
from fastapi import FastAPI, WebSocket
from fastapi.staticfiles import StaticFiles
from config import ServerConfig
from tools.shell import ShellTool
from tools.filesystem import FileSystemTool
from tools.screenshot import ScreenshotTool
from agent.runner import AgentRunner
from session.manager import SessionManager
from handlers.websocket import WebSocketManager
from handlers.api import create_api_router
from conversations.store import ConversationStore
from memory.rdbms.base import make_engine, make_session_factory

logging.basicConfig(
    level=logging.DEBUG,
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
    datefmt="%H:%M:%S",
)


def create_app(
    config: ServerConfig | None = None,
    *,
    conversation_store: ConversationStore | None = None,
    agent_runner: AgentRunner | None = None,
) -> FastAPI:
    if config is None:
        config = ServerConfig(api_key="sk-test")

    app = FastAPI(title="WeSee Server")

    tools = [
        ShellTool(workspace_path="/tmp"),
        FileSystemTool(workspace_path="/tmp"),
        ScreenshotTool(workspace_path="/tmp"),
    ]
    resolved_agent_runner = agent_runner or AgentRunner(config=config, tools=tools)
    if conversation_store is None:
        engine = make_engine(config.postgres_dsn)
        conversation_store = ConversationStore(make_session_factory(engine))

        @app.on_event("shutdown")
        async def dispose_database_engine():
            await engine.dispose()

    session_manager = SessionManager()
    ws_manager = WebSocketManager()

    # API routes
    api_router = create_api_router(
        session_manager,
        resolved_agent_runner,
        conversation_store,
    )
    app.include_router(api_router)

    # WebSocket endpoint
    @app.websocket("/ws")
    async def websocket_endpoint(ws: WebSocket):
        await ws_manager.handle_client(
            ws,
            session_manager,
            resolved_agent_runner,
            conversation_store,
        )

    # Static files
    try:
        app.mount("/", StaticFiles(directory="static", html=True), name="static")
    except Exception:
        pass

    return app


if __name__ == "__main__":
    import uvicorn
    config = ServerConfig()
    app = create_app(config)
    uvicorn.run(app, host="0.0.0.0", port=config.http_port)
