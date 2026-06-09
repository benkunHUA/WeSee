import json
from typing import AsyncIterator

import httpx

from config import get_settings

settings = get_settings()

SYSTEM_PROMPT = """You are a helpful, friendly AI assistant. Answer concisely and naturally.
Use the conversation history for context. Respond in the same language as the user's most recent message."""


def build_messages(history: list[dict], user_content: str) -> list[dict]:
    messages = [{"role": "system", "content": SYSTEM_PROMPT}]
    for h in history:
        role = "user" if h["is_from_me"] else "assistant"
        messages.append({"role": role, "content": h["content"]})
    messages.append({"role": "user", "content": user_content})
    return messages


async def stream_chat(
    history: list[dict],
    user_content: str,
) -> AsyncIterator[str]:
    """Call DeepSeek API with streaming, yield one token at a time."""
    messages = build_messages(history, user_content)

    async with httpx.AsyncClient(timeout=httpx.Timeout(60.0)) as client:
        async with client.stream(
            "POST",
            f"{settings.deepseek_base_url}/v1/chat/completions",
            headers={
                "Authorization": f"Bearer {settings.deepseek_api_key}",
                "Content-Type": "application/json",
            },
            json={
                "model": settings.deepseek_model,
                "messages": messages,
                "stream": True,
                "temperature": 0.7,
                "max_tokens": 2048,
            },
        ) as response:
            response.raise_for_status()
            async for line in response.aiter_lines():
                if line.startswith("data: "):
                    data_str = line[6:]
                    if data_str == "[DONE]":
                        return
                    try:
                        data = json.loads(data_str)
                        delta = data["choices"][0].get("delta", {})
                        content = delta.get("content", "")
                        if content:
                            yield content
                    except (json.JSONDecodeError, KeyError, IndexError):
                        continue
