#!/usr/bin/env python3
"""Run on the Mac Mini; disposable signed fixture, never the installed app."""
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

helper = sys.modules.get("archive_local_rollback")
if helper is None:
    spec = importlib.util.spec_from_file_location("archive_local_rollback", Path(__file__).with_name("archive-local-rollback.py"))
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)


class RollbackTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="agentflow-archive-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / "AgentFlow.app"
        contents = self.app / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        self.exe = contents / "MacOS/AgentFlow"
        subprocess.run(["/usr/bin/clang", "-x", "c", "-", "-o", str(self.exe)],
                       input="int main(void) { return 0; }\n", text=True, check=True, capture_output=True)
        self.info = {"CFBundleIdentifier": "com.ethansk.VoiceInkPlusPlus",
                     "CFBundleExecutable": "AgentFlow", "CFBundleVersion": "999",
                     "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "2.0"}
        (contents / "Info.plist").write_bytes(plistlib.dumps(self.info))
        resources = contents / "Resources"
        resources.mkdir()
        (resources / "resource.txt").write_text("rollback resource\n")
        (resources / "resource-link").symlink_to("resource.txt")
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(self.app)],
                       check=True, capture_output=True)
        self.destination = self.root / "Rollback Archives"

    def test_signed_roundtrip_preserves_source_signature_resources_and_symlink(self):
        before = helper.identity(self.app)
        result = helper.archive(self.app, self.destination)
        self.assertTrue(result["verified"])
        self.assertEqual(helper.identity(self.app), before)
        archive = Path(result["archive"])
        self.assertEqual(archive.suffix, ".zip")
        self.assertEqual(archive.stat().st_mode & 0o777, 0o600)
        self.assertFalse(any(x.suffix == ".app" for x in self.destination.iterdir()))
        restored = self.root / "restored"
        subprocess.run(["/usr/bin/ditto", "-x", "-k", str(archive), str(restored)], check=True)
        app = restored / "AgentFlow.app"
        self.assertTrue((app / "Contents/Resources/resource-link").is_symlink())
        self.assertEqual((app / "Contents/Resources/resource-link").read_text(), "rollback resource\n")
        helper.verify_signature(app)

    def test_existing_checkpoint_never_overwritten(self):
        result = helper.archive(self.app, self.destination)
        before = helper.digest(Path(result["archive"]))
        with self.assertRaises(FileExistsError):
            helper.archive(self.app, self.destination)
        self.assertEqual(helper.digest(Path(result["archive"])), before)

    def test_applications_and_nested_app_destinations_rejected(self):
        for path in [Path("/Applications/AgentFlow Rollbacks"),
                     self.root / "Applications/Backups", self.app / "Backups"]:
            with self.subTest(path=path), self.assertRaises(ValueError):
                helper.archive(self.app, path)

    def test_destination_symlink_into_applications_rejected(self):
        link = self.root / "redirect"
        link.symlink_to("/Applications")
        with self.assertRaises(ValueError):
            helper.archive(self.app, link / "Backups")

    def test_source_symlink_rejected(self):
        link = self.root / "alias.app"
        link.symlink_to(self.app)
        with self.assertRaises(ValueError):
            helper.archive(link, self.destination)

    def test_official_or_unrelated_app_rejected(self):
        self.info["CFBundleIdentifier"] = "com.prakashjoshipax.VoiceInk"
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info))
        with self.assertRaises(ValueError):
            helper.archive(self.app, self.destination)

    def test_unsigned_or_modified_source_rejected(self):
        (self.app / "Contents/Resources/resource.txt").write_text("changed")
        with self.assertRaises(subprocess.CalledProcessError):
            helper.archive(self.app, self.destination)
        self.assertFalse(self.destination.exists())

    def test_invalid_executable_name_and_build_rejected(self):
        for key, value in [("CFBundleExecutable", "../outside"), ("CFBundleVersion", "unknown")]:
            info = dict(self.info)
            info[key] = value
            (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
            with self.subTest(key=key), self.assertRaises(ValueError):
                helper.identity(self.app)

    def test_failed_extraction_does_not_publish_or_leave_apps(self):
        real_run = helper.subprocess.run
        def run(args, **kwargs):
            if args[:3] == ["/usr/bin/ditto", "-x", "-k"]:
                raise subprocess.CalledProcessError(1, args)
            return real_run(args, **kwargs)
        with patch.object(helper.subprocess, "run", side_effect=run):
            with self.assertRaises(subprocess.CalledProcessError):
                helper.archive(self.app, self.destination)
        self.assertEqual(list(self.destination.iterdir()), [])
        helper.verify_signature(self.app)

    def test_concurrent_archive_cannot_be_overwritten(self):
        real_link = helper.os.link
        def race(source, target):
            Path(target).write_bytes(b"another installer")
            return real_link(source, target)
        with patch.object(helper.os, "link", side_effect=race):
            with self.assertRaises(FileExistsError):
                helper.archive(self.app, self.destination)
        self.assertEqual(next(self.destination.iterdir()).read_bytes(), b"another installer")


if __name__ == "__main__":
    unittest.main(verbosity=2)
