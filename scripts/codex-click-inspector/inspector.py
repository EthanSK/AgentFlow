#!/usr/bin/env python3
"""User-operated Codex click inspector. No focus writes, clicks, keys or text reads.

This tool is for Ethan to inspect locally, NOT an automation workaround for a
Computer Use refusal. Agents must not read its live Codex results or use it to
resolve/activate a target. Validate it against fixtures, not Ethan's live chats.
"""
import ctypes as C
import argparse
import queue
import threading
import time
from pathlib import Path

import AppKit as K
import Quartz as Q
import objc
from Foundation import NSObject, NSTimer, NSBundle
from pane_model import Node, PaneModel, Rect, Sample, Observation, Diagnostics, describe, MAX_ANCESTORS

OPTIONS = None


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
                     ("AXRole", "AXSubrole", "AXDescription", "AXIdentifier", "AXDOMIdentifier", "AXParent", "AXWindow", "AXPosition", "AXSize",
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
        focus_stable = None
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
                node = Node(role, self.text(current, "AXIdentifier"),
                            self.text(current, "AXDOMIdentifier"), self.rect(current),
                            self.boolean(current, "AXFocused") if focus and index == 0 else None,
                            self.editable(current, role) if focus and index == 0 else None,
                            subrole, conversation)
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


class Inspector(NSObject):
    def applicationDidFinishLaunching_(self, notification):
        self.model, self.diagnostics = PaneModel(), Diagnostics()
        # Demo construction never creates an AX reader or event monitor. It is
        # the only agent-operated UI validation path; live Codex stays user-only.
        self.reader = None if OPTIONS.demo else AXReader()
        self.pending, self.completed = queue.Queue(maxsize=1), queue.Queue()
        self.sequence, self.last, self.monitor, self.paused = 0, None, None, False
        self.events_seen, self.codex_clicks = 0, 0
        if self.reader:
            self.thread = threading.Thread(target=self.worker, daemon=True)
            self.thread.start()
        if not self.make_window():
            return
        if self.reader:
            # Mouse-down observes the PREVIOUS keyboard focus in many hosts.
            # Sample after release plus one short settling interval, off the UI.
            self.monitor = K.NSEvent.addGlobalMonitorForEventsMatchingMask_handler_(K.NSEventMaskLeftMouseUp, self.clicked)
            trusted = "ready" if self.reader.trusted() else "Accessibility access needed"
            self.event_status.setStringValue_(f"LIVE · monitor {'active' if self.monitor else 'unavailable'} · {trusted} · clicks received: 0")
        self.timer = NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            0.1, self, "refresh:", None, True)
        self.window.orderFrontRegardless()  # A non-activating panel; never activate another app.
        # AppKit may apply a launch cascade before the first order-front. Position
        # this task-owned panel LAST, after layout, to keep it on the built-in screen.
        self.window.contentView().layoutSubtreeIfNeeded()
        self.window.setFrame_display_(self.window.frameRectForContentRect_(self.initial_rect), True)
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            0.2, self, "place:", None, False)
        print(f"Inspector ready · window {self.window.windowNumber()} · built-in display", flush=True)
        if OPTIONS.demo:
            self.demoMismatch_(None)

    def place_(self, timer):
        # AppKit can finish its initial cascade on the next run-loop turn.
        # One placement only: never chase the user's later moves or app focus.
        self.window.setFrame_display_(self.window.frameRectForContentRect_(self.initial_rect), True)
        print(f"Inspector placement verified · {K.NSStringFromRect(self.window.frame())}", flush=True)

    @objc.python_method
    def make_window(self):
        screen = next((s for s in K.NSScreen.screens() if s.localizedName() == "Built-in Retina Display"), None)
        if screen is None:
            print("Inspector not opened: Built-in Retina Display is unavailable", flush=True)
            K.NSApp.terminate_(None)
            return False
        visible = screen.visibleFrame()
        width, height = min(720, visible.size.width * 0.8), min(960, visible.size.height * 0.8)
        rect = K.NSMakeRect(visible.origin.x + (visible.size.width - width) / 2,
                            visible.origin.y + (visible.size.height - height) / 2, width, height)
        self.initial_rect = rect
        self.window = K.NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
            rect, K.NSWindowStyleMaskTitled | K.NSWindowStyleMaskClosable | K.NSWindowStyleMaskResizable
            | K.NSWindowStyleMaskNonactivatingPanel, K.NSBackingStoreBuffered, False)
        self.window.setTitle_("Codex Focus Inspector" + (" — Demo" if OPTIONS.demo else " — Live"))
        self.window.setLevel_(K.NSFloatingWindowLevel)
        self.window.setHidesOnDeactivate_(False)
        self.window.setDelegate_(self)
        self.window.setAppearance_(K.NSAppearance.appearanceNamed_(K.NSAppearanceNameDarkAqua))
        stack = K.NSStackView.alloc().initWithFrame_(K.NSMakeRect(0, 0, width, height))
        stack.setOrientation_(K.NSUserInterfaceLayoutOrientationVertical)
        stack.setAlignment_(K.NSLayoutAttributeLeading)
        stack.setSpacing_(12)
        stack.setEdgeInsets_((20, 20, 20, 20))
        stack.setTranslatesAutoresizingMaskIntoConstraints_(False)
        self.window.contentView().addSubview_(stack)
        K.NSLayoutConstraint.activateConstraints_([
            stack.leadingAnchor().constraintEqualToAnchor_(self.window.contentView().leadingAnchor()),
            stack.trailingAnchor().constraintEqualToAnchor_(self.window.contentView().trailingAnchor()),
            stack.topAnchor().constraintEqualToAnchor_(self.window.contentView().topAnchor()),
            stack.bottomAnchor().constraintEqualToAnchor_(self.window.contentView().bottomAnchor())])
        def label(text, size=14, color=None):
            v = K.NSTextField.wrappingLabelWithString_(text)
            v.setFont_(K.NSFont.systemFontOfSize_(size))
            if color:
                v.setTextColor_(color)
            stack.addArrangedSubview_(v)
            return v
        label("Codex Focus Inspector", 22)
        label("Read-only. No cursor movement, typing or focus changes.", color=K.NSColor.secondaryLabelColor())
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
        app = K.NSWorkspace.sharedWorkspace().frontmostApplication()
        url = app.bundleURL() if app else None
        if not url or Path(str(url.path())).name not in ("Codex.app", "ChatGPT.app"):
            self.event_status.setStringValue_(f"LIVE · clicks received: {self.events_seen} · Codex: {self.codex_clicks}")
            self.sequence += 1
            self.last = None
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
        self.event_status.setStringValue_(f"LIVE · clicks received: {self.events_seen} · Codex: {self.codex_clicks} · reading…")
        point = Q.CGEventGetLocation(event.CGEvent())
        self.sequence += 1
        info = NSBundle.bundleWithPath_(str(url.path())).infoDictionary() or {}
        version = f"{info.get('CFBundleShortVersionString', '')} / {info.get('CFBundleVersion', '')}"
        request = self.sequence, point.x, point.y, app.processIdentifier(), time.monotonic(), Path(str(url.path())).name, version
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
            sequence, x, y, pid, captured, host, version = self.pending.get()
            # A delayed queue must not attribute a newer screen to an old click.
            remaining = captured + 0.09 - time.monotonic()
            if remaining > 0:
                threading.Event().wait(remaining)
            if sequence != self.sequence or self.paused:
                continue
            try:
                sample = self.reader.sample(x, y, pid)
                focused = self.reader.sample(x, y, pid, focus=True)
            except Exception as exc:
                sample = Sample(pid, 0, None, x, y, (), f"Read unavailable ({type(exc).__name__})")
                focused = sample
            self.completed.put((sequence, Observation(sample, focused, sequence, host=host, version=version)))

    def refresh_(self, timer):
        while True:
            try:
                sequence, observation = self.completed.get_nowait()
            except queue.Empty:
                return
            if sequence == self.sequence and not self.paused:
                self.last = observation
                self.diagnostics.append(observation, self.model)
                self.containers.removeAllItems()
                for i, node in enumerate(observation.click.nodes):
                    bounds = node.frame.short() if node.frame else "no bounds"
                    self.containers.addItemWithTitle_(f"{i} · {node.role} · {bounds}")
                if not observation.click.nodes:
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
        self.input_status.setStringValue_(self.model.input_state(
            self.last.focus, self.last.host, self.last.version))
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
        sender.setTitle_("Resume" if self.paused else "Pause")
        self.evidence.setStringValue_("Paused" if self.paused else "Click a Codex area to continue")

    def permissions_(self, sender):
        # User initiated only. Do not auto-prompt, reset TCC or grant permissions.
        from Foundation import NSURL
        K.NSWorkspace.sharedWorkspace().openURL_(NSURL.URLWithString_(
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"))

    def quit_(self, sender):
        K.NSApp.terminate_(None)

    def windowWillClose_(self, notification):
        K.NSApp.terminate_(None)

    def applicationWillTerminate_(self, notification):
        print("Inspector closed", flush=True)
        if self.monitor:
            K.NSEvent.removeMonitor_(self.monitor)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--demo", action="store_true", help="Synthetic data only; no AX reader or global event monitor")
    OPTIONS = parser.parse_args()
    app = K.NSApplication.sharedApplication()
    app.setActivationPolicy_(K.NSApplicationActivationPolicyAccessory)
    delegate = Inspector.alloc().init()
    app.setDelegate_(delegate)
    app.run()
