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
                   interrupt_highlight=None, current_main: bool = False, coarse_hits: int = 0,
                   typing_box_returns_keyboard: bool = False, input_pane: str | None = None,
                   agent_flow_running: bool = True, focus_status: str = "fixture focus",
                   proof_sequence: int = 0, focused_sample=None, click_sample=None, click_point=(100, 620)):
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
            focuser=Mock(), completed=Mock(), pending=Mock(), health=HelperHealth(),
            typing_box_returns_keyboard=typing_box_returns_keyboard,
            input_proof=(8, input_pane, proof_sequence) if input_pane else None)
        owner.process_request = lambda request: inspector.Inspector.process_request(owner, request)
        owner.key_count = lambda: int(newer_key)
        owner.focuser.focus.return_value = focus_status
        coarse = Sample(7, 8, Rect(0, 0, 1000, 700), 100, 620, (Node("AXGroup", "", "", Rect(0, 0, 1000, 700)),))
        remaining_coarse_hits = [coarse_hits]
        def read_sample(x, y, pid, focus=False):
            if not focus and remaining_coarse_hits[0] > 0:
                remaining_coarse_hits[0] -= 1
                return coarse  # Chromium's first answer at a new point is often only the window.
            if focus and focused_sample is not None:
                return focused_sample
            if not focus and click_sample is not None:
                return click_sample
            return sample
        owner.reader.sample.side_effect = read_sample
        owner.pending.get.side_effect = [
            (1, click_point[0], click_point[1], 7, time.monotonic() - 1, "ChatGPT.app", "future", gesture, 0),
            StopIteration]
        with patch("inspector.threading.Event") as event, patch("inspector.agent_flow_is_running", return_value=agent_flow_running):
            if interrupt_highlight:
                event.return_value.wait.side_effect = lambda _: interrupt_highlight(owner)
            with self.assertRaises(StopIteration):
                inspector.Inspector.worker(owner)
        return owner

    def test_typing_box_keeps_a_highlight_in_the_pane_that_has_codexs_input(self):
        for gesture in (ClickGesture(click_count=2), ClickGesture(click_count=3), ClickGesture(drag_points=12)):
            with self.subTest(gesture=gesture):
                owner = self.run_worker(gesture, typing_box_returns_keyboard=True, input_pane="Main chat")
                owner.focuser.focus.assert_not_called()
                self.assertEqual(owner.input_proof, (8, "Main chat", 1))  # A kept highlight moved nothing.

    def test_proof_older_than_the_previous_click_focuses_as_usual(self):
        # The fixture highlight's release is sequence 1, and each click advances the sequence twice.
        for gesture, newest_stale in ((ClickGesture(drag_points=12), -2), (ClickGesture(click_count=3), -6)):
            with self.subTest(gesture=gesture, kept=True):  # Only this gesture's own clicks came after the proof.
                self.run_worker(gesture, typing_box_returns_keyboard=True, input_pane="Main chat",
                                proof_sequence=newest_stale + 1).focuser.focus.assert_not_called()
            with self.subTest(gesture=gesture, kept=False):  # One more click, pause or reconnect sits in between.
                self.run_worker(gesture, typing_box_returns_keyboard=True, input_pane="Main chat",
                                proof_sequence=newest_stale).focuser.focus.assert_called_once()

    def test_interrupted_focus_in_the_proven_pane_keeps_the_proof(self):
        # A slow double click: its first click starts a focus that the second click cancels.
        for input_pane, expected in (("Main chat", (8, "Main chat", 1)), ("Side chat", None)):
            with self.subTest(input_pane=input_pane):
                owner = self.run_worker(ClickGesture(), input_pane=input_pane, focus_status="Skipped · request superseded")
                self.assertEqual(owner.input_proof, expected)

    def composer_sample(self, x, y, window_key=8):
        composer = Rect(40, 640, 520, 50)
        return Sample(7, window_key, Rect(0, 0, 1000, 700), x, y, (
            Node("AXTextArea", "", "", composer, True, True),
            Node("AXGroup", "", "", Rect(0, 0, 600, 700), False, False, "AXLandmarkRegion", True),
            Node("AXGroup", "", "fixture-chat-panel", Rect(0, 0, 600, 700))), focus_stable=True)

    def test_control_click_with_a_composer_still_focused_forgets_the_pane(self):
        # The tab or button was sampled before Codex moved focus to another pane's input.
        region = Rect(0, 0, 600, 700)
        button = Sample(7, 8, Rect(0, 0, 1000, 700), 100, 620, (
            Node("AXButton", "", "", Rect(80, 600, 60, 30)),
            Node("AXGroup", "", "", region, False, False, "AXLandmarkRegion", True),
            Node("AXGroup", "", "fixture-chat-panel", region)), focus_stable=True)
        owner = self.run_worker(ClickGesture(), input_pane="Main chat", click_sample=button,
                                focused_sample=self.composer_sample(100, 620))
        owner.focuser.focus.assert_not_called()
        self.assertIsNone(owner.input_proof)

    def test_click_inside_the_focused_composer_proves_its_pane(self):
        owner = self.run_worker(ClickGesture(), click_point=(100, 660), click_sample=self.composer_sample(100, 660),
                                focused_sample=self.composer_sample(100, 660))
        owner.focuser.focus.assert_not_called()
        self.assertEqual(owner.input_proof, (8, "Main chat", 1))

    def test_highlight_in_another_pane_still_focuses_so_the_paste_follows_it(self):
        owner = self.run_worker(ClickGesture(click_count=3), side=True,
                                typing_box_returns_keyboard=True, input_pane="Main chat")
        owner.focuser.focus.assert_called_once()

    def test_unproven_input_pane_focuses_as_usual(self):
        self.run_worker(ClickGesture(click_count=3), typing_box_returns_keyboard=True).focuser.focus.assert_called_once()

    def test_highlight_focuses_as_usual_without_the_typing_box(self):
        self.run_worker(ClickGesture(click_count=3), input_pane="Main chat").focuser.focus.assert_called_once()

    def test_crashed_agent_flow_cannot_leave_highlights_kept(self):
        self.run_worker(ClickGesture(click_count=3), typing_box_returns_keyboard=True, input_pane="Main chat",
                        agent_flow_running=False).focuser.focus.assert_called_once()

    def test_plain_click_still_focuses_while_the_typing_box_returns_keyboard(self):
        self.run_worker(ClickGesture(), typing_box_returns_keyboard=True, input_pane="Main chat").focuser.focus.assert_called_once()

    def test_verified_focus_proves_the_input_pane_and_a_failed_one_forgets_it(self):
        # The earlier proof names the other pane, so only a verified write can prove this one.
        for status, expected in (("Focused Main chat input · verified · caret · held", "Main chat"),
                                 ("Focus sent to Main chat input · not confirmed", None),
                                 ("Skipped · no pane input found within the search limit", None)):
            with self.subTest(status=status):
                owner = self.run_worker(ClickGesture(), input_pane="Side chat", focus_status=status)
                self.assertEqual(owner.input_proof, (8, expected, 1) if expected else None)

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
