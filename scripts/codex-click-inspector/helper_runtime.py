"""Bounded result delivery and one local helper instance; no Accessibility calls."""
import fcntl
import json
import os
from pathlib import Path
import threading
import time


class HelperPreferences:
    """Preserve explicit Pause/focus choices across an automatic helper restart."""
    def __init__(self, path):
        self.path = Path(path)
        self.paused, self.focus_inputs = False, True
        try:
            if self.path.stat().st_size <= 128:
                saved = json.loads(self.path.read_text())
                if isinstance(saved, dict):
                    for name in ("paused", "focus_inputs"):
                        if type(saved.get(name)) is bool:
                            setattr(self, name, saved[name])
        except (OSError, ValueError):
            pass

    def save(self, paused, focus_inputs):
        temp = self.path.with_suffix('.tmp')
        try:
            with temp.open('w', encoding='utf-8') as f:
                os.fchmod(f.fileno(), 0o600)
                json.dump({"paused": paused, "focus_inputs": focus_inputs}, f)
            os.replace(temp, self.path)
        except OSError:
            pass


class HealthLog:
    """Sixteen tiny recovery receipts, with no application or selected text."""
    def __init__(self, path):
        self.path = Path(path)
        self.lock = threading.Lock()
        self.events = []
        try:
            if self.path.stat().st_size <= 16384:
                saved = json.loads(self.path.read_text())
                if isinstance(saved, list):
                    self.events = saved[-16:]
        except (OSError, ValueError):
            pass

    def record(self, reason, state):
        event = {"at": round(time.time(), 3), "reason": reason[:80]}
        allowed = {"worker_busy", "worker_request_ms", "worker_errors", "last_error_kind", "control_misses"}
        event.update({k: v for k, v in state.items() if k in allowed})
        with self.lock:
            self.events = (self.events + [event])[-16:]
            temp = self.path.with_suffix('.tmp')
            try:
                with temp.open('w', encoding='utf-8') as f:
                    os.fchmod(f.fileno(), 0o600)
                    json.dump(self.events, f)
                os.replace(temp, self.path)
            except OSError:
                pass  # A diagnostic write must never block normal focus recovery.


class HelperHealth:
    """Own-process liveness only. No click inactivity or AX polling is a failure.

    The worker cannot be safely replaced while a native call is stuck: it could
    later return and write focus. Restart the whole existing helper instead.
    """
    def __init__(self, now=None):
        now = time.monotonic() if now is None else now
        self.lock = threading.Lock()
        self.main_at = self.watch_at = now
        self.resume_until = now
        self.job_at = None
        self.worker_errors = self.error_streak = 0
        self.last_error = None
        self.control_token = None
        self.control_due = None
        self.control_misses = self.control_serial = 0

    def begin_job(self, now=None):
        with self.lock:
            self.job_at = time.monotonic() if now is None else now

    def end_job(self, error=None):
        with self.lock:
            self.job_at = None
            self.error_streak = self.error_streak + 1 if error else 0
            if error:
                self.worker_errors += 1
                self.last_error = error  # Exception class only, never its text.

    def acknowledge(self, token):
        with self.lock:
            if token is None or self.control_token is None or token != self.control_token:
                return False
            self.control_token = self.control_due = None
            self.control_misses = 0
            return True

    def control_received(self):
        with self.lock:
            self.control_token = self.control_due = None
            self.control_misses = 0

    def main_tick(self, now=None):
        now = time.monotonic() if now is None else now
        with self.lock:
            self.main_at = now
            action = None
            if self.control_due is not None and now >= self.control_due:
                self.control_misses += 1
                action = "reconnect" if self.control_misses == 1 else "restart"
            self.control_serial += 1
            self.control_token = f"health:{self.control_serial}"
            self.control_due = now + 4
            return action, self.control_token

    def watchdog_failure(self, worker_alive, now=None):
        now = time.monotonic() if now is None else now
        with self.lock:
            # A scheduling gap can be sleep/App Nap; do not punish the first
            # waking thread for the main loop not having resumed yet.
            if now - self.watch_at > 6:
                self.resume_until = now + 15
            self.watch_at = now
            if now < self.resume_until:
                return None
            if now - self.main_at > 15:
                return "main loop unresponsive"
            if not worker_alive:
                return "worker stopped"
            if self.job_at is not None and now - self.job_at > 6:
                return "worker request exceeded 6 seconds"
            if self.error_streak >= 3:
                return "worker repeatedly threw"
            return None

    def snapshot(self, now=None):
        now = time.monotonic() if now is None else now
        with self.lock:
            return {"worker_busy": self.job_at is not None,
                    "worker_request_ms": round(1000 * (now - self.job_at)) if self.job_at is not None else None,
                    "worker_errors": self.worker_errors, "last_error_kind": self.last_error,
                    "control_misses": self.control_misses}


class LatestResult:
    """Coalesce worker results into one main-loop wakeup, without a timer."""
    def __init__(self, wake):
        self.wake = wake
        self.lock = threading.Lock()
        self.value = None
        self.scheduled = False

    def put(self, value):
        with self.lock:
            self.value = value
            notify = not self.scheduled
            self.scheduled = True
        if notify:
            self.wake()

    def take(self):
        with self.lock:
            value, self.value = self.value, None
            self.scheduled = False
            return value


class SingleInstance:
    """Keep the lock inode, so restarting cannot create two focus writers."""
    def __init__(self, directory):
        self.directory = Path(directory)
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.path = self.directory / "instance.lock"
        self.file = None

    def acquire(self):
        self.file = self.path.open("a+")
        try:
            fcntl.flock(self.file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self.file.close()
            self.file = None
            return False
        os.fchmod(self.file.fileno(), 0o600)
        self.publish(False)
        return True

    def publish(self, ready, visible=False, accessibility=None, request=None, runtime=None):
        if self.file is None:
            return
        self.file.seek(0)
        self.file.truncate()
        state = {"pid": os.getpid(), "ready": ready, "visible": visible,
                 "accessibility": accessibility, "request": request}
        if runtime is not None:
            state["runtime"] = runtime
        json.dump(state, self.file)
        self.file.flush()

    def read(self):
        try:
            return json.loads(self.path.read_text())
        except (OSError, ValueError):
            return {}

    def wait_ready(self, timeout=2.0):
        # Only an explicit CLI command waits; the background helper never polls.
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            state = self.read()
            if state.get("ready"):
                return state
            time.sleep(0.025)
        return {}

    def wait_reply(self, request, timeout=2.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            state = self.read()
            if state.get("request") == request:
                return state
            time.sleep(0.025)
        return {}

    def close(self):
        if self.file is not None:
            self.publish(False)
            self.file.close()
            self.file = None
