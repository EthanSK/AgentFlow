#!/usr/bin/env python3
"""Click-triggered Codex helper with an optional inspector. No clicks, keys or text reads; the only writes
are the optional, on-by-default pane-input focus Ethan requested (see pane_focuser.py) and the
Claude Prompt focus after a plain click in a Claude chat pane, plus the dormant one for when Agent Flow stops recording (see claude_prompt_focuser.py).

This tool is for Ethan to inspect locally, NOT an automation workaround for a
Computer Use refusal. Agents must not read its live Codex results or use it to
resolve/activate a target. Validate it against fixtures, not Ethan's live chats.
"""
import ctypes as C
import argparse
import queue
import math
import json
import os
import threading
import time
from dataclasses import replace
from pathlib import Path

import AppKit as K
import Quartz as Q
import objc
from Foundation import NSObject, NSTimer, NSRunLoop, NSRunLoopCommonModes, NSBundle, NSDictionary, NSProcessInfo, NSDistributedNotificationCenter, NSNotificationSuspensionBehaviorDeliverImmediately
from pane_model import (Node, PaneModel, Rect, Sample, Observation, Diagnostics, describe, MAX_ANCESTORS, MAIN_CONTENT_CLASS,
                        ClickGesture, input_focus_plan, input_pane_after_click, is_highlight_gesture, needs_hit_retest, KEPT_HIGHLIGHT_ACTION, HIT_RETEST_ATTEMPTS, HIT_RETEST_INTERVAL_SECONDS)
from pane_focuser import PaneInputFocuser
from claude_prompt_focuser import ClaudePromptFocuser, CLAUDE_BUNDLE_ID, RECORDING_STOPPED, ENABLED as CLAUDE_FOCUS_ENABLED
from helper_runtime import (LatestResult, SingleInstance, HelperHealth, HealthLog, HelperPreferences)
from mouse_monitor import MouseMonitor

OPTIONS = None
HIGHLIGHT_FOCUS_DELAY_SECONDS = 0.3  # Preserve the existing opportunity for Agent Flow to read a highlight before focus moves.
IDLE_HIGHLIGHT_FOCUS_DELAY_SECONDS = 3.0  # Ethan (2026-11-11): "delay the input focus a bit" while Agent Flow is idle, so a highlight made just before pressing start is still there for it to read.
IDLE_WAIT_SLICE_SECONDS = 0.025  # Short slices, so a newer click never queues behind the idle wait.
INSTANCE = None
CONTROL_NAME = "com.ethansk.agentflow.codex-focus-helper.control"
AGENT_FLOW_BUNDLE_ID = "com.ethansk.VoiceInkPlusPlus"
TYPING_BOX_RETURN_ON = "com.ethansk.voiceink.typingBoxKeyboardReturnOn"  # Must match Agent Flow's RecorderTypingFocus.
TYPING_BOX_RETURN_OFF = "com.ethansk.voiceink.typingBoxKeyboardReturnOff"  # Must match Agent Flow's RecorderTypingFocus.
RECORDING_STARTED = "com.ethansk.voiceink.recordingStarted"  # Must match Agent Flow's RecordingActivityNotifier.
RECORDING_STOPPED_PRESERVING_PLAYBACK = "com.ethansk.voiceink.recordingStoppedPreservingPlayback"  # Must match Agent Flow's RecordingActivityNotifier.


def control_object(demo=False):
    return f"{os.getuid()}:{'demo' if demo else 'live'}"


def agent_flow_is_running():
    return len(K.NSRunningApplication.runningApplicationsWithBundleIdentifier_(AGENT_FLOW_BUNDLE_ID)) > 0


def is_close_shortcut(key_code, modifiers, inspector_is_key):
    """Only the inspector's own Command-W; never a global shortcut."""
    relevant = (K.NSEventModifierFlagCommand | K.NSEventModifierFlagShift
                | K.NSEventModifierFlagControl | K.NSEventModifierFlagOption)
    return inspector_is_key and key_code == 13 and modifiers & relevant == K.NSEventModifierFlagCommand


class Point(C.Structure):
    _fields_ = [("x", C.c_double), ("y", C.c_double)]


class Size(C.Structure):
    _fields_ = [("width", C.c_double), ("height", C.c_double)]


class AXReader:
    """Public, bounded hit-test and ancestor-only reads on a worker thread."""
    def __init__(self):
        self.cf = C.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        self.ax = C.CDLL("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices")
        ptr = C.c_void_p
        def bind(lib, name, result, *args):
            fn = getattr(lib, name)
            fn.restype, fn.argtypes = result, list(args)
            return fn
        self.release = bind(self.cf, "CFRelease", None, ptr)
        self.retain = bind(self.cf, "CFRetain", ptr, ptr)
        self.hash = bind(self.cf, "CFHash", C.c_ulong, ptr)
        self.equal = bind(self.cf, "CFEqual", C.c_bool, ptr, ptr)
        self.type_id = bind(self.cf, "CFGetTypeID", C.c_ulong, ptr)
        self.string_type = bind(self.cf, "CFStringGetTypeID", C.c_ulong)
        self.array_type = bind(self.cf, "CFArrayGetTypeID", C.c_ulong)
        self.array_count = bind(self.cf, "CFArrayGetCount", C.c_long, ptr)
        self.array_item = bind(self.cf, "CFArrayGetValueAtIndex", ptr, ptr, C.c_long)
        self.bool_type = bind(self.cf, "CFBooleanGetTypeID", C.c_ulong)
        self.bool_value = bind(self.cf, "CFBooleanGetValue", C.c_bool, ptr)
        self.string = bind(self.cf, "CFStringCreateWithCString", ptr, ptr, C.c_char_p, C.c_uint32)
        self.get_string = bind(self.cf, "CFStringGetCString", C.c_bool, ptr, ptr, C.c_long, C.c_uint32)
        self.system = bind(self.ax, "AXUIElementCreateSystemWide", ptr)()
        self.create_app = bind(self.ax, "AXUIElementCreateApplication", ptr, C.c_int)
        self.attr = bind(self.ax, "AXUIElementCopyAttributeValue", C.c_int, ptr, ptr, C.POINTER(ptr))
        self.hit = bind(self.ax, "AXUIElementCopyElementAtPosition", C.c_int, ptr, C.c_float, C.c_float, C.POINTER(ptr))
        self.get_pid = bind(self.ax, "AXUIElementGetPid", C.c_int, ptr, C.POINTER(C.c_int))
        self.value = bind(self.ax, "AXValueGetValue", C.c_bool, ptr, C.c_int, ptr)
        self.value_type = bind(self.ax, "AXValueGetTypeID", C.c_ulong)
        self.settable = bind(self.ax, "AXUIElementIsAttributeSettable", C.c_int, ptr, ptr, C.POINTER(C.c_bool))
        self.timeout = bind(self.ax, "AXUIElementSetMessagingTimeout", C.c_int, ptr, C.c_float)
        self.trusted = bind(self.ax, "AXIsProcessTrusted", C.c_bool)
        self.keys = {name: self.string(None, name.encode(), 0x08000100) for name in
                     ("AXRole", "AXSubrole", "AXDescription", "AXIdentifier", "AXDOMIdentifier", "AXDOMClassList", "AXParent", "AXWindow", "AXPosition", "AXSize",
                      "AXFocusedUIElement", "AXFocused", "AXEditable", "AXValue", "AXSelectedText")}
        self.timeout(self.system, 0.08)
        self.deadline, self.errors = 0, []

    def copy(self, element, name):
        # Budget EVERY attribute, not just the loop: a slow app must not turn
        # dozens of ancestors into a many-second backlog.
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            return None
        self.timeout(element, min(0.04, remaining))
        value = C.c_void_p()
        error = self.attr(element, self.keys[name], C.byref(value))
        if error == 0:
            return value.value
        if len(self.errors) < 48:
            self.errors.append(f"{name}:{error}")
        return None

    def boolean(self, element, name):
        value = self.copy(element, name)
        if not value:
            return None
        try:
            return bool(self.bool_value(value)) if self.type_id(value) == self.bool_type() else None
        finally:
            self.release(value)

    def editable(self, element, role):
        if role not in ("AXTextField", "AXTextArea", "AXComboBox"):
            return False
        declared = self.boolean(element, "AXEditable")
        if declared is not None:
            return declared
        for name in ("AXSelectedText", "AXValue"):
            if time.monotonic() >= self.deadline:
                break
            self.timeout(element, min(0.04, max(0.001, self.deadline - time.monotonic())))
            result = C.c_bool()
            error = self.settable(element, self.keys[name], C.byref(result))
            if error == 0 and result.value:
                return True
        return None  # An unreadable property is not proof of an editor.

    def text(self, element, name):
        value = self.copy(element, name)
        if not value:
            return ""
        try:
            if self.type_id(value) != self.string_type():
                return ""
            buf = C.create_string_buffer(1024)
            if self.get_string(value, buf, len(buf), 0x08000100):
                return buf.value.decode("utf-8", errors="replace").replace("\n", " ")[:160]
            return ""
        finally:
            self.release(value)

    def main_content(self, element) -> bool:
        """Reads only the known main-pane class marker; never retains arbitrary class names."""
        classes = self.copy(element, "AXDOMClassList")
        if not classes:
            return False
        try:
            if self.type_id(classes) != self.array_type():
                return False
            for index in range(self.array_count(classes)):
                if time.monotonic() >= self.deadline:
                    break
                value = self.array_item(classes, index)
                if value and self.type_id(value) == self.string_type():
                    buf = C.create_string_buffer(1024)
                    if self.get_string(value, buf, len(buf), 0x08000100) and buf.value == MAIN_CONTENT_CLASS.encode():
                        return True
            return False
        finally:
            self.release(classes)

    def rect(self, element):
        pos, size = self.copy(element, "AXPosition"), self.copy(element, "AXSize")
        try:
            p, s = Point(), Size()
            if (pos and size and self.type_id(pos) == self.value_type()
                    and self.type_id(size) == self.value_type()
                    and self.value(pos, 1, C.byref(p)) and self.value(size, 2, C.byref(s))):
                return Rect(p.x, p.y, s.width, s.height)
            return None
        finally:
            for v in (pos, size):
                if v:
                    self.release(v)

    def sample(self, x, y, expected_pid, focus=False):
        started = time.monotonic()
        # Reserve the last 100ms for a fresh same-app focus/owner check even when
        # the ancestry hits its budget. A partial path must not hide changed focus.
        final_deadline = started + 0.85
        self.deadline, self.errors = started + 0.75, []
        if not self.trusted():
            return Sample(expected_pid, 0, None, x, y, (), "Accessibility access needed")
        if self.frontmost_pid() != expected_pid:
            return Sample(expected_pid, 0, None, x, y, (), "Click owner changed")
        app_element = self.create_app(expected_pid) if focus else None
        element = C.c_void_p()
        if focus:
            # System-wide focus reads failed in the supplied live report.
            # Query the already-verified click owner's public app element, never
            # discover or activate another app as a fallback.
            element.value = self.copy(app_element, "AXFocusedUIElement") if app_element else None
            err = 0 if element.value else -1
        else:
            err = self.hit(self.system, x, y, C.byref(element))
        if err or not element.value:
            if app_element:
                self.release(app_element)
            return Sample(expected_pid, 0, None, x, y, (),
                          "Focused element unavailable" if focus else f"Hit-test unavailable ({err})",
                          errors=tuple(self.errors))
        current, nodes, window_key, window_rect = element.value, [], 0, None
        original = current
        self.retain(original)
        seen, end, failure = set(), "", ""
        focus_stable, conversation_seen = None, False
        try:
            pid = C.c_int()
            if self.get_pid(current, C.byref(pid)) or pid.value != expected_pid:
                return Sample(expected_pid, 0, None, x, y, (),
                              "Keyboard focus belongs to another app" if focus else "Click owner changed")
            window = self.copy(current, "AXWindow")
            if window:
                try:
                    self.timeout(window, 0.06)
                    window_key, window_rect = self.hash(window), self.rect(window)
                finally:
                    self.release(window)
            for index in range(MAX_ANCESTORS):
                if time.monotonic() >= self.deadline:
                    end, failure = "time-budget", "Read timed out"
                    break
                token = self.hash(current)
                if token in seen:
                    end, failure = "ancestor-cycle", "Ancestor cycle"
                    break
                seen.add(token)
                self.timeout(current, 0.06)
                role = self.text(current, "AXRole")
                subrole = self.text(current, "AXSubrole")
                # Retain only this structural label, not arbitrary description
                # text or a chat title. Other AXDescription values are discarded.
                conversation = (subrole == "AXLandmarkRegion"
                                and self.text(current, "AXDescription") == "Conversation")
                conversation_seen |= conversation
                node = Node(role, self.text(current, "AXIdentifier"),
                            self.text(current, "AXDOMIdentifier"), self.rect(current),
                            self.boolean(current, "AXFocused") if focus and index == 0 else None,
                            self.editable(current, role) if focus and index == 0 else None,
                            subrole, conversation,
                            self.main_content(current) if conversation_seen and role == "AXGroup" else False)
                nodes.append(node)
                if node.role == "AXWindow":
                    window_key, window_rect = self.hash(current), node.frame
                    end = "window"
                    break
                parent = self.copy(current, "AXParent")
                if not parent:
                    end, failure = "parent-unavailable", "Ancestor path incomplete"
                    break
                self.release(current)
                current = parent
            else:
                end, failure = "ancestor-limit", "Ancestor limit reached"
            if time.monotonic() >= self.deadline:
                failure = "Read timed out"
            self.deadline = final_deadline
            if focus:
                check = self.copy(app_element, "AXFocusedUIElement")
                try:
                    focus_stable = bool(check and self.equal(check, original))
                    if not focus_stable:
                        failure = ("Keyboard focus changed during read" if check
                                   else "Keyboard focus could not be rechecked")
                finally:
                    if check:
                        self.release(check)
                if nodes and nodes[0].frame:
                    rect = nodes[0].frame
                    x, y = rect.x + rect.width / 2, rect.y + rect.height / 2
            if self.frontmost_pid() != expected_pid:
                failure, focus_stable = "Click owner changed", False
            return Sample(expected_pid, window_key, window_rect, x, y, tuple(nodes), failure,
                          end, round((time.monotonic() - started) * 1000), tuple(self.errors), focus_stable)
        finally:
            self.release(current)
            self.release(original)
            if app_element:
                self.release(app_element)

    @staticmethod
    def frontmost_pid():
        app = K.NSWorkspace.sharedWorkspace().frontmostApplication()
        return app.processIdentifier() if app else None

    def request_accessibility(self):
        # Only the explicit control command may prompt. Call from the actual
        # service so macOS attributes consent to it, not the command sender.
        prompt_key = C.c_void_p.in_dll(self.ax, "kAXTrustedCheckOptionPrompt")
        key = objc.objc_object(c_void_p=prompt_key.value)
        options = NSDictionary.dictionaryWithObject_forKey_(True, key)
        request = self.ax.AXIsProcessTrustedWithOptions
        request.argtypes, request.restype = [C.c_void_p], C.c_bool
        return bool(request(C.c_void_p(objc.pyobjc_id(options))))


class FlippedView(K.NSView):
    """Top-anchored scroll document for the inspector's own content."""
    def isFlipped(self):
        return True


class Inspector(NSObject):
    def applicationDidFinishLaunching_(self, notification):
        self.model, self.diagnostics = PaneModel(), Diagnostics()
        # Demo construction never creates an AX reader or event monitor. It is
        # the only agent-operated UI validation path; live Codex stays user-only.
        self.reader = None if OPTIONS.demo else AXReader()
        self.focuser = PaneInputFocuser(self.reader) if self.reader else None
        self.focus_inputs, self.mouse_down_point, self.down_monitor = True, None, None  # Ethan: on by default.
        # Off until Agent Flow says otherwise, so a helper restarted mid-session just focuses inputs as usual.
        # input_proof is (window key, pane, click sequence): it only counts for the very next gesture, so a click this helper never finished reading cannot leave a stale pane behind.
        self.typing_box_returns_keyboard, self.input_proof = False, None
        # Idle until Agent Flow says otherwise: a helper restarted mid-recording only focuses later, and that recording's stop still drops a waiting focus. The epoch counts Agent Flow's state changes so a waiting highlight can tell one happened.
        self.agent_flow_recording, self.agent_flow_epoch = False, 0
        # Own reader: the click worker changes its reader's deadline at the same time.
        self.claude_focuser = ClaudePromptFocuser(AXReader()) if self.reader and CLAUDE_FOCUS_ENABLED else None  # Off: no observer, checkbox greyed out.
        self.claude_click_focuser = ClaudePromptFocuser(self.reader) if self.reader else None  # Separate from the dormant stop trigger above (Ethan, 2026-11-08). Shares the Codex reader because both run only on the one click worker.
        self.focus_claude, self.claude_running = True, threading.Lock()  # Ethan approved on by default, 2026-10-19.
        self.pending = queue.Queue(maxsize=1)
        self.completed = LatestResult(lambda: self.performSelectorOnMainThread_withObject_waitUntilDone_(
            "refresh:", None, False))
        self.sequence, self.last, self.monitor, self.paused = 0, None, None, False
        self.preferences = HelperPreferences(INSTANCE.directory / "preferences.json")
        self.paused, self.focus_inputs = self.preferences.paused, self.preferences.focus_inputs
        self.window = None
        self.close_monitor = None
        self.events_seen, self.codex_clicks = 0, 0
        self.event_source_revision = 0
        self.last_reconnect_reason = "startup"
        self.callback_errors = self.callback_error_streak = 0
        self.health = HelperHealth()
        self.health_log = HealthLog(INSTANCE.directory / "health-events.json")
        self.health_stop = threading.Event()
        self.watchdog = self.health_timer = self.activity = None
        self.monitor_retry_at, self.monitor_retry_delay = 0, 5
        if self.reader:
            self.thread = threading.Thread(target=self.worker, daemon=True, name="pane-focus-worker")
            self.thread.start()
        # Non-activating panels cannot rely on another app's menu-bar Close
        # command. Handle only key events already delivered to this process,
        # and only while this panel owns the keyboard. Never steal Codex's W.
        self.close_monitor = K.NSEvent.addLocalMonitorForEventsMatchingMask_handler_(
            K.NSEventMaskKeyDown, self.close_key_event)
        self.reconnect_event_sources("startup")
        if self.reader:
            workspace_center = K.NSWorkspace.sharedWorkspace().notificationCenter()
            for name in (K.NSWorkspaceDidWakeNotification, K.NSWorkspaceSessionDidBecomeActiveNotification,
                         K.NSWorkspaceDidLaunchApplicationNotification):
                workspace_center.addObserver_selector_name_object_(self, "workspaceChanged:", name, None)
            # Keep this tiny interactive observer responsive without preventing
            # system sleep. No destination or message is read by its health timer.
            from Foundation import NSActivityUserInitiatedAllowingIdleSystemSleep
            self.activity = NSProcessInfo.processInfo().beginActivityWithOptions_reason_(
                NSActivityUserInitiatedAllowingIdleSystemSleep, "Codex pane focus event handling")
            self.health_timer = NSTimer.timerWithTimeInterval_target_selector_userInfo_repeats_(
                5.0, self, "healthTick:", None, True)
            NSRunLoop.mainRunLoop().addTimer_forMode_(self.health_timer, NSRunLoopCommonModes)
            self.watchdog = threading.Thread(target=self.watch_health, daemon=True, name="pane-helper-health")
            self.watchdog.start()
        if (OPTIONS.demo and not OPTIONS.background) or OPTIONS.show_inspector:
            self.showInspector_(None)
        self.publish_state()
        print("Focus helper ready", flush=True)

    @objc.python_method
    def reconnect_event_sources(self, reason):
        """Rearm subscriptions after desktop lifecycle changes, never poll or focus.

        Ethan's pane focusing went silent with an eight-day-old process: its
        worker was idle and even a fresh control notification got no reply.
        Restarting restored replies. Recreate the existing sources on wake,
        session return and Codex relaunch instead of relying on their lifetime.
        This is not evidence that every focus-loss report has the same cause.
        """
        self.sequence += 1  # Work captured before a session transition is stale.
        self.callback_error_streak = 0
        self.mouse_down_point = None
        if self.monitor is not None:
            self.monitor.close()
        self.monitor = self.down_monitor = None
        self.event_source_revision += 1
        revision = self.event_source_revision
        center = NSDistributedNotificationCenter.defaultCenter()
        center.removeObserver_(self)
        center.addObserver_selector_name_object_suspensionBehavior_(
            self, "control:", CONTROL_NAME, control_object(OPTIONS.demo),
            NSNotificationSuspensionBehaviorDeliverImmediately)
        if self.claude_focuser:
            center.addObserver_selector_name_object_suspensionBehavior_(
                self, "recordingStopped:", RECORDING_STOPPED, None, NSNotificationSuspensionBehaviorDeliverImmediately)
        for name in (RECORDING_STARTED, RECORDING_STOPPED, RECORDING_STOPPED_PRESERVING_PLAYBACK):  # Separate from the dormant Claude stop trigger above, which stays off.
            center.addObserver_selector_name_object_suspensionBehavior_(
                self, "agentFlowRecordingChanged:", name, None, NSNotificationSuspensionBehaviorDeliverImmediately)
        for name in (TYPING_BOX_RETURN_ON, TYPING_BOX_RETURN_OFF):
            center.addObserver_selector_name_object_suspensionBehavior_(
                self, "typingBoxReturnChanged:", name, None, NSNotificationSuspensionBehaviorDeliverImmediately)
        if self.reader:
            self.monitor = MouseMonitor(lambda kind, event: self.mouse_event(revision, kind, event))
            if not self.monitor.start():
                print("Helper mouse listener unavailable · no permission prompt requested", flush=True)
                self.monitor_retry_at = time.monotonic() + self.monitor_retry_delay
                self.monitor_retry_delay = min(60, self.monitor_retry_delay * 2)
            else:
                self.monitor_retry_at, self.monitor_retry_delay = 0, 5
        self.last_reconnect_reason = reason
        if hasattr(self, "health_log"):
            self.health_log.record(reason, self.health.snapshot())
        print(f"Helper event sources reconnected · {reason} · revision {self.event_source_revision}", flush=True)

    @objc.python_method
    def mouse_event(self, revision, kind, event):
        if revision != self.event_source_revision:
            return  # A queued callback from a removed listener owns no new click.
        if kind in (Q.kCGEventTapDisabledByTimeout, Q.kCGEventTapDisabledByUserInput,
                    Q.kCGEventRightMouseDown, Q.kCGEventOtherMouseDown):
            self.sequence += 1
            self.mouse_down_point = None
            return
        try:
            native = K.NSEvent.eventWithCGEvent_(event)
            if native is None:
                return
            if kind == Q.kCGEventLeftMouseDown:
                self.mouse_down(native)
            elif kind == Q.kCGEventLeftMouseUp:
                self.clicked(native)
            self.callback_error_streak = 0
        except Exception as exc:
            self.callback_errors += 1
            self.callback_error_streak += 1
            if self.callback_error_streak == 1:
                print(f"Helper mouse callback failed · {type(exc).__name__}", flush=True)

    def healthTick_(self, timer):
        action, token = self.health.main_tick()
        if action == "restart":
            self.fail_helper("control connection did not recover")
            return
        if action == "reconnect":
            self.reconnect_event_sources("control reply timed out")
        if self.callback_error_streak >= 3:
            self.reconnect_event_sources("mouse callback repeatedly threw")
        if (self.monitor is not None and self.monitor.tap is None
                and time.monotonic() >= self.monitor_retry_at):
            self.reconnect_event_sources("mouse listener unavailable")
        if self.monitor is not None and self.monitor.tap is not None and not self.monitor.enabled():
            self.sequence += 1
            self.mouse_down_point = None
            self.monitor.enable()
            if not self.monitor.enabled():
                self.reconnect_event_sources("mouse listener disabled")
        NSDistributedNotificationCenter.defaultCenter().postNotificationName_object_userInfo_deliverImmediately_(
            CONTROL_NAME, control_object(OPTIONS.demo), {"command": "health", "request": token}, True)

    @objc.python_method
    def watch_health(self):
        while not self.health_stop.wait(2):
            reason = self.health.watchdog_failure(self.thread.is_alive())
            if reason:
                self.fail_helper(reason)
                return

    @objc.python_method
    def fail_helper(self, reason):
        # Never replace a stuck AX thread in place: an old request might later
        # return and steal focus. Exiting this one helper lets its existing
        # launchd KeepAlive restart one clean process; Agent Flow stays running.
        self.sequence += 1
        self.health_stop.set()
        if hasattr(self, "health_log"):
            self.health_log.record(reason, self.health.snapshot())
        print(f"Helper recovery restart · {time.strftime('%Y-%m-%dT%H:%M:%S%z')} · {reason}", flush=True)
        os._exit(70)

    def workspaceChanged_(self, notification):
        name = notification.name()
        if name == K.NSWorkspaceDidLaunchApplicationNotification:
            app = (notification.userInfo() or {}).get(K.NSWorkspaceApplicationKey)
            if app and app.bundleIdentifier() == AGENT_FLOW_BUNDLE_ID:
                self.typing_box_returns_keyboard = self.agent_flow_recording = False  # A relaunch after a crash never sent Off or Stopped for the old session.
                self.agent_flow_epoch += 1
                return
            url = app.bundleURL() if app else None
            if not url or Path(str(url.path())).name not in ("Codex.app", "ChatGPT.app"):
                return
            reason = "Codex launched"
        else:
            reason = "wake" if name == K.NSWorkspaceDidWakeNotification else "session active"
        self.reconnect_event_sources(reason)
        self.publish_state()

    @objc.python_method
    def publish_state(self, request=None):
        # Permission belongs to THIS service, not the short-lived CLI sender.
        # Refresh only for startup or an explicit command, never on an idle timer.
        runtime = None
        if hasattr(self, "event_source_revision"):
            runtime = {"event_source_revision": self.event_source_revision,
                       "last_reconnect_reason": self.last_reconnect_reason,
                       "monitor_active": bool(self.monitor is not None and self.monitor.enabled()),
                       "worker_alive": bool(self.reader and self.thread.is_alive()),
                       "paused": self.paused, "focus_inputs": self.focus_inputs,
                       "events_seen": self.events_seen, "codex_clicks": self.codex_clicks}
            if hasattr(self, "health"):
                runtime.update(self.health.snapshot())
                runtime["watchdog_alive"] = bool(self.watchdog and self.watchdog.is_alive())
                runtime["mouse_disable_events"] = self.monitor.disabled_count if self.monitor else 0
                runtime["callback_errors"] = self.callback_errors
                runtime["focus_worker_threads"] = sum(t.is_alive() and t.name == "pane-focus-worker"
                                                       for t in threading.enumerate())
                runtime["health_threads"] = sum(t.is_alive() and t.name == "pane-helper-health"
                                                 for t in threading.enumerate())
        INSTANCE.publish(True, bool(self.window and self.window.isVisible()),
                         self.reader.trusted() if self.reader else None, request, runtime=runtime)

    def control_(self, notification):
        command = (notification.userInfo() or {}).get("command")
        if command == "health":
            self.health.acknowledge((notification.userInfo() or {}).get("request"))
            return  # Internal self-ping never rewrites the status file.
        if hasattr(self, "health"):
            self.health.control_received()  # A real command also proves receipt.
        if command == "show":
            self.showInspector_(None)
        elif command == "hide":
            self.hideInspector_(None)
        elif command == "quit":
            self.quit_(None)
            return
        elif command == "request-accessibility" and self.reader:
            self.reader.request_accessibility()
        elif command == "reconnect":
            self.reconnect_event_sources("explicit reconnect")
        self.publish_state((notification.userInfo() or {}).get("request"))

    def showInspector_(self, sender):
        # The background service creates no window. Only an explicit show
        # command (or the synthetic Demo) constructs and presents the inspector.
        created = self.window is None
        if created and not self.make_window():
            return
        self.update_snapshot_ui()
        self.window.orderFrontRegardless()  # A non-activating panel; never activate another app.
        # AppKit may apply a launch cascade before the first order-front. Position
        # this task-owned panel LAST, after layout, to keep it on the built-in screen.
        if created:
            self.window.contentView().layoutSubtreeIfNeeded()
            self.window.setFrame_display_(self.window.frameRectForContentRect_(self.initial_rect), True)
            NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
                0.2, self, "place:", None, False)
        print(f"Inspector ready · window {self.window.windowNumber()} · built-in display", flush=True)
        self.publish_state()
        if OPTIONS.demo and created:
            self.demoMismatch_(None)

    def hideInspector_(self, sender):
        if self.window:
            self.window.orderOut_(None)
        self.publish_state()

    def place_(self, timer):
        # AppKit can finish its initial cascade on the next run-loop turn.
        # One placement only: never chase the user's later moves or app focus.
        if not self.window or not self.window.isVisible():
            return
        self.window.setFrame_display_(self.window.frameRectForContentRect_(self.initial_rect), True)
        print(f"Inspector placement verified · {K.NSStringFromRect(self.window.frame())}", flush=True)

    @objc.python_method
    def make_window(self):
        screen = next((s for s in K.NSScreen.screens() if s.localizedName() == "Built-in Retina Display"), None)
        if screen is None:
            print("Inspector not opened: Built-in Retina Display is unavailable", flush=True)
            return False
        visible = screen.visibleFrame()
        width, height = min(720, visible.size.width * 0.8), min(560, visible.size.height * 0.6)
        rect = K.NSMakeRect(visible.origin.x + (visible.size.width - width) / 2,
                            visible.origin.y + (visible.size.height - height) / 2, width, height)
        self.initial_rect = rect
        self.window = K.NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
            rect, K.NSWindowStyleMaskTitled | K.NSWindowStyleMaskClosable | K.NSWindowStyleMaskResizable
            | K.NSWindowStyleMaskNonactivatingPanel, K.NSBackingStoreBuffered, False)
        self.window.setTitle_("Codex Focus Inspector" + (" — Demo" if OPTIONS.demo else " — Live"))
        self.window.setLevel_(K.NSFloatingWindowLevel)
        self.window.setHidesOnDeactivate_(False)
        self.window.setReleasedWhenClosed_(False)
        self.window.setDelegate_(self)
        self.window.setAppearance_(K.NSAppearance.appearanceNamed_(K.NSAppearanceNameDarkAqua))
        stack = K.NSStackView.alloc().initWithFrame_(K.NSMakeRect(0, 0, width, height))
        stack.setOrientation_(K.NSUserInterfaceLayoutOrientationVertical)
        stack.setAlignment_(K.NSLayoutAttributeLeading)
        stack.setSpacing_(12)
        stack.setEdgeInsets_((20, 20, 20, 20))
        stack.setTranslatesAutoresizingMaskIntoConstraints_(False)
        # Ethan wants a short window: the whole content scrolls instead of the
        # window forcing its full height. A flipped document keeps it top-anchored.
        outer = K.NSScrollView.alloc().initWithFrame_(K.NSMakeRect(0, 0, width, height))
        outer.setHasVerticalScroller_(True)
        outer.setDrawsBackground_(False)
        outer.setTranslatesAutoresizingMaskIntoConstraints_(False)
        document = FlippedView.alloc().initWithFrame_(K.NSMakeRect(0, 0, width, height))
        document.setTranslatesAutoresizingMaskIntoConstraints_(False)
        document.addSubview_(stack)
        outer.setDocumentView_(document)
        content = self.window.contentView()
        content.addSubview_(outer)
        clip = outer.contentView()
        K.NSLayoutConstraint.activateConstraints_([
            outer.leadingAnchor().constraintEqualToAnchor_(content.leadingAnchor()),
            outer.trailingAnchor().constraintEqualToAnchor_(content.trailingAnchor()),
            outer.topAnchor().constraintEqualToAnchor_(content.topAnchor()),
            outer.bottomAnchor().constraintEqualToAnchor_(content.bottomAnchor()),
            document.leadingAnchor().constraintEqualToAnchor_(clip.leadingAnchor()),
            document.trailingAnchor().constraintEqualToAnchor_(clip.trailingAnchor()),
            document.topAnchor().constraintEqualToAnchor_(clip.topAnchor()),
            stack.leadingAnchor().constraintEqualToAnchor_(document.leadingAnchor()),
            stack.trailingAnchor().constraintEqualToAnchor_(document.trailingAnchor()),
            stack.topAnchor().constraintEqualToAnchor_(document.topAnchor()),
            stack.bottomAnchor().constraintEqualToAnchor_(document.bottomAnchor())])
        self.window.setContentMinSize_(K.NSMakeSize(360, 160))
        def label(text, size=14, color=None):
            v = K.NSTextField.wrappingLabelWithString_(text)
            v.setFont_(K.NSFont.systemFontOfSize_(size))
            if color:
                v.setTextColor_(color)
            stack.addArrangedSubview_(v)
            return v
        label("Codex Focus Inspector", 22)
        self.focus_toggle = K.NSButton.checkboxWithTitle_target_action_(
            "Focus that pane's input when I click or highlight in its chat area", self, "toggleFocus:")
        self.focus_toggle.setState_(K.NSControlStateValueOn if self.focuser and self.focus_inputs else K.NSControlStateValueOff)
        self.focus_toggle.setEnabled_(self.focuser is not None)  # Demo has no reader, so nothing to focus.
        stack.addArrangedSubview_(self.focus_toggle)
        self.claude_toggle = K.NSButton.checkboxWithTitle_target_action_(
            "Focus Claude's Prompt box when Agent Flow stops recording", self, "toggleClaudeFocus:")
        self.claude_toggle.setState_(K.NSControlStateValueOn if self.claude_focuser else K.NSControlStateValueOff)
        self.claude_toggle.setEnabled_(self.claude_focuser is not None)  # Demo has no reader either.
        stack.addArrangedSubview_(self.claude_toggle)
        label("No cursor movement, typing, pasting or sending. Highlights focus after 0.3 s; modifier clicks are left alone.",
              color=K.NSColor.secondaryLabelColor())
        self.event_status = label("DEMO · buttons only; Codex clicks are ignored" if OPTIONS.demo else "Starting click monitor…", 14,
                                  K.NSColor.systemOrangeColor() if OPTIONS.demo else K.NSColor.secondaryLabelColor())
        self.result = label("Clicked pane: waiting", 23)
        self.focus_result = label("Focused pane: waiting", 23)
        self.input_status = label("Input focus: waiting", 16)
        self.comparison = label("Click the main input, side input, then each chat body.", 16)
        self.evidence = label("Each click takes one snapshot after release. Keyboard-only focus changes are not tracked.")
        self.next_check = label("Unknown stays unknown; no destination is guessed.", color=K.NSColor.secondaryLabelColor())
        self.position = label("No clicks yet", color=K.NSColor.secondaryLabelColor())
        toolbar = K.NSStackView.stackViewWithViews_([])
        toolbar.setSpacing_(10)
        for title, action in (("Pause", "pause:"), ("Clear", "clear:"),
                              ("Copy diagnostics", "copy:"), ("Quit", "quit:")):
            button = K.NSButton.buttonWithTitle_target_action_(title, self, action)
            toolbar.addArrangedSubview_(button)
            if title == "Pause":
                self.pause_button = button
                button.setTitle_("Resume" if self.paused else "Pause")
        stack.addArrangedSubview_(toolbar)
        if OPTIONS.demo:
            demos = K.NSStackView.stackViewWithViews_([])
            demos.setSpacing_(8)
            for title, action in (("Same pane", "demoSame:"), ("Different panes", "demoMismatch:"),
                                  ("Chat area", "demoConversation:"), ("Partial read", "demoPartial:"),
                                  ("Unknown", "demoUnknown:"), ("Read failure", "demoFailure:")):
                demos.addArrangedSubview_(K.NSButton.buttonWithTitle_target_action_(title, self, action))
            stack.addArrangedSubview_(demos)
        else:
            access = K.NSButton.buttonWithTitle_target_action_("Accessibility settings", self, "permissions:")
            stack.addArrangedSubview_(access)
        label("Label a Pane If No Marker Is Exposed", 16)
        label("Choose a pane container, not a word or the whole window. Labels are a layout experiment, not Codex's own pane identity.")
        self.containers = K.NSPopUpButton.alloc().initWithFrame_pullsDown_(K.NSMakeRect(0, 0, width - 40, 28), False)
        self.containers.addItemWithTitle_("Click a Codex area first")
        stack.addArrangedSubview_(self.containers)
        teach = K.NSStackView.stackViewWithViews_([])
        teach.setSpacing_(10)
        for title, action in (("Use container as Main chat", "main:"), ("Use container as Side chat", "side:")):
            teach.addArrangedSubview_(K.NSButton.buttonWithTitle_target_action_(title, self, action))
        stack.addArrangedSubview_(teach)
        self.details = K.NSTextView.alloc().initWithFrame_(K.NSMakeRect(0, 0, width - 40, 250))
        self.details.setEditable_(False)
        self.details.setFont_(K.NSFont.monospacedSystemFontOfSize_weight_(12, K.NSFontWeightRegular))
        self.details.setTextColor_(K.NSColor.labelColor())
        scroll = K.NSScrollView.alloc().initWithFrame_(K.NSMakeRect(0, 0, width - 40, 250))
        scroll.setDocumentView_(self.details)
        scroll.setHasVerticalScroller_(True)
        scroll.setTranslatesAutoresizingMaskIntoConstraints_(False)
        stack.addArrangedSubview_(scroll)
        scroll.widthAnchor().constraintEqualToAnchor_constant_(stack.widthAnchor(), -40).setActive_(True)
        scroll.heightAnchor().constraintGreaterThanOrEqualToConstant_(160).setActive_(True)
        label("Last 20 samples stay in memory. Copy shares only roles, counts and failure reasons—not text, IDs or titles.", 12, K.NSColor.secondaryLabelColor())
        return True

    @objc.python_method
    def clicked(self, event):
        if self.paused:
            return
        self.events_seen += 1
        down, self.mouse_down_point = self.mouse_down_point, None
        if down is None:
            # A release spanning startup/wake/reconnect has no measured drag.
            # Never turn it into a guessed plain click that can clear selection.
            self.sequence += 1
            return
        app = K.NSWorkspace.sharedWorkspace().frontmostApplication()
        url = app.bundleURL() if app else None
        if not url or Path(str(url.path())).name not in ("Codex.app", "ChatGPT.app"):
            self.sequence += 1
            self.last = None
            if self.claude_click_focuser and self.focus_inputs and app and app.bundleIdentifier() == CLAUDE_BUNDLE_ID:  # Ethan (2026-11-08): the Codex click-to-input behaviour in Claude too. The shared worker means a newer click or key cancels this one.
                point = Q.CGEventGetLocation(event.CGEvent())
                self.enqueue_click((self.sequence, point.x, point.y, app.processIdentifier(), time.monotonic(),
                                    CLAUDE_BUNDLE_ID, "", self.click_gesture(event, point, down), self.key_count()))
            if not self.window or not self.window.isVisible():
                return
            self.event_status.setStringValue_(f"LIVE · clicks received: {self.events_seen} · Codex: {self.codex_clicks}")
            self.result.setStringValue_("Clicked pane: outside Codex")
            self.focus_result.setStringValue_("Focused pane: not sampled")
            self.input_status.setStringValue_("Input focus: not sampled")
            self.comparison.setStringValue_("No current Codex snapshot")
            self.evidence.setStringValue_("Click a Codex input to take a fresh snapshot.")
            self.next_check.setStringValue_("No destination is guessed.")
            self.position.setStringValue_("No current sample")
            self.details.setString_("")
            return
        self.codex_clicks += 1
        if self.window and self.window.isVisible():
            self.event_status.setStringValue_(f"LIVE · clicks received: {self.events_seen} · Codex: {self.codex_clicks} · reading…")
        point = Q.CGEventGetLocation(event.CGEvent())
        gesture = self.click_gesture(event, point, down)
        self.sequence += 1
        info = NSBundle.bundleWithPath_(str(url.path())).infoDictionary() or {}
        version = f"{info.get('CFBundleShortVersionString', '')} / {info.get('CFBundleVersion', '')}"
        request = (self.sequence, point.x, point.y, app.processIdentifier(), time.monotonic(),
                   Path(str(url.path())).name, version, gesture, self.key_count())
        self.enqueue_click(request)

    @objc.python_method
    def click_gesture(self, event, point, down):
        modifiers = (K.NSEventModifierFlagCommand | K.NSEventModifierFlagShift
                     | K.NSEventModifierFlagControl | K.NSEventModifierFlagOption)
        return ClickGesture(event.clickCount(),
                            math.hypot(point.x - down.x, point.y - down.y) if down else 0.0,
                            bool(event.modifierFlags() & modifiers))

    @objc.python_method
    def enqueue_click(self, request):
        try:
            self.pending.put_nowait(request)
        except queue.Full:
            try:
                self.pending.get_nowait()
            except queue.Empty:
                pass
            self.pending.put_nowait(request)

    @objc.python_method
    def worker(self):
        while True:
            request = self.pending.get()
            self.health.begin_job()
            error = None
            try:
                self.process_request(request)
            except Exception as exc:
                error = type(exc).__name__
                print(f"Helper worker request failed · {error}", flush=True)
            finally:
                self.health.end_job(error)

    @objc.python_method
    def key_count(self):
        return Q.CGEventSourceCounterForEventType(Q.kCGEventSourceStateCombinedSessionState, Q.kCGEventKeyDown)  # A count only, no key listener or text: typing after a click must cancel delayed caret recovery.

    @objc.python_method
    def process_request(self, request):
        sequence, x, y, pid, captured, host, version, gesture, keys_at_click = request
        current = lambda: sequence == self.sequence and not self.paused and self.focus_inputs and self.key_count() == keys_at_click
        # A delayed queue must not attribute a newer screen to an old click.
        remaining = captured + 0.09 - time.monotonic()
        if remaining > 0:
            threading.Event().wait(remaining)
        if sequence != self.sequence or self.paused or self.key_count() != keys_at_click:
            return
        if host == CLAUDE_BUNDLE_ID:  # Claude has no Codex pane model or inspector snapshot; its focuser proves the clicked pane itself.
            self.focus_claude_click(pid, (x, y), gesture, current)
            return
        try:
            sample = self.reader.sample(x, y, pid)
            for _ in range(HIT_RETEST_ATTEMPTS):  # Without this re-read most chat clicks saw only the window and never planned a focus.
                if not needs_hit_retest(sample):
                    break
                threading.Event().wait(HIT_RETEST_INTERVAL_SECONDS)
                if sequence != self.sequence or self.paused or self.key_count() != keys_at_click:
                    return  # A newer click or key owns focus now; the old click must not act on it.
                sample = self.reader.sample(x, y, pid)
            focused = self.reader.sample(x, y, pid, focus=True)
        except Exception as exc:
            sample = Sample(pid, 0, None, x, y, (), f"Read unavailable ({type(exc).__name__})")
            focused = sample
        observation = Observation(sample, focused, sequence, host=host, version=version, gesture=gesture)
        highlight = is_highlight_gesture(gesture)
        agent_flow_epoch = self.agent_flow_epoch
        if highlight and (self.agent_flow_recording or self.typing_box_returns_keyboard) and agent_flow_is_running():
            threading.Event().wait(HIGHLIGHT_FOCUS_DELAY_SECONDS)
        elif highlight:
            # Ethan (2026-11-11): with Agent Flow idle, the usual 0.3 s focus cleared a
            # highlight before he could press start, so nothing was added. Waiting here
            # replaces "keep the existing settling interval" for the idle case only;
            # recordings and the typing box keep 0.3 s. The focus below fires only if
            # Agent Flow stayed idle for the whole wait. If it started, its start-up read
            # gets the in-session 0.3 s first, since it sends no receipt to wait for. If it
            # stopped, a late focus could move the auto-send Return to another chat.
            # Known limit: a typed-only session with automatic return switched off sends
            # neither signal, so it counts as idle here.
            for _ in range(round(IDLE_HIGHLIGHT_FOCUS_DELAY_SECONDS / IDLE_WAIT_SLICE_SECONDS)):  # Counted, not clocked, so the wait is exact under test.
                threading.Event().wait(IDLE_WAIT_SLICE_SECONDS)
                if (sequence != self.sequence or self.paused or self.key_count() != keys_at_click
                        or agent_flow_epoch != self.agent_flow_epoch):
                    break
            if self.key_count() != keys_at_click:
                return  # A key during the wait owns the keyboard now: a copy, typing or a shortcut.
            if (agent_flow_epoch != self.agent_flow_epoch and sequence == self.sequence and not self.paused
                    and (self.agent_flow_recording or self.typing_box_returns_keyboard) and agent_flow_is_running()):
                # Ethan (2026-11-11): "can it do both", so the paste lands in the highlighted pane without a click. Agent Flow started during the wait, so give its start-up read the same 0.3 s an in-session highlight gets, then focus as if the highlight came mid-session. A voice-plus-typing start posts two broadcasts, so only a session that ended during the settle skips.
                threading.Event().wait(HIGHLIGHT_FOCUS_DELAY_SECONDS)
                if self.key_count() != keys_at_click:
                    return  # Typing into the typing box right after start: leave Codex alone rather than race those keys.
                if (self.agent_flow_recording or self.typing_box_returns_keyboard) and agent_flow_is_running():
                    agent_flow_epoch = self.agent_flow_epoch
            self.health.begin_job()  # The wait was deliberate, not a stuck native call; the watchdog's 6 seconds apply to the work after it.
        # Ethan (2026-11-06): every chat-text click must focus its input, including
        # double/triple clicks without Agent Flow capture. The old receipt veto
        # deliberately preserved pre-start selections; do not restore that veto
        # over this preference (task 01a0d315-7d5e-7be0-bc08-80626ca0729b).
        # Ethan (2026-11-09) narrowed it for one case: while Agent Flow's typing box
        # will take the keyboard back, a highlight in the pane that already has
        # Codex's input stays highlighted, because the final paste lands there
        # anyway. A highlight in any other pane still focuses its input so the
        # 2026-10-17 paste rule holds. Rejected: focusing the pane at finish instead.
        # Nothing orders that write before a typed-only paste, and a late write would
        # move the auto-send Return to the other pane. This reads Agent Flow's state,
        # not the old capture receipt, so it cannot race the capture.
        if self.focus_inputs and sequence == self.sequence and not self.paused:
            pane = None
            try:
                pane, frame = input_focus_plan(self.model, observation)
                proof, self.input_proof = self.input_proof, None  # A focus error below must leave the pane unproven.
                # Every click advances the sequence twice, at press and at release. So this accepts a proof only from the click just before this gesture or from the gesture's own clicks; any other click, pause or reconnect in between makes the gap too large.
                input_pane = proof[1] if (proof and proof[0] == focused.window_key
                                          and proof[2] >= sequence - 2 * max(1, gesture.click_count)) else None
                if pane and (sequence != self.sequence or self.paused):
                    action = "Skipped · a newer click arrived"
                elif pane and highlight and agent_flow_epoch != self.agent_flow_epoch:
                    action = "Skipped · Agent Flow started or stopped during the highlight wait"
                elif (pane and highlight and pane == input_pane and self.typing_box_returns_keyboard
                      and agent_flow_is_running()):  # The running check covers Agent Flow crashing before it can say Off.
                    action = KEPT_HIGHLIGHT_ACTION
                else:
                    action = self.focuser.focus(pid, frame, pane,
                        is_current=current,
                        window_key=focused.window_key,
                        click_point=(x, y)) if pane else frame
                input_pane = input_pane_after_click(self.model, observation, pane, action, input_pane)
                self.input_proof = (focused.window_key, input_pane, sequence) if input_pane else None
                if highlight:
                    action = "After highlight · " + action
            except Exception as exc:
                action = f"Failed · focus step error ({type(exc).__name__})"
            observation = replace(observation, focus_action=action)
            if pane:
                # Status vocabulary only (pane names, AX roles, error numbers),
                # so focus attempts can be reviewed without the clipboard.
                print(f"focus attempt · snapshot {sequence} · {action}", flush=True)
        self.completed.put((sequence, observation))

    def refresh_(self, timer):
        result = self.completed.take()
        if result is None:
            return
        sequence, observation = result
        if sequence == self.sequence and not self.paused:
            self.last = observation
            self.diagnostics.append(observation, self.model)
            if self.window and self.window.isVisible():
                self.update_snapshot_ui()

    @objc.python_method
    def update_snapshot_ui(self):
        if not self.last:
            return
        self.containers.removeAllItems()
        for i, node in enumerate(self.last.click.nodes):
            bounds = node.frame.short() if node.frame else "no bounds"
            self.containers.addItemWithTitle_(f"{i} · {node.role} · {bounds}")
        if not self.last.click.nodes:
            self.containers.addItemWithTitle_("No containers available")
        self.render()
        self.event_status.setStringValue_(f"LIVE · clicks received: {self.events_seen} · Codex: {self.codex_clicks} · snapshot ready")

    @objc.python_method
    def render(self):
        if not self.last:
            return
        pane, reason, focus, focus_reason, relation, next_check = describe(self.model, self.last)
        self.result.setStringValue_(f"Clicked pane: {pane}")
        self.focus_result.setStringValue_(f"Focused pane: {focus}")
        input_state = self.model.input_state(self.last.focus, self.last.host, self.last.version)
        # The snapshot is taken before the optional focus write, so show both.
        self.input_status.setStringValue_(
            f"{input_state} → {self.last.focus_action}" if self.last.focus_action else input_state)
        self.comparison.setStringValue_(relation)
        color = {"Main chat": K.NSColor.systemTealColor(), "Side chat": K.NSColor.systemPurpleColor()}.get(pane, K.NSColor.systemOrangeColor())
        self.result.setTextColor_(color)
        self.focus_result.setTextColor_({"Main chat": K.NSColor.systemTealColor(), "Side chat": K.NSColor.systemPurpleColor()}.get(focus, K.NSColor.systemOrangeColor()))
        self.evidence.setStringValue_(f"Click: {reason}\nFocus: {focus_reason}")
        self.next_check.setStringValue_(next_check)
        s = self.last.click
        self.position.setStringValue_(f"Snapshot {self.last.number} · release + {self.last.delay_ms} ms · reads {s.elapsed_ms} / {self.last.focus.elapsed_ms} ms")
        lines = [f"Host: {self.last.host} · {self.last.version}",
                 "CLICKED ELEMENT → PARENTS", ""]
        for i, node in enumerate(s.nodes):
            lines += [f"{i} {node.role} {node.subrole}", f"  bounds: {node.frame.short() if node.frame else 'unavailable'}",
                      f"  identifier: {node.identifier or '—'}", f"  DOM identifier: {node.dom_identifier or '—'}", ""]
        lines += ["KEYBOARD-FOCUSED ELEMENT → PARENTS", ""]
        for i, node in enumerate(self.last.focus.nodes):
            lines += [f"{i} {node.role} {node.subrole} · focused={node.focused} · editable={node.editable}",
                      f"  bounds: {node.frame.short() if node.frame else 'unavailable'}",
                      f"  identifier: {node.identifier or '—'}", f"  DOM identifier: {node.dom_identifier or '—'}"]
        lines += ["", "READ DIAGNOSTICS", f"Click ended: {s.end}; input ended: {self.last.focus.end}",
                  f"Click errors: {', '.join(s.errors) or 'none'}",
                  f"Input errors: {', '.join(self.last.focus.errors) or 'none'}", "", "LABELLED REGIONS (cleared on quit)"]
        for pane, (_, node) in self.model.regions.items():
            lines += [f"{pane}: {node.frame.short()}"]
        self.details.setString_("\n".join(lines))

    @objc.python_method
    def learn(self, pane):
        if self.last and self.model.learn(pane, self.last.click, self.containers.indexOfSelectedItem()):
            self.render()
        else:
            self.evidence.setStringValue_("Use a container inside the clicked window; unavailable or changed reads cannot be labelled.")

    def main_(self, sender):
        self.learn("Main chat")

    def side_(self, sender):
        self.learn("Side chat")

    def clear_(self, sender):
        self.model.regions.clear()
        self.diagnostics.observations.clear()
        self.sequence += 1
        self.last = None
        self.result.setStringValue_("Clicked pane: waiting")
        self.focus_result.setStringValue_("Focused pane: waiting")
        self.input_status.setStringValue_("Input focus: waiting")
        self.comparison.setStringValue_("Samples and pane labels cleared")
        self.evidence.setStringValue_("Click a Codex input to take a fresh snapshot.")
        self.next_check.setStringValue_("Unknown stays unknown; no destination is guessed.")
        self.position.setStringValue_("No clicks yet")
        self.containers.removeAllItems()
        self.containers.addItemWithTitle_("Click a Codex area first")
        self.details.setString_("")

    def copy_(self, sender):
        board = K.NSPasteboard.generalPasteboard()
        board.clearContents()
        board.setString_forType_(self.diagnostics.report(self.model), K.NSPasteboardTypeString)
        self.next_check.setStringValue_("Diagnostics copied. Paste them in the chat if detection failed.")

    @objc.python_method
    def demo(self, clicked, focused, failure="", editable=True, coarse=False):
        self.sequence += 1
        window = Rect(0, 0, 1200, 800)
        def sample(pane, is_focus):
            rect = Rect(20 if pane == "main-chat" else 820, 650, 330, 90)
            nodes = (Node("AXTextArea" if is_focus and editable else "AXGroup", "", "", rect,
                          True if is_focus else None, editable if is_focus else None,
                          "AXLandmarkRegion" if is_focus and not editable else "",
                          is_focus and not editable),
                     Node("AXGroup", pane, "", Rect(0, 0, 800, 800) if pane == "main-chat" else Rect(800, 0, 400, 800)),
                     Node("AXWindow", "", "", window))
            if coarse and not is_focus:
                nodes = (Node("AXGroup", "", "", window), Node("AXWindow", "", "", window))
            return Sample(42, 8, window, rect.x + 10, 690, nodes, failure,
                          "ancestor-limit" if failure == "Ancestor limit reached" else "window", 4,
                          focus_stable=True if is_focus else None)
        self.last = Observation(sample(clicked, False), sample(focused, True), self.sequence, host="demo")
        self.diagnostics.append(self.last, self.model)
        self.containers.removeAllItems()
        for i, node in enumerate(self.last.click.nodes):
            self.containers.addItemWithTitle_(f"{i} · {node.role}")
        self.render()

    def demoSame_(self, sender):
        self.demo("main-chat", "main-chat")

    def demoMismatch_(self, sender):
        self.demo("main-chat", "side-chat")

    def demoConversation_(self, sender):
        self.demo("main-chat", "main-chat", editable=False, coarse=True)

    def demoPartial_(self, sender):
        self.demo("main-chat", "side-chat", "Ancestor limit reached")

    def demoUnknown_(self, sender):
        self.demo("", "")

    def demoFailure_(self, sender):
        self.demo("main-chat", "side-chat", "Accessibility access needed")

    def pause_(self, sender):
        self.paused = not self.paused
        self.sequence += 1  # In-flight reads cannot overwrite a paused or resumed screen.
        self.preferences.save(self.paused, self.focus_inputs)
        sender.setTitle_("Resume" if self.paused else "Pause")
        self.evidence.setStringValue_("Paused" if self.paused else "Click a Codex area to continue")

    def permissions_(self, sender):
        # User initiated only. Do not auto-prompt, reset TCC or grant permissions.
        from Foundation import NSURL
        K.NSWorkspace.sharedWorkspace().openURL_(NSURL.URLWithString_(
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"))

    def quit_(self, sender):
        K.NSApp.terminate_(None)

    def toggleFocus_(self, sender):
        self.focus_inputs = sender.state() == K.NSControlStateValueOn
        self.sequence += 1
        self.mouse_down_point = None
        self.preferences.save(self.paused, self.focus_inputs)

    def toggleClaudeFocus_(self, sender):
        self.focus_claude = sender.state() == K.NSControlStateValueOn

    def typingBoxReturnChanged_(self, notification):
        self.typing_box_returns_keyboard = str(notification.name()) == TYPING_BOX_RETURN_ON
        self.agent_flow_epoch += 1

    def agentFlowRecordingChanged_(self, notification):
        self.agent_flow_recording = str(notification.name()) == RECORDING_STARTED
        self.agent_flow_epoch += 1

    def recordingStopped_(self, notification):
        # Every Agent Flow finish posts this, including cancel and the clipboard-only
        # "Won't paste" finish; Ethan accepted that those also move focus to the Prompt.
        app = K.NSWorkspace.sharedWorkspace().frontmostApplication()
        if self.paused or not self.focus_claude or not app or app.bundleIdentifier() != CLAUDE_BUNDLE_ID:
            return
        if not self.claude_running.acquire(blocking=False):  # Stops are seconds apart; never queue a stale run.
            print("claude prompt focus · skipped · previous run still active", flush=True)
            return
        threading.Thread(target=self.focus_claude_prompt, args=(app.processIdentifier(),), daemon=True).start()

    @objc.python_method
    def focus_claude_prompt(self, pid):
        try:
            status = self.claude_focuser.focus_prompt(pid)
        except Exception as exc:
            status = f"Failed · focus step error ({type(exc).__name__})"
        finally:
            self.claude_running.release()
        # Status vocabulary only, like the Codex focus lines; never message text.
        print(f"claude prompt focus · recording stopped · {status}", flush=True)

    @objc.python_method
    def focus_claude_click(self, pid, point, gesture, current):
        # Plain clicks only, unlike Codex, where Ethan also asked for highlights: focusing the Prompt would clear the text he just selected to copy.
        if is_highlight_gesture(gesture) or gesture.modifier_held:
            return
        try:
            status = self.claude_click_focuser.focus_clicked_pane(pid, point, current)
        except Exception as exc:
            status = f"Failed · focus step error ({type(exc).__name__})"
        print(f"claude prompt focus · click · {status}", flush=True)  # Status vocabulary only, like the Codex focus lines; never message text.

    @objc.python_method
    def mouse_down(self, event):
        self.sequence += 1  # Cancel old work at press time, before a new selection.
        self.mouse_down_point = Q.CGEventGetLocation(event.CGEvent())

    @objc.python_method
    def close_key_event(self, event):
        if self.window and is_close_shortcut(event.keyCode(), event.modifierFlags(), K.NSApp.keyWindow() == self.window):
            self.window.performClose_(None)
            return None
        return event

    def windowShouldClose_(self, window):
        self.hideInspector_(None)
        return False

    def applicationWillTerminate_(self, notification):
        print("Focus helper stopped", flush=True)
        NSDistributedNotificationCenter.defaultCenter().removeObserver_(self)
        self.health_stop.set()
        if self.health_timer is not None:
            self.health_timer.invalidate()
        if self.activity is not None:
            NSProcessInfo.processInfo().endActivity_(self.activity)
        if self.reader:
            K.NSWorkspace.sharedWorkspace().notificationCenter().removeObserver_(self)
        INSTANCE.close()
        if self.monitor:
            self.monitor.close()
        if getattr(self, "close_monitor", None):
            K.NSEvent.removeMonitor_(self.close_monitor)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--demo", action="store_true", help="Synthetic data only; no AX reader or global event monitor")
    parser.add_argument("--background", action="store_true")
    commands = parser.add_mutually_exclusive_group()
    commands.add_argument("--show-inspector", action="store_true")
    commands.add_argument("--hide-inspector", action="store_true")
    commands.add_argument("--quit", action="store_true")
    commands.add_argument("--status", action="store_true")
    commands.add_argument("--request-accessibility", action="store_true")
    commands.add_argument("--reconnect", action="store_true", help="Rearm this helper's existing event subscriptions")
    OPTIONS = parser.parse_args()
    directory = Path.home() / "Library/Application Support/AgentFlow/CodexFocusHelper"
    INSTANCE = SingleInstance(directory / ("demo" if OPTIONS.demo else "live"))
    acquired = INSTANCE.acquire()
    command = ("show" if OPTIONS.show_inspector else "hide" if OPTIONS.hide_inspector
               else "quit" if OPTIONS.quit else "status" if OPTIONS.status
               else "request-accessibility" if OPTIONS.request_accessibility else None)
    if OPTIONS.reconnect:
        command = "reconnect"
    if OPTIONS.status or not acquired or command in ("hide", "quit", "request-accessibility", "reconnect"):
        state = {} if acquired else INSTANCE.wait_ready()
        if command and not acquired and state:
            request = f"{os.getpid()}:{time.monotonic_ns()}"
            NSDistributedNotificationCenter.defaultCenter().postNotificationName_object_userInfo_deliverImmediately_(
                CONTROL_NAME, control_object(OPTIONS.demo), {"command": command, "request": request}, True)
            if command != "quit":
                state = INSTANCE.wait_reply(request)
                if not state:
                    print("Helper control request not confirmed")
                    raise SystemExit(1)
        elif not acquired and not state:
            print("Helper is starting; control request not delivered")
            raise SystemExit(1)
        if OPTIONS.reconnect and acquired:
            print("Helper control request not confirmed")
            INSTANCE.close()
            raise SystemExit(1)
        if OPTIONS.status or OPTIONS.reconnect:
            print(json.dumps({"running": not acquired, **state}))
        INSTANCE.close()
        raise SystemExit(0)
    app = K.NSApplication.sharedApplication()
    app.setActivationPolicy_(K.NSApplicationActivationPolicyAccessory)
    delegate = Inspector.alloc().init()
    app.setDelegate_(delegate)
    app.run()
