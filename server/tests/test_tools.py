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
        assert "timed out" in result.lower() or "terminated" in result.lower()


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

    def test_local_execution_handles_screencapture(self):
        tool = ScreenshotTool(workspace_path="/tmp")
        result = tool._run()
        # Either succeeds with a file path or returns error message
        assert result  # should have some output


import asyncio
from unittest.mock import MagicMock
from tools.base import ws_manager_var


class TestClientForwardToolAsync:
    def test_local_fallback_when_no_ws_manager(self):
        """When no WebSocket manager is set, should execute locally."""
        tool = ShellTool(workspace_path="/tmp")
        result = asyncio.run(tool._arun(command="echo local"))
        assert "local" in result

    def test_forward_when_ws_manager_available(self):
        """When WebSocket manager has client, should forward."""
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
