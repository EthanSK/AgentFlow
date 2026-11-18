#!/usr/bin/env python3
"""Exercise the production Sparkle signing block without a certificate or native build."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
PACKAGE = (ROOT / "scripts/package-public-release.sh").read_text()
START = PACKAGE.index('sparkle_autoupdate="$app/Contents/Frameworks/Sparkle.framework/')
END = PACKAGE.index('\nfind "$app/Contents" -depth', START)
BLOCK = PACKAGE[START:END]


class SparkleSigningTests(unittest.TestCase):
    def test_default_app_configs_match_standalone_signature(self):
        import json
        import plistlib
        project = ROOT / "VoiceInk.xcodeproj/project.pbxproj"
        data = json.loads(subprocess.check_output(
            ["plutil", "-convert", "json", "-o", "-", str(project)]))["objects"]
        app, = (obj for obj in data.values()
                if obj.get("productType") == "com.apple.product-type.application")
        configs = [data[key] for key in data[app["buildConfigurationList"]]["buildConfigurations"]]
        self.assertEqual({cfg["name"] for cfg in configs}, {"Release", "Debug"})
        for config in configs:
            with self.subTest(configuration=config["name"]):
                settings = config["buildSettings"]
                self.assertIn("LOCAL_BUILD", settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"].split())
                entitlements = plistlib.loads((ROOT / settings["CODE_SIGN_ENTITLEMENTS"]).read_bytes())
                self.assertTrue(entitlements["com.apple.security.device.audio-input"])
                self.assertNotIn("com.apple.developer.icloud-container-identifiers", entitlements)

    def test_failed_xcode_run_cannot_pass_with_green_swift_testing_summary(self):
        import shutil
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory) / "repo"
            (repo / "scripts").mkdir(parents=True)
            (repo / "VoiceInk.xcodeproj").mkdir()
            gate = repo / "scripts/test-public-release.sh"
            shutil.copy2(ROOT / "scripts/test-public-release.sh", gate)
            shutil.copy2(ROOT / "VoiceInk.xcodeproj/project.pbxproj",
                         repo / "VoiceInk.xcodeproj/project.pbxproj")
            fake = repo / "xcodebuild"
            fake.write_text("#!/bin/sh\n"
                            "i=0; while [ $i -lt 365 ]; do\n"
                            "  echo \"✔ Test fixture$i() passed after 0.01 seconds.\"\n"
                            "  i=$((i + 1))\ndone\n"
                            "echo '✔ Test run with 365 tests in 2 suites passed after 0.02 seconds.'\n"
                            "exit \"$FIXTURE_XCODE_EXIT\"\n")
            fake.chmod(0o755)
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
            subprocess.run(["git", "-C", str(repo), "-c", "user.name=Fixture",
                            "-c", "user.email=fixture@localhost", "commit", "-qm", "Fixture"], check=True)
            for xcode_exit in (0, 65):
                with self.subTest(xcode_exit=xcode_exit):
                    result = subprocess.run(
                        ["bash", str(gate), str(Path(directory) / f"out-{xcode_exit}")],
                        env={**os.environ, "PATH": str(repo) + ":" + os.environ["PATH"],
                             "FIXTURE_XCODE_EXIT": str(xcode_exit)}, capture_output=True, text=True)
                    self.assertEqual(result.returncode == 0, xcode_exit == 0, result.stderr)
                    if xcode_exit:
                        self.assertIn("Xcode failed", result.stderr)

    def test_public_checksum_manifest_works_in_another_download_folder(self):
        line = next(line for line in PACKAGE.splitlines()
                    if line.startswith('(cd "$output" && shasum'))
        with tempfile.TemporaryDirectory(prefix="release builder ") as build, \
                tempfile.TemporaryDirectory(prefix="user download ") as download:
            archive = Path(build) / "AgentFlow-v2.0.458-mac-universal.zip"
            archive.write_bytes(b"fixture archive")
            appcast = Path(build) / "appcast.xml"
            appcast.write_bytes(b"fixture signed feed")
            subprocess.run(["bash", "-ec", line], check=True,
                           env={**os.environ, "output": build, "archive": str(archive)})
            import shutil
            shutil.copy2(archive, download)
            shutil.copy2(appcast, download)
            shutil.copy2(Path(build) / "SHA256SUMS", download)
            result = subprocess.run(["shasum", "-a", "256", "-c", "SHA256SUMS"],
                                    cwd=download, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn(build, (Path(download) / "SHA256SUMS").read_text())

    def test_coverage_output_stays_outside_source_checkout(self):
        source = (ROOT / "scripts/test-public-release.sh").read_text()
        lines = [line for line in source.splitlines()
                 if line.startswith("export LLVM_PROFILE_FILE=")]
        self.assertEqual(len(lines), 1)
        with tempfile.TemporaryDirectory(prefix="agentflow release coverage ") as output:
            result = subprocess.run(
                ["bash", "-c", 'set -eu; output="$1"; ' + lines[0]
                 + '; printf "%s" "$LLVM_PROFILE_FILE"', "fixture", output],
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, str(Path(output) / "profile-%p.profraw"))

    def run_fixture(self, version, helper=True):
        with tempfile.TemporaryDirectory(prefix="agentflow-signing-test-") as directory:
            base = Path(directory)
            app = base / "AgentFlow.app"
            versions = app / "Contents/Frameworks/Sparkle.framework/Versions"
            (versions / version).mkdir(parents=True)
            (versions / "Current").symlink_to(version)
            if helper:
                (versions / version / "Autoupdate").touch()
            receipt = base / "signing-receipt"
            # Stub only the irreversible operation; execute the actual path/guard logic.
            script = ('set -eu\nidentity="Fixture identity"\n'
                      'codesign() { printf "%s\\n" "$*" >> "$receipt"; }\n' + BLOCK)
            result = subprocess.run(
                ["bash", "-c", script], capture_output=True, text=True,
                env={**os.environ, "app": str(app), "receipt": str(receipt)})
            calls = receipt.read_text() if receipt.exists() else ""
            return result, calls

    def test_version_a_is_signed_with_runtime_and_timestamp(self):
        result, calls = self.run_fixture("A")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--options runtime --timestamp", calls)
        self.assertIn("Versions/Current/Autoupdate", calls)

    def test_version_b_is_not_silently_skipped(self):
        result, calls = self.run_fixture("B")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls.splitlines()), 1)
        self.assertIn("Versions/Current/Autoupdate", calls)

    def test_missing_helper_fails_before_signing(self):
        result, calls = self.run_fixture("B", helper=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Sparkle Autoupdate helper is missing", result.stderr)
        self.assertEqual(calls, "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
