"""Opt-in "focus the clicked pane's input" experiment for the inspector.

Ethan asked for this on 2026-10-17: a plain click in a Codex chat area should
put the caret in that same pane's input, so a later Agent Flow paste does not
land in the input Codex last remembered. It renews focus and the caret only
on the measured input, with one bounded recovery if its Conversation retakes focus. It never clicks, types, pastes, sends, reads message
values, or changes Agent Flow's delivery route.
"""
from __future__ import annotations
import ctypes as C
import time
from typing import Callable
from pane_model import MAX_ANCESTORS, Rect

# Measured on ChatGPT.app 26.1013.31256 / 20586: both the main and side inputs
# expose this structural label, so the pane comes from the Conversation region.
COMPOSER_DESCRIPTION = "Work with Codex"
MAX_SEARCH_DEPTH = 10  # The side input measured 6 levels below its Conversation region.
MAX_SEARCH_NODES = 400  # Bounds a long chat history; the input is searched last-child first.
SEARCH_BUDGET_SECONDS = 0.5
VERIFY_SECONDS, VERIFY_INTERVAL_SECONDS = 0.2, 0.025  # Bounded wait for Chromium's async focus.
HOLD_CHECK_SECONDS = 0.6  # One later check can recover only the original Conversation losing its caret.


class PaneInputFocuser:
    """Bounded click-owned focus renewal, reusing AXReader's reads."""

    def __init__(self, reader):
        self.reader = reader
        ptr = C.c_void_p
        cf, ax = reader.cf, reader.ax
        self.array_count = cf.CFArrayGetCount
        self.array_count.restype, self.array_count.argtypes = C.c_long, [ptr]
        self.array_item = cf.CFArrayGetValueAtIndex
        self.array_item.restype, self.array_item.argtypes = ptr, [ptr, C.c_long]
        self.set_attribute = ax.AXUIElementSetAttributeValue
        self.set_attribute.restype, self.set_attribute.argtypes = C.c_int, [ptr, ptr, ptr]
        self.true_value = ptr.in_dll(cf, "kCFBooleanTrue")
        self.value_create = ax.AXValueCreate
        self.value_create.restype, self.value_create.argtypes = ptr, [C.c_int, ptr]
        self.number_value = cf.CFNumberGetValue
        self.number_value.restype, self.number_value.argtypes = C.c_bool, [ptr, C.c_int, ptr]
        for name in ("AXChildren", "AXNumberOfCharacters", "AXSelectedTextRange"):
            reader.keys.setdefault(name, reader.string(None, name.encode(), 0x08000100))
        self.arrays = []

    def focus(self, pid: int, region_frame: Rect, pane: str,
              is_current: Callable[[], bool] | None = None, window_key: int = 0,
              click_point: tuple[float, float] | None = None) -> str:
        """Focuses the freshly proven clicked pane, preserving other editors and newer input."""
        r = self.reader
        current = is_current or (lambda: True)
        r.deadline, r.errors = time.monotonic() + SEARCH_BUDGET_SECONDS, []
        app = initial = region = target = check = None
        try:
            if not current():
                return "Skipped · request superseded"
            if r.frontmost_pid() != pid:
                return "Skipped · Codex is no longer frontmost"
            app = r.create_app(pid)
            initial = r.copy(app, "AXFocusedUIElement") if app else None
            if not initial or not self.same_window(initial, window_key):
                return "Skipped · pane window changed"
            initial_role = r.text(initial, "AXRole")
            initial_composer = (initial_role == "AXTextArea" and r.text(initial, "AXDescription") == COMPOSER_DESCRIPTION)
            if initial_role in ("AXTextArea", "AXTextField", "AXComboBox"):
                if not initial_composer:
                    return "Skipped · another editor has focus"
                if self.selection_length(initial) != 0:
                    return "Skipped · input selection present or unreadable"
            region = self.conversation(initial, region_frame) if initial else None
            if not region and click_point and initial_role:
                region = self.region_at_point(pid, click_point, region_frame)
            if not region:
                return "Skipped · focus moved before the input lookup"
            if not self.same_window(region, window_key):
                return "Skipped · pane window changed"
            target = self.find_input(region, region_frame)
            if target is None:
                return "Skipped · no pane input found within the search limit"
            renew = r.equal(initial, target)
            if renew and self.selection_length(target) != 0:
                return "Skipped · input selection present or unreadable"
            # Last check before the focus write: the user may have clicked again
            # or switched apps while the bounded search ran.
            r.deadline = time.monotonic() + 0.1
            check = r.copy(app, "AXFocusedUIElement")
            if (not current() or r.frontmost_pid() != pid or not check or not r.equal(check, initial)
                    or not self.same_window(region, window_key)):
                return "Skipped · focus moved during the input lookup"
            r.release(check)
            check = None
            if renew:
                error = self.set_focused(region)  # Chromium ignores AXFocused=false; reset through the clicked Conversation then its composer, never an invented blur flag (task 01a0d315-7d5e-7be0-bc08-80626ca0729b).
                if error:
                    return f"Failed · Codex refused the focus reset ({error})"
                reset_until = time.monotonic() + VERIFY_SECONDS
                while True:
                    r.deadline = time.monotonic() + 0.1
                    if not current() or r.frontmost_pid() != pid or not self.same_window(target, window_key):
                        return "Skipped · request superseded during focus reset"
                    if self.target_focused(app, region):
                        break
                    if not self.target_focused(app, target):
                        return "Skipped · another control took focus during reset"
                    if time.monotonic() >= reset_until:
                        return "Focus reset sent · not confirmed"
                    time.sleep(VERIFY_INTERVAL_SECONDS)
            error = self.set_focused(target)
            if error:
                return f"Failed · Codex refused the focus write ({error})"
            # Chromium applies an AX focus write asynchronously in the renderer; the
            # first live re-read (2026-10-17) still saw the Conversation region.
            # Re-read only, never re-write, for up to VERIFY_SECONDS.
            give_up = time.monotonic() + VERIFY_SECONDS
            while True:
                r.deadline = time.monotonic() + 0.05
                check = r.copy(app, "AXFocusedUIElement")
                if check and r.equal(check, target):
                    caret = self.place_caret(target, is_current=lambda: (
                        current() and r.frontmost_pid() == pid and self.same_window(target, window_key)
                        and self.target_focused(app, target)))
                    held = self.hold_check(app, target, is_current=current)
                    if held.endswith("to Conversation region"):
                        held = self.recover(app, region, target, pid, region_frame, window_key, current, held)
                    return f"Focused {pane} input · verified · {caret} · {held}"
                if check:
                    r.release(check)
                    check = None
                if time.monotonic() >= give_up:
                    return f"Focus sent to {pane} input · not confirmed"
                time.sleep(VERIFY_INTERVAL_SECONDS)
        finally:
            for value in (check, target, region, initial, app):
                if value:
                    r.release(value)
            for array in self.arrays:
                r.release(array)
            self.arrays = []

    def conversation(self, focused, frame):
        """Retains the measured Conversation around a focused or freshly hit element."""
        r = self.reader
        current = r.retain(focused)
        try:
            for _ in range(MAX_ANCESTORS):
                if self.is_region(current, frame):
                    return r.retain(current)
                parent = r.copy(current, "AXParent")
                if not parent:
                    return None
                r.release(current)
                current = parent
            return None
        finally:
            r.release(current)

    def region_at_point(self, pid: int, point: tuple[float, float], frame: Rect) -> int | None:
        """Retains the clicked Conversation after a fresh owner-checked hit-test."""
        r = self.reader
        hit = C.c_void_p()
        error = r.hit(r.system, point[0], point[1], C.byref(hit))
        if not hit.value:
            return None
        try:
            owner = C.c_int()
            if error or r.get_pid(hit.value, C.byref(owner)) or owner.value != pid:
                return None
            return self.conversation(hit.value, frame)
        finally:
            r.release(hit.value)

    def recover(self, app, region, target, pid, frame, window_key, current, lost):
        """Retries once only when the same click's Conversation retook focus."""
        r = self.reader
        r.deadline = time.monotonic() + SEARCH_BUDGET_SECONDS
        check = r.copy(app, "AXFocusedUIElement")
        fresh_target = None
        try:
            if (not current() or r.frontmost_pid() != pid or not check or not r.equal(check, region)
                    or not self.same_window(region, window_key) or not self.is_region(region, frame)):
                return lost + " · recovery skipped (new input or focus)"
            fresh_target = self.find_input(region, frame)
            if not fresh_target or not r.equal(fresh_target, target) or self.selection_length(target) != 0:
                return lost + " · recovery skipped (input changed or selected)"
            if (not current() or r.frontmost_pid() != pid or not self.target_focused(app, region)
                    or not self.same_window(target, window_key) or not self.is_region(region, frame)):
                return lost + " · recovery skipped (new input or focus)"
            error = self.set_focused(target)  # The old helper only reported this measured lost-focus case; one retry repairs it without a repeating focus-stealing loop.
            if error:
                return lost + f" · recovery refused ({error})"
            give_up = time.monotonic() + VERIFY_SECONDS
            while current() and r.frontmost_pid() == pid and self.same_window(target, window_key):
                r.deadline = time.monotonic() + 0.05
                if self.target_focused(app, target):
                    caret = self.place_caret(target, is_current=lambda: current() and r.frontmost_pid() == pid
                                             and self.same_window(target, window_key) and self.target_focused(app, target))
                    return f"focus recovered once · verified · {caret}"
                if time.monotonic() >= give_up:
                    break
                time.sleep(VERIFY_INTERVAL_SECONDS)
            return lost + " · recovery sent, not confirmed"
        finally:
            for value in (check, fresh_target):
                if value:
                    r.release(value)

    def same_window(self, element, expected):
        if not expected:
            return True  # Existing callers may supply only a proven region.
        window = self.reader.copy(element, "AXWindow")
        if not window:
            return False
        try:
            return self.reader.hash(window) == expected
        finally:
            self.reader.release(window)

    def target_focused(self, app, target):
        focused = self.reader.copy(app, "AXFocusedUIElement")
        if not focused:
            return False
        try:
            return self.reader.equal(focused, target)
        finally:
            self.reader.release(focused)

    def place_caret(self, target, is_current=None):
        """Puts the caret at the end of the input's existing draft; never edits its text.

        Live 2026-10-17: AXFocused alone left Codex's input focused (held 0.6 s)
        with no caret, so Ethan saw nothing. A zero-length AXSelectedTextRange
        at the end draws the caret without reading or changing the draft.
        """
        r = self.reader
        current = is_current or (lambda: True)
        if not current():
            return "caret not placed (request superseded)"
        r.deadline = time.monotonic() + 0.1
        count = self.character_count(target)
        if count is None:
            return "caret not placed (length unreadable)"
        range_value = self.make_range(count)
        if not range_value:
            return "caret not placed (range unavailable)"
        try:
            if self.selection_length(target) != 0:
                return "caret not placed (selection present or unreadable)"
            if not current():
                return "caret not placed (request superseded)"
            error = self.set_attribute(target, r.keys["AXSelectedTextRange"], range_value)
        finally:
            r.release(range_value)
        return "caret placed at end" if error == 0 else f"caret not placed ({error})"

    def selection_length(self, target):
        class CFRange(C.Structure):
            _fields_ = [("location", C.c_long), ("length", C.c_long)]
        value = self.reader.copy(target, "AXSelectedTextRange")
        if not value:
            return None
        try:
            out = CFRange()
            return out.length if self.reader.value(value, 4, C.byref(out)) else None
        finally:
            self.reader.release(value)

    def character_count(self, element):
        number = self.reader.copy(element, "AXNumberOfCharacters")
        if not number:
            return None
        try:
            out = C.c_longlong()
            return out.value if self.number_value(number, 4, C.byref(out)) else None  # kCFNumberSInt64Type
        finally:
            self.reader.release(number)

    def make_range(self, location):
        class CFRange(C.Structure):
            _fields_ = [("location", C.c_long), ("length", C.c_long)]
        value = CFRange(location, 0)
        return self.value_create(4, C.byref(value))  # kAXValueCFRangeType

    def hold_check(self, app, target, is_current: Callable[[], bool] | None = None):
        """Re-reads focus once after HOLD_CHECK_SECONDS; names only the AX role of any taker.

        Ethan saw no caret although the immediate check verified (2026-10-17), so
        this tells "Codex took focus back" apart from "focus held but no caret".
        """
        r = self.reader
        current = is_current or (lambda: True)
        until = time.monotonic() + HOLD_CHECK_SECONDS
        while True:
            if not current():
                return "Skipped · request superseded"
            remaining = until - time.monotonic()
            if remaining <= 0:
                break
            time.sleep(min(VERIFY_INTERVAL_SECONDS, remaining))  # A newer pane click must not wait behind the old click's 0.6-second hold check.
        r.deadline = time.monotonic() + 0.1
        later = r.copy(app, "AXFocusedUIElement")
        if not later:
            return f"focus unreadable at {HOLD_CHECK_SECONDS:g} s"
        try:
            if r.equal(later, target):
                return f"still focused at {HOLD_CHECK_SECONDS:g} s"
            role, subrole = r.text(later, "AXRole"), r.text(later, "AXSubrole")
            conversation = subrole == "AXLandmarkRegion" and r.text(later, "AXDescription") == "Conversation"
            taker = "Conversation region" if conversation else "/".join(p for p in (role, subrole) if p) or "unknown"
            return f"lost by {HOLD_CHECK_SECONDS:g} s to {taker}"
        finally:
            r.release(later)

    def is_region(self, element, frame):
        r = self.reader
        return (r.text(element, "AXSubrole") == "AXLandmarkRegion"
                and r.text(element, "AXDescription") == "Conversation"
                and r.rect(element) == frame)

    def find_input(self, region, frame):
        """Returns a retained input element, searching last children first, or None."""
        r = self.reader
        stack, visited = [(child, 1) for child in self.children(region)], 0
        while stack and visited < MAX_SEARCH_NODES and time.monotonic() < r.deadline:
            element, depth = stack.pop()
            visited += 1
            if (r.text(element, "AXRole") == "AXTextArea"
                    and r.text(element, "AXDescription") == COMPOSER_DESCRIPTION):
                rect = r.rect(element)
                if rect is not None and rect.inside(frame):
                    r.retain(element)
                    return element
            if depth < MAX_SEARCH_DEPTH:
                stack.extend((child, depth + 1) for child in self.children(element))
        return None

    def children(self, element):
        # Array items stay valid until their owning array is released in focus().
        array = self.reader.copy(element, "AXChildren")
        if not array:
            return []
        self.arrays.append(array)
        return [self.array_item(array, i) for i in range(self.array_count(array))]

    def set_focused(self, element):
        # The only two attributes written here remain AXFocused and the caret range above.
        return self.set_attribute(element, self.reader.keys["AXFocused"], self.true_value)
