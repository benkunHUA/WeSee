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
