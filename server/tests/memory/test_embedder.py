import pytest
import respx
from httpx import Response
from memory.config import MemoryConfig
from memory.embeddings import DoubaoEmbedder

CFG = MemoryConfig(
    postgres_dsn="x",
    milvus_lite_path="x",
    ark_api_key="ak-test",
    ark_base_url="https://ark.example.com/api/coding/v3",
    embedding_model="doubao-embedding-vision",
    write_async=True,
)


@pytest.mark.asyncio
@respx.mock
async def test_embed_calls_ark_api_with_correct_payload():
    route = respx.post(
        "https://ark.example.com/api/coding/v3/embeddings"
    ).mock(
        return_value=Response(
            200,
            json={"data": [{"embedding": [0.1, 0.2, 0.3]}]},
        )
    )
    emb = DoubaoEmbedder(CFG)
    vecs = await emb.embed(["hello"])
    assert vecs == [[0.1, 0.2, 0.3]]
    assert route.called
    req = route.calls.last.request
    assert req.headers["authorization"] == "Bearer ak-test"
    body = req.read().decode()
    assert "doubao-embedding-vision" in body
    assert "hello" in body


@pytest.mark.asyncio
@respx.mock
async def test_dim_probe_caches_dimension():
    respx.post(
        "https://ark.example.com/api/coding/v3/embeddings"
    ).mock(
        return_value=Response(
            200,
            json={"data": [{"embedding": [0.0] * 1024}]},
        )
    )
    emb = DoubaoEmbedder(CFG)
    await emb.probe()
    assert emb.dim == 1024
    # second access does not re-call
    await emb.probe()
    assert respx.calls.call_count == 1


@pytest.mark.asyncio
@respx.mock
async def test_embed_raises_on_http_error():
    respx.post(
        "https://ark.example.com/api/coding/v3/embeddings"
    ).mock(return_value=Response(500, json={"error": "boom"}))
    emb = DoubaoEmbedder(CFG)
    from memory.embeddings import EmbeddingError
    with pytest.raises(EmbeddingError):
        await emb.embed(["x"])
