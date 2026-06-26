from __future__ import annotations

import logging
import os

from langchain_core.tools import BaseTool
from pymilvus import MilvusClient

from memory.embeddings import Embedder
from tools.schema import (
    TOOL_INDEX_COLLECTION,
    TOOL_INDEX_DIM,
    TOOL_INDEX_FIELD_DESC,
    TOOL_INDEX_FIELD_ID,
    TOOL_INDEX_FIELD_VECTOR,
)

logger = logging.getLogger("wesee.tools")


def _build_embedding_text(tool: BaseTool) -> str:
    parts = [f"name: {tool.name}", f"description: {tool.description}"]
    if tool.args_schema is not None:
        try:
            schema = tool.args_schema.model_fields
        except AttributeError:
            schema = {}
        arg_lines = []
        for field_name, field_info in schema.items():
            desc = getattr(field_info, "description", "") or ""
            arg_lines.append(f"{field_name} ({desc})" if desc else field_name)
        if arg_lines:
            parts.append("args: " + ", ".join(arg_lines))
    return "\n".join(parts)


class ToolIndex:
    def __init__(self, embedder: Embedder, milvus_path: str):
        self._embedder = embedder
        self._milvus_path = milvus_path
        self._client: MilvusClient | None = None
        self._tool_map: dict[str, BaseTool] = {}

    def _connect(self) -> MilvusClient:
        if self._client is None:
            parent = os.path.dirname(os.path.abspath(self._milvus_path))
            os.makedirs(parent, exist_ok=True)
            self._client = MilvusClient(uri=self._milvus_path)
        return self._client

    async def build_index(self, tools: list[BaseTool]) -> None:
        client = self._connect()
        self._tool_map = {tool.name: tool for tool in tools}

        if not tools:
            return

        texts = [_build_embedding_text(tool) for tool in tools]
        try:
            vectors = await self._embedder.embed(texts)
        except Exception as exc:
            logger.warning(
                "Failed to embed tool descriptions; skipping index build: %s", exc
            )
            return

        if client.has_collection(TOOL_INDEX_COLLECTION):
            client.drop_collection(TOOL_INDEX_COLLECTION)

        client.create_collection(
            collection_name=TOOL_INDEX_COLLECTION,
            dimension=TOOL_INDEX_DIM,
            metric_type="COSINE",
            auto_id=False,
            primary_field_name=TOOL_INDEX_FIELD_ID,
            id_type="string",
            max_length=256,
        )

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
        client = self._connect()
        if not client.has_collection(TOOL_INDEX_COLLECTION):
            return []

        try:
            query_vec = (await self._embedder.embed([query]))[0]
        except Exception:
            logger.warning("Failed to embed query; returning empty tools")
            return []

        results = client.search(
            collection_name=TOOL_INDEX_COLLECTION,
            data=[query_vec],
            limit=k,
            output_fields=[TOOL_INDEX_FIELD_ID],
        )

        tool_names: list[str] = []
        for hit in results[0]:
            tool_names.append(hit["entity"][TOOL_INDEX_FIELD_ID])

        return [self._tool_map[name] for name in tool_names if name in self._tool_map]
