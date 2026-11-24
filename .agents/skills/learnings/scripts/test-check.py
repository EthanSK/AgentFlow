"""Offline regression coverage for both documented learnings layouts."""
import pathlib
import subprocess
import tempfile
import unittest


class CheckTests(unittest.TestCase):
    def run_search(self, learnings, failed, keyword):
        with tempfile.TemporaryDirectory(prefix="agentflow-learnings-test-") as folder:
            root = pathlib.Path(folder)
            (root / "LEARNINGS.md").write_text(learnings)
            (root / "FAILED_APPROACHES.md").write_text(failed)
            return subprocess.run(
                ["bash", str(pathlib.Path(__file__).with_name("check.sh")), keyword, folder],
                check=True, capture_output=True, text=True,
            ).stdout

    def test_modern_and_legacy_blocks_are_both_searchable(self):
        result = self.run_search(
            "# Learnings\n\n## New evidence\nMentions (newest first) inline.\nRAINBOW [a] lesson.\n\n"
            "## Unrelated\nDo not include this.\n\n(newest first)\n\n"
            "---\nOld rainbow [a] lesson.\n---\n\n---\nOther old lesson.\n---\n",
            "Rejected rainbow [a] mechanism.\n", "rainbow [a]",
        )
        self.assertIn("RAINBOW [a] lesson.", result)
        self.assertIn("Old rainbow [a] lesson.", result)
        self.assertIn("Rejected rainbow [a] mechanism.", result)
        self.assertNotIn("Do not include this.", result)
        self.assertNotIn("Other old lesson.", result)
        self.assertIn("Found 2 matching LEARNINGS.md entries and 1", result)

    def test_modern_only_file_flushes_last_entry(self):
        result = self.run_search("# Learnings\n## Last entry\nRainbow\n", "", "rainbow")
        self.assertIn("Found 1 matching LEARNINGS.md entries", result)

    def test_missing_match_is_not_an_error(self):
        result = self.run_search("## Entry\nA plain fact.\n", "", "[a]")
        self.assertIn('no matching prior learnings for "[a]"', result)

    def test_recorded_entry_before_modern_headings_is_searchable(self):
        with tempfile.TemporaryDirectory(prefix="agentflow-learnings-test-") as folder:
            root = pathlib.Path(folder)
            (root / "LEARNINGS.md").write_text(
                "# Learnings\n\n## Previous decision\nKeep this old fact.\n\n"
                "(newest first)\n\n---\nAnother historical entry.\n---\n"
            )
            scripts = pathlib.Path(__file__).parent
            subprocess.run([
                "bash", str(scripts / "record.sh"), "--repo", folder,
                "--symptom", "A unique [one-line] recorder decision.",
                "--cause", "New verified evidence.", "--fix", "Keep the whole version visible.",
                "--commit", "fixture",
            ], check=True, capture_output=True, text=True)
            result = subprocess.run([
                "bash", str(scripts / "check.sh"), "[one-line]", folder,
            ], check=True, capture_output=True, text=True).stdout
            self.assertIn("New verified evidence.", result)
            self.assertIn("Found 1 matching LEARNINGS.md entries", result)
            self.assertNotIn("Keep this old fact.", result)
            self.assertNotIn("Another historical entry.", result)


if __name__ == "__main__":
    unittest.main()
