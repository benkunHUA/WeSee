import httpx
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
        self._client = httpx.AsyncClient(
            base_url=cfg.ark_base_url,
            timeout=timeout,
            headers={
                "Authorization": f"Bearer {cfg.ark_api_key}",
                "Content-Type": "application/json",
            },
        )

    @property
    def dim(self) -> int:
        if self._dim is None:
            raise EmbeddingError("dim not probed yet; call await probe() first")
        return self._dim

    async def probe(self) -> int:
        if self._dim is not None:
            return self._dim
        vecs = await self.embed(["probe"])
        self._dim = len(vecs[0])
        return self._dim

    async def embed(self, texts: list[str]) -> list[list[float]]:
        if not texts:
            return []
        payload = {"model": self._cfg.embedding_model, "input": texts}
        try:
            resp = await self._client.post("/embeddings", json=payload)
        except httpx.HTTPError as e:
            raise EmbeddingError(f"embedding HTTP error: {e}") from e
        if resp.status_code != 200:
            raise EmbeddingError(
                f"embedding non-200: {resp.status_code} {resp.text[:200]}"
            )
        data = resp.json().get("data", [])
        return [item["embedding"] for item in data]

    async def aclose(self) -> None:
        await self._client.aclose()
