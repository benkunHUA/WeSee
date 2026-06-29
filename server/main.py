# server/main.py
import logging
from contextlib import asynccontextmanager

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

# 全局日志配置：
# - level=logging.DEBUG：本地开发阶段能看到更多细节（包含你们自定义 logger 的 info/debug）
# - format/datefmt：统一输出格式，方便排查问题
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
    # create_app：FastAPI 的应用工厂（Application Factory）
    # - 好处：方便测试与依赖注入（测试时可传入 fake 的 conversation_store/agent_runner）
    # - 参数说明：
    #   - config：服务端配置（通常来自环境变量/.env）
    #   - conversation_store：对话存储（可注入，避免测试连真实数据库）
    #   - agent_runner：Agent 执行器（可注入，测试可跳过真实 LLM/工具/RAG）
    if config is None:
        # 没有显式传 config 时给一个默认值（方便本地/单元测试跑起来）
        # 注意：这里的 api_key 只是占位值，真正运行时一般通过环境变量提供
        config = ServerConfig(api_key="sk-test")

    # 工具列表（Tools）：
    # - Agent 会根据用户的任务选择调用工具
    # - workspace_path="/tmp" 是一个默认工作目录（真实产品可能会是用户的项目目录）
    tools = [
        ShellTool(workspace_path="/tmp"),
        FileSystemTool(workspace_path="/tmp"),
        ScreenshotTool(workspace_path="/tmp"),
    ]

    # Tool RAG index setup — only when agent_runner is not injected (tests skip this)
    # ToolIndex：给工具做向量检索（RAG）索引，用来从一堆工具里挑最相关的几个
    # 这里的设计点：
    # - 如果外部注入了 agent_runner（例如测试场景），则跳过 ToolIndex、Embedder 等初始化
    # - 这样测试不会依赖 embedding 服务/Milvus Lite 等外部组件
    tool_index = None
    resolved_agent_runner = agent_runner
    if resolved_agent_runner is None:
        # 1) 先初始化 ToolIndex
        # - embedder：把工具描述向量化（用于相似度检索）
        # - milvus_path：Milvus Lite 存储路径（本地文件）
        tool_index = ToolIndex(
            embedder=DoubaoEmbedder(MemoryConfig.from_server_config(config)),
            milvus_path=config.milvus_lite_path,
        )

        # whitelist：可用工具白名单
        # - 通常用于安全控制：即使 tools 里注册了很多工具，也只允许部分工具可被调用
        whitelist = {"shell", "file_system"}

        # 2) 初始化 AgentRunner（Agent 运行器）
        # - 负责把 LLM、tools、tool_index、对话历史等组织起来执行，并输出流式事件
        resolved_agent_runner = AgentRunner(
            config=config,
            tools=tools,
            tool_index=tool_index,
            whitelist=whitelist,
        )

    # 会话/对话存储（数据库）初始化：
    # - 如果没有注入 conversation_store，就用 config.postgres_dsn 创建真实连接
    # - 如果注入了（测试），这里会跳过数据库连接
    _engine = None
    if conversation_store is None:
        _engine = make_engine(config.postgres_dsn)
        conversation_store = ConversationStore(make_session_factory(_engine))

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        # lifespan：FastAPI 生命周期钩子（启动/关闭）
        # 启动阶段做：
        # - 确保默认用户存在（对话系统需要）
        # - 构建 ToolIndex（把工具描述向量化并写入 Milvus Lite），便于后续 RAG 检索工具
        await conversation_store.ensure_default_user()
        if tool_index is not None:
            await tool_index.build_index(tools)
        yield
        # 关闭阶段做：
        # - 释放数据库连接
        if _engine is not None:
            await _engine.dispose()

    # 创建 FastAPI app，并绑定 lifespan
    app = FastAPI(title="WeSee Server", lifespan=lifespan)

    # SessionManager：管理会话（比如 ws 连接对应的 session / thread）
    session_manager = SessionManager()
    # WebSocketManager：负责 websocket 连接的生命周期、消息收发与路由
    ws_manager = WebSocketManager()

    # API routes
    # REST API 路由：
    # - create_api_router 会把 session_manager / agent_runner / conversation_store 注入到接口层
    api_router = create_api_router(
        session_manager,
        resolved_agent_runner,
        conversation_store,
    )
    app.include_router(api_router)

    # WebSocket endpoint
    @app.websocket("/ws")
    async def websocket_endpoint(ws: WebSocket):
        # websocket 入口：
        # - 把 ws 连接交给 ws_manager 统一处理
        # - 处理过程中会用到 session_manager、agent_runner、conversation_store
        await ws_manager.handle_client(
            ws,
            session_manager,
            resolved_agent_runner,
            conversation_store,
        )

    # Static files
    # 静态文件挂载：
    # - 如果 static 目录存在，会把它作为网站根目录（/）提供
    # - try/except 是为了兼容某些运行环境没有 static 目录时不报错
    try:
        app.mount("/", StaticFiles(directory="static", html=True), name="static")
    except Exception:
        pass

    return app


if __name__ == "__main__":
    import uvicorn

    # 直接 python server/main.py 启动服务时走这里：
    # - ServerConfig() 会从环境变量/.env 读取配置（见 server/config.py）
    # - uvicorn.run 以 config.http_port 启动 HTTP 服务
    config = ServerConfig()
    app = create_app(config)
    uvicorn.run(app, host="0.0.0.0", port=config.http_port)
