#!/usr/bin/env python3
"""Exercise screenshot setup with an isolated defaults store, never the real Mac."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("configure-screenshot-capture.sh")


class ScreenshotSetupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.store = self.root / "defaults.json"
        self.store.write_text(json.dumps({"location": "/keep/my/screenshots", "type": "jpg"}))
        self.calls = self.root / "calls"
        (self.root / "uname").write_text("#!/bin/sh\necho Darwin\n")
        (self.root / "defaults").write_text("""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
p=Path(os.environ["TEST_STORE"]); d=json.loads(p.read_text())
with open(os.environ["TEST_CALLS"],"a") as f: f.write(json.dumps(sys.argv[1:])+"\\n")
assert sys.argv[2]=="com.apple.screencapture"
key=sys.argv[3]
if sys.argv[1]=="read":
    if key not in d: sys.exit(1)
    print(d[key])
else:
    assert sys.argv[1:]==["write","com.apple.screencapture","show-thumbnail","-bool","false"]
    if os.environ.get("TEST_FAIL_WRITE"): sys.exit(1)
    d[key]=0;p.write_text(json.dumps(d))
""")
        for name in ("uname", "defaults"):
            (self.root / name).chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.root)+os.pathsep+os.environ["PATH"],
                        TEST_STORE=str(self.store), TEST_CALLS=str(self.calls))

    def tearDown(self):
        self.temp.cleanup()

    def run_setup(self, *args):
        return subprocess.run(["bash", str(SCRIPT), *args], env=self.env,
                              capture_output=True, text=True)

    def test_check_missing_is_read_only(self):
        before = self.store.read_bytes()
        self.assertEqual(self.run_setup("--check").returncode, 1)
        self.assertEqual(self.store.read_bytes(), before)

    def test_setup_preserves_other_preferences_and_is_idempotent(self):
        self.assertEqual(self.run_setup().returncode, 0)
        self.assertEqual(json.loads(self.store.read_text()),
                         {"location": "/keep/my/screenshots", "type": "jpg", "show-thumbnail": 0})
        self.assertEqual(self.run_setup().returncode, 0)
        self.assertEqual(self.run_setup("--check").returncode, 0)
        writes = [json.loads(x) for x in self.calls.read_text().splitlines()
                  if json.loads(x)[0] == "write"]
        self.assertEqual(len(writes), 1)

    def test_enabled_thumbnail_is_disabled(self):
        self.store.write_text('{"show-thumbnail": 1}')
        self.assertEqual(self.run_setup().returncode, 0)
        self.assertEqual(json.loads(self.store.read_text())["show-thumbnail"], 0)

    def test_failed_write_is_not_success(self):
        self.env["TEST_FAIL_WRITE"] = "1"
        self.assertNotEqual(self.run_setup().returncode, 0)
        self.assertNotIn("show-thumbnail", json.loads(self.store.read_text()))

    def test_first_use_check_does_not_change_settings_or_create_home(self):
        self.env["HOME"] = str(self.root / "empty-home")
        before = self.store.read_bytes()
        result = subprocess.run(["bash", str(SCRIPT.with_name("install-first-use.sh")), "--check"],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Screenshot immediate saving: not configured", result.stdout)
        self.assertEqual(self.store.read_bytes(), before)
        self.assertFalse(Path(self.env["HOME"]).exists())

    def test_non_macos_is_refused_without_writes(self):
        (self.root / "uname").write_text("#!/bin/sh\necho Linux\n")
        self.assertEqual(self.run_setup().returncode, 1)
        self.assertFalse(self.calls.exists())

    def test_bad_arguments_do_not_touch_defaults(self):
        self.assertEqual(self.run_setup("--wrong").returncode, 2)
        self.assertEqual(self.run_setup("--check", "extra").returncode, 2)
        self.assertFalse(self.calls.exists())


if __name__ == "__main__":
    unittest.main()
