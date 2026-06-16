# server/tests/test_prompt.py
from agent.prompt import build_system_prompt


def test_build_system_prompt():
    prompt = build_system_prompt("/Users/test/projects")
    assert "helpful assistant" in prompt
    assert "/Users/test/projects" in prompt
    assert "Chinese" in prompt or "中文" in prompt


def test_build_system_prompt_different_workspace():
    prompt = build_system_prompt("/tmp")
    assert "/tmp" in prompt
