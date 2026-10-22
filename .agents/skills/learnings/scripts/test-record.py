#!/usr/bin/env python3
"""Guard record.sh's insertion point in modern and historical learnings files."""

from pathlib import Path
import subprocess
import tempfile


script = Path(__file__).with_name("record.sh")
for body in (
    "# Learnings\n\n## Modern entry\nMentions (newest first) in prose.\n\n(newest first)\n",
    "# Learnings\n\n## Entries\n\n(newest first)\n",
):
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "LEARNINGS.md"
        path.write_text(body)
        subprocess.run(
            ["bash", str(script), "--repo", directory, "--symptom", "test symptom",
             "--cause", "test cause", "--fix", "test fix", "--commit", "abc123"],
            check=True, capture_output=True, text=True,
        )
        updated = path.read_text()
        assert updated.startswith("# Learnings\n\n---\n**Date:**"), updated[:120]
        assert updated.count("test symptom") == 1
        assert updated.endswith(body.removeprefix("# Learnings\n"))

print("record.sh inserts above modern and historical entries")
