#!/usr/bin/env python3
"""Install one shared Agent Flow skill without replacing anyone's skills/settings."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile


NAME = "interpret-agent-flow-context"
SOURCE = Path(__file__).resolve().parent.parent / ".agents" / "skills" / NAME


def files(folder):
    return sorted(p for p in folder.rglob("*") if p.is_file()
                  and "__pycache__" not in p.parts and p.suffix != ".pyc"
                  and p.name != ".agentflow-install.json")


def digest(folder):
    result = hashlib.sha256()
    for path in files(folder):
        result.update(path.relative_to(folder).as_posix().encode())
        result.update(b"\0")
        result.update(path.read_bytes())
        result.update(b"\0")
    return result.hexdigest()


def install(home, check=False):
    canonical = home / ".agents" / "skills" / NAME
    links = [home / name / "skills" / NAME for name in (".codex", ".claude")]
    source_digest = digest(SOURCE)
    if not (SOURCE / "SKILL.md").is_file():
        raise ValueError("The source checkout is missing the Agent Flow skill.")
    # Preflight the complete plan before making even a partial installation.
    if canonical.is_symlink() or (canonical.exists() and
            (not canonical.is_dir() or digest(canonical) != source_digest)):
        raise ValueError(f"Existing skill differs; nothing replaced: {canonical}")
    for link in links:
        if os.path.lexists(link) and not (link.is_symlink() and
                                        link.resolve() == canonical.resolve()):
            raise ValueError(f"Existing skill/link preserved: {link}")
    if check:
        ready = canonical.is_dir() and all(link.is_symlink() and
                    link.resolve() == canonical.resolve() for link in links)
        print("Skill ready for Codex and Claude Code." if ready else
              "Skill can be installed; run without --check to install.")
        return ready
    if not canonical.exists():
        canonical.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=".agentflow-skill-", dir=canonical.parent) as temp:
            staged = Path(temp) / NAME
            shutil.copytree(SOURCE, staged, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
            (staged / ".agentflow-install.json").write_text(json.dumps({
                "repository": "https://github.com/EthanSK/AgentFlow",
                "sourceDigest": source_digest,
            }, indent=2) + "\n")
            # rename refuses an existing non-empty destination; never merge/overwrite.
            staged.rename(canonical)
    for link in links:
        link.parent.mkdir(parents=True, exist_ok=True)
        if not os.path.lexists(link):
            link.symlink_to(canonical, target_is_directory=True)
    print(f"Installed one shared skill: {canonical}")
    print("Codex and Claude Code use links to that same folder; no app settings changed.")
    print("Start a new agent session if its skill list was already loaded.")
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Check only; do not write files")
    args = parser.parse_args()
    try:
        ready = install(Path.home(), args.check)
    except (OSError, ValueError) as error:
        parser.exit(1, f"{error}\n")
    return 0 if ready or not args.check else 2


if __name__ == "__main__":
    raise SystemExit(main())
