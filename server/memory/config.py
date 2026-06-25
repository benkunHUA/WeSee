from dataclasses import dataclass
from config import ServerConfig


@dataclass(frozen=True)
class MemoryConfig:
    postgres_dsn: str
    milvus_lite_path: str
    ark_api_key: str
    ark_base_url: str
    embedding_model: str
    write_async: bool

    @classmethod
    def from_server_config(cls, cfg: ServerConfig) -> "MemoryConfig":
        return cls(
            postgres_dsn=cfg.postgres_dsn,
            milvus_lite_path=cfg.milvus_lite_path,
            ark_api_key=cfg.ark_api_key,
            ark_base_url=cfg.ark_base_url,
            embedding_model=cfg.embedding_model,
            write_async=cfg.memory_write_async,
        )
