"""Failure injection for own-process supervision; no apps or native input."""
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch
from helper_runtime import HelperHealth, HealthLog, HelperPreferences
from pathlib import Path
import tempfile
import json
import inspector


class HealthTests(unittest.TestCase):
    def test_restart_preserves_explicit_pause_and_focus_off(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "preferences.json"
            settings = HelperPreferences(path)
            self.assertEqual((settings.paused, settings.focus_inputs), (False, True))
            settings.save(True, False)
            settings = HelperPreferences(path)
            self.assertEqual((settings.paused, settings.focus_inputs), (True, False))
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            path.write_text('{"paused": "false", "focus_inputs": 0}')
            settings = HelperPreferences(path)
            self.assertEqual((settings.paused, settings.focus_inputs), (False, True))
    def test_recovery_receipts_remain_bounded_private_and_survive_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "health.json"
            log = HealthLog(path)
            for _ in range(40):
                log.record("worker timeout", {"worker_busy": True, "private": "not allowed"})
            saved = json.loads(path.read_text())
            self.assertEqual(len(saved), 16)
            self.assertNotIn("private", path.read_text())
            self.assertLess(path.stat().st_size, 16384)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(len(HealthLog(path).events), 16)
    def test_idle_without_clicks_is_healthy_indefinitely(self):
        h = HelperHealth(now=0)
        for now in range(0, 500, 2):
            action, token = h.main_tick(now)
            self.assertIsNone(action)
            h.acknowledge(token)
            self.assertIsNone(h.watchdog_failure(True, now))

    def test_lost_control_connection_reconnects_once_then_restarts(self):
        h = HelperHealth(now=0)
        self.assertIsNone(h.main_tick(0)[0])
        action, token = h.main_tick(5)
        self.assertEqual(action, "reconnect")
        self.assertFalse(h.acknowledge("health:1"))
        self.assertEqual(h.main_tick(10)[0], "restart")

    def test_control_reply_after_reconnect_clears_miss(self):
        h = HelperHealth(now=0)
        h.main_tick(0)
        action, token = h.main_tick(5)
        self.assertTrue(h.acknowledge(token))
        self.assertIsNone(h.main_tick(10)[0])
        self.assertEqual(h.snapshot(10)["control_misses"], 0)

    def test_fresh_command_is_liveness_but_empty_ack_is_not(self):
        h = HelperHealth(now=0)
        self.assertFalse(h.acknowledge(None))
        h.main_tick(0); h.main_tick(5)
        h.control_received()
        self.assertIsNone(h.main_tick(10)[0])

    def test_hung_worker_requires_process_restart_not_another_worker(self):
        h = HelperHealth(now=0)
        h.begin_job(0)
        for now in (0, 2, 4, 6):
            h.main_tick(now)
            self.assertIsNone(h.watchdog_failure(True, now))
        self.assertEqual(h.watchdog_failure(True, 7), "worker request exceeded 6 seconds")
        self.assertEqual(h.watchdog_failure(False, 7), "worker stopped")

    def test_main_loop_hang_and_resume_gap_are_distinguished(self):
        h = HelperHealth(now=0)
        for now in range(0, 16, 2):
            self.assertIsNone(h.watchdog_failure(True, now))
        self.assertEqual(h.watchdog_failure(True, 16), "main loop unresponsive")
        h = HelperHealth(now=0)
        self.assertIsNone(h.watchdog_failure(True, 100))  # Entire process slept.
        for now in range(102, 114, 2):
            self.assertIsNone(h.watchdog_failure(True, now))
        h.main_tick(114)
        self.assertIsNone(h.watchdog_failure(True, 116))

    def test_worker_exception_does_not_kill_worker_or_leave_busy_state(self):
        owner = SimpleNamespace(pending=Mock(), health=HelperHealth(), process_request=Mock())
        owner.pending.get.side_effect = ["bad", "next", StopIteration]
        owner.process_request.side_effect = [RuntimeError("private text must not be recorded"), None]
        with self.assertRaises(StopIteration):
            inspector.Inspector.worker(owner)
        self.assertEqual(owner.process_request.call_count, 2)
        self.assertEqual(owner.health.snapshot()["worker_errors"], 1)
        self.assertEqual(owner.health.snapshot()["last_error_kind"], "RuntimeError")
        self.assertFalse(owner.health.snapshot()["worker_busy"])

    def test_three_consecutive_worker_failures_are_not_silently_healthy(self):
        h = HelperHealth(now=0)
        for _ in range(3):
            h.begin_job(0); h.end_job("ValueError")
        self.assertEqual(h.watchdog_failure(True, 0), "worker repeatedly threw")

    def test_failed_helper_exits_nonzero_for_existing_launchd_keepalive(self):
        owner = SimpleNamespace(sequence=7, health_stop=Mock())
        with patch.object(inspector.os, "_exit") as exit_process:
            inspector.Inspector.fail_helper(owner, "worker stopped")
        self.assertEqual(owner.sequence, 8)
        owner.health_stop.set.assert_called_once()
        exit_process.assert_called_once_with(70)


if __name__ == "__main__":
    unittest.main()
