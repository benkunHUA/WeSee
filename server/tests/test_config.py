# server/tests/test_config.py
import os
import pytest
from config import ServerConfig


def test_config_defaults():
    """Should use defaults when env vars are not set."""
    config = ServerConfig(api_key="test-key")  # api_key is required
    assert config.base_url == "https://api.deepseek.com"
    assert config.model == "deepseek-v4-pro"
    assert config.enable_thinking is True
    assert config.reasoning_effort is None
    assert config.http_port == 8080


def test_config_from_env(monkeypatch):
    """Should read from WESEE_ prefixed env vars."""
    monkeypatch.setenv("WESEE_API_KEY", "sk-env-key")
    monkeypatch.setenv("WESEE_BASE_URL", "https://custom.api.com")
    monkeypatch.setenv("WESEE_MODEL", "custom-model")
    monkeypatch.setenv("WESEE_HTTP_PORT", "9090")

    config = ServerConfig()
    assert config.api_key == "sk-env-key"
    assert config.base_url == "https://custom.api.com"
    assert config.model == "custom-model"
    assert config.http_port == 9090


def test_config_missing_api_key():
    """Should raise validation error when api_key is missing."""
    with pytest.raises(ValueError):
        ServerConfig(api_key="")  # empty after init
