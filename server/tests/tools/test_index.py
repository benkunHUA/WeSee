import os
import tempfile
from unittest.mock import AsyncMock, MagicMock

import pytest

from tools.index import ToolIndex


def _fake_embedder(dim: int = 1024):
    import math

    async def embed(texts: list[str]) -> list[list[float]]:
        vectors = []
        for t in texts:
            t_lower = t.lower()
            vec = [0.0] * dim
            # Character-level trigrams for fuzzy matching
            for i in range(len(t_lower) - 2):
                idx = hash(t_lower[i : i + 3]) % dim
                vec[idx] = 1.0
            # Also include word-level hashing
            for w in t_lower.split():
                idx = hash(w) % dim
                vec[idx] = 1.0
            # Normalize
            norm = math.sqrt(sum(v * v for v in vec))
            if norm > 0:
                vec = [v / norm for v in vec]
            vectors.append(vec)
        return vectors

    mock = AsyncMock()
    mock.embed = embed
    mock.dim = dim
    return mock


def _make_tool(name: str, description: str):
    from langchain_core.tools import BaseTool

    tool = MagicMock(spec=BaseTool)
    tool.name = name
    tool.description = description
    tool.args_schema = None
    return tool


@pytest.mark.asyncio
async def test_build_index_and_search_round_trip():
    with tempfile.TemporaryDirectory() as tmpdir:
        db_path = os.path.join(tmpdir, "test_milvus.db")
        embedder = _fake_embedder()
        index = ToolIndex(embedder, db_path)

        tools = [
            _make_tool("shell", "Run shell commands safely"),
            _make_tool("file_system", "Read write list files in workspace"),
            _make_tool("screenshot", "Take screenshots on macOS"),
        ]

        await index.build_index(tools)

        results = await index.search("execute a command", k=1)
        assert len(results) == 1
        assert results[0].name == "shell"

        results = await index.search("capture the screen", k=1)
        assert len(results) == 1
        assert results[0].name == "screenshot"


@pytest.mark.asyncio
async def test_build_index_upsert_does_not_duplicate():
    with tempfile.TemporaryDirectory() as tmpdir:
        db_path = os.path.join(tmpdir, "test_milvus.db")
        embedder = _fake_embedder()
        index = ToolIndex(embedder, db_path)

        tools = [_make_tool("shell", "Run shell commands safely")]
        await index.build_index(tools)
        await index.build_index(tools)

        results = await index.search("command", k=5)
        assert len(results) == 1


@pytest.mark.asyncio
async def test_search_returns_empty_when_index_not_built():
    with tempfile.TemporaryDirectory() as tmpdir:
        db_path = os.path.join(tmpdir, "test_milvus2.db")
        embedder = _fake_embedder()
        index = ToolIndex(embedder, db_path)
        results = await index.search("anything", k=3)
        assert results == []
