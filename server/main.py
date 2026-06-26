# server/main.py
import logging
from fastapi import FastAPI, WebSocket
from fastapi.staticfiles import StaticFiles
from config import ServerConfig
from tools.index import ToolIndex
from tools.shell import ShellTool
from tools.filesystem import FileSystemTool
from tools.screenshot import ScreenshotTool
from agent.runner import AgentRunner
from memory.config import MemoryConfig
from memory.embeddings import DoubaoEmbedder
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

    # Tool RAG index setup — only when agent_runner is not injected (tests skip this)
    tool_index = None
    resolved_agent_runner = agent_runner
    if resolved_agent_runner is None:
        tool_index = ToolIndex(
            embedder=DoubaoEmbedder(MemoryConfig.from_server_config(config)),
            milvus_path=config.milvus_lite_path,
        )
        whitelist = {"shell", "file_system"}
        resolved_agent_runner = AgentRunner(
            config=config,
            tools=tools,
            tool_index=tool_index,
            whitelist=whitelist,
        )
    if conversation_store is None:
        engine = make_engine(config.postgres_dsn)
        conversation_store = ConversationStore(make_session_factory(engine))

        @app.on_event("shutdown")
        async def dispose_database_engine():
            await engine.dispose()

    @app.on_event("startup")
    async def on_startup():
        await conversation_store.ensure_default_user()
        if tool_index is not None:
            await tool_index.build_index(tools)

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
