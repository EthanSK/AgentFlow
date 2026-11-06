"""Focus Claude desktop's Prompt box when Agent Flow stops recording.

Ethan approved this on 2026-10-19 (option 2 of the Claude paste investigation).
Agent Flow's Primary finish pastes into whatever has keyboard focus, and Claude
drops that paste once a click on its conversation or one of its buttons has
moved focus off the Prompt box. Live trace 2026-10-19 15:05: a next-step button
click, then Command-V and Return posted into frontmost Claude; nothing arrived
until Ethan pasted by hand 30 s later. Codex avoids this by routing a paste to
its remembered input, which is why it never needed this.

The trigger is Agent Flow's existing `recordingStopped` broadcast. Ethan
approved this one consumer next to the YouTube bridge. A click watcher alone was
rejected because it must skip drags, so it cannot fix a highlight. Changing
Agent Flow's Primary delivery was rejected because Primary must stay
app-blind (AGENTS.md "Primary isolation"). Agent Flow's own Command-V and Return
are unchanged; this only prepares Claude's focus before they arrive.

The only writes are AXFocused and the end-of-draft caret, both inherited from
PaneInputFocuser. It never clicks, types, pastes, sends or reads message text.
"""
import time

from pane_focuser import PaneInputFocuser, VERIFY_SECONDS, VERIFY_INTERVAL_SECONDS

ENABLED = False  # Ethan disabled it 2026-10-19 after it never fired live: typing-only Agent Flow sessions post no recordingStopped (Recorder.swift sets recordingActivityStarted only once the mic starts). Needs a trigger that covers typing before re-enabling.
CLAUDE_BUNDLE_ID = "com.anthropic.claudefordesktop"
RECORDING_STOPPED = "com.ethansk.voiceink.recordingStopped"  # Must match Agent Flow's RecordingActivityNotifier.
# Measured on Claude 2.42304.0 (2026-10-19): the composer is an AXTextArea named
# "Prompt" inside an AXGroup named "Primary pane". Not pinned to that version:
# Claude updates often, and a changed tree only makes this skip, never misfire.
PROMPT_DESCRIPTION = "Prompt"
PANE_SUFFIX = " pane"
MAX_ANCESTORS = 80  # The Prompt sat 34 levels below the window.
MAX_PANE_DEPTH, MAX_PANE_NODES = 24, 600  # A walk that stops at panes visited 325 nodes; the pane sat 15 deep.
MAX_PROMPT_DEPTH, MAX_PROMPT_NODES = 40, 400  # Last child first reached the Prompt at node 71 of 1,336.
BUDGET_SECONDS = 1.0  # Agent Flow pasted 1.2 s after a typed-only stop, so stay well inside that.


class ClaudePromptFocuser(PaneInputFocuser):
    """Puts the caret in Claude's Prompt box so a following Agent Flow paste lands there."""

    def __init__(self, reader):
        super().__init__(reader)
        reader.keys.setdefault("AXMainWindow", reader.string(None, b"AXMainWindow", 0x08000100))

    def focus_prompt(self, pid):
        """Focuses the Prompt box of the pane Ethan is in; returns a status line with no message text."""
        r = self.reader
        r.deadline, r.errors = time.monotonic() + BUDGET_SECONDS, []
        app = focused = pane = window = target = check = None
        try:
            if r.frontmost_pid() != pid:
                return "Skipped · Claude is not frontmost"
            app = r.create_app(pid)
            # Unreadable while Agent Flow's typing box still holds the keyboard.
            focused = r.copy(app, "AXFocusedUIElement") if app else None
            if focused:
                role = r.text(focused, "AXRole")
                if self.is_prompt(focused):
                    return "Skipped · Prompt already focused"
                if r.editable(focused, role):
                    # Primary pastes where Ethan last typed, such as a rename field.
                    return "Skipped · another text input has focus"
                pane = self.pane_holding(focused)
            if pane is None:
                window = r.copy(app, "AXMainWindow") if app else None
                if not window:
                    return "Skipped · Claude window unreadable"
                pane, reason = self.only_pane(window)
                if pane is None:
                    return f"Skipped · {reason}"
            target = self.find_prompt(pane)
            if target is None:
                return "Skipped · no Prompt box found within the search limit"
            # Read on the element itself: app-level focus can be unreadable here.
            if r.boolean(target, "AXFocused"):
                return "Skipped · Prompt already focused"
            # Last check before the only write: Ethan may have switched apps or
            # clicked into another input while the bounded search ran.
            r.deadline = time.monotonic() + 0.1
            if r.frontmost_pid() != pid:
                return "Skipped · Claude stopped being frontmost during the lookup"
            check = r.copy(app, "AXFocusedUIElement")
            if focused and (not check or not r.equal(check, focused)):
                return "Skipped · focus moved during the lookup"
            if not focused and check and r.editable(check, r.text(check, "AXRole")):
                return "Skipped · a text input took focus during the lookup"
            error = self.set_focused(target)
            if error:
                return f"Failed · Claude refused the focus write ({error})"
            # Chromium applies the write asynchronously; re-read only, never re-write.
            give_up = time.monotonic() + VERIFY_SECONDS
            while True:
                r.deadline = time.monotonic() + 0.05
                if r.boolean(target, "AXFocused"):
                    return f"Focused Claude Prompt · verified · {self.place_caret(target)}"
                if time.monotonic() >= give_up:
                    return "Focus sent to Claude Prompt · not confirmed"
                time.sleep(VERIFY_INTERVAL_SECONDS)
        finally:
            for value in (check, target, window, pane, focused, app):
                if value:
                    r.release(value)
            for array in self.arrays:
                r.release(array)
            self.arrays = []

    def is_prompt(self, element):
        r = self.reader
        return r.text(element, "AXRole") == "AXTextArea" and r.text(element, "AXDescription") == PROMPT_DESCRIPTION

    def is_pane(self, element):
        r = self.reader
        return r.text(element, "AXRole") == "AXGroup" and r.text(element, "AXDescription").endswith(PANE_SUFFIX)

    def pane_holding(self, focused):
        """Returns a retained pane group above the focused element, or None (e.g. focus is in the sidebar)."""
        r = self.reader
        current = focused
        r.retain(current)
        for _ in range(MAX_ANCESTORS):
            if self.is_pane(current):
                return current
            parent = r.copy(current, "AXParent")
            r.release(current)
            if not parent:
                return None
            current = parent
        r.release(current)
        return None

    def only_pane(self, window):
        """Returns (retained pane, "") when the window has exactly one, else (None, reason).

        With no focused element to place Ethan, a split view is ambiguous, so the
        walk must finish and find exactly one pane before anything is focused.
        """
        r = self.reader
        stack, visited, panes = [(window, 0)], 0, []
        while stack:
            if visited >= MAX_PANE_NODES or time.monotonic() >= r.deadline:
                return None, "pane search hit its limit"
            element, depth = stack.pop()
            visited += 1
            if depth and self.is_pane(element):
                panes.append(element)
                continue  # Never walk the conversation itself here.
            if depth < MAX_PANE_DEPTH:
                stack.extend((child, depth + 1) for child in self.children(element))
        if len(panes) != 1:
            return None, f"{len(panes)} panes and none holds focus"
        r.retain(panes[0])
        return panes[0], ""

    def find_prompt(self, pane):
        """Returns a retained Prompt box inside the pane, searching last children first, or None."""
        stack, visited = [(child, 1) for child in self.children(pane)], 0
        while stack and visited < MAX_PROMPT_NODES and time.monotonic() < self.reader.deadline:
            element, depth = stack.pop()
            visited += 1
            if self.is_prompt(element):
                self.reader.retain(element)
                return element
            if depth < MAX_PROMPT_DEPTH:
                stack.extend((child, depth + 1) for child in self.children(element))
        return None
