"""Regress the former capture-receipt veto using the real worker and fake AX only."""
import time
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

from helper_runtime import HelperHealth
from pane_model import ClickGesture, Node, PaneModel, Rect, Sample
import inspector


class ClickFocusTests(unittest.TestCase):
    def run_worker(self, gesture: ClickGesture, *, side: bool = False,
                   newer_click: bool = False, newer_key: bool = False,
                   paused: bool = False, focus_inputs: bool = True,
                   interrupt_highlight=None, current_main: bool = False):
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
        owner.reader.sample.return_value = sample
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
