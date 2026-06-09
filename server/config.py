import os
from functools import lru_cache


class Settings:
    deepseek_api_key: str = os.environ.get("DEEPSEEK_API_KEY", "")
    deepseek_base_url: str = os.environ.get(
        "DEEPSEEK_BASE_URL", "https://api.deepseek.com"
    )
    deepseek_model: str = os.environ.get("DEEPSEEK_MODEL", "deepseek-chat")
    database_url: str = os.environ.get(
        "DATABASE_URL", "sqlite+aiosqlite:///./weseed.db"
    )
    server_host: str = os.environ.get("SERVER_HOST", "127.0.0.1")
    server_port: int = int(os.environ.get("SERVER_PORT", "8000"))


@lru_cache()
def get_settings() -> Settings:
    return Settings()
