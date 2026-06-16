# server/config.py
from pydantic import field_validator
from pydantic_settings import BaseSettings


class ServerConfig(BaseSettings):
    api_key: str
    base_url: str = "https://api.deepseek.com"
    model: str = "deepseek-v4-pro"
    enable_thinking: bool = True
    reasoning_effort: str | None = None
    http_port: int = 8080

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
