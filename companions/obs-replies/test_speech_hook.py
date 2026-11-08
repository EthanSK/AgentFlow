"""Exercise actual child-exit timestamps and optional-hook failure isolation."""
import json
import io
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import speech_hook
from skill_guidance import compose_skill


class SpeechHookTests(unittest.TestCase):
    def test_generated_skill_guidance_is_repeatable_and_preserves_other_text(self):
        source = "# Existing skill\n\nManual preference stays here.\n\n## Definition of done\n\nExisting acceptance.\n"
        composed = compose_skill(source, "recover-missed-speech")
        self.assertEqual(composed, compose_skill(composed, "recover-missed-speech"))
        self.assertIn("Manual preference stays here.", composed)
        self.assertIn("Existing acceptance.", composed)

    def test_manual_guidance_edit_is_preserved_by_refusal(self):
        composed = compose_skill("## Definition of done\n", "recover-missed-speech")
        changed = composed.replace("Physical speaker/Bluetooth latency remains unmeasured.", "A deliberate manual correction.")
        with self.assertRaises(ValueError):
            compose_skill(changed, "recover-missed-speech")

    def test_relative_runtime_configuration_never_creates_a_worker(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory)/'settings.json'
            config.write_text(json.dumps({'enabled': True, 'state_directory': 'relative',
                'runtime_directory': '/tmp/runtime', 'python': '/usr/bin/python3'}))
            with patch.object(speech_hook, 'SETTINGS', config), patch.object(speech_hook.subprocess, 'Popen') as spawn:
                self.assertIsNone(speech_hook.begin(['/tmp/speak-with-youtube.swift', '/tmp/sentence'],
                    {'CODEX_THREAD_ID': '01a0f279-0db9-7df3-b65b-70b67e51d721'}))
                spawn.assert_not_called()

    def test_missing_optional_settings_changes_nothing(self):
        with patch.object(speech_hook, "SETTINGS", Path("/missing/obs-reply-settings")):
            self.assertIsNone(speech_hook.begin(["/bin/true"], {}))

    def test_success_passes_original_precise_receipt_through_pipe(self):
        with tempfile.TemporaryDirectory() as directory:
            event = Path(directory)
            receipt = {"endedUptime": 123.123456, "endedWall": 567.456789, "returncode": 0, "reason": "exit"}
            (event / "playback-end.json").write_text(json.dumps(receipt))
            read_fd, write_fd = os.pipe()
            speech_hook.finish({"event": event, "write_fd": write_fd}, {"outcome": "spoken", "returncode": 0})
            with os.fdopen(read_fd) as pipe:
                self.assertEqual(json.load(pipe)["playback"], receipt)

    def test_missing_receipt_closes_worker_pipe_without_inventing_a_finish(self):
        with tempfile.TemporaryDirectory() as directory:
            read_fd, write_fd = os.pipe()
            speech_hook.finish({"event": Path(directory), "write_fd": write_fd}, {"outcome": "spoken", "returncode": 0})
            with os.fdopen(read_fd) as pipe:
                self.assertEqual(pipe.read(), "")

    def test_swift_records_actual_child_exit_before_later_bookkeeping(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt = root / "playback-end.json"
            source = root / "observation.swift"
            source.write_text('import Foundation\nimport Darwin\nlet speech = Process()\n' +
                Path(__file__).with_name("playback-observation.swift").read_text() +
                '\nspeech.executableURL = URL(fileURLWithPath: "/usr/bin/true")\n'
                'try speech.run()\nspeech.waitUntilExit()\n'
                'print(ProcessInfo.processInfo.systemUptime)\n')
            environment = {**os.environ, "AGENTFLOW_OBS_PLAYBACK_RECEIPT": str(receipt)}
            result = subprocess.run(["/usr/bin/swift", str(source)], capture_output=True, text=True, env=environment, timeout=15, check=True)
            observed = json.loads(receipt.read_text())
            self.assertEqual(observed["returncode"], 0)
            self.assertEqual(observed["reason"], "exit")
            self.assertLessEqual(observed["endedUptime"], float(result.stdout.strip()))
            self.assertLess(float(result.stdout.strip()) - observed["endedUptime"], 0.1)


if __name__ == "__main__":
    unittest.main()
