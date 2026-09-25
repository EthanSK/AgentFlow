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
