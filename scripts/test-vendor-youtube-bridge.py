#!/usr/bin/env python3
"""Keep private checkout state outside the public runtime snapshot."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("vendor", Path(__file__).with_name("vendor-youtube-bridge.py"))
vendor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vendor)


class BridgeSnapshotTests(unittest.TestCase):
    def fixture(self, root):
        for folder in vendor.COMPONENTS:
            (root / folder).mkdir()
        (root / "scripts").mkdir()
        (root / vendor.EXTRA).write_text("#!/bin/bash\n")
        (root / "extension/background.js").write_text("// public runtime\n")

    def test_only_approved_runtime_roots_are_selected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.fixture(root)
            for name in (".env", "README.md", "scripts/install.sh", "scripts/build.sh"):
                (root / name).write_text("private local data")
            (root / "Rollbacks").mkdir()
            (root / "Rollbacks/private.json").write_text("private local data")
            self.assertEqual(set(vendor.source_files(root)),
                             {vendor.EXTRA, "extension/background.js"})

    def test_links_and_unapproved_files_are_rejected(self):
        for mode in ("link", "extra"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                self.fixture(root)
                path = root / "extension/unapproved.env"
                if mode == "link":
                    path.symlink_to(root / "scripts/package-extension.sh")
                else:
                    path.write_text("private")
                with self.assertRaises(ValueError):
                    vendor.source_files(root)

    def test_checked_in_snapshot_matches_every_imported_file(self):
        import json
        manifest = json.loads(vendor.MANIFEST.read_text())
        actual = {name: vendor.digest(path) for name, path in vendor.source_files(vendor.DESTINATION).items()}
        self.assertEqual(actual, manifest["files"])
        self.assertTrue(manifest["sourceIncludesUncommittedChanges"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
