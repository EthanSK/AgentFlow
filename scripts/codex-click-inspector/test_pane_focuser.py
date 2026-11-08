"""Fake-AX checks for the opt-in pane-input focus. Never touches the live desktop."""
import time
import unittest
from unittest.mock import patch
from collections import Counter
import pane_focuser
from pane_focuser import PaneInputFocuser, MAX_SEARCH_NODES
from pane_model import Rect, Node, Sample, Observation, PaneModel, input_focus_plan

REGION_FRAME = Rect(1313, 197, 671, 1007)  # Side Conversation region measured live 2026-10-17.


class FakeReader:
    def __init__(self):
        self.keys = {"AXFocused": "AXFocused", "AXSelectedTextRange": "AXSelectedTextRange"}
        self.deadline, self.errors = 0, []
        self.frontmost, self.refs = 42, Counter()
        # Measured shape: messages first, input wrapper last, input 6 levels down.
        self.tree = {"region": ["history", "wrap1"], "history": [f"msg{i}" for i in range(50)]}
        self.attrs = {"region": {"AXRole": "AXGroup", "AXSubrole": "AXLandmarkRegion", "AXDescription": "Conversation",
                                 "frame": REGION_FRAME},
                      "input": {"AXRole": "AXTextArea", "AXDescription": "Work with Codex",
                                "frame": Rect(1341, 1104, 615, 44)}}
        for depth in range(1, 6):
            self.tree[f"wrap{depth}"] = [f"wrap{depth + 1}"] if depth < 5 else ["input"]
        self.focused = "region"
        self.window = "window"
        self.on_children = None
        self.system, self.hit_element, self.hit_owner = 900, 100, 42
        self.attrs[100] = dict(self.attrs["region"])
        self.tree[100] = self.tree["region"]
        self.hit_points = []

    def hit(self, system, x, y, output):
        self.hit_points.append((x, y))
        output._obj.value = self.hit_element
        self.refs.update([self.hit_element])
        return 0

    def get_pid(self, element, output):
        output._obj.value = self.hit_owner
        return 0

    def frontmost_pid(self):
        return self.frontmost

    def create_app(self, pid):
        self.refs.update(["app"])
        return "app"

    def copy(self, element, name):
        if name == "AXParent":
            parent = next((p for p, children in self.tree.items() if element in children), None)
            if parent:
                self.refs.update([parent])
            return parent
        if name == "AXWindow":
            self.refs.update([self.window])
            return self.window
        assert name == "AXFocusedUIElement", name
        if self.focused:
            self.refs.update([self.focused])
        return self.focused

    def text(self, element, name):
        return self.attrs.get(element, {}).get(name, "")

    def rect(self, element):
        return self.attrs.get(element, {}).get("frame")

    def equal(self, a, b):
        return a == b

    def hash(self, value):
        return hash(value)

    def retain(self, value):
        self.refs.update([value])
        return value

    def release(self, value):
        self.refs.subtract([value])


class FakeFocuser(PaneInputFocuser):
    def __init__(self, reader):
        self.reader, self.arrays, self.writes, self.children_calls = reader, [], [], 0
        self.follow_write = True
        self.caret_writes, self.draft_length = [], 7
        self.selected_length = 0

    def selection_length(self, target):
        return self.selected_length

    def character_count(self, element):
        return self.draft_length

    def make_range(self, location):
        value = ("range", location)
        self.reader.retain(value)  # AXValueCreate returns an owned value.
        return value

    def set_attribute(self, element, key, value):
        self.caret_writes.append((element, key, value))
        return 0

    def children(self, element):
        self.children_calls += 1
        if self.reader.on_children:
            self.reader.on_children()
        return list(self.reader.tree.get(element, []))

    def set_focused(self, element):
        self.writes.append(element)
        if self.follow_write:
            self.reader.focused = element
        return 0


class PaneFocuserTests(unittest.TestCase):
    def setUp(self):
        pane_focuser.HOLD_CHECK_SECONDS = 0.01  # Keep the later re-read fast in fixtures.
        self.reader = FakeReader()
        self.focuser = FakeFocuser(self.reader)

    def run_focus(self):
        status = self.focuser.focus(42, REGION_FRAME, "Side chat")
        self.assertTrue(all(n == 0 for n in self.reader.refs.values()), self.reader.refs)
        return status

    def test_focuses_the_input_inside_the_clicked_conversation_region(self):
        self.assertEqual(self.run_focus(), "Focused Side chat input · verified · caret placed at end · still focused at 0.01 s")
        self.assertEqual(self.focuser.writes, ["input"])
        self.assertLess(self.focuser.children_calls, 10)  # Last child first: chat history is not walked.

    def test_caret_goes_to_the_end_of_the_existing_draft_only_after_verified_focus(self):
        # Live 2026-10-17: focus held 0.6 s but no caret showed until a range is set.
        self.run_focus()
        self.assertEqual(self.focuser.caret_writes, [("input", "AXSelectedTextRange", ("range", 7))])
        self.focuser.caret_writes.clear()
        self.focuser.follow_write = False  # Unverified focus: never move the caret.
        self.run_focus()
        self.assertEqual(self.focuser.caret_writes, [])

    def test_unreadable_length_skips_the_caret_but_keeps_focus(self):
        self.focuser.draft_length = None
        self.assertIn("caret not placed (length unreadable)", self.run_focus())
        self.assertEqual(self.focuser.caret_writes, [])

    def test_hold_check_recovers_once_when_codex_takes_focus_back(self):
        # Live 2026-10-17: verified immediately, yet Ethan saw no caret.
        original_sleep = pane_focuser.time.sleep
        def sleep(seconds):
            if 0 < seconds <= pane_focuser.HOLD_CHECK_SECONDS:
                self.reader.focused = "region"  # Codex refocuses the chat area.
            original_sleep(seconds)
        pane_focuser.time.sleep = sleep
        try:
            self.assertEqual(self.run_focus(),
                             "Focused Side chat input · verified · caret placed at end · focus recovered once · verified · caret placed at end")
        finally:
            pane_focuser.time.sleep = original_sleep
        self.assertEqual(self.focuser.writes, ["input", "input"])

    def test_body_click_renews_a_composer_which_still_claims_focus(self):
        self.reader.focused = "input"
        self.assertIn("verified", self.run_focus())
        self.assertEqual(self.focuser.writes, ["region", "input"])
        self.assertEqual(len(self.focuser.caret_writes), 1)

    def test_already_focused_selection_is_preserved(self):
        self.reader.focused = "input"
        for selected in (5, None):
            self.focuser.selected_length = selected
            self.assertIn("selection", self.run_focus())
        self.assertEqual(self.focuser.writes, [])

    def test_another_editor_in_the_same_region_is_not_replaced(self):
        self.reader.tree["history"].append("note")
        self.reader.attrs["note"] = {"AXRole": "AXTextArea", "AXDescription": "Edit message"}
        self.reader.focused = "note"
        self.assertIn("another editor", self.run_focus())
        self.assertEqual(self.focuser.writes, [])

    def test_late_recovery_never_fights_new_input_app_window_or_selection(self):
        original_sleep = pane_focuser.time.sleep
        for change in (lambda: setattr(self.reader, "frontmost", 99),
                       lambda: setattr(self.reader, "window", "changed"),
                       lambda: setattr(self.reader, "focused", "other-input"),
                       lambda: setattr(self.focuser, "selected_length", 4),
                       lambda: current.__setitem__(0, False)):
            self.setUp()
            current = [True]
            def sleep(seconds):
                if 0 < seconds <= pane_focuser.HOLD_CHECK_SECONDS:
                    self.reader.focused = "region"
                    change()
                original_sleep(seconds)
            pane_focuser.time.sleep = sleep
            try:
                self.focuser.focus(42, REGION_FRAME, "Side chat", is_current=lambda: current[0],
                                   window_key=hash("window"))
            finally:
                pane_focuser.time.sleep = original_sleep
            self.assertEqual(self.focuser.writes, ["input"])
            self.assertTrue(all(n == 0 for n in self.reader.refs.values()), self.reader.refs)

    def test_proven_click_can_focus_a_different_pane_without_a_reset_hop(self):
        self.reader.focused = "old-input"
        self.reader.attrs["old-input"] = {"AXRole": "AXTextArea", "AXDescription": "Work with Codex"}
        status = self.focuser.focus(42, REGION_FRAME, "Side chat", window_key=hash("window"),
                                    click_point=(1400, 500))
        self.assertIn("verified", status)
        self.assertEqual(self.focuser.writes, ["input"])
        self.assertEqual(self.reader.hit_points, [(1400, 500)])
        self.assertTrue(all(n == 0 for n in self.reader.refs.values()), self.reader.refs)

    def test_current_main_plan_and_writer_leave_the_old_side_composer(self):
        window = Rect(0, 0, 2200, 1400)
        clicked = Sample(42, hash("window"), window, 1400, 500, (
            Node("AXGroup", "", "", REGION_FRAME, subrole="AXLandmarkRegion", conversation=True),
            Node("AXGroup", "", "", REGION_FRAME, main_content=True)))
        old_input_frame = Rect(100, 1100, 500, 44)
        focused = Sample(42, hash("window"), window, 350, 1122, (
            Node("AXTextArea", "", "", old_input_frame, True, True),
            Node("AXGroup", "", "", Rect(0, 0, 1000, 1400), conversation=True),
            Node("AXGroup", "", "app-shell-tab-panel-app-shell-tab:68", None, subrole="AXTabPanel")),
            focus_stable=True)
        pane, frame = input_focus_plan(PaneModel(), Observation(clicked, focused, 1, host="ChatGPT.app"))
        self.assertEqual((pane, frame), ("Main chat", REGION_FRAME))
        self.reader.focused = "old-input"
        self.reader.attrs["old-input"] = {"AXRole": "AXTextArea", "AXDescription": "Work with Codex",
                                           "frame": old_input_frame}
        status = self.focuser.focus(42, frame, pane, window_key=clicked.window_key,
                                    click_point=(clicked.x, clicked.y))
        self.assertIn("Focused Main chat input · verified", status)
        self.assertEqual(self.focuser.writes, ["input"])
        self.assertEqual(self.reader.hit_points, [(1400, 500)])
        self.assertTrue(all(n == 0 for n in self.reader.refs.values()), self.reader.refs)

    def test_proven_click_can_leave_a_non_editor_control(self):
        self.reader.focused = "button"
        self.reader.attrs["button"] = {"AXRole": "AXButton"}
        status = self.focuser.focus(42, REGION_FRAME, "Side chat", click_point=(1400, 500))
        self.assertIn("verified", status)
        self.assertEqual(self.focuser.writes, ["input"])

    def test_new_hit_must_still_match_owner_region_and_original_window(self):
        for change in (lambda: setattr(self.reader, "hit_owner", 99),
                       lambda: self.reader.attrs[100].update(frame=Rect(0, 0, 500, 500)),
                       lambda: setattr(self.reader, "window", "changed")):
            self.setUp()
            self.reader.focused = "button"
            self.reader.attrs["button"] = {"AXRole": "AXButton"}
            change()
            self.focuser.focus(42, REGION_FRAME, "Side chat", window_key=hash("window"),
                               click_point=(1400, 500))
            self.assertEqual(self.focuser.writes, [])
            self.assertTrue(all(n == 0 for n in self.reader.refs.values()), self.reader.refs)

    def test_new_hit_never_overrides_another_editor_or_selected_composer(self):
        for description, selection in (("Edit message", 0), ("Work with Codex", 4), ("Work with Codex", None)):
            self.setUp()
            self.reader.focused = "old-input"
            self.reader.attrs["old-input"] = {"AXRole": "AXTextArea", "AXDescription": description}
            self.focuser.selected_length = selection
            self.focuser.focus(42, REGION_FRAME, "Side chat", click_point=(1400, 500))
            self.assertEqual(self.focuser.writes, [])
            self.assertEqual(self.reader.hit_points, [])

    def test_superseded_hold_check_releases_worker_after_one_short_slice(self):
        current = iter((True, False))
        pane_focuser.HOLD_CHECK_SECONDS = 0.6
        try:
            with patch("pane_focuser.time.sleep") as sleep:
                result = self.focuser.hold_check("app", "input", is_current=lambda: next(current))
            self.assertEqual(result, "Skipped · request superseded")
            sleep.assert_called_once_with(pane_focuser.VERIFY_INTERVAL_SECONDS)
        finally:
            pane_focuser.HOLD_CHECK_SECONDS = 0.01

    def test_supersession_between_reset_and_refocus_stops_the_write(self):
        self.reader.focused = "input"
        current = [True]
        original = self.focuser.set_focused
        def write(element):
            error = original(element)
            if element == "region":
                current[0] = False
            return error
        self.focuser.set_focused = write
        status = self.focuser.focus(42, REGION_FRAME, "Side chat", is_current=lambda: current[0])
        self.assertIn("superseded during focus reset", status)
        self.assertEqual(self.focuser.writes, ["region"])
        self.assertEqual(self.focuser.caret_writes, [])

    def test_no_write_when_focus_is_not_that_region(self):
        self.reader.focused = "input-of-other-pane"
        self.assertIn("Skipped", self.run_focus())
        self.assertEqual(self.focuser.writes, [])

    def test_no_write_when_region_frame_changed(self):
        self.reader.attrs["region"]["frame"] = Rect(0, 0, 10, 10)
        self.assertIn("Skipped", self.run_focus())
        self.assertEqual(self.focuser.writes, [])

    def test_no_write_when_focus_moves_during_lookup(self):
        def move():
            self.reader.focused = "elsewhere"
        self.reader.on_children = move
        self.assertEqual(self.run_focus(), "Skipped · focus moved during the input lookup")
        self.assertEqual(self.focuser.writes, [])

    def test_no_write_when_codex_is_no_longer_frontmost(self):
        self.reader.frontmost = 7
        self.assertIn("no longer frontmost", self.run_focus())
        self.assertEqual(self.focuser.writes, [])

    def test_superseded_request_never_writes_even_if_region_is_reused(self):
        current = [True]
        self.reader.on_children = lambda: current.__setitem__(0, False)
        self.assertIn("Skipped", self.focuser.focus(42, REGION_FRAME, "Side chat", is_current=lambda: current[0]))
        self.assertEqual(self.focuser.writes, [])

    def test_window_replacement_with_identical_bounds_never_writes(self):
        self.assertIn("window changed", self.focuser.focus(42, REGION_FRAME, "Main chat", window_key=hash("old-window")))
        self.assertEqual(self.focuser.writes, [])

    def test_window_or_pid_replacement_during_lookup_never_writes(self):
        for change in (lambda: setattr(self.reader, "window", "replacement-window"),
                       lambda: setattr(self.reader, "frontmost", 99)):
            self.setUp()
            expected = hash(self.reader.window)
            self.reader.on_children = change
            self.assertIn("Skipped", self.focuser.focus(42, REGION_FRAME, "Side chat", window_key=expected))
            self.assertEqual(self.focuser.writes, [])

    def test_new_selection_is_never_collapsed_by_caret_placement(self):
        for length in (5, None):
            self.focuser.selected_length = length
            self.focuser.caret_writes.clear()
            self.run_focus()
            self.assertEqual(self.focuser.caret_writes, [])

    def test_superseded_after_focus_write_does_not_move_caret(self):
        current = [True]
        original = self.focuser.set_focused
        def write(element):
            result = original(element)
            current[0] = False
            return result
        self.focuser.set_focused = write
        status = self.focuser.focus(42, REGION_FRAME, "Main chat", is_current=lambda: current[0])
        self.assertIn("caret not placed", status)
        self.assertEqual(self.focuser.caret_writes, [])

    def test_no_write_without_a_matching_input_inside_the_region(self):
        self.reader.attrs["input"]["frame"] = Rect(10, 10, 100, 40)  # Outside the region.
        self.assertIn("no pane input found", self.run_focus())
        self.reader.attrs["input"].update(frame=Rect(1341, 1104, 615, 44), AXDescription="Edit message")
        self.assertIn("no pane input found", self.run_focus())
        self.assertEqual(self.focuser.writes, [])

    def test_search_is_bounded_on_a_huge_region(self):
        self.reader.tree = {"region": [f"n{i}" for i in range(5000)]}
        start = time.monotonic()
        self.assertIn("no pane input found", self.run_focus())
        self.assertLessEqual(self.focuser.children_calls, MAX_SEARCH_NODES + 1)
        self.assertLess(time.monotonic() - start, 1.0)

    def test_unconfirmed_write_is_reported_not_claimed(self):
        self.focuser.follow_write = False
        self.assertEqual(self.run_focus(), "Focus sent to Side chat input · not confirmed")
        self.assertEqual(self.focuser.writes, ["input"])  # Waiting never re-writes.

    def test_async_focus_is_verified_within_the_bounded_wait(self):
        # Live 2026-10-17: Chromium had not applied the focus on the first re-read.
        self.focuser.follow_write = False
        reads = {"n": 0}
        original_copy = self.reader.copy
        def delayed_copy(element, name):
            if self.focuser.writes:
                reads["n"] += 1
                if reads["n"] == 3:
                    self.reader.focused = "input"
            return original_copy(element, name)
        self.reader.copy = delayed_copy
        self.assertTrue(self.run_focus().startswith("Focused Side chat input · verified"))
        self.assertEqual(self.focuser.writes, ["input"])


if __name__ == "__main__":
    unittest.main()
