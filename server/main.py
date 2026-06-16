# server/main.py
from fastapi import FastAPI, WebSocket
from config import ServerConfig
from tools.shell import ShellTool
from tools.filesystem import FileSystemTool
from tools.screenshot import ScreenshotTool
from agent.runner import AgentRunner
from session.manager import SessionManager
from handlers.websocket import WebSocketManager


def create_app(config: ServerConfig | None = None) -> FastAPI:
    if config is None:
        config = ServerConfig(api_key="sk-test")

    app = FastAPI(title="WeSee Server")

    tools = [
        ShellTool(workspace_path="/tmp"),
        FileSystemTool(workspace_path="/tmp"),
        ScreenshotTool(workspace_path="/tmp"),
    ]
    agent_runner = AgentRunner(config=config, tools=tools)
    session_manager = SessionManager()
    ws_manager = WebSocketManager()

    @app.websocket("/ws")
    async def websocket_endpoint(ws: WebSocket):
        await ws_manager.handle_client(ws, session_manager, agent_runner)

    return app


if __name__ == "__main__":
    import uvicorn
    config = ServerConfig()
    app = create_app(config)
    uvicorn.run(app, host="0.0.0.0", port=config.http_port)
