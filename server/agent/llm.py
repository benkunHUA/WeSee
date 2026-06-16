# server/agent/llm.py
from langchain_openai import ChatOpenAI
from config import ServerConfig


def create_llm(config: ServerConfig) -> ChatOpenAI:
    return ChatOpenAI(
        model=config.model,
        base_url=f"{config.base_url.rstrip('/')}/v1",
        api_key=config.api_key,
        streaming=True,
        temperature=0.7,
    )
