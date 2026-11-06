"""Render the per-user LaunchAgent; installation remains an explicit operation."""
from pathlib import Path
import plistlib
import sys

LABEL = "com.ethansk.agentflow.codex-focus-helper"


def configuration(python, source, home):
    source, home = Path(source).resolve(), Path(home).resolve()
    logs = home / "Library/Logs/AgentFlow"
    return {
        "Label": LABEL,
        # Keep the configured stable Python symlink, not a Homebrew version that
        # may be removed at the next runtime upgrade.
        "ProgramArguments": [str(Path(python).absolute()), str(source / "inspector.py"), "--background"],
        "WorkingDirectory": str(source),
        "RunAtLoad": True,
        # A deliberate Quit stays stopped. Only abnormal exits are restarted.
        "KeepAlive": {"SuccessfulExit": False},
        "ThrottleInterval": 10,
        "LimitLoadToSessionType": "Aqua",
        "ProcessType": "Interactive",
        "StandardOutPath": str(logs / "codex-focus-helper.log"),
        "StandardErrorPath": str(logs / "codex-focus-helper.err.log"),
    }


if __name__ == "__main__":
    python = sys.argv[1] if len(sys.argv) == 2 else sys.executable
    sys.stdout.buffer.write(plistlib.dumps(configuration(python, Path(__file__).parent, Path.home())))
