# server/tests/test_config.py
import os
import pytest
from pydantic import ValidationError
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
    with pytest.raises(ValidationError):
        ServerConfig(api_key="")


def test_config_whitespace_api_key():
    """Should reject whitespace-only api_key."""
    with pytest.raises(ValidationError):
        ServerConfig(api_key="   ")


def test_config_valid_reasoning_effort():
    """Should accept valid reasoning_effort values."""
    for value in ("low", "medium", "high"):
        config = ServerConfig(api_key="test-key", reasoning_effort=value)
        assert config.reasoning_effort == value


def test_config_invalid_reasoning_effort():
    """Should reject invalid reasoning_effort values."""
    with pytest.raises(ValidationError):
        ServerConfig(api_key="test-key", reasoning_effort="invalid")


def test_config_invalid_http_port_too_low():
    """Should reject http_port below 1."""
    with pytest.raises(ValidationError):
        ServerConfig(api_key="test-key", http_port=0)


def test_config_invalid_http_port_too_high():
    """Should reject http_port above 65535."""
    with pytest.raises(ValidationError):
        ServerConfig(api_key="test-key", http_port=65536)
