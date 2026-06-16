# server/tests/conftest.py
import pytest
from config import ServerConfig


@pytest.fixture
def test_config():
    return ServerConfig(api_key="test-key-for-unit-tests")
