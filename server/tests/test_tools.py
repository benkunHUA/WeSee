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
