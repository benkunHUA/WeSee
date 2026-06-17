# server/tools/filesystem.py
import os
from typing import Any
from pydantic import BaseModel, Field
from tools.base import ClientForwardTool


class FileSystemInput(BaseModel):
    action: str = Field(description="One of: read_file, write_file, list_directory")
    path: str = Field(description="Path relative to the workspace directory")
    content: str = Field(default="", description="File content to write (required for write_file)")


class FileSystemTool(ClientForwardTool):
    name: str = "file_system"
    description: str = (
        "Read, write, and list files within the workspace directory. "
        "Use read_file to read content, write_file to create or overwrite "
        "files, and list_directory to list directory contents. "
        "All paths are relative to the workspace root."
    )
    args_schema: type[BaseModel] = FileSystemInput
    max_file_size: int = 1_000_000

    def _run_local(self, action: str = "", path: str = "", content: str = "", **kwargs: Any) -> str:
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
            return "Error: unknown action '{}'. Supported: read_file, write_file, list_directory".format(action)

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
