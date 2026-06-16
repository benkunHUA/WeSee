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
