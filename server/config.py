# server/config.py
from typing import Literal

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings


class ServerConfig(BaseSettings):
    api_key: str
    base_url: str = "https://api.deepseek.com"
    model: str = "deepseek-v4-pro"
    enable_thinking: bool = True
    reasoning_effort: Literal["low", "medium", "high"] | None = None
    http_port: int = Field(default=8080, ge=1, le=65535)
    postgres_dsn: str = "postgresql+asyncpg://wesee:wesee@localhost:5432/wesee"
    milvus_lite_path: str = "./data/wesee_memory.db"
    ark_api_key: str = ""
    ark_base_url: str = "https://ark.cn-beijing.volces.com/api/coding/v3"
    embedding_model: str = "doubao-embedding-vision"
    memory_write_async: bool = True

    @field_validator("api_key")
    @classmethod
    def api_key_must_not_be_empty(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("api_key must not be empty")
        return v

    model_config = {
        "env_prefix": "WESEE_",
        "env_file": ".env",
        "extra": "ignore",
    }
