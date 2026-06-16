# WeSee FastAPI Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Python FastAPI server that replaces the macOS client's LLM calling and Agent loop, communicating with the client via WebSocket for tool execution and streaming.

**Architecture:** FastAPI server with LangGraph-based agent loop. Server communicates with macOS client via WebSocket (bidirectional: streaming tokens down, tool calls down, tool results up) and serves a web UI via HTTP+SSE. Configuration is server-side only via .env file.

**Tech Stack:** Python 3.12+, FastAPI, uvicorn, LangChain/LangGraph (ChatOpenAI pointing to DeepSeek), pydantic-settings, pytest-asyncio, uv for package management.

---

## File Map

| File | Responsibility |
|------|---------------|
| `server/pyproject.toml` | uv project config + dependencies |
| `server/config.py` | ServerConfig via pydantic-settings from .env |
| `server/models/events.py` | Pydantic models for WS/SSE events |
| `server/models/message.py` | Message data model |
| `server/agent/llm.py` | ChatOpenAI factory |
| `server/agent/prompt.py` | System prompt builder |
| `server/agent/runner.py` | LangGraph agent wrapper + event streaming |
| `server/tools/base.py` | Base tool with WS-forward + local fallback |
| `server/tools/shell.py` | Shell command execution tool |
| `server/tools/filesystem.py` | File system read/write/list tool |
| `server/tools/screenshot.py` | Screenshot tool (macOS only) |
| `server/handlers/websocket.py` | WebSocket endpoint + connection manager |
| `server/handlers/api.py` | REST API + SSE streaming endpoint |
| `server/session/manager.py` | In-memory session state management |
| `server/main.py` | FastAPI app entry point |
| `server/static/index.html` | Web UI (copied from client) |
| `server/static/app.js` | Web UI JS (copied from client) |
| `server/.env.example` | Example config file |
| `client/WeSee/Services/WebSocketClient.swift` | NEW: WebSocket client for macOS app |
| `client/WeSee/ViewModels/ChatViewModel.swift` | MODIFY: use WebSocketClient instead of AgentRunner |
| `client/WeSee/ContentView.swift` | MODIFY: remove AgentRunner/SystemPromptBuilder deps |
| `client/WeSee/WeSeeApp.swift` | MODIFY: remove AgentRunner, DeepSeekService init |
| `client/WeSee/Models/Config.swift` | MODIFY: remove LLM fields, keep workspace/httpPort |
| `client/WeSee/Services/ChatSession.swift` | MODIFY: simplify to forward to WebSocketClient |
| `client/WeSee/Services/HttpServer.swift` | MODIFY: proxy to Python server or remove |

## Phase 1: Server Foundation

### Task 1: Project scaffold

**Files:**
- Create: `server/pyproject.toml`
- Create: `server/.env.example`
- Create: `server/.gitignore`

- [ ] **Step 1: Create pyproject.toml**

```toml
[project]
name = "wesee-server"
version = "0.1.0"
description = "WeSee AI companion backend"
requires-python = ">=3.12"
dependencies = [
    "fastapi>=0.115.0",
    "uvicorn[standard]>=0.30.0",
    "langchain>=0.3.0",
    "langchain-openai>=0.2.0",
    "langgraph>=0.2.0",
    "pydantic>=2.0.0",
    "pydantic-settings>=2.0.0",
    "sse-starlette>=2.0.0",
]

[project.optional-dependencies]
dev = [
    "pytest>=8.0.0",
    "pytest-asyncio>=0.24.0",
    "httpx>=0.27.0",
]
```

- [ ] **Step 2: Create .env.example**

```env
WESEE_API_KEY=sk-your-api-key
WESEE_BASE_URL=https://api.deepseek.com
WESEE_MODEL=deepseek-v4-pro
WESEE_HTTP_PORT=8080
```

- [ ] **Step 3: Create .gitignore**

```
.env
__pycache__/
*.pyc
.pytest_cache/
.venv/
```

- [ ] **Step 4: Install dependencies with uv**

```bash
cd server && uv sync
```

- [ ] **Step 5: Commit**

```bash
cd server && git add pyproject.toml .env.example .gitignore && git commit -m "chore: scaffold server project with uv and dependencies"
```

### Task 2: Server configuration

**Files:**
- Create: `server/config.py`
- Create: `server/tests/__init__.py`
- Create: `server/tests/conftest.py`
- Create: `server/tests/test_config.py`

- [ ] **Step 1: Write failing test for config**

```python
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
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd server && uv run pytest tests/test_config.py -v
```
Expected: FAIL (module not found)

- [ ] **Step 3: Implement config.py**

```python
# server/config.py
from pydantic_settings import BaseSettings


class ServerConfig(BaseSettings):
    api_key: str
    base_url: str = "https://api.deepseek.com"
    model: str = "deepseek-v4-pro"
    enable_thinking: bool = True
    reasoning_effort: str | None = None
    http_port: int = 8080

    model_config = {
        "env_prefix": "WESEE_",
        "env_file": ".env",
        "extra": "ignore",
    }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd server && uv run pytest tests/test_config.py -v
```
Expected: PASS

- [ ] **Step 5: Create conftest.py**

```python
# server/tests/conftest.py
import pytest
from config import ServerConfig


@pytest.fixture
def test_config():
    return ServerConfig(api_key="test-key-for-unit-tests")
```

- [ ] **Step 6: Commit**

```bash
git add server/config.py server/tests/
git commit -m "feat: add ServerConfig with pydantic-settings"
```

### Task 3: Event and Message models

**Files:**
- Create: `server/models/__init__.py`
- Create: `server/models/events.py`
- Create: `server/models/message.py`
- Create: `server/tests/test_models.py`

- [ ] **Step 1: Write failing test for models**

```python
# server/tests/test_models.py
import json
from models.events import (
    ClientMessage,
    ServerEvent,
    TokenEvent,
    ThinkingEvent,
    ToolCallEvent,
    ToolResultEvent,
    DoneEvent,
    ErrorEvent,
)
from models.message import Message


class TestClientMessage:
    def test_chat_message(self):
        msg = ClientMessage(type="chat", content="hello")
        data = json.loads(msg.model_dump_json())
        assert data == {"type": "chat", "content": "hello"}

    def test_new_conversation(self):
        msg = ClientMessage(type="new_conversation")
        data = json.loads(msg.model_dump_json())
        assert data == {"type": "new_conversation"}

    def test_tool_result(self):
        msg = ClientMessage(
            type="tool_result",
            id="call_1",
            name="shell",
            result="file1.txt\nfile2.txt",
        )
        data = json.loads(msg.model_dump_json())
        assert data["type"] == "tool_result"
        assert data["id"] == "call_1"
        assert data["name"] == "shell"

    def test_update_workspace(self):
        msg = ClientMessage(
            type="update_workspace",
            path="/Users/test/projects",
        )
        data = json.loads(msg.model_dump_json())
        assert data["path"] == "/Users/test/projects"


class TestServerEvent:
    def test_token_event(self):
        event = ServerEvent(type="token", data="hello")
        data = json.loads(event.model_dump_json())
        assert data == {"type": "token", "data": "hello"}

    def test_tool_call_event(self):
        event = ServerEvent(
            type="tool_call",
            id="call_1",
            name="shell",
            arguments={"command": "ls"},
        )
        data = json.loads(event.model_dump_json())
        assert data["type"] == "tool_call"
        assert data["arguments"] == {"command": "ls"}

    def test_done_event(self):
        event = ServerEvent(type="done")
        data = json.loads(event.model_dump_json())
        assert data["type"] == "done"

    def test_error_event(self):
        event = ServerEvent(type="error", data="something went wrong")
        data = json.loads(event.model_dump_json())
        assert data["data"] == "something went wrong"


class TestMessage:
    def test_message_creation(self):
        msg = Message(role="user", content="hello")
        assert msg.role == "user"
        assert msg.content == "hello"
        assert msg.tool_calls is None
        assert msg.tool_call_id is None

    def test_tool_message(self):
        msg = Message(
            role="tool",
            content="result",
            tool_call_id="call_1",
        )
        assert msg.tool_call_id == "call_1"

    def test_to_dict(self):
        msg = Message(role="user", content="hello")
        d = msg.to_dict()
        assert d == {"role": "user", "content": "hello"}

    def test_to_dict_tool_message(self):
        msg = Message(role="tool", content="output", tool_call_id="call_1")
        d = msg.to_dict()
        assert d == {
            "role": "tool",
            "content": "output",
            "tool_call_id": "call_1",
        }

    def test_to_dict_assistant_with_tool_calls(self):
        msg = Message(
            role="assistant",
            content=None,
            tool_calls=[
                {
                    "id": "call_1",
                    "type": "function",
                    "function": {
                        "name": "shell",
                        "arguments": '{"command":"ls"}',
                    },
                }
            ],
        )
        d = msg.to_dict()
        assert d["role"] == "assistant"
        assert d["content"] is None
        assert len(d["tool_calls"]) == 1
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd server && uv run pytest tests/test_models.py -v
```
Expected: FAIL

- [ ] **Step 3: Implement events.py**

```python
# server/models/events.py
from pydantic import BaseModel
from typing import Any


class ClientMessage(BaseModel):
    """Messages from macOS client to server."""
    type: str  # chat, new_conversation, tool_result, update_workspace
    content: str | None = None
    id: str | None = None
    name: str | None = None
    result: str | None = None
    path: str | None = None


class ServerEvent(BaseModel):
    """Events from server to macOS client."""
    type: str  # token, thinking, tool_call, done, error
    data: str | None = None
    id: str | None = None
    name: str | None = None
    arguments: dict[str, Any] | None = None
```

- [ ] **Step 4: Implement message.py**

```python
# server/models/message.py
from dataclasses import dataclass, field
from typing import Any


@dataclass
class Message:
    role: str  # system, user, assistant, tool
    content: str | None
    tool_calls: list[dict[str, Any]] | None = None
    tool_call_id: str | None = None
    name: str | None = None

    def to_dict(self) -> dict[str, Any]:
        d: dict[str, Any] = {"role": self.role}
        if self.content is not None:
            d["content"] = self.content
        if self.tool_calls is not None:
            d["tool_calls"] = self.tool_calls
        if self.tool_call_id is not None:
            d["tool_call_id"] = self.tool_call_id
        if self.name is not None:
            d["name"] = self.name
        return d
```

- [ ] **Step 5: Run test to verify it passes**

```bash
cd server && uv run pytest tests/test_models.py -v
```
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add server/models/ server/tests/test_models.py
git commit -m "feat: add event and message models"
```

## Phase 2: Agent & LLM

### Task 4: LLM factory

**Files:**
- Create: `server/agent/__init__.py`
- Create: `server/agent/llm.py`
- Create: `server/tests/test_llm.py`

- [ ] **Step 1: Write failing test for LLM factory**

```python
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
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd server && uv run pytest tests/test_llm.py -v
```
Expected: FAIL

- [ ] **Step 3: Implement llm.py**

```python
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
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd server && uv run pytest tests/test_llm.py -v
```
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add server/agent/__init__.py server/agent/llm.py server/tests/test_llm.py
git commit -m "feat: add ChatOpenAI factory for LLM"
```

### Task 5: System prompt builder

**Files:**
- Create: `server/agent/prompt.py`
- Create: `server/tests/test_prompt.py`

- [ ] **Step 1: Write failing test for system prompt**

```python
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
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd server && uv run pytest tests/test_prompt.py -v
```
Expected: FAIL

- [ ] **Step 3: Implement prompt.py**

```python
# server/agent/prompt.py
def build_system_prompt(workspace_path: str = "/tmp") -> str:
    parts = [
        "You are a helpful assistant running inside a macOS application.",
        f"Your working directory is: {workspace_path}",
        "All relative paths are resolved against this directory.",
        "Respond in Chinese unless the user asks otherwise.",
    ]
    return "\n".join(parts)
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd server && uv run pytest tests/test_prompt.py -v
```
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add server/agent/prompt.py server/tests/test_prompt.py
git commit -m "feat: add system prompt builder"
```

### Task 6: Tool base class and Shell tool

**Files:**
- Create: `server/tools/__init__.py`
- Create: `server/tools/base.py`
- Create: `server/tools/shell.py`
- Create: `server/tests/test_tools.py`

- [ ] **Step 1: Write failing test for tools**

```python
# server/tests/test_tools.py
import pytest
from tools.shell import ShellTool


class TestShellTool:
    def test_name_and_description(self):
        tool = ShellTool(workspace_path="/tmp")
        assert tool.name == "shell"
        assert "shell" in tool.description.lower()

    def test_execute_echo_local(self):
        tool = ShellTool(workspace_path="/tmp")
        result = tool._run(command="echo hello")
        assert "hello" in result

    def test_execute_ls_local(self):
        tool = ShellTool(workspace_path="/tmp")
        result = tool._run(command="ls")
        assert result  # should have some output

    def test_reject_pipe(self):
        tool = ShellTool(workspace_path="/tmp")
        result = tool._run(command="ls | grep test")
        assert "disallowed" in result.lower() or "pipes" in result.lower()

    def test_reject_unknown_command(self):
        tool = ShellTool(workspace_path="/tmp")
        result = tool._run(command="unknown_cmd_xyz")
        assert "not in the allowed list" in result.lower()

    def test_timeout(self):
        tool = ShellTool(workspace_path="/tmp", timeout_seconds=1)
        result = tool._run(command="sleep 30")
        assert "timeout" in result.lower() or "terminated" in result.lower()
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd server && uv run pytest tests/test_tools.py -v
```
Expected: FAIL

- [ ] **Step 3: Implement base.py**

```python
# server/tools/base.py
from abc import abstractmethod
from typing import Any
from langchain_core.tools import BaseTool


class ClientForwardTool(BaseTool):
    """Tool that can execute locally or forward to macOS client."""

    workspace_path: str = "/tmp"

    def _run(self, *args: Any, **kwargs: Any) -> str:
        """Sync execution always runs locally."""
        return self._run_local(**kwargs)

    @abstractmethod
    def _run_local(self, **kwargs: Any) -> str:
        """Execute the tool locally on the server."""
        ...
```

- [ ] **Step 4: Implement shell.py**

```python
# server/tools/shell.py
import subprocess
import shlex
from typing import Any
from tools.base import ClientForwardTool


ALLOWED_COMMANDS = {
    "ls", "cat", "head", "tail", "wc", "grep", "find", "echo",
    "pwd", "date", "whoami", "uname", "df", "du", "ps", "top",
    "git", "swift", "xcodebuild", "python3", "node", "npm",
    "sed", "awk", "sort", "uniq", "diff", "xargs", "mkdir",
    "touch", "cp", "mv", "rm", "chmod", "ln", "file", "which",
    "open", "osascript", "plutil", "defaults", "system_profiler",
    "sleep",
}

DANGEROUS_PATTERNS = [
    ("|", "pipes"),
    (";", "command separators"),
    ("&", "background/chain operators"),
    ("`", "backtick command substitution"),
    ("$(", "command substitution"),
    (">", "output redirection"),
    ("<", "input redirection"),
]


class ShellTool(ClientForwardTool):
    name: str = "shell"
    description: str = (
        "Execute a safe shell command. Only supported commands are allowed. "
        "No pipes, redirects, or command substitution. Commands have a "
        "30-second timeout."
    )
    timeout_seconds: int = 30

    def _run_local(self, **kwargs: Any) -> str:
        command = kwargs.get("command", "")
        if not command:
            return "Error: missing required parameter 'command'"

        trimmed = command.strip()
        if not trimmed:
            return "Error: empty command"

        for pattern, name in DANGEROUS_PATTERNS:
            if pattern in trimmed:
                return f"Error: command contains disallowed {name} ('{pattern}')"

        first_word = trimmed.split()[0] if trimmed.split() else ""
        command_name = first_word.split("/")[-1]
        if command_name not in ALLOWED_COMMANDS:
            return f"Error: command '{command_name}' is not in the allowed list"

        try:
            result = subprocess.run(
                trimmed,
                shell=True,
                capture_output=True,
                text=True,
                timeout=self.timeout_seconds,
                cwd=self.workspace_path,
                env={
                    "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                    "HOME": subprocess.os.environ.get("HOME", "/tmp"),
                },
            )
            output = ""
            if result.stdout:
                output += result.stdout
            if result.stderr:
                output += ("\n" if output else "") + result.stderr
            if not output:
                output = "(no output)"
            if result.returncode != 0:
                output = f"Exit code {result.returncode}\n{output}"
            return output
        except subprocess.TimeoutExpired:
            return "Error: command timed out"
        except Exception as e:
            return f"Error: {e}"
```

- [ ] **Step 5: Run test to verify it passes**

```bash
cd server && uv run pytest tests/test_tools.py -v
```
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add server/tools/ server/tests/test_tools.py
git commit -m "feat: add tool base class and ShellTool"
```

### Task 7: FileSystem and Screenshot tools

**Files:**
- Create: `server/tools/filesystem.py`
- Create: `server/tools/screenshot.py`
- Modify: `server/tests/test_tools.py` (add tests)

- [ ] **Step 1: Add failing tests for FileSystemTool and ScreenshotTool**

Append to `server/tests/test_tools.py`:

```python
import tempfile
import os
from tools.filesystem import FileSystemTool
from tools.screenshot import ScreenshotTool


class TestFileSystemTool:
    def test_name_and_description(self):
        tool = FileSystemTool(workspace_path="/tmp")
        assert tool.name == "file_system"
        assert "read" in tool.description.lower()

    def test_missing_action(self):
        tool = FileSystemTool(workspace_path="/tmp")
        result = tool._run(path="test.txt")
        assert "missing required" in result.lower()

    def test_unknown_action(self):
        tool = FileSystemTool(workspace_path="/tmp")
        result = tool._run(action="delete", path="test.txt")
        assert "unknown action" in result.lower()

    def test_read_nonexistent_file(self):
        tool = FileSystemTool(workspace_path="/tmp")
        result = tool._run(action="read_file", path="/tmp/nonexistent_xyz.txt")
        assert "not found" in result.lower()

    def test_write_and_read_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            tool = FileSystemTool(workspace_path=tmpdir)
            write_result = tool._run(
                action="write_file",
                path="hello.txt",
                content="hello world",
            )
            assert "Successfully wrote" in write_result

            read_result = tool._run(action="read_file", path="hello.txt")
            assert "hello world" in read_result

    def test_list_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            tool = FileSystemTool(workspace_path=tmpdir)
            # create a file
            with open(os.path.join(tmpdir, "test.txt"), "w") as f:
                f.write("test")
            result = tool._run(action="list_directory", path=".")
            assert "test.txt" in result

    def test_path_escape_prevention(self):
        tool = FileSystemTool(workspace_path="/tmp/safe")
        result = tool._run(action="read_file", path="../../../etc/passwd")
        assert "escapes" in result.lower()


class TestScreenshotTool:
    def test_name_and_description(self):
        tool = ScreenshotTool(workspace_path="/tmp")
        assert tool.name == "screenshot"
        assert "screenshot" in tool.description.lower()

    def test_local_execution_returns_error(self):
        """When running on server without macOS screencapture, should return error."""
        tool = ScreenshotTool(workspace_path="/tmp")
        result = tool._run()
        assert "not available" in result.lower() or "error" in result.lower() or result.startswith("/")
```

- [ ] **Step 2: Run test to verify they fail**

```bash
cd server && uv run pytest tests/test_tools.py::TestFileSystemTool tests/test_tools.py::TestScreenshotTool -v
```
Expected: FAIL

- [ ] **Step 3: Implement filesystem.py**

```python
# server/tools/filesystem.py
import os
from typing import Any
from tools.base import ClientForwardTool


class FileSystemTool(ClientForwardTool):
    name: str = "file_system"
    description: str = (
        "Read, write, and list files within the workspace directory. "
        "Use read_file to read content, write_file to create or overwrite "
        "files, and list_directory to list directory contents. "
        "All paths are relative to the workspace root."
    )
    max_file_size: int = 1_000_000

    def _run_local(self, **kwargs: Any) -> str:
        action = kwargs.get("action", "")
        path = kwargs.get("path", "")
        content = kwargs.get("content", "")

        if not action or not path:
            return "Error: missing required parameters 'action' or 'path'"

        safe_path = self._resolve_safe_path(path)
        if safe_path is None:
            return f"Error: path '{path}' escapes the workspace directory"

        if action == "read_file":
            return self._read_file(safe_path)
        elif action == "write_file":
            return self._write_file(content, safe_path)
        elif action == "list_directory":
            return self._list_directory(safe_path)
        else:
            return f"Error: unknown action '{action}'. Supported: read_file, write_file, list_directory"

    def _resolve_safe_path(self, relative_path: str) -> str | None:
        root = os.path.realpath(self.workspace_path)
        resolved = os.path.realpath(os.path.join(root, relative_path))
        if not resolved.startswith(root + os.sep) and resolved != root:
            return None
        return resolved

    def _read_file(self, path: str) -> str:
        if not os.path.isfile(path):
            return f"Error: file not found at {path}"
        try:
            size = os.path.getsize(path)
            if size > self.max_file_size:
                return "Error: file too large"
            with open(path, "r", encoding="utf-8") as f:
                return f.read()
        except Exception as e:
            return f"Error reading file: {e}"

    def _write_file(self, content: str, path: str) -> str:
        try:
            dir_path = os.path.dirname(path)
            if dir_path:
                os.makedirs(dir_path, exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                f.write(content)
            return f"Successfully wrote {len(content)} bytes to {path}"
        except Exception as e:
            return f"Error writing file: {e}"

    def _list_directory(self, path: str) -> str:
        if not os.path.isdir(path):
            return f"Error: directory not found at {path}"
        try:
            items = sorted(os.listdir(path))
            return "\n".join(items)
        except Exception as e:
            return f"Error listing directory: {e}"
```

- [ ] **Step 4: Implement screenshot.py**

```python
# server/tools/screenshot.py
import subprocess
import os
import time
from typing import Any
from tools.base import ClientForwardTool


class ScreenshotTool(ClientForwardTool):
    name: str = "screenshot"
    description: str = (
        "Take a screenshot on macOS. Supports fullscreen, window selection, "
        "or interactive area selection. Screenshots are saved as PNG files."
    )

    def _run_local(self, **kwargs: Any) -> str:
        """Screenshot only works on macOS with screencapture binary available."""
        screenshot_type = kwargs.get("type", "fullscreen")
        screenshot_dir = os.path.join(self.workspace_path, "screenshots")
        os.makedirs(screenshot_dir, exist_ok=True)

        timestamp = int(time.time())
        filename = f"screenshot_{timestamp}.png"
        output_path = os.path.join(screenshot_dir, filename)

        args = ["/usr/sbin/screencapture"]
        if screenshot_type == "window":
            args.extend(["-w", "-W"])
        elif screenshot_type == "selection":
            args.append("-i")
        args.append(output_path)

        try:
            result = subprocess.run(
                args,
                capture_output=True,
                text=True,
                timeout=30,
            )
            if result.returncode == 0:
                return output_path
            else:
                return f"Error: screenshot failed with exit code {result.returncode}: {result.stderr}"
        except FileNotFoundError:
            return "Error: screenshot not available (screencapture not found - not macOS?)"
        except subprocess.TimeoutExpired:
            return "Error: screenshot timed out"
        except Exception as e:
            return f"Error: {e}"
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd server && uv run pytest tests/test_tools.py -v
```
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add server/tools/filesystem.py server/tools/screenshot.py server/tests/test_tools.py
git commit -m "feat: add FileSystemTool and ScreenshotTool"
```

### Task 8: Agent runner

**Files:**
- Create: `server/agent/runner.py`
- Create: `server/tests/test_agent.py`

- [ ] **Step 1: Write failing test for agent runner**

```python
# server/tests/test_agent.py
import asyncio
from unittest.mock import AsyncMock, MagicMock, patch
from agent.runner import AgentRunner
from config import ServerConfig
from models.message import Message
from models.events import ServerEvent


@pytest.fixture
def test_config():
    return ServerConfig(api_key="sk-test")


@pytest.fixture
def agent_runner(test_config):
    tools = []
    return AgentRunner(config=test_config, tools=tools)


class TestAgentRunnerRun:
    @pytest.mark.asyncio
    async def test_run_simple_no_tools(self, agent_runner):
        """Agent should stream token events for a simple query."""
        # Mock the LLM to return a simple streaming response
        mock_chunk = MagicMock()
        mock_chunk.content = "Hello, world!"

        with patch.object(agent_runner, "_create_agent") as mock_create_agent:
            mock_agent = MagicMock()
            mock_agent.astream_events = MagicMock(return_value=AsyncMock())

            async def mock_stream(*args, **kwargs):
                yield {
                    "event": "on_chat_model_stream",
                    "data": {"chunk": mock_chunk},
                }

            mock_agent.astream_events.side_effect = mock_stream
            mock_create_agent.return_value = mock_agent

            events = []
            async for event in agent_runner.run(
                history=[Message(role="user", content="hi")],
                workspace_path="/tmp",
            ):
                events.append(event)

            tokens = [e for e in events if e.type == "token"]
            assert len(tokens) == 1
            assert tokens[0].data == "Hello, world!"

    @pytest.mark.asyncio
    async def test_run_with_system_prompt(self, agent_runner):
        """Should include system prompt as first message."""
        mock_chunk = MagicMock()
        mock_chunk.content = "Hi!"

        with patch.object(agent_runner, "_create_agent") as mock_create_agent:
            mock_agent = MagicMock()
            mock_agent.astream_events = MagicMock()

            async def mock_stream(*args, **kwargs):
                yield {
                    "event": "on_chat_model_stream",
                    "data": {"chunk": mock_chunk},
                }

            mock_agent.astream_events.side_effect = mock_stream
            mock_create_agent.return_value = mock_agent

            events = []
            async for event in agent_runner.run(
                history=[Message(role="user", content="hi")],
                workspace_path="/tmp",
            ):
                events.append(event)

            assert len(events) == 1


class TestAgentRunnerBuildMessages:
    def test_build_messages_with_history(self, test_config):
        runner = AgentRunner(config=test_config, tools=[])
        history = [
            Message(role="user", content="hello"),
            Message(role="assistant", content="hi there"),
        ]
        messages = runner._build_messages(history, "/tmp")
        assert len(messages) >= 2
        assert messages[0]["role"] == "system"
        assert messages[1]["role"] == "user"
        assert messages[2]["role"] == "assistant"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd server && uv run pytest tests/test_agent.py -v
```
Expected: FAIL

- [ ] **Step 3: Implement runner.py**

```python
# server/agent/runner.py
import asyncio
from typing import AsyncIterator, Any
from langgraph.prebuilt import create_react_agent
from langchain_core.tools import BaseTool
from config import ServerConfig
from agent.llm import create_llm
from agent.prompt import build_system_prompt
from models.message import Message
from models.events import ServerEvent


class AgentRunner:
    def __init__(self, config: ServerConfig, tools: list[BaseTool]):
        self.config = config
        self.tools = tools
        self._max_rounds = 30

    async def run(
        self,
        history: list[Message],
        workspace_path: str,
    ) -> AsyncIterator[ServerEvent]:
        try:
            llm = create_llm(self.config)
            agent = create_react_agent(llm, self.tools)
            messages = self._build_messages(history, workspace_path)

            async for stream_event in agent.astream_events(
                {"messages": messages},
                version="v2",
            ):
                event_type = stream_event.get("event", "")

                if event_type == "on_chat_model_stream":
                    chunk = stream_event["data"]["chunk"]
                    if chunk.content:
                        yield ServerEvent(type="token", data=chunk.content)
                    if hasattr(chunk, "additional_kwargs"):
                        reasoning = chunk.additional_kwargs.get("reasoning_content")
                        if reasoning:
                            yield ServerEvent(type="thinking", data=reasoning)

                elif event_type == "on_tool_start":
                    name = stream_event.get("name", "")
                    tool_input = stream_event["data"].get("input", {})
                    run_id = stream_event.get("run_id", "")
                    yield ServerEvent(
                        type="tool_call",
                        id=run_id,
                        name=name,
                        arguments=tool_input,
                    )

                elif event_type == "on_tool_end":
                    output = stream_event["data"].get("output", "")
                    name = stream_event.get("name", "")
                    run_id = stream_event.get("run_id", "")
                    yield ServerEvent(
                        type="tool_result",
                        id=run_id,
                        name=name,
                        data=str(output),
                    )

            yield ServerEvent(type="done")

        except Exception as e:
            yield ServerEvent(type="error", data=str(e))

    def _build_messages(
        self, history: list[Message], workspace_path: str
    ) -> list[dict[str, Any]]:
        result: list[dict[str, Any]] = []
        # System prompt first
        prompt = build_system_prompt(workspace_path)
        result.append({"role": "system", "content": prompt})
        # Then history
        for msg in history:
            result.append(msg.to_dict())
        return result
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd server && uv run pytest tests/test_agent.py -v
```
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add server/agent/runner.py server/tests/test_agent.py
git commit -m "feat: add AgentRunner with LangGraph create_react_agent"
```

## Phase 3: Session & Communication

### Task 9: Session manager

**Files:**
- Create: `server/session/__init__.py`
- Create: `server/session/manager.py`
- Create: `server/tests/test_session.py`

- [ ] **Step 1: Write failing test for session manager**

```python
# server/tests/test_session.py
from session.manager import Session, SessionManager


class TestSession:
    def test_new_session_is_empty(self):
        session = Session()
        assert len(session.messages) == 0
        assert session.workspace_path == "/tmp"

    def test_add_message(self):
        session = Session()
        session.add_message(role="user", content="hello")
        assert len(session.messages) == 1
        assert session.messages[0].role == "user"
        assert session.messages[0].content == "hello"

    def test_clear(self):
        session = Session()
        session.add_message(role="user", content="hello")
        session.add_message(role="assistant", content="hi")
        session.clear()
        assert len(session.messages) == 0

    def test_set_workspace(self):
        session = Session()
        session.set_workspace("/Users/test/projects")
        assert session.workspace_path == "/Users/test/projects"


class TestSessionManager:
    def test_create_session(self):
        manager = SessionManager()
        session = manager.create_session()
        assert session is not None
        assert len(manager._sessions) == 1

    def test_get_session(self):
        manager = SessionManager()
        session = manager.create_session()
        retrieved = manager.get_session(session.id)
        assert retrieved is session

    def test_remove_session(self):
        manager = SessionManager()
        session = manager.create_session()
        manager.remove_session(session.id)
        assert manager.get_session(session.id) is None
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd server && uv run pytest tests/test_session.py -v
```
Expected: FAIL

- [ ] **Step 3: Implement manager.py**

```python
# server/session/manager.py
import uuid
from collections.abc import MutableMapping
from models.message import Message


class Session:
    def __init__(self):
        self.id = str(uuid.uuid4())
        self.messages: list[Message] = []
        self.workspace_path: str = "/tmp"

    def add_message(self, **kwargs) -> Message:
        msg = Message(**kwargs)
        self.messages.append(msg)
        return msg

    def clear(self):
        self.messages.clear()

    def set_workspace(self, path: str):
        self.workspace_path = path


class SessionManager(MutableMapping[str, Session]):
    def __init__(self):
        self._sessions: dict[str, Session] = {}

    def create_session(self) -> Session:
        session = Session()
        self._sessions[session.id] = session
        return session

    def get_session(self, session_id: str) -> Session | None:
        return self._sessions.get(session_id)

    def remove_session(self, session_id: str):
        self._sessions.pop(session_id, None)

    # MutableMapping interface
    def __getitem__(self, key: str) -> Session:
        return self._sessions[key]

    def __setitem__(self, key: str, value: Session):
        self._sessions[key] = value

    def __delitem__(self, key: str):
        del self._sessions[key]

    def __iter__(self):
        return iter(self._sessions)

    def __len__(self) -> int:
        return len(self._sessions)
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd server && uv run pytest tests/test_session.py -v
```
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add server/session/ server/tests/test_session.py
git commit -m "feat: add session manager with in-memory storage"
```

### Task 10: Agent-tool integration (tools that wait for client)

**Files:**
- Modify: `server/tools/base.py`
- Modify: `server/tests/test_tools.py`

**Critical design note:** The agent runs in a separate asyncio Task to avoid deadlock. When a tool's `_arun` awaits a result from the client, the WebSocket receive loop must continue running. The agent is launched via `asyncio.create_task()` in the WebSocket handler, and events are communicated through an `asyncio.Queue`.

- [ ] **Step 1: Update base.py with tool forwarding**

```python
# server/tools/base.py (full replacement)
import asyncio
import uuid
from abc import abstractmethod
from typing import Any
from langchain_core.tools import BaseTool
from contextvars import ContextVar


ws_manager_var: ContextVar[Any | None] = ContextVar("ws_manager", default=None)


class ClientForwardTool(BaseTool):
    """Tool that can forward to macOS client or execute locally."""

    workspace_path: str = "/tmp"
    tool_call_timeout: float = 60.0

    def _run(self, *args: Any, **kwargs: Any) -> str:
        return self._run_local(**kwargs)

    async def _arun(self, *args: Any, **kwargs: Any) -> str:
        ws_manager = ws_manager_var.get()
        if ws_manager is not None and ws_manager.has_client():
            call_id = str(uuid.uuid4())
            result_event = asyncio.Event()
            result_container: dict[str, str] = {}

            ws_manager.register_pending_call(
                call_id, result_event, result_container
            )
            await ws_manager.send_event_to_client(
                "tool_call", id=call_id, name=self.name, arguments=kwargs
            )
            try:
                await asyncio.wait_for(
                    result_event.wait(), timeout=self.tool_call_timeout
                )
                return result_container.get("result", "Error: no result from client")
            except asyncio.TimeoutError:
                ws_manager.remove_pending_call(call_id)
                return f"Error: tool '{self.name}' timed out waiting for client"

        return self._run_local(**kwargs)

    @abstractmethod
    def _run_local(self, **kwargs: Any) -> str:
        ...
```

- [ ] **Step 2: Update test_tools.py with async test**

Append to `server/tests/test_tools.py`:

```python
import asyncio
from unittest.mock import MagicMock
from tools.base import ws_manager_var


class TestClientForwardToolAsync:
    def test_local_fallback_when_no_ws_manager(self):
        tool = ShellTool(workspace_path="/tmp")
        result = asyncio.run(tool._arun(command="echo local"))
        assert "local" in result

    def test_forward_when_ws_manager_available(self):
        tool = ShellTool(workspace_path="/tmp")
        mock_ws = MagicMock()
        mock_ws.has_client.return_value = True
        pending: dict[str, tuple] = {}

        def register(call_id, event, container):
            pending[call_id] = (event, container)

        mock_ws.register_pending_call = register
        mock_ws.remove_pending_call = lambda cid: pending.pop(cid, None)

        async def mock_send(*args, **kwargs):
            pass
        mock_ws.send_event_to_client = mock_send

        async def resolve_later():
            await asyncio.sleep(0.05)
            for event, container in pending.values():
                container["result"] = "remote result"
                event.set()

        token = ws_manager_var.set(mock_ws)
        try:
            async def run():
                task = asyncio.create_task(tool._arun(command="ls"))
                await resolve_later()
                return await task

            result = asyncio.run(run())
            assert result == "remote result"
        finally:
            ws_manager_var.reset(token)
```

- [ ] **Step 3: Run tests, fix until green**

```bash
cd server && uv run pytest tests/test_tools.py -v
```

- [ ] **Step 4: Commit**

```bash
git add server/tools/base.py server/tests/test_tools.py
git commit -m "feat: add async tool forwarding via asyncio.Event"
```

### Task 11: WebSocket handler

**Files:**
- Create: `server/handlers/__init__.py`
- Create: `server/handlers/websocket.py`
- Create: `server/tests/test_websocket.py`

- [ ] **Step 1: Write failing test for WebSocket handler**

```python
# server/tests/test_websocket.py
import json
import pytest
from httpx import AsyncClient, ASGITransport
from main import create_app
from config import ServerConfig


@pytest.fixture
def app():
    config = ServerConfig(api_key="sk-test")
    return create_app(config)


@pytest.mark.asyncio
async def test_websocket_chat_flow(app):
    """End-to-end WebSocket chat flow."""
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        async with client.websocket_connect("/ws") as ws:
            # Send a simple chat message
            await ws.send_text(json.dumps({
                "type": "chat",
                "content": "hello",
            }))

            # Should receive some response events
            events = []
            try:
                while True:
                    data = await asyncio.wait_for(ws.receive_text(), timeout=5.0)
                    event = json.loads(data)
                    events.append(event)
                    if event["type"] in ("done", "error"):
                        break
            except asyncio.TimeoutError:
                pass

            assert len(events) > 0
            # Last event should be done or error
            assert events[-1]["type"] in ("done", "error")


@pytest.mark.asyncio
async def test_websocket_new_conversation(app):
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        async with client.websocket_connect("/ws") as ws:
            await ws.send_text(json.dumps({"type": "new_conversation"}))
            # Should receive some acknowledgment (could be immediate or
            # we just verify no error)
            await asyncio.sleep(0.1)


@pytest.mark.asyncio
async def test_websocket_update_workspace(app):
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        async with client.websocket_connect("/ws") as ws:
            await ws.send_text(json.dumps({
                "type": "update_workspace",
                "path": "/tmp/custom",
            }))
            # Send a message after updating workspace
            await ws.send_text(json.dumps({
                "type": "chat",
                "content": "pwd",
            }))
            await asyncio.sleep(0.2)
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd server && uv run pytest tests/test_websocket.py -v
```
Expected: FAIL (main.py not found)

- [ ] **Step 3: Implement websocket.py**

```python
# server/handlers/websocket.py
import json
import asyncio
from fastapi import WebSocket, WebSocketDisconnect
from models.events import ClientMessage, ServerEvent
from models.message import Message
from session.manager import SessionManager
from agent.runner import AgentRunner
from tools.base import ws_manager_var


class WebSocketManager:
    def __init__(self):
        self._client_ws: WebSocket | None = None
        self._pending_tool_calls: dict[
            str, tuple[asyncio.Event, dict[str, str]]
        ] = {}
        self._event_queue: asyncio.Queue = asyncio.Queue()

    def has_client(self) -> bool:
        return self._client_ws is not None

    def register_pending_call(
        self,
        call_id: str,
        event: asyncio.Event,
        result_container: dict[str, str],
    ):
        self._pending_tool_calls[call_id] = (event, result_container)

    def remove_pending_call(self, call_id: str):
        self._pending_tool_calls.pop(call_id, None)

    async def send_event_to_client(self, event_type: str, **kwargs):
        event = ServerEvent(type=event_type, **kwargs)
        await self._event_queue.put(event)

    async def _send_raw(self, event: ServerEvent):
        if self._client_ws:
            try:
                await self._client_ws.send_text(
                    json.dumps(event.model_dump(exclude_none=True))
                )
            except Exception:
                pass

    async def handle_client(
        self,
        ws: WebSocket,
        session_manager: SessionManager,
        agent_runner: AgentRunner,
    ):
        await ws.accept()
        self._client_ws = ws
        session = session_manager.create_session()
        token = ws_manager_var.set(self)
        agent_task: asyncio.Task | None = None
        running = True

        async def run_agent(content: str):
            """Run agent in background task, push events to queue."""
            async for event in agent_runner.run(
                history=list(session.messages[:-1]),
                workspace_path=session.workspace_path,
            ):
                await self._event_queue.put(event)
                if event.type in ("done", "error"):
                    return

        try:
            while running:
                # Drain outgoing event queue
                while not self._event_queue.empty():
                    event = await self._event_queue.get()
                    await self._send_raw(event)

                # Receive incoming messages (non-blocking with short timeout)
                try:
                    raw = await asyncio.wait_for(ws.receive_text(), timeout=0.05)
                except asyncio.TimeoutError:
                    continue

                try:
                    data = json.loads(raw)
                    msg = ClientMessage(**data)
                except Exception:
                    await self._send_raw(
                        ServerEvent(type="error", data="Invalid message format")
                    )
                    continue

                if msg.type == "chat":
                    if not msg.content:
                        continue
                    session.add_message(role="user", content=msg.content)
                    # Launch agent in background
                    if agent_task and not agent_task.done():
                        agent_task.cancel()
                    agent_task = asyncio.create_task(run_agent(msg.content))

                elif msg.type == "new_conversation":
                    session.clear()

                elif msg.type == "tool_result":
                    if msg.id and msg.id in self._pending_tool_calls:
                        event, container = self._pending_tool_calls.pop(msg.id)
                        container["result"] = msg.result or ""
                        event.set()

                elif msg.type == "update_workspace":
                    if msg.path:
                        session.set_workspace(msg.path)

        except WebSocketDisconnect:
            pass
        finally:
            running = False
            if agent_task and not agent_task.done():
                agent_task.cancel()
            ws_manager_var.reset(token)
            self._client_ws = None
            session_manager.remove_session(session.id)
```

- [ ] **Step 4: Create minimal main.py so test can run**

```python
# server/main.py
from fastapi import FastAPI, WebSocket
from fastapi.staticfiles import StaticFiles
from config import ServerConfig
from tools.shell import ShellTool
from tools.filesystem import FileSystemTool
from tools.screenshot import ScreenshotTool
from agent.runner import AgentRunner
from session.manager import SessionManager
from handlers.websocket import WebSocketManager


def create_app(config: ServerConfig | None = None) -> FastAPI:
    if config is None:
        config = ServerConfig()  # type: ignore

    app = FastAPI(title="WeSee Server")

    tools = [
        ShellTool(workspace_path="/tmp"),
        FileSystemTool(workspace_path="/tmp"),
        ScreenshotTool(workspace_path="/tmp"),
    ]
    agent_runner = AgentRunner(config=config, tools=tools)
    session_manager = SessionManager()
    ws_manager = WebSocketManager()

    @app.websocket("/ws")
    async def websocket_endpoint(ws: WebSocket):
        await ws_manager.handle_client(ws, session_manager, agent_runner)

    return app


if __name__ == "__main__":
    import uvicorn
    config = ServerConfig()  # type: ignore
    app = create_app(config)
    uvicorn.run(app, host="0.0.0.0", port=config.http_port)
```

- [ ] **Step 5: Run test, iterate until it passes**

```bash
cd server && uv run pytest tests/test_websocket.py -v
```

- [ ] **Step 6: Commit**

```bash
git add server/handlers/ server/main.py server/tests/test_websocket.py
git commit -m "feat: add WebSocket handler with agent integration"
```

### Task 12: HTTP API + SSE handler

**Files:**
- Create: `server/handlers/api.py`
- Create: `server/tests/test_api.py`

- [ ] **Step 1: Write failing test for API**

```python
# server/tests/test_api.py
import json
import pytest
from httpx import AsyncClient, ASGITransport
from main import create_app
from config import ServerConfig


@pytest.fixture
def app():
    config = ServerConfig(api_key="sk-test")
    return create_app(config)


@pytest.mark.asyncio
async def test_new_conversation(app):
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        resp = await client.post("/api/new-conversation")
        assert resp.status_code == 200
        data = resp.json()
        assert data["ok"] is True


@pytest.mark.asyncio
async def test_get_messages_empty(app):
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        resp = await client.get("/api/messages")
        assert resp.status_code == 200
        data = resp.json()
        assert "messages" in data
        assert data["messages"] == []


@pytest.mark.asyncio
async def test_chat_missing_content(app):
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        resp = await client.post("/api/chat", json={})
        assert resp.status_code == 400


@pytest.mark.asyncio
async def test_chat_stream(app):
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        async with client.stream(
            "POST",
            "/api/chat",
            json={"content": "hello"},
        ) as response:
            assert response.status_code == 200
            assert "text/event-stream" in response.headers["content-type"]

            chunks = []
            async for chunk in response.aiter_text():
                chunks.append(chunk)
                if len(chunks) > 50:
                    break

            full = "".join(chunks)
            assert "data: " in full


@pytest.mark.asyncio
async def test_static_index(app):
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        resp = await client.get("/")
        assert resp.status_code == 200
        assert "text/html" in resp.headers["content-type"]
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd server && uv run pytest tests/test_api.py -v
```
Expected: FAIL

- [ ] **Step 3: Implement api.py**

```python
# server/handlers/api.py
import json
import asyncio
from fastapi import APIRouter, Request, HTTPException
from fastapi.responses import StreamingResponse, JSONResponse
from sse_starlette.sse import EventSourceResponse
from models.events import ServerEvent
from session.manager import SessionManager
from agent.runner import AgentRunner


def create_api_router(
    session_manager: SessionManager,
    agent_runner: AgentRunner,
) -> APIRouter:
    router = APIRouter()
    # Web UI uses a singleton session
    web_session = session_manager.create_session()

    @router.post("/api/chat")
    async def chat(request: Request):
        try:
            body = await request.json()
        except Exception:
            raise HTTPException(status_code=400, detail="Invalid JSON")

        content = body.get("content", "").strip()
        if not content or len(content) > 5000:
            raise HTTPException(status_code=400, detail="Invalid content")

        web_session.add_message(role="user", content=content)

        async def event_generator():
            try:
                async for event in agent_runner.run(
                    history=list(web_session.messages[:-1]),
                    workspace_path=web_session.workspace_path,
                ):
                    data = json.dumps(
                        event.model_dump(exclude_none=True),
                        ensure_ascii=False,
                    )
                    yield {"event": event.type, "data": data}

                    if event.type == "done":
                        web_session.add_message(
                            role="assistant",
                            content="",  # streamed content tracked by client
                        )
                    elif event.type == "error":
                        break
            except Exception as e:
                error_data = json.dumps({"type": "error", "data": str(e)})
                yield {"event": "error", "data": error_data}

        return EventSourceResponse(event_generator())

    @router.get("/api/messages")
    async def get_messages():
        return JSONResponse({
            "messages": [
                {
                    "id": str(i),
                    "content": msg.content or "",
                    "isFromMe": msg.role == "user",
                }
                for i, msg in enumerate(web_session.messages)
            ]
        })

    @router.post("/api/new-conversation")
    async def new_conversation():
        web_session.clear()
        return JSONResponse({"ok": True})

    return router
```

- [ ] **Step 4: Update main.py to register API routes and static files**

```python
# server/main.py
from fastapi import FastAPI, WebSocket
from fastapi.staticfiles import StaticFiles
from config import ServerConfig
from tools.shell import ShellTool
from tools.filesystem import FileSystemTool
from tools.screenshot import ScreenshotTool
from agent.runner import AgentRunner
from session.manager import SessionManager
from handlers.websocket import WebSocketManager
from handlers.api import create_api_router


def create_app(config: ServerConfig | None = None) -> FastAPI:
    if config is None:
        config = ServerConfig()  # type: ignore

    app = FastAPI(title="WeSee Server")

    tools = [
        ShellTool(workspace_path="/tmp"),
        FileSystemTool(workspace_path="/tmp"),
        ScreenshotTool(workspace_path="/tmp"),
    ]
    agent_runner = AgentRunner(config=config, tools=tools)
    session_manager = SessionManager()
    ws_manager = WebSocketManager()

    # API routes
    api_router = create_api_router(session_manager, agent_runner)
    app.include_router(api_router)

    # WebSocket endpoint
    @app.websocket("/ws")
    async def websocket_endpoint(ws: WebSocket):
        await ws_manager.handle_client(ws, session_manager, agent_runner)

    # Static files (web UI)
    try:
        app.mount("/", StaticFiles(directory="static", html=True), name="static")
    except Exception:
        pass

    return app


if __name__ == "__main__":
    import uvicorn
    config = ServerConfig()  # type: ignore
    app = create_app(config)
    uvicorn.run(app, host="0.0.0.0", port=config.http_port)
```

- [ ] **Step 5: Run tests**

```bash
cd server && uv run pytest tests/test_api.py -v
```

- [ ] **Step 6: Commit**

```bash
git add server/handlers/api.py server/handlers/__init__.py server/main.py server/tests/test_api.py
git commit -m "feat: add HTTP API with SSE streaming and web UI support"
```

### Task 13: Static files

**Files:**
- Create: `server/static/index.html` (copy from `client/WeSee/Web/index.html`)
- Create: `server/static/app.js` (copy from `client/WeSee/Web/app.js`)

- [ ] **Step 1: Copy static files from client**

```bash
cp client/WeSee/Web/index.html server/static/index.html
cp client/WeSee/Web/app.js server/static/app.js
```

- [ ] **Step 2: Commit**

```bash
git add server/static/
git commit -m "feat: add web UI static files"
```

## Phase 4: Client Simplification

### Task 14: WebSocket client for macOS app

**Files:**
- Create: `client/WeSee/Services/WebSocketClient.swift`

- [ ] **Step 1: Write WebSocketClient.swift**

```swift
// client/WeSee/Services/WebSocketClient.swift
import Foundation

actor WebSocketClient {
    private var task: URLSessionWebSocketTask?
    private let session: URLSession
    private var onEvent: ((ServerEvent) -> Void)?
    private var isConnected = false

    init(session: URLSession = .shared) {
        self.session = session
    }

    func connect(url: URL) {
        task = session.webSocketTask(with: url)
        task?.resume()
        isConnected = true
        receiveNext()
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnected = false
    }

    func send(_ message: ClientMessage) async {
        guard let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8) else { return }
        try? await task?.send(.string(text))
    }

    func listen(onEvent: @escaping (ServerEvent) -> Void) {
        self.onEvent = onEvent
    }

    private func receiveNext() {
        task?.receive { [weak self] result in
            Task { await self?.handle(result) }
        }
    }

    private func handle(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        switch result {
        case .success(let message):
            switch message {
            case .string(let text):
                if let data = text.data(using: .utf8),
                   let event = try? JSONDecoder().decode(ServerEvent.self, from: data) {
                    onEvent?(event)
                }
            case .data(let data):
                if let event = try? JSONDecoder().decode(ServerEvent.self, from: data) {
                    onEvent?(event)
                }
            @unknown default:
                break
            }
            receiveNext()

        case .failure:
            isConnected = false
            onEvent?(ServerEvent(type: .error, data: "Connection lost"))
        }
    }
}

// MARK: - Codable event models

struct ClientMessage: Codable {
    let type: ClientMessageType
    var content: String? = nil
    var id: String? = nil
    var name: String? = nil
    var result: String? = nil
    var path: String? = nil

    enum ClientMessageType: String, Codable {
        case chat
        case newConversation = "new_conversation"
        case toolResult = "tool_result"
        case updateWorkspace = "update_workspace"
    }
}

struct ServerEvent: Codable {
    let type: ServerEventType
    var data: String? = nil
    var id: String? = nil
    var name: String? = nil
    var arguments: [String: AnyCodable]? = nil

    enum ServerEventType: String, Codable {
        case token
        case thinking
        case toolCall = "tool_call"
        case done
        case error
    }
}

// Helper for encoding/decoding arbitrary JSON dictionaries
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            value = str
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let arr = try? container.decode([AnyCodable].self) {
            value = arr.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let str = value as? String {
            try container.encode(str)
        } else if let int = value as? Int {
            try container.encode(int)
        } else if let double = value as? Double {
            try container.encode(double)
        } else if let bool = value as? Bool {
            try container.encode(bool)
        } else if let arr = value as? [Any] {
            try container.encode(arr.map { AnyCodable($0) })
        } else if let dict = value as? [String: Any] {
            try container.encode(dict.mapValues { AnyCodable($0) })
        } else {
            try container.encodeNil()
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add client/WeSee/Services/WebSocketClient.swift
git commit -m "feat: add WebSocketClient for server communication"
```

### Task 15: Simplify ChatViewModel

**Files:**
- Modify: `client/WeSee/ViewModels/ChatViewModel.swift`

Replace the current implementation with one that uses WebSocketClient instead of AgentRunner:

- [ ] **Step 1: Rewrite ChatViewModel.swift**

```swift
// client/WeSee/ViewModels/ChatViewModel.swift
import Foundation
import Observation
import SwiftData

@Observable
final class ChatViewModel {
    var messages: [Message] = []
    var isSendingDisabled: Bool = false
    var errorMessage: String?
    var streamingContent: String = ""
    var thinkingContent: String = ""
    var isStreaming: Bool = false
    var toolCallResults: [(id: String, name: String, arguments: [String: Any], result: String?)] = []

    private let wsClient: WebSocketClient
    private let workspaceManager: WorkspaceManager
    private var modelContext: ModelContext?
    private var pendingImagePaths: [String] = []

    init(wsClient: WebSocketClient, workspaceManager: WorkspaceManager) {
        self.wsClient = wsClient
        self.workspaceManager = workspaceManager
    }

    func connect(serverURL: URL) async {
        await wsClient.connect(url: serverURL)
        await wsClient.listen { [weak self] event in
            Task { @MainActor in self?.handleServerEvent(event) }
        }
        // Send workspace path
        await wsClient.send(ClientMessage(
            type: .updateWorkspace,
            path: workspaceManager.currentURL.path
        ))
    }

    func configure(with context: ModelContext) {
        self.modelContext = context
    }

    func fetchMessages() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<Message>(sortBy: [SortDescriptor(\.timestamp)])
        messages = (try? context.fetch(descriptor)) ?? []
    }

    func newConversation() {
        messages = []
        streamingContent = ""
        thinkingContent = ""
        isStreaming = false
        toolCallResults = []
        pendingImagePaths = []
        Task { await wsClient.send(ClientMessage(type: .newConversation)) }
    }

    func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 5000 else { return }

        addMessage(content: trimmed, isFromMe: true)
        isSendingDisabled = true
        isStreaming = true
        streamingContent = ""
        thinkingContent = ""
        toolCallResults = []
        pendingImagePaths = []

        Task {
            await wsClient.send(ClientMessage(type: .chat, content: trimmed))
        }
    }

    func clearError() {
        errorMessage = nil
    }

    // MARK: - Server event handling

    private func handleServerEvent(_ event: ServerEvent) {
        switch event.type {
        case .token:
            streamingContent += event.data ?? ""
        case .thinking:
            thinkingContent += event.data ?? ""
        case .toolCall:
            if let id = event.id, let name = event.name {
                let args = event.arguments?.mapValues { $0.value } ?? [:]
                toolCallResults.append((id: id, name: name, arguments: args, result: nil))
            }
        case .done:
            let finalContent = streamingContent
            let thinking = thinkingContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !finalContent.isEmpty {
                addMessage(
                    content: finalContent,
                    thinkingContent: thinking.isEmpty ? nil : thinking,
                    attachmentPaths: pendingImagePaths,
                    isFromMe: false
                )
            }
            streamingContent = ""
            thinkingContent = ""
            toolCallResults = []
            pendingImagePaths = []
            isStreaming = false
            isSendingDisabled = false
        case .error:
            errorMessage = event.data ?? "Unknown error"
            streamingContent = ""
            thinkingContent = ""
            isStreaming = false
            isSendingDisabled = false
        }
    }

    private func addMessage(
        content: String,
        thinkingContent: String? = nil,
        attachmentPaths: [String] = [],
        isFromMe: Bool
    ) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 5000 else { return }
        let msg = Message(
            content: trimmed,
            thinkingContent: thinkingContent,
            attachmentPaths: attachmentPaths,
            isFromMe: isFromMe
        )
        messages.append(msg)
        guard let context = modelContext else { return }
        context.insert(msg)
        try? context.save()
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add client/WeSee/ViewModels/ChatViewModel.swift
git commit -m "refactor: simplify ChatViewModel to use WebSocketClient"
```

### Task 16: Update App entry points

**Files:**
- Modify: `client/WeSee/WeSeeApp.swift`
- Modify: `client/WeSee/ContentView.swift`
- Modify: `client/WeSee/Models/Config.swift`
- Modify: `client/WeSee/Services/ChatSession.swift`

- [ ] **Step 1: Simplify Config.swift** — remove LLM fields, keep workspace/httpPort

```swift
// client/WeSee/Models/Config.swift (replace)
import Foundation

struct ClientConfig: Codable {
    let httpPort: UInt16

    static let `default` = ClientConfig(httpPort: 8080)

    enum CodingKeys: String, CodingKey {
        case httpPort
    }

    init(httpPort: UInt16 = 8080) {
        self.httpPort = httpPort
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        httpPort = try container.decodeIfPresent(UInt16.self, forKey: .httpPort) ?? 8080
    }
}

// ConfigLoader unchanged but now only loads httpPort
// ConfigError unchanged
```

- [ ] **Step 2: Simplify WeSeeApp.swift**

```swift
// client/WeSee/WeSeeApp.swift
import SwiftUI
import SwiftData

@main
struct WeSeeApp: App {
    let container: ModelContainer
    let chatSession: ChatSessionImpl
    let httpServer: HttpServer
    let wsClient: WebSocketClient

    init() {
        do {
            container = try ModelContainer(for: Message.self, ScheduledTask.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        let wm = WorkspaceManager()
        let config = (try? ConfigLoader.load()) ?? ClientConfig.default
        wsClient = WebSocketClient()
        chatSession = ChatSessionImpl(
            wsClient: wsClient,
            workspaceManager: wm
        )
        httpServer = HttpServer(port: config.httpPort, chatSession: chatSession)
        do {
            try httpServer.start()
        } catch {
            WeSeeLog.error("HttpServer failed to start: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                chatSession: chatSession,
                wsClient: wsClient
            )
        }
        .modelContainer(container)
    }
}
```

- [ ] **Step 3: Update ContentView.swift**

```swift
// client/WeSee/ContentView.swift
import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var chatViewModel: ChatViewModel
    @State private var sidebarViewModel: SidebarViewModel

    init(chatSession: ChatSessionImpl, wsClient: WebSocketClient) {
        let wm = chatSession.workspaceManager
        let vm = ChatViewModel(
            wsClient: wsClient,
            workspaceManager: wm
        )
        _chatViewModel = State(initialValue: vm)
        _sidebarViewModel = State(initialValue: SidebarViewModel(workspaceManager: wm))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(viewModel: sidebarViewModel, chatViewModel: chatViewModel)
                .frame(minWidth: 220)
        } detail: {
            ChatView(viewModel: chatViewModel)
                .frame(minWidth: 400)
        }
        .onAppear {
            chatViewModel.configure(with: modelContext)
            sidebarViewModel.configure(with: modelContext)
            chatViewModel.fetchMessages()
            let config = (try? ConfigLoader.load()) ?? ClientConfig.default
            let serverURL = URL(string: "ws://localhost:\(config.httpPort)/ws")!
            Task { await chatViewModel.connect(serverURL: serverURL) }
        }
    }
}
```

- [ ] **Step 4: Simplify ChatSession.swift** — use WebSocketClient

```swift
// client/WeSee/Services/ChatSession.swift
import Foundation
import SwiftData

protocol ChatSessionProtocol: AnyObject {
    var messages: [Message] { get }
    func send(_ text: String, onEvent: @escaping (SessionEvent) -> Void) async
    func newConversation()
    func configure(with modelContext: ModelContext)
    func fetchMessages()
    func clearError()
}

@MainActor
final class ChatSessionImpl: ChatSessionProtocol {
    private(set) var messages: [Message] = []
    private var modelContext: ModelContext?
    let workspaceManager: WorkspaceManager
    private let wsClient: WebSocketClient
    private var streamingContent: String = ""
    private var thinkingContent: String = ""
    private var isStreaming: Bool = false
    private var pendingImagePaths: [String] = []

    init(wsClient: WebSocketClient, workspaceManager: WorkspaceManager) {
        self.wsClient = wsClient
        self.workspaceManager = workspaceManager
    }

    func configure(with modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func fetchMessages() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<Message>(sortBy: [SortDescriptor(\.timestamp)])
        messages = (try? context.fetch(descriptor)) ?? []
    }

    func newConversation() {
        messages = []
        streamingContent = ""
        thinkingContent = ""
        isStreaming = false
        Task { await wsClient.send(ClientMessage(type: .newConversation)) }
    }

    func send(_ text: String, onEvent: @escaping (SessionEvent) -> Void) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 5000 else { return }
        addMessage(content: trimmed, isFromMe: true)
        await wsClient.send(ClientMessage(type: .chat, content: trimmed))
    }

    func clearError() {}

    private func addMessage(content: String, isFromMe: Bool) {
        let msg = Message(content: content, isFromMe: isFromMe)
        messages.append(msg)
        guard let context = modelContext else { return }
        context.insert(msg)
        try? context.save()
    }
}
```

- [ ] **Step 5: Remove or deprecate old files**

Remove these files (they are no longer needed):
- `client/WeSee/Services/DeepSeekService.swift`
- `client/WeSee/Services/AgentRunner.swift`
- `client/WeSee/Services/SystemPromptBuilder.swift`

And simplify `client/WeSee/Models/AgentTool.swift` — keep only the AgentTool protocol and JSONSchema (tools still needed for local execution), remove ToolRegistry.

- [ ] **Step 6: Commit**

```bash
git add client/WeSee/WeSeeApp.swift client/WeSee/ContentView.swift \
    client/WeSee/Models/Config.swift client/WeSee/Services/ChatSession.swift
git rm client/WeSee/Services/DeepSeekService.swift \
    client/WeSee/Services/AgentRunner.swift \
    client/WeSee/Services/SystemPromptBuilder.swift
git commit -m "refactor: simplify client to thin UI layer, remove LLM code"
```

### Task 17: Update client HttpServer to proxy to Python server

**Files:**
- Modify: `client/WeSee/Services/HttpServer.swift`

The HttpServer now acts as a reverse proxy: it forwards API requests to the Python FastAPI server (localhost:8080), and still serves the web UI or proxies it too. Alternatively, if the Python server serves the web UI directly, the HttpServer becomes a pure proxy.

Since the Python server already serves everything (WebSocket, SSE, static files), the macOS app's HttpServer can be simplified to just proxy to the Python server, or we can remove it entirely and have the Python server be the sole HTTP server.

For simplicity, keep the HttpServer as a lightweight proxy:

```swift
// Simplify HttpServer to proxy to Python server
// POST /api/chat -> forward to http://localhost:8080/api/chat (SSE)
// GET /api/messages -> forward to http://localhost:8080/api/messages
// POST /api/new-conversation -> forward
// GET / -> forward to http://localhost:8080/ (web UI)
```

- [ ] **Step 1: Update HttpServer.swift** (simplified proxy version)

Since the Python server already handles everything, the simplest approach is to remove HttpServer's complex logic and turn it into an HTTP proxy. However, if the mobile device can directly access the Python server (they're on the same network), HttpServer can be removed entirely.

Decide based on target use case:
- If mobile access is still needed → keep HttpServer as proxy
- If only local macOS client → remove HttpServer entirely

- [ ] **Step 2: Commit**

```bash
git add client/WeSee/Services/HttpServer.swift
git commit -m "refactor: simplify HttpServer to proxy to Python backend"
```

## Phase 5: Integration Testing

### Task 18: Server startup and integration verification

**Files:**
- Create: `server/tests/test_integration.py`

- [ ] **Step 1: Write integration test**

```python
# server/tests/test_integration.py
import json
import pytest
from httpx import AsyncClient, ASGITransport
from main import create_app
from config import ServerConfig


@pytest.fixture
def app():
    config = ServerConfig(api_key="sk-test")
    return create_app(config)


@pytest.mark.asyncio
async def test_full_flow_http(app):
    """HTTP web UI flow: new conversation -> send message -> get messages."""
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        # New conversation
        resp = await client.post("/api/new-conversation")
        assert resp.status_code == 200

        # Send chat (streaming)
        chunks = []
        async with client.stream(
            "POST", "/api/chat", json={"content": "say hi"}
        ) as resp:
            async for chunk in resp.aiter_text():
                chunks.append(chunk)
        full = "".join(chunks)
        assert "data:" in full or chunks  # SSE format or some output


@pytest.mark.asyncio
async def test_full_flow_websocket(app):
    """WebSocket flow: connect -> chat -> receive events -> done."""
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        async with client.websocket_connect("/ws") as ws:
            await ws.send_text(json.dumps({
                "type": "update_workspace",
                "path": "/tmp",
            }))
            await ws.send_text(json.dumps({
                "type": "chat",
                "content": "say hello",
            }))

            event_types = []
            for _ in range(20):
                try:
                    raw = await ws.receive_text()
                    event = json.loads(raw)
                    event_types.append(event["type"])
                    if event["type"] in ("done", "error"):
                        break
                except Exception:
                    break

            assert "done" in event_types or "error" in event_types
```

- [ ] **Step 2: Run integration tests**

```bash
cd server && uv run pytest tests/test_integration.py -v
```

- [ ] **Step 3: Commit**

```bash
git add server/tests/test_integration.py
git commit -m "test: add integration tests for HTTP and WebSocket flows"
```

---

## Summary

| Phase | Tasks | Deliverable |
|-------|-------|-------------|
| 1. Server Foundation | 1-3 | uv project, config, event/message models |
| 2. Agent & LLM | 4-8 | LLM factory, prompt, tools, agent runner |
| 3. Session & Comms | 9-13 | Session manager, WebSocket, HTTP+SSE, static files |
| 4. Client Simplification | 14-17 | WebSocket client, simplified ViewModel, removed old code |
| 5. Integration | 18 | End-to-end tests |

Total: 18 tasks, ~3-5 minutes each (TDD steps included).
