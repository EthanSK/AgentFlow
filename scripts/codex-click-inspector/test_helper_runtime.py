"""No live AX reads: pure queues/locks and the inspector's own lifecycle only."""
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
from types import SimpleNamespace

from helper_runtime import LatestResult, SingleInstance
from launch_agent import configuration
import inspector


class ResultTests(unittest.TestCase):
    def test_no_idle_wakeup(self):
        wake = Mock()
        results = LatestResult(wake)
        self.assertIsNone(results.take())
        wake.assert_not_called()

    def test_completed_results_coalesce_without_growth(self):
        wake = Mock()
        results = LatestResult(wake)
        for number in range(10000):
            results.put(number)
        wake.assert_called_once_with()
        self.assertEqual(results.take(), 9999)
        self.assertIsNone(results.take())
        results.put("next")
        self.assertEqual(wake.call_count, 2)
        self.assertEqual(results.take(), "next")


class InstanceTests(unittest.TestCase):
    def test_second_instance_cannot_become_another_writer(self):
        with tempfile.TemporaryDirectory() as directory:
            first, second = SingleInstance(directory), SingleInstance(directory)
            self.assertTrue(first.acquire())
            self.assertFalse(second.acquire())
            first.publish(True, False)
            self.assertEqual(second.wait_ready(), {"pid": os.getpid(), "ready": True, "visible": False,
                                                   "accessibility": None, "request": None})
            first.close()
            self.assertTrue(second.acquire())
            second.close()

    def test_lock_inode_survives_close(self):
        with tempfile.TemporaryDirectory() as directory:
            instance = SingleInstance(directory)
            instance.acquire()
            inode = instance.path.stat().st_ino
            instance.close()
            self.assertEqual(instance.path.stat().st_ino, inode)
            self.assertFalse(instance.read()["ready"])

    def test_incomplete_start_has_bounded_command_wait(self):
        with tempfile.TemporaryDirectory() as directory:
            instance = SingleInstance(directory)
            self.assertEqual(instance.wait_ready(timeout=0), {})

    def test_demo_and_live_have_independent_locks(self):
        with tempfile.TemporaryDirectory() as directory:
            live, demo = SingleInstance(Path(directory) / "live"), SingleInstance(Path(directory) / "demo")
            self.assertTrue(live.acquire())
            self.assertTrue(demo.acquire())
            live.close()
            demo.close()

    def test_command_reply_has_fresh_service_permission_not_sender_permission(self):
        with tempfile.TemporaryDirectory() as directory:
            instance = SingleInstance(directory)
            instance.acquire()
            instance.publish(True, False, False, "old")
            self.assertEqual(instance.wait_reply("new", timeout=0), {})
            instance.publish(True, False, True, "new")
            self.assertTrue(instance.wait_reply("new")["accessibility"])
            instance.close()


class LifecycleTests(unittest.TestCase):
    def test_only_explicit_command_requests_service_permission(self):
        owner = inspector.Inspector.alloc().init()
        owner.window, owner.reader = None, Mock()
        notification = Mock()
        with patch.object(inspector, "INSTANCE", Mock()):
            notification.userInfo.return_value = {"command": "status", "request": "a"}
            owner.control_(notification)
            owner.reader.request_accessibility.assert_not_called()
            notification.userInfo.return_value = {"command": "request-accessibility", "request": "b"}
            owner.control_(notification)
            owner.reader.request_accessibility.assert_called_once_with()

    def test_close_only_hides_window_and_leaves_worker_running(self):
        owner = inspector.Inspector.alloc().init()
        owner.window, owner.reader = Mock(), None
        owner.window.isVisible.return_value = False
        with patch.object(inspector, "INSTANCE", Mock()) as instance:
            self.assertFalse(owner.windowShouldClose_(owner.window))
            owner.window.orderOut_.assert_called_once_with(None)
            instance.publish.assert_called_once_with(True, False, None, None, runtime=None)

    def test_reconnect_replaces_monitors_and_keeps_claude_disabled(self):
        owner = inspector.Inspector.alloc().init()
        owner.sequence, owner.event_source_revision = 4, 1
        owner.reader, owner.claude_focuser = Mock(), None
        old, first, second, center = Mock(), Mock(), Mock(), Mock()
        owner.monitor, owner.down_monitor = old, None
        with patch.object(inspector, "MouseMonitor", side_effect=[first, second]), \
                patch.object(inspector, "NSDistributedNotificationCenter", Mock(defaultCenter=Mock(return_value=center))), \
                patch.object(inspector, "OPTIONS", SimpleNamespace(demo=False)):
            owner.reconnect_event_sources("wake")
            owner.reconnect_event_sources("session active")
        self.assertEqual(owner.sequence, 6)
        self.assertEqual(owner.event_source_revision, 3)
        self.assertEqual(owner.last_reconnect_reason, "session active")
        self.assertIs(owner.monitor, second)
        self.assertIsNone(owner.down_monitor)
        old.close.assert_called_once()
        first.close.assert_called_once()
        second.close.assert_not_called()
        names = [c.args[1] for c in center.addObserver_selector_name_object_suspensionBehavior_.call_args_list]
        self.assertEqual(names, ["control:"] * 2)
        owner.reader.create_app.assert_not_called()

    def test_workspace_wake_session_and_codex_launch_reconnect_only_own_sources(self):
        owner = inspector.Inspector.alloc().init()
        with patch.object(inspector.Inspector, "reconnect_event_sources") as reconnect, \
                patch.object(inspector.Inspector, "publish_state") as publish:
            for name in (inspector.K.NSWorkspaceDidWakeNotification,
                         inspector.K.NSWorkspaceSessionDidBecomeActiveNotification):
                note = Mock(); note.name.return_value = name
                owner.workspaceChanged_(note)
            self.assertEqual([c.args[0] for c in reconnect.call_args_list], ["wake", "session active"])
            note = Mock(); note.name.return_value = inspector.K.NSWorkspaceDidLaunchApplicationNotification
            app = Mock(); note.userInfo.return_value = {inspector.K.NSWorkspaceApplicationKey: app}
            app.bundleURL.return_value.path.return_value = "/Applications/Other.app"
            owner.workspaceChanged_(note)
            self.assertEqual(reconnect.call_count, 2)
            app.bundleURL.return_value.path.return_value = "/Applications/ChatGPT.app"
            owner.workspaceChanged_(note)
            reconnect.assert_called_with("Codex launched")
            self.assertEqual(publish.call_count, 3)

    def test_runtime_status_is_live_and_contains_no_pane_contents(self):
        owner = inspector.Inspector.alloc().init()
        owner.window, owner.reader, owner.thread = None, Mock(), Mock()
        owner.reader.trusted.return_value = True
        owner.thread.is_alive.return_value = True
        owner.monitor, owner.event_source_revision = Mock(), 7
        owner.monitor.enabled.return_value = True
        owner.last_reconnect_reason = "wake"
        owner.paused, owner.focus_inputs, owner.events_seen, owner.codex_clicks = False, True, 12, 4
        with patch.object(inspector, "INSTANCE", Mock()) as instance:
            owner.publish_state("test")
        runtime = instance.publish.call_args.kwargs["runtime"]
        self.assertEqual(runtime, {"event_source_revision": 7, "last_reconnect_reason": "wake",
                                  "monitor_active": True, "worker_alive": True, "paused": False,
                                  "focus_inputs": True, "events_seen": 12, "codex_clicks": 4})

    def test_release_spanning_reconnect_never_becomes_a_plain_click(self):
        owner = inspector.Inspector.alloc().init()
        owner.paused, owner.events_seen, owner.sequence = False, 3, 9
        owner.mouse_down_point, owner.pending = None, Mock()
        with patch.object(inspector.K, "NSWorkspace") as workspace:
            owner.clicked(Mock())
        workspace.sharedWorkspace.assert_not_called()
        owner.pending.put_nowait.assert_not_called()
        self.assertEqual((owner.events_seen, owner.sequence), (4, 10))

    def test_startup_registers_event_driven_recovery_without_starting_claude(self):
        owner = inspector.Inspector.alloc().init()
        workspace_center = Mock()
        with patch.object(inspector, "OPTIONS", SimpleNamespace(demo=False, background=True, show_inspector=False)), \
                patch.object(inspector, "AXReader"), patch.object(inspector, "PaneInputFocuser"), \
                patch.object(inspector, "CLAUDE_FOCUS_ENABLED", False), \
                patch.object(inspector, "LatestResult"), patch.object(inspector.threading, "Thread"), \
                patch.object(inspector, "HealthLog"), \
                patch.object(inspector, "HelperPreferences", return_value=SimpleNamespace(paused=False, focus_inputs=True)), \
                patch.object(inspector, "INSTANCE", SimpleNamespace(directory=Path("/no-real-directory"))), \
                patch.object(inspector.Inspector, "reconnect_event_sources") as reconnect, \
                patch.object(inspector.Inspector, "publish_state"), \
                patch.object(inspector.K, "NSEvent"), \
                patch.object(inspector, "NSTimer"), patch.object(inspector, "NSRunLoop"), \
                patch.object(inspector, "NSProcessInfo"), \
                patch.object(inspector.K, "NSWorkspace") as workspace:
            workspace.sharedWorkspace.return_value.notificationCenter.return_value = workspace_center
            owner.applicationDidFinishLaunching_(None)
        reconnect.assert_called_once_with("startup")
        self.assertIsNone(owner.claude_focuser)
        self.assertEqual([c.args[2] for c in workspace_center.addObserver_selector_name_object_.call_args_list],
                         [inspector.K.NSWorkspaceDidWakeNotification,
                          inspector.K.NSWorkspaceSessionDidBecomeActiveNotification,
                          inspector.K.NSWorkspaceDidLaunchApplicationNotification])

    def test_hidden_results_update_state_without_rendering(self):
        owner = inspector.Inspector.alloc().init()
        owner.window, owner.sequence, owner.paused = None, 4, False
        owner.model, owner.diagnostics = Mock(), Mock()
        owner.completed = LatestResult(Mock())
        result = object()
        owner.completed.put((4, result))
        owner.refresh_(None)
        self.assertIs(owner.last, result)
        owner.diagnostics.append.assert_called_once_with(result, owner.model)

    def test_stale_completion_cannot_overwrite_newer_click(self):
        owner = inspector.Inspector.alloc().init()
        owner.window, owner.sequence, owner.paused, owner.last = None, 5, False, None
        owner.model, owner.diagnostics = Mock(), Mock()
        owner.completed = LatestResult(Mock())
        owner.completed.put((4, object()))
        owner.refresh_(None)
        self.assertIsNone(owner.last)
        owner.diagnostics.append.assert_not_called()

    def test_no_repeating_ui_timer_or_unbounded_result_queue(self):
        source = Path(inspector.__file__).read_text()
        self.assertNotIn('"refresh:", None, True', source)
        self.assertIn('"refresh:", None, False', source)
        self.assertIn("self.pending.get()", source)
        self.assertNotIn("self.completed = queue.Queue", source)

    def test_stale_monitor_callback_cannot_dispatch_after_reconnect(self):
        owner = inspector.Inspector.alloc().init()
        owner.event_source_revision = 3
        with patch.object(inspector.K, "NSEvent") as events:
            owner.mouse_event(2, inspector.Q.kCGEventLeftMouseUp, Mock())
        events.eventWithCGEvent_.assert_not_called()

    def test_interrupted_or_nonleft_gesture_only_cancels_existing_work(self):
        owner = inspector.Inspector.alloc().init()
        owner.sequence, owner.event_source_revision, owner.mouse_down_point = 4, 2, object()
        with patch.object(inspector.K, "NSEvent") as events:
            for kind in (inspector.Q.kCGEventRightMouseDown, inspector.Q.kCGEventOtherMouseDown,
                         inspector.Q.kCGEventTapDisabledByTimeout, inspector.Q.kCGEventTapDisabledByUserInput):
                owner.mouse_event(2, kind, None)
        self.assertEqual(owner.sequence, 8)
        self.assertIsNone(owner.mouse_down_point)
        events.eventWithCGEvent_.assert_not_called()

    def test_disabled_monitor_is_enabled_without_spawning_a_worker(self):
        owner = inspector.Inspector.alloc().init()
        owner.sequence, owner.mouse_down_point = 4, object()
        owner.health = Mock(); owner.health.main_tick.return_value = (None, "health:1")
        owner.callback_error_streak, owner.monitor = 0, Mock()
        owner.monitor.tap = object()
        owner.monitor.enabled.side_effect = [False, True]
        with patch.object(inspector, "NSDistributedNotificationCenter", Mock()), \
                patch.object(inspector, "OPTIONS", SimpleNamespace(demo=False)), \
                patch.object(inspector.threading, "Thread") as thread:
            owner.healthTick_(None)
        thread.assert_not_called()
        owner.monitor.enable.assert_called_once()
        self.assertEqual(owner.sequence, 5)
        self.assertIsNone(owner.mouse_down_point)

    def test_missing_monitor_obeys_retry_backoff(self):
        owner = inspector.Inspector.alloc().init()
        owner.health = Mock(); owner.health.main_tick.return_value = (None, "health:1")
        owner.callback_error_streak, owner.monitor, owner.monitor_retry_at = 0, Mock(), 30
        owner.monitor.tap = None
        with patch.object(inspector, "NSDistributedNotificationCenter", Mock()), \
                patch.object(inspector, "OPTIONS", SimpleNamespace(demo=False)), \
                patch.object(inspector.time, "monotonic", return_value=20), \
                patch.object(inspector.Inspector, "reconnect_event_sources") as reconnect:
            owner.healthTick_(None)
            reconnect.assert_not_called()
        with patch.object(inspector, "NSDistributedNotificationCenter", Mock()), \
                patch.object(inspector, "OPTIONS", SimpleNamespace(demo=False)), \
                patch.object(inspector.time, "monotonic", return_value=31), \
                patch.object(inspector.Inspector, "reconnect_event_sources") as reconnect:
            owner.healthTick_(None)
            reconnect.assert_called_once_with("mouse listener unavailable")

    def test_launch_agent_is_hidden_and_only_restarts_failures(self):
        config = configuration("/usr/bin/python3", "/tmp/helper", "/tmp/home")
        self.assertEqual(config["ProgramArguments"][-1], "--background")
        self.assertNotIn("--show-inspector", config["ProgramArguments"])
        self.assertTrue(config["RunAtLoad"])
        self.assertEqual(config["KeepAlive"], {"SuccessfulExit": False})

    def test_launch_agent_keeps_the_configured_runtime_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "versioned-python"
            target.touch()
            stable = Path(directory) / "python3"
            stable.symlink_to(target)
            self.assertEqual(configuration(stable, directory, directory)["ProgramArguments"][0], str(stable))


if __name__ == "__main__":
    unittest.main()
