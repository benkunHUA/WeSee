import asyncio
from typing import Protocol

from memory.config import MemoryConfig


# EmbeddingError：向量化（embedding）相关错误的统一异常类型
# - 继承 RuntimeError，表示运行时阶段出现的问题（网络/接口/数据格式等）
class EmbeddingError(RuntimeError):
    pass


# Embedder：一个“协议(Protocol)”接口，用来描述“Embedder 需要具备哪些能力”
# - Protocol 类似“接口/契约”，不提供实现，只规定方法签名
# - 任何类只要实现了 embed() 和 dim 属性，就可以被当做 Embedder 使用（结构化类型/鸭子类型）
class Embedder(Protocol):
    # embed：把一组文本转换为一组向量
    # - 返回值 list[list[float]]：每个输入文本对应一个浮点向量
    async def embed(self, texts: list[str]) -> list[list[float]]: ...

    @property
    # dim：向量维度（例如 1024/1536 等）
    # - 这里定义为属性而不是方法，便于调用方像访问字段一样读取
    def dim(self) -> int: ...


# DoubaoEmbedder：一个基于火山引擎 Ark SDK 的向量化实现
# - 这里的名字“Doubao”来自项目的 embedding 服务来源（豆包/火山引擎一类的命名）
# - 依赖 MemoryConfig 提供 API Key、模型名等配置
class DoubaoEmbedder:
    def __init__(self, cfg: MemoryConfig, timeout: float = 30.0):
        # cfg：从 ServerConfig 转换来的 MemoryConfig，仅包含 memory/embedding 相关配置
        self._cfg = cfg
        # timeout：超时时间（目前只存储，实际请求是否使用取决于 SDK 的实现/参数）
        self._timeout = timeout

        # _dim：缓存向量维度
        # - 初始为 None，表示尚未探测（probe）
        # - 之所以缓存，是为了避免每次都做一次“探测调用”
        self._dim: int | None = None

        # _client：懒加载的 Ark 客户端
        # - 延迟导入/创建：减少启动成本，也避免在没用到 embedding 时就引入依赖
        self._client = None

    @property
    def dim(self) -> int:
        # dim 是一个“只读属性”
        # - 若尚未 probe，就抛错，强制调用方先完成探测
        if self._dim is None:
            raise EmbeddingError("dim not probed yet; call await probe() first")
        return self._dim

    async def _get_client(self):
        # 懒加载 Ark 客户端：
        # - 首次调用时才 import 并创建 client
        # - 后续复用 self._client，避免重复初始化
        if self._client is None:
            # 这里采用“函数内导入”，让依赖只在需要时才加载
            from volcenginesdkarkruntime import Ark

            # 创建 Ark 客户端（SDK 的具体参数以 volcenginesdkarkruntime 为准）
            self._client = Ark(api_key=self._cfg.ark_api_key)
        return self._client

    async def probe(self) -> int:
        # probe：探测向量维度
        # - 通常 embedding API 的返回向量维度与模型相关
        # - 这里用一次最小调用 embed(["probe"]) 来推断维度并缓存
        if self._dim is not None:
            return self._dim
        vecs = await self.embed(["probe"])
        self._dim = len(vecs[0])
        return self._dim

    async def embed(self, texts: list[str]) -> list[list[float]]:
        # embed：核心方法，把 texts 转为向量
        # - 注意这是 async 方法，适合在 FastAPI / 异步任务中调用
        if not texts:
            # 空输入直接返回空列表，避免无意义的外部请求
            return []

        # 获取/创建 Ark 客户端
        client = await self._get_client()

        # 把纯文本转成 SDK 需要的输入格式（多模态输入结构）
        input_items = [{"type": "text", "text": t} for t in texts]
        try:
            # SDK 的 create 方法可能是同步阻塞的（网络 IO）
            # - asyncio.to_thread：把同步阻塞函数放到线程池执行，避免阻塞事件循环
            # - 这样 FastAPI 的其他请求/协程不会被卡住
            resp = await asyncio.to_thread(
                client.multimodal_embeddings.create,
                model=self._cfg.embedding_model,
                input=input_items,
            )
        except Exception as e:
            # 把第三方异常包装成 EmbeddingError，便于上层统一捕获与处理
            raise EmbeddingError(f"embedding error: {e}") from e

        # 这里假设 resp.data.embedding 是“扁平的一维数组”：
        # - 假设有 N 条文本，每条向量维度为 D
        # - 那么 resp.data.embedding 的长度为 N * D
        # - 通过总长度 // N 推出 D（dim）
        dim = len(resp.data.embedding) // len(texts)

        # 按 dim 把扁平数组切分回 N 个向量
        return [
            resp.data.embedding[i : i + dim]
            for i in range(0, len(resp.data.embedding), dim)
        ]

    async def aclose(self) -> None:
        # aclose：关闭/释放资源
        # - 这里没有显式 close SDK client（取决于 SDK 是否提供关闭方法）
        # - 通过置空让客户端可被 GC 回收，并在下次调用时重新初始化
        self._client = None
