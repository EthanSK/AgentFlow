"""Regress the former capture-receipt veto using the real worker and fake AX only."""
import time
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

from helper_runtime import HelperHealth
from pane_model import ClickGesture, Node, PaneModel, Rect, Sample
import inspector


class ClaudeClickRoutingTests(unittest.TestCase):
    def route(self, gesture: ClickGesture, *, newer_click: bool = False):
        owner = SimpleNamespace(sequence=2 if newer_click else 1, paused=False, focus_inputs=True,
                                reader=Mock(), claude_click_focuser=Mock(), key_count=lambda: 0)
        owner.focus_claude_click = lambda *args: inspector.Inspector.focus_claude_click(owner, *args)
        owner.claude_click_focuser.focus_clicked_pane.return_value = "fixture status"
        inspector.Inspector.process_request(owner, (1, 100, 620, 7, time.monotonic() - 1, inspector.CLAUDE_BUNDLE_ID, "", gesture, 0))
        return owner

    def test_plain_click_focuses_the_clicked_claude_pane_without_reading_codex(self):
        owner = self.route(ClickGesture())
        owner.claude_click_focuser.focus_clicked_pane.assert_called_once()
        self.assertEqual(owner.claude_click_focuser.focus_clicked_pane.call_args.args[:2], (7, (100, 620)))
        owner.reader.sample.assert_not_called()

    def test_selecting_text_in_claude_keeps_the_selection(self):
        for gesture in (ClickGesture(drag_points=12), ClickGesture(click_count=2), ClickGesture(click_count=3), ClickGesture(modifier_held=True)):
            with self.subTest(gesture=gesture):
                self.route(gesture).claude_click_focuser.focus_clicked_pane.assert_not_called()

    def test_newer_click_cancels_the_claude_focus(self):
        self.route(ClickGesture(), newer_click=True).claude_click_focuser.focus_clicked_pane.assert_not_called()


class ClickFocusTests(unittest.TestCase):
    def run_worker(self, gesture: ClickGesture, *, side: bool = False,
                   newer_click: bool = False, newer_key: bool = False,
                   paused: bool = False, focus_inputs: bool = True,
                   interrupt_highlight=None, current_main: bool = False, coarse_hits: int = 0):
        region = Rect(0, 0, 600, 700)
        marker = "app-shell-tab-panel-app-shell-tab:68" if side else "fixture-chat-panel"
        if current_main:
            marker = ""  # The current main portal no longer supplies the old chat-panel id.
        sample = Sample(7, 8, Rect(0, 0, 1000, 700), 100, 620, (
            Node("AXGroup", "", "", region, True, False, "AXLandmarkRegion", True),
            Node("AXGroup", "", marker, region, subrole="AXTabPanel" if side else "",
                 main_content=current_main)), focus_stable=True)
        owner = SimpleNamespace(sequence=2 if newer_click else 1, paused=paused,
            reader=Mock(), model=PaneModel(), focus_inputs=focus_inputs,
            focuser=Mock(), completed=Mock(), pending=Mock(), health=HelperHealth())
        owner.process_request = lambda request: inspector.Inspector.process_request(owner, request)
        owner.key_count = lambda: int(newer_key)
        owner.focuser.focus.return_value = "fixture focus"
        coarse = Sample(7, 8, Rect(0, 0, 1000, 700), 100, 620, (Node("AXGroup", "", "", Rect(0, 0, 1000, 700)),))
        remaining_coarse_hits = [coarse_hits]
        def read_sample(x, y, pid, focus=False):
            if not focus and remaining_coarse_hits[0] > 0:
                remaining_coarse_hits[0] -= 1
                return coarse  # Chromium's first answer at a new point is often only the window.
            return sample
        owner.reader.sample.side_effect = read_sample
        owner.pending.get.side_effect = [
            (1, 100, 620, 7, time.monotonic() - 1, "ChatGPT.app", "future", gesture, 0),
            StopIteration]
        with patch("inspector.threading.Event") as event:
            if interrupt_highlight:
                event.return_value.wait.side_effect = lambda _: interrupt_highlight(owner)
            with self.assertRaises(StopIteration):
                inspector.Inspector.worker(owner)
        return owner

    def test_single_double_triple_and_later_clicks_focus_without_capture(self):
        for side in (False, True):
            for clicks in (1, 2, 3, 4):
                with self.subTest(side=side, clicks=clicks):
                    owner = self.run_worker(ClickGesture(click_count=clicks), side=side)
                    owner.focuser.focus.assert_called_once()
                    self.assertEqual(owner.focuser.focus.call_args.args[2],
                                     "Side chat" if side else "Main chat")

    def test_drag_and_modified_text_clicks_focus_without_capture(self):
        for gesture in (ClickGesture(drag_points=12), ClickGesture(modifier_held=True),
                        ClickGesture(click_count=3, modifier_held=True)):
            with self.subTest(gesture=gesture):
                self.run_worker(gesture).focuser.focus.assert_called_once()

    def test_current_main_portal_clicks_reach_the_existing_focus_writer(self):
        for clicks in (1, 2, 3, 4):
            owner = self.run_worker(ClickGesture(click_count=clicks), current_main=True)
            owner.focuser.focus.assert_called_once()
            self.assertEqual(owner.focuser.focus.call_args.args[2], "Main chat")

    def test_window_sized_first_answers_are_reread_until_the_chat_is_found(self):
        for coarse_hits in (1, 2, 3):
            with self.subTest(coarse_hits=coarse_hits):
                owner = self.run_worker(ClickGesture(), coarse_hits=coarse_hits, current_main=True)
                owner.focuser.focus.assert_called_once()
                self.assertEqual(owner.focuser.focus.call_args.args[2], "Main chat")

    def test_hit_retest_is_bounded_when_the_answer_stays_window_sized(self):
        owner = self.run_worker(ClickGesture(), coarse_hits=99)
        hit_reads = [call for call in owner.reader.sample.call_args_list if not call.kwargs.get("focus")]
        self.assertEqual(len(hit_reads), 1 + inspector.HIT_RETEST_ATTEMPTS)

    def test_precise_first_answer_is_not_reread(self):
        owner = self.run_worker(ClickGesture())
        hit_reads = [call for call in owner.reader.sample.call_args_list if not call.kwargs.get("focus")]
        self.assertEqual(len(hit_reads), 1)

    def test_new_click_during_hit_retest_cancels_focus(self):
        owner = self.run_worker(ClickGesture(), coarse_hits=1,
            interrupt_highlight=lambda current: setattr(current, "sequence", 2))
        owner.focuser.focus.assert_not_called()

    def test_superseded_click_does_not_focus(self):
        self.run_worker(ClickGesture(click_count=3), newer_click=True).focuser.focus.assert_not_called()

    def test_typing_since_click_does_not_focus(self):
        self.run_worker(ClickGesture(click_count=3), newer_key=True).focuser.focus.assert_not_called()

    def test_pause_and_focus_preference_still_apply(self):
        self.run_worker(ClickGesture(click_count=3), paused=True).focuser.focus.assert_not_called()
        self.run_worker(ClickGesture(click_count=3), focus_inputs=False).focuser.focus.assert_not_called()

    def test_new_click_during_existing_highlight_wait_cancels_focus(self):
        owner = self.run_worker(ClickGesture(click_count=3),
            interrupt_highlight=lambda current: setattr(current, "sequence", 2))
        owner.focuser.focus.assert_not_called()

    def test_pause_during_existing_highlight_wait_cancels_focus(self):
        owner = self.run_worker(ClickGesture(click_count=3),
            interrupt_highlight=lambda current: setattr(current, "paused", True))
        owner.focuser.focus.assert_not_called()
