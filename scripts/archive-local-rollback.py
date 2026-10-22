#!/usr/bin/env python3
"""Preserve one signed rollback as a verified ZIP, never a registered .app copy.

Does not quit, move, replace or delete the source app. Guarded installers must
archive successfully before their separately authorized, idle-only replacement.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import zipfile


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def identity(app):
    if app.is_symlink() or not app.is_dir():
        raise ValueError("Source must be a real app bundle, not a symlink")
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != "com.ethansk.VoiceInkPlusPlus":
        raise ValueError("Source is not the Agent Flow fork")
    executable = info["CFBundleExecutable"]
    if not isinstance(executable, str) or Path(executable).name != executable:
        raise ValueError("Invalid executable name")
    build = str(info["CFBundleVersion"])
    if not re.fullmatch(r"[0-9]+", build):
        raise ValueError("A numeric build is required")
    stat = app.stat()
    return {"build": build, "bundle_id": info["CFBundleIdentifier"],
            "executable_sha256": digest(app / "Contents/MacOS" / executable),
            "inode": stat.st_ino, "device": stat.st_dev}


def verify_signature(app):
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)],
                   check=True, capture_output=True, timeout=60)


def validate_destination(destination):
    destination = destination.expanduser().resolve()
    # Renaming or hiding an unpacked bundle is not enough: LaunchServices reads
    # bundle contents. Never retain rollback apps or archives in app directories.
    for parent in (destination, *destination.parents):
        if parent.name == "Applications" or parent.name.endswith(".app"):
            raise ValueError("Rollback archives cannot be stored inside Applications or an app")
    return destination


def archive(source, destination):
    if source.is_symlink():
        raise ValueError("Symlink sources are not accepted")
    source = source.resolve(strict=True)
    destination = validate_destination(destination)
    if destination == source or source in destination.parents:
        raise ValueError("Archive destination cannot be inside the source")
    before = identity(source)
    verify_signature(source)
    destination.mkdir(parents=True, mode=0o700, exist_ok=True)
    target = destination / ("build-" + before["build"] + "-" +
                            before["executable_sha256"][:16] + ".zip")
    if target.exists():
        raise FileExistsError("Archive already exists; never overwrite a checkpoint: " + str(target))
    with tempfile.TemporaryDirectory(prefix=".rollback-verification-", dir=destination) as raw:
        stage = Path(raw)
        candidate = stage / "rollback.zip"
        subprocess.run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent",
                        str(source), str(candidate)], check=True, capture_output=True, timeout=300)
        with zipfile.ZipFile(candidate) as z:
            bad = z.testzip()
            if bad:
                raise ValueError("ZIP integrity failure: " + bad)
        restored_dir = stage / "restored"
        restored_dir.mkdir()
        subprocess.run(["/usr/bin/ditto", "-x", "-k", str(candidate), str(restored_dir)],
                       check=True, capture_output=True, timeout=300)
        restored = restored_dir / source.name
        after = identity(restored)
        for key in ("build", "bundle_id", "executable_sha256"):
            if after[key] != before[key]:
                raise ValueError("Archive round-trip identity mismatch: " + key)
        verify_signature(restored)
        if identity(source) != before:
            raise ValueError("Source changed while archiving")
        verify_signature(source)
        # Exclusive link is atomic and never overwrites an archive created by a
        # concurrent installer. Temporary extraction is cleaned even on failure.
        candidate.chmod(0o600)
        os.link(candidate, target)
    return {"archive": str(target), "source": str(source), **before,
            "archive_sha256": digest(target), "verified": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--directory", type=Path, default=Path.home() /
                        "Library/Application Support/AgentFlow/Release Rollbacks/Archives")
    args = parser.parse_args()
    print(json.dumps(archive(args.source, args.directory), sort_keys=True))


if __name__ == "__main__":
    main()
