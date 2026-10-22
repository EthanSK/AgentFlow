#!/usr/bin/env python3
"""Reproduce the approved bridge snapshot without exporting its private repository."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
DESTINATION = ROOT / "companions/youtube-bridge"
MANIFEST = DESTINATION / "SOURCE_SNAPSHOT.json"
COMPONENTS = {"extension": {".js", ".json", ".html", ".css", ".png"},
              "shared": {".swift"}, "menu-bar": {".swift"},
              "native-host": {".swift"}, "tests": {".mjs"}}
EXTRA = "scripts/package-extension.sh"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_files(source):
    files = {}
    for folder, extensions in COMPONENTS.items():
        base = source / folder
        if not base.is_dir() or base.is_symlink():
            raise ValueError(f"Missing or linked source folder: {folder}")
        for path in sorted(base.rglob("*")):
            if path.is_symlink():
                raise ValueError(f"Symlinks are not exported: {path.relative_to(source)}")
            if not path.is_file():
                continue
            relative = path.relative_to(source)
            if any(part.startswith(".") for part in relative.parts) or path.suffix not in extensions:
                raise ValueError(f"Unapproved source file: {relative}")
            files[relative.as_posix()] = path
    extra = source / EXTRA
    if extra.is_symlink() or not extra.is_file():
        raise ValueError(f"Missing or linked source file: {EXTRA}")
    files[EXTRA] = extra
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", type=Path, help="Approved local source checkout; never published")
    parser.add_argument("--check", action="store_true", help="Verify the public snapshot without changing files")
    args = parser.parse_args()
    if args.check:
        manifest = json.loads(MANIFEST.read_text())
        for name, expected in manifest["files"].items():
            path = DESTINATION / name
            if not path.is_file() or path.is_symlink() or digest(path) != expected:
                raise ValueError(f"Public snapshot differs: {name}")
        if args.source_dir:
            actual = {name: digest(path) for name, path in source_files(args.source_dir.resolve()).items()}
            if actual != manifest["files"]:
                raise ValueError("Approved source differs from the public snapshot")
        print(f"Verified {len(manifest['files'])} bridge source files")
        return
    if not args.source_dir:
        parser.error("--source-dir is required for an approved export")
    source = args.source_dir.resolve()
    if source == DESTINATION or DESTINATION in source.parents:
        raise ValueError("Source must be independent of the public snapshot")
    files = source_files(source)
    # Only these component files are exported. No Git history, settings, credentials,
    # logs, Rollbacks, local build scripts, or installed artifacts enter this snapshot.
    revision = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    manifest = {"schema": 1, "component": "Agent Flow video bridge",
                "sourceBaseCommit": revision,
                "sourceIncludesUncommittedChanges": bool(subprocess.check_output(
                    ["git", "-C", str(source), "status", "--porcelain"], text=True).strip()),
                "files": {name: digest(path) for name, path in files.items()}}
    for name, path in files.items():
        target = DESTINATION / name
        if target.is_symlink():
            raise ValueError(f"Refusing linked destination: {name}")
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
    MANIFEST.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(f"Exported {len(files)} approved bridge source files; private repository unchanged")


if __name__ == "__main__":
    main()
