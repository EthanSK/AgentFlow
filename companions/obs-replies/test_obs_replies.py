"""Focused reply tests; fake endpoints never contact OBS, ASR or a chat."""
import asyncio
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import obs_replies as replies
from transcribe_current import accept_completion, transcription_update, VoiceSettings


class ClockTests(unittest.TestCase):
    def setUp(self):
        self.playback = {"endedUptime": 100, "endedWall": 1000, "returncode": 0, "reason": "exit"}
        self.clock = {"uptime": 102, "wall": 1002, "media": 202, "roundTrip": 0.002}

    def test_maps_actual_end_not_later_bookkeeping(self):
        start, bound = replies.reply_start(self.playback, self.clock, 1 / 30)
        self.assertEqual(start, 200)
        self.assertLess(bound, 0.04)

    def test_rejects_clock_jump(self):
        self.clock["wall"] += 2
        with self.assertRaises(ValueError):
            replies.reply_start(self.playback, self.clock, 1 / 30)

    def test_rejects_imprecise_obs_response(self):
        self.clock["roundTrip"] = 0.3
        with self.assertRaises(ValueError):
            replies.reply_start(self.playback, self.clock, 1 / 30)

    def test_non_natural_playback_never_arms(self):
        for status, reason in [(1, "exit"), (124, "exit"), (6, "exit"), (0, "signal")]:
            with self.subTest(status=status, reason=reason), self.assertRaises(ValueError):
                replies.reply_start({**self.playback, "returncode": status, "reason": reason}, self.clock, 1 / 30)

    def test_stale_playback_rejected(self):
        self.clock.update(uptime=200, wall=1100)
        with self.assertRaises(ValueError):
            replies.reply_start(self.playback, self.clock, 1 / 30)

    def test_natural_child_exit_survives_late_recording_lease_cleanup_status(self):
        self.assertEqual(replies.completed_playback({'outcome': 'failed', 'returncode': 6,
            'cancelled': False, 'playback': self.playback}), self.playback)

    def test_parent_failure_never_overrides_interrupted_or_missing_audio(self):
        for playback in [None, {}, {**self.playback, 'returncode': -15}, {**self.playback, 'reason': 'signal'}]:
            with self.subTest(playback=playback), self.assertRaises(ValueError):
                replies.completed_playback({'outcome': 'failed', 'returncode': 6, 'playback': playback})

    def test_cancellation_and_other_parent_failures_remain_rejected(self):
        for outcome, code, cancelled in [('spoken', 0, True), ('failed', 1, False), ('suppressed', 6, False)]:
            with self.subTest(outcome=outcome), self.assertRaises(ValueError):
                replies.completed_playback({'outcome': outcome, 'returncode': code,
                    'cancelled': cancelled, 'playback': self.playback})


class SourceTests(unittest.TestCase):
    def setUp(self):
        self.samples = [(100 + n * 0.05, {"mic": 0.1, "camera": 0}) for n in range(301)]

    def test_nominal_camera_track_with_zero_audio_is_safe(self):
        replies.verify_mic_window(self.samples, 100, "mic", ["camera"])

    def test_other_track_audio_rejected(self):
        self.samples[125][1]["camera"] = 0.001
        with self.assertRaises(ValueError):
            replies.verify_mic_window(self.samples, 100, "mic", ["camera"])

    def test_missing_other_source_meter_is_unknown_not_silent(self):
        del self.samples[125][1]['camera']
        with self.assertRaisesRegex(ValueError, 'not observable'):
            replies.verify_mic_window(self.samples, 100, 'mic', ['camera'])

    def test_missing_meter_edge_rejected(self):
        with self.assertRaises(ValueError):
            replies.verify_mic_window(self.samples[12:], 100, "mic", ["camera"])

    def test_meter_gap_rejected(self):
        with self.assertRaises(ValueError):
            replies.verify_mic_window(self.samples[:20] + self.samples[40:], 100, "mic", ["camera"])

    def test_digital_zero_is_source_error(self):
        for _, levels in self.samples:
            levels["mic"] = 0
        with self.assertRaises(ValueError):
            replies.verify_mic_window(self.samples, 100, "mic", ["camera"])


class TranscriptTests(unittest.TestCase):
    def test_actual_live_provider_probe_projection(self):
        observed = json.loads(Path(__file__).with_name("fixtures").joinpath("observed-gpt-live-probe.json").read_text())["result"]
        result = accept_completion({"item_id": observed["itemID"], "transcript": observed["text"], "usage": observed["usage"]}, observed["itemID"], 15)
        self.assertEqual(result["status"], "transcribed")
        self.assertIn("final code", result["text"])
    def test_spoken_announcement_echo_does_not_wake_agent(self):
        self.assertTrue(replies.suspect_transcript("Agent Flow is ready, answer aloud after the sound.",
            "Agent Flow is ready. Answer aloud after the sound."))

    def test_short_yes_is_not_confused_with_echo(self):
        self.assertFalse(replies.suspect_transcript("Yes, do that", "Agent Flow, say yes if you want me to do that."))

    def test_obvious_asr_repetition_is_rejected(self):
        self.assertTrue(replies.suspect_transcript("thanks for watching " * 8, "Which microphone?"))
    def test_empty_acknowledged_transcript_is_not_provider_failure(self):
        result = accept_completion({"item_id": "item1", "transcript": "", "usage": {"type": "duration", "seconds": 15}}, "item1", 15)
        self.assertEqual(result["status"], "no_speech")

    def test_partial_duration_cannot_claim_complete_reply(self):
        with self.assertRaises(ValueError):
            accept_completion({"item_id": "item1", "transcript": "yes", "usage": {"type": "duration", "seconds": 2}}, "item1", 15)

    def test_wrong_committed_item_rejected(self):
        with self.assertRaises(ValueError):
            accept_completion({"item_id": "item2", "transcript": "yes", "usage": {"type": "duration", "seconds": 15}}, "item1", 15)

    def test_asr_has_no_spoken_question_or_selection_hints(self):
        config = transcription_update(VoiceSettings("gpt-live-transcribe", "en", "secret-test"))
        data = json.dumps(config)
        self.assertNotIn("secret-test", data)
        self.assertNotIn("prompt", data)
        self.assertNotIn("keywords", data)
        self.assertIsNone(config["session"]["audio"]["input"]["turn_detection"])


class RoutingTests(unittest.TestCase):
    def test_only_read_only_obs_methods_exist(self):
        self.assertTrue(all(name.startswith("Get") for name in replies.OBS.METHODS))
        with self.assertRaises(ValueError):
            asyncio.run(replies.OBS(Path("unused")).request("StopRecord"))

    def test_new_user_input_supersedes_observed_audio(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "chat.jsonl"
            path.write_text('{"type":"event_msg","payload":{"type":"agent_message"}}\n')
            cursor = path, path.stat().st_ino, path.stat().st_size
            self.assertFalse(replies.chat_has_new_user_message(cursor))
            with path.open("a") as file:
                file.write('{"type":"event_msg","payload":{"type":"user_message","message":"new typed reply"}}\n')
            self.assertTrue(replies.chat_has_new_user_message(cursor))

    def test_unknown_or_rotated_chat_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "chat.jsonl"
            path.write_text("x")
            self.assertTrue(replies.chat_has_new_user_message((path, path.stat().st_ino + 1, 0)))


if __name__ == "__main__":
    unittest.main()
