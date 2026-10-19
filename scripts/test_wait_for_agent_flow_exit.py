"""Mini-only tests: disposable sleep children, never the user's running app."""
import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("exit_waiter", Path(__file__).with_name("wait-for-agent-flow-exit.py"))
waiter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(waiter)


class ExitWaiterTests(unittest.TestCase):
    def test_kernel_exit_event_wakes_once(self):
        with subprocess.Popen(["/bin/sleep", "0.15"]) as child:
            waiter.wait_for_exit(child.pid, 2)
            self.assertEqual(child.wait(timeout=1), 0)

    def test_timeout_does_not_terminate_child(self):
        with subprocess.Popen(["/bin/sleep", "0.2"]) as child:
            with self.assertRaises(TimeoutError):
                waiter.wait_for_exit(child.pid, 0.01)
            self.assertIsNone(child.poll())
            self.assertEqual(child.wait(timeout=1), 0)

    def test_already_exited_child_does_not_wait(self):
        child = subprocess.Popen(["/bin/sleep", "0"])
        child.wait(timeout=1)
        waiter.wait_for_exit(child.pid, 1)

    def test_invalid_values_fail_before_kernel_access(self):
        for pid, timeout in [(0, 1), (1, 1), (2, 0), (2, float("inf")), (2, 86401)]:
            with self.assertRaises(ValueError):
                waiter.wait_for_exit(pid, timeout)

    def test_identity_check_rejects_other_executables(self):
        with patch("sys.argv", ["waiter", "42"]), patch.object(waiter, "executable_path", return_value="/bin/sleep"):
            with patch.object(waiter, "wait_for_exit") as kernel_wait:
                with self.assertRaises(ValueError):
                    waiter.main()
                kernel_wait.assert_not_called()

    def test_identity_check_accepts_already_exited_pid(self):
        with patch("sys.argv", ["waiter", "42"]), patch.object(waiter, "executable_path", return_value=None):
            with patch.object(waiter, "wait_for_exit") as kernel_wait:
                waiter.main()
                kernel_wait.assert_not_called()


if __name__ == "__main__":
    unittest.main()
