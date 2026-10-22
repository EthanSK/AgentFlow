#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("installer", Path(__file__).with_name("install-context-skill.py"))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class SkillInstallTests(unittest.TestCase):
    def test_clean_home_and_repeat_share_one_skill(self):
        with tempfile.TemporaryDirectory(prefix="Agent Flow fresh user ") as folder:
            home = Path(folder)
            self.assertFalse(installer.install(home, check=True))
            self.assertFalse((home / ".agents").exists())
            installer.install(home)
            canonical = home / ".agents/skills" / installer.NAME
            self.assertEqual(installer.digest(canonical), installer.digest(installer.SOURCE))
            for client in (".codex", ".claude"):
                self.assertEqual((home / client / "skills" / installer.NAME).resolve(), canonical.resolve())
            installer.install(home)
            self.assertTrue(installer.install(home, check=True))

    def test_existing_client_skill_is_preserved_before_any_write(self):
        for client in (".codex", ".claude", ".agents"):
            with self.subTest(client=client), tempfile.TemporaryDirectory() as folder:
                home = Path(folder)
                existing = home / client / "skills" / installer.NAME
                existing.mkdir(parents=True)
                (existing / "SKILL.md").write_text("My custom skill")
                with self.assertRaises(ValueError):
                    installer.install(home)
                self.assertEqual((existing / "SKILL.md").read_text(), "My custom skill")
                if client != ".agents":
                    self.assertFalse((home / ".agents").exists())

    def test_broken_symlink_is_not_replaced(self):
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder)
            link = home / ".claude/skills" / installer.NAME
            link.parent.mkdir(parents=True)
            link.symlink_to(home / "missing")
            with self.assertRaises(ValueError):
                installer.install(home)
            self.assertTrue(link.is_symlink())
            self.assertFalse((home / ".agents").exists())


if __name__ == "__main__":
    unittest.main()
