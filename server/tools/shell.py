# server/tools/shell.py
import subprocess
from typing import Any
from pydantic import BaseModel, Field
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


class ShellInput(BaseModel):
    command: str = Field(description="The shell command to execute")


class ShellTool(ClientForwardTool):
    name: str = "shell"
    description: str = (
        "Execute a safe shell command. Only supported commands are allowed. "
        "No pipes, redirects, or command substitution. Commands have a "
        "30-second timeout."
    )
    args_schema: type[BaseModel] = ShellInput
    timeout_seconds: int = 30

    def _run_local(self, command: str = "", **kwargs: Any) -> str:
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
                    "HOME": __import__("os").environ.get("HOME", "/tmp"),
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
