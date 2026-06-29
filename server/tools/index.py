from __future__ import annotations

import logging
import os

# 用于给“工具列表”做一个轻量的 RAG（检索增强）索引：
# - 把每个工具的名称/描述/参数信息拼成文本
# - 用 embedder 把文本转为向量
# - 把向量写入 Milvus Lite（本地 milvus 文件）中
# - 查询时把 query 向量化，并在 Milvus 里做向量相似度搜索，返回最相关的工具
#
# 这类索引的作用：当工具很多时，让 Agent 先“挑选最相关的少量工具”，降低工具调用的搜索空间。

# 抑制 Milvus Lite 的 gRPC "too_many_pings" 噪音日志
os.environ["GRPC_VERBOSITY"] = "NONE"
os.environ["GRPC_TRACE"] = ""

from langchain_core.tools import BaseTool
from pymilvus import MilvusClient

from memory.embeddings import Embedder
from tools.schema import (
    TOOL_INDEX_COLLECTION,
    TOOL_INDEX_FIELD_DESC,
    TOOL_INDEX_FIELD_ID,
    TOOL_INDEX_FIELD_VECTOR,
)

logger = logging.getLogger("wesee.tools")


def _build_embedding_text(tool: BaseTool) -> str:
    # 把一个 Tool 的信息整理成可被向量化的文本：
    # - name/description 是最核心的信息
    # - args_schema（如果存在）则把参数名与描述也拼进去，增强可检索性
    # 这样用户输入“截图/文件/命令”等关键词时，更容易把工具检索出来
    parts = [f"name: {tool.name}", f"description: {tool.description}"]
    if tool.args_schema is not None:
        try:
            # Pydantic v2：schema 会有 model_fields
            schema = tool.args_schema.model_fields
        except AttributeError:
            # 兼容某些工具 schema 不符合预期的情况：直接忽略参数信息
            schema = {}
        arg_lines = []
        for field_name, field_info in schema.items():
            # 字段描述不一定存在，用 getattr 做兜底
            desc = getattr(field_info, "description", "") or ""
            arg_lines.append(f"{field_name} ({desc})" if desc else field_name)
        if arg_lines:
            parts.append("args: " + ", ".join(arg_lines))
    return "\n".join(parts)


class ToolIndex:
    def __init__(self, embedder: Embedder, milvus_path: str):
        # embedder：一个“文本 -> 向量”的组件（duck typing：只要实现 embed()/dim 就行）
        self._embedder = embedder
        # milvus_path：Milvus Lite 的本地存储路径（一般是一个文件路径）
        self._milvus_path = milvus_path
        # _client：懒加载的 MilvusClient（第一次用到时才创建）
        self._client: MilvusClient | None = None
        # _tool_map：工具名 -> 工具对象
        # - 搜索时 Milvus 只返回工具名（id），这里用 map 把它还原成 BaseTool
        self._tool_map: dict[str, BaseTool] = {}

    def _connect(self) -> MilvusClient:
        # 连接（或创建）Milvus Lite 客户端：
        # - MilvusClient(uri=...) 在 Lite 模式下会把数据落到本地路径
        # - 这里确保 milvus_path 的父目录存在
        if self._client is None:
            parent = os.path.dirname(os.path.abspath(self._milvus_path))
            os.makedirs(parent, exist_ok=True)
            self._client = MilvusClient(uri=self._milvus_path)
        return self._client

    async def build_index(self, tools: list[BaseTool]) -> None:
        # 构建索引（通常在服务启动时调用一次）：
        # 1) 生成每个工具的“embedding 文本”
        # 2) 让 embedder 批量向量化
        # 3) 在 Milvus Lite 创建 collection 并写入向量
        client = self._connect()
        self._tool_map = {tool.name: tool for tool in tools}

        if not tools:
            # 没有工具就无需建索引
            return

        texts = [_build_embedding_text(tool) for tool in tools]
        try:
            # 批量向量化：一次请求生成所有工具的向量
            vectors = await self._embedder.embed(texts)
        except Exception as exc:
            # embedding 失败时，选择降级：跳过索引构建，不影响服务启动
            logger.warning(
                "Failed to embed tool descriptions; skipping index build: %s", exc
            )
            return

        # 向量维度由 embedder/model 决定，通常所有向量维度相同
        dim = len(vectors[0])

        if client.has_collection(TOOL_INDEX_COLLECTION):
            # 为了保证“工具列表变化后索引一致”，这里选择直接删表重建
            # - 优点：逻辑简单
            # - 代价：工具多时重建开销更大（但一般工具数量不大）
            client.drop_collection(TOOL_INDEX_COLLECTION)

        client.create_collection(
            collection_name=TOOL_INDEX_COLLECTION,
            dimension=dim,
            metric_type="COSINE",
            auto_id=False,
            primary_field_name=TOOL_INDEX_FIELD_ID,
            id_type="string",
            max_length=256,
        )

        # 准备写入 Milvus 的数据结构：
        # - id：工具名（作为主键）
        # - desc：工具描述（可选，但可用于调试/展示）
        # - vector：工具向量（用于相似度检索）
        data = []
        for tool, vector in zip(tools, vectors):
            data.append({
                TOOL_INDEX_FIELD_ID: tool.name,
                TOOL_INDEX_FIELD_DESC: tool.description,
                TOOL_INDEX_FIELD_VECTOR: vector,
            })

        client.insert(collection_name=TOOL_INDEX_COLLECTION, data=data)
        logger.info("Built tool index with %d tools", len(tools))

    async def search(self, query: str, k: int = 2) -> list[BaseTool]:
        # 搜索最相关的 k 个工具：
        # 1) 把 query 向量化
        # 2) 在 Milvus 里用向量相似度搜索
        # 3) 用 _tool_map 把“工具名”还原成 BaseTool 返回
        client = self._connect()
        if not client.has_collection(TOOL_INDEX_COLLECTION):
            # 还没建索引就直接返回空
            return []

        try:
            # 把查询文本向量化，取第一条向量作为 query_vec
            query_vec = (await self._embedder.embed([query]))[0]
        except Exception:
            # 查询向量化失败时降级返回空（避免影响主流程）
            logger.warning("Failed to embed query; returning empty tools")
            return []

        results = client.search(
            collection_name=TOOL_INDEX_COLLECTION,
            data=[query_vec],
            limit=k,
            output_fields=[TOOL_INDEX_FIELD_ID],
        )

        # results 的结构通常是：
        # - 外层 list：对应每个 query 向量（这里我们只搜 1 个 query_vec）
        # - 内层 list：Top-K 的命中结果，每个 hit 包含 entity + distance 等字段
        tool_names: list[str] = []
        for hit in results[0]:
            name = hit["entity"][TOOL_INDEX_FIELD_ID]
            score = hit.get("distance", 0)
            tool_names.append(name)
            logger.info("RAG hit: tool=%s score=%.4f", name, score)

        # 返回工具对象列表；若工具名找不到（可能 tools 列表更新），则跳过
        return [self._tool_map[name] for name in tool_names if name in self._tool_map]
