"""Fake Quartz checks; never creates an actual event tap."""
import unittest
from unittest.mock import Mock
from mouse_monitor import MouseMonitor


class MouseMonitorTests(unittest.TestCase):
    def setUp(self):
        self.q = Mock()
        names = ("kCGEventLeftMouseDown", "kCGEventLeftMouseUp", "kCGSessionEventTap",
                 "kCGTailAppendEventTap", "kCGEventTapOptionListenOnly", "kCFRunLoopCommonModes",
                 "kCGEventTapDisabledByTimeout", "kCGEventTapDisabledByUserInput",
                 "kCGEventRightMouseDown", "kCGEventOtherMouseDown")
        for i, name in enumerate(names):
            setattr(self.q, name, i + 1)
        self.q.CGEventTapCreate.return_value = "tap"
        self.q.CFMachPortCreateRunLoopSource.return_value = "source"
        self.q.CGEventTapIsEnabled.return_value = True
        self.on_event = Mock()
        self.monitor = MouseMonitor(self.on_event, self.q)

    def test_one_listen_only_mouse_tap_and_balanced_cleanup(self):
        self.assertTrue(self.monitor.start())
        args = self.q.CGEventTapCreate.call_args.args
        self.assertEqual(args[2], self.q.kCGEventTapOptionListenOnly)
        self.assertEqual(args[3], sum(1 << k for k in (self.q.kCGEventLeftMouseDown, self.q.kCGEventLeftMouseUp,
                                                      self.q.kCGEventRightMouseDown, self.q.kCGEventOtherMouseDown)))
        self.monitor.close(); self.monitor.close()
        self.q.CFMachPortInvalidate.assert_called_once_with("tap")
        self.q.CFRunLoopRemoveSource.assert_called_once()

    def test_disabled_listener_is_reenabled_without_input_or_focus(self):
        self.monitor.start()
        for kind in (self.q.kCGEventTapDisabledByTimeout, self.q.kCGEventTapDisabledByUserInput):
            self.assertEqual(self.monitor.callback(None, kind, "event", None), "event")
        self.assertEqual(self.monitor.disabled_count, 2)
        self.assertEqual(self.q.CGEventTapEnable.call_count, 3)
        self.assertEqual(self.on_event.call_count, 2)  # Invalidation only, never a click.

    def test_closed_listener_queued_callback_never_dispatches(self):
        self.monitor.start(); self.monitor.close()
        self.monitor.callback(None, self.q.kCGEventLeftMouseUp, "event", None)
        self.on_event.assert_not_called()

    def test_failed_creation_never_prompts_or_installs_another_listener(self):
        self.q.CGEventTapCreate.return_value = None
        self.assertFalse(self.monitor.start())
        self.assertFalse(self.monitor.enabled())
        self.q.CFRunLoopAddSource.assert_not_called()
        self.q.CGEventTapCreate.assert_called_once()


if __name__ == "__main__":
    unittest.main()
