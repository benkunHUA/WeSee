import asyncio
from typing import Protocol

from memory.config import MemoryConfig


class EmbeddingError(RuntimeError):
    pass


class Embedder(Protocol):
    async def embed(self, texts: list[str]) -> list[list[float]]: ...
    @property
    def dim(self) -> int: ...


class DoubaoEmbedder:
    def __init__(self, cfg: MemoryConfig, timeout: float = 30.0):
        self._cfg = cfg
        self._timeout = timeout
        self._dim: int | None = None
        self._client = None

    @property
    def dim(self) -> int:
        if self._dim is None:
            raise EmbeddingError("dim not probed yet; call await probe() first")
        return self._dim

    async def _get_client(self):
        if self._client is None:
            from volcenginesdkarkruntime import Ark

            self._client = Ark(api_key=self._cfg.ark_api_key)
        return self._client

    async def probe(self) -> int:
        if self._dim is not None:
            return self._dim
        vecs = await self.embed(["probe"])
        self._dim = len(vecs[0])
        return self._dim

    async def embed(self, texts: list[str]) -> list[list[float]]:
        if not texts:
            return []
        client = await self._get_client()
        input_items = [{"type": "text", "text": t} for t in texts]
        try:
            resp = await asyncio.to_thread(
                client.multimodal_embeddings.create,
                model=self._cfg.embedding_model,
                input=input_items,
            )
        except Exception as e:
            raise EmbeddingError(f"embedding error: {e}") from e
        dim = len(resp.data.embedding) // len(texts)
        return [
            resp.data.embedding[i : i + dim]
            for i in range(0, len(resp.data.embedding), dim)
        ]

    async def aclose(self) -> None:
        self._client = None
