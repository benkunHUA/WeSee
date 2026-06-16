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
