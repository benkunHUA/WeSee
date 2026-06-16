# server/tests/test_llm.py
from agent.llm import create_llm
from config import ServerConfig


def test_create_llm_returns_chat_openai():
    config = ServerConfig(api_key="sk-test")
    llm = create_llm(config)
    assert llm.model_name == "deepseek-v4-pro"
    assert "api.deepseek.com" in str(llm.openai_api_base)


def test_create_llm_with_custom_config():
    config = ServerConfig(
        api_key="sk-custom",
        base_url="https://custom.api.com",
        model="custom-model",
    )
    llm = create_llm(config)
    assert llm.model_name == "custom-model"
    assert "custom.api.com" in str(llm.openai_api_base)
