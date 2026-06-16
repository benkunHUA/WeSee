def build_system_prompt(workspace_path: str = "/tmp") -> str:
    parts = [
        "You are a helpful assistant running inside a macOS application.",
        f"Your working directory is: {workspace_path}",
        "All relative paths are resolved against this directory.",
        "Respond in Chinese unless the user asks otherwise.",
    ]
    return "\n".join(parts)
