"""Synthetic-only checks. Run on the Mini; never interrogate a live Codex tree."""
import unittest
from dataclasses import replace
from pane_model import Node, PaneModel, Rect, Sample, Observation, Diagnostics, describe
import json
from pathlib import Path


class PaneModelTests(unittest.TestCase):
    def setUp(self):
        self.model = PaneModel()
        self.sample = Sample(42, 8, Rect(0, 0, 1000, 700), 100, 200, (
            Node("AXStaticText", "", "", Rect(50, 150, 180, 100)),
            Node("AXGroup", "", "", Rect(0, 0, 600, 700)),
            Node("AXWindow", "", "", Rect(0, 0, 1000, 700)),
        ))

    def test_missing_identifiers_is_unknown_not_main_by_default(self):
        self.assertEqual(self.model.classify(self.sample)[0], "Unknown")

    def test_explicit_main_marker(self):
        s = replace(self.sample, nodes=(Node("AXGroup", "main-chat", "", None),))
        self.assertEqual(self.model.classify(s)[0], "Main chat")

    def test_explicit_side_dom_marker_and_camelcase(self):
        for marker in ("side-chat", "sideChat", "app:side-chat:body"):
            s = replace(self.sample, nodes=(Node("AXGroup", "", marker, None),))
            self.assertEqual(self.model.classify(s)[0], "Side chat")

    def test_sidebar_does_not_imply_side_chat(self):
        s = replace(self.sample, nodes=(Node("AXGroup", "sidebar", "side-chatter", None),))
        self.assertEqual(self.model.classify(s)[0], "Unknown")

    def test_conflicting_markers_fail_closed(self):
        s = replace(self.sample, nodes=(Node("AXGroup", "main-chat", "side-chat", None),))
        self.assertEqual(self.model.classify(s)[0], "Unknown")

    def test_learned_region_has_explicitly_different_evidence(self):
        self.assertTrue(self.model.learn("Main chat", self.sample, 1))
        pane, evidence = self.model.classify(self.sample)
        self.assertEqual(pane, "Main chat")
        self.assertTrue(evidence.startswith("Learned region"))

    def test_other_process_window_or_layout_never_reuses_region(self):
        self.model.learn("Main chat", self.sample, 1)
        for s in (replace(self.sample, pid=43), replace(self.sample, window_key=9),
                  replace(self.sample, window=Rect(1, 0, 1000, 700))):
            self.assertEqual(self.model.classify(s)[0], "Unknown")

    def test_overlapping_regions_are_unknown(self):
        self.model.learn("Main chat", self.sample, 1)
        self.model.learn("Side chat", self.sample, 1)
        self.assertEqual(self.model.classify(self.sample)[0], "Unknown")

    def test_no_window_or_whole_window_cannot_be_calibrated(self):
        self.assertFalse(self.model.learn("Main chat", self.sample, 2))
        self.assertFalse(self.model.learn("Main chat", replace(self.sample, window=None), 0))

    def test_failed_read_does_not_use_retained_region(self):
        self.model.learn("Main chat", self.sample, 1)
        self.assertEqual(self.model.classify(replace(self.sample, error="Read unavailable"))[0], "Unknown")

    def test_point_outside_container_cannot_teach_a_region(self):
        self.assertFalse(self.model.learn("Side chat", replace(self.sample, x=900), 1))

    def focus(self, marker="main-chat", **kwargs):
        return replace(self.sample, nodes=(
            Node("AXTextArea", "", "", Rect(50, 600, 400, 60), True, True),
            Node("AXGroup", marker, "", Rect(0, 0, 600, 700)),
            Node("AXWindow", "", "", self.sample.window)), x=250, y=630, **kwargs)

    def test_confirmed_focused_input_can_have_different_pane_from_click(self):
        click = replace(self.sample, nodes=(Node("AXGroup", "main-chat", "", None),))
        result = describe(self.model, Observation(click, self.focus("side-chat"), 1))
        self.assertEqual((result[0], result[2], result[4]), ("Main chat", "Side chat", "Different panes"))

    def test_same_pane_label_in_other_window_is_not_a_match(self):
        click = self.focus()
        result = describe(self.model, Observation(click, replace(click, window_key=9), 1))
        self.assertEqual(result[4], "Different windows")

    def test_focused_non_editor_does_not_claim_keyboard_input(self):
        sample = self.focus()
        for role, focused, editable in (("AXGroup", True, True), ("AXTextArea", None, True),
                                         ("AXTextArea", False, True), ("AXTextField", True, None),
                                         ("AXSecureTextField", True, True)):
            leaf = replace(sample.nodes[0], role=role, focused=focused, editable=editable)
            self.assertEqual(self.model.classify_focus(replace(sample, nodes=(leaf,) + sample.nodes[1:]))[0], "Unknown")

    def test_focus_must_use_its_own_bounds_not_click_position(self):
        self.model.learn("Main chat", self.sample, 1)
        sample = self.focus("")
        self.assertEqual(self.model.classify_focus(sample)[0], "Main chat")
        leaf = replace(sample.nodes[0], frame=Rect(550, 600, 400, 60))
        self.assertEqual(self.model.classify_focus(replace(sample, nodes=(leaf,) + sample.nodes[1:]))[0], "Unknown")

    def test_divider_resize_invalidates_learned_container(self):
        self.model.learn("Main chat", self.sample, 1)
        changed = replace(self.sample.nodes[1], frame=Rect(0, 0, 400, 700))
        self.assertEqual(self.model.classify(replace(self.sample, nodes=(self.sample.nodes[0], changed)))[0], "Unknown")

    def test_incomplete_or_changed_focus_fails_closed_even_with_marker(self):
        for error in ("Keyboard focus changed during read", "Read timed out", "Ancestor limit reached",
                      "Keyboard focus belongs to another app", "Accessibility access needed"):
            self.assertEqual(self.model.classify_focus(self.focus(error=error))[0], "Unknown")

    def test_unknown_contains_next_check_not_guess(self):
        result = describe(self.model, Observation(self.sample, self.sample, 1))
        self.assertEqual(result[4], "Not enough evidence")
        self.assertIn("actual chat input", result[5])

    def test_report_omits_ids_text_geometry_and_keeps_bounded_evidence(self):
        diagnostics = Diagnostics()
        node = Node("AXTextArea", "private-task-title", "secret-document-path", Rect(123, 456, 70, 80), True, True)
        sample = replace(self.sample, nodes=(node,), elapsed_ms=12, errors=("AXParent:-25212",))
        for n in range(25):
            diagnostics.append(Observation(sample, sample, n), self.model)
        report = diagnostics.report(self.model)
        for private in ("private-task-title", "secret-document-path", "123", "456"):
            self.assertNotIn(private, report)
        parsed = json.loads(report)
        self.assertEqual(len(parsed["samples"]), 20)
        self.assertEqual(parsed["samples"][0]["sample"], 5)
        self.assertEqual(parsed["samples"][0]["click"]["errors"], ["AXParent:-25212"])

    def test_later_calibration_does_not_rewrite_earlier_misses(self):
        diagnostics = Diagnostics()
        diagnostics.append(Observation(self.sample, self.sample, 1), self.model)
        self.model.learn("Main chat", self.sample, 1)
        self.assertEqual(json.loads(diagnostics.report(self.model))["samples"][0]["clicked_pane"], "Unknown")

    def test_live_adapter_never_reads_values_or_mutates_other_apps(self):
        source = Path(__file__).with_name("inspector.py").read_text()
        for forbidden in ("AXUIElementSetAttributeValue", "AXUIElementPerformAction", "AXChildren",
                          'self.copy(element, "AXValue")', 'self.copy(element, "AXSelectedText")',
                          "CGEventPost", "AXPress"):
            self.assertNotIn(forbidden, source)
        self.assertIn("NSEventMaskLeftMouseUp", source)
        self.assertIn("captured + 0.09", source)
        self.assertIn("None if OPTIONS.demo else AXReader()", source)


if __name__ == "__main__":
    unittest.main()
