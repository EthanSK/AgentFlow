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

    def measured(self, side=False, editable=True, **kwargs):
        leaf = Node("AXTextArea" if editable else "AXGroup", "", "", Rect(50, 600, 400, 60),
                    True, editable, "" if editable else "AXLandmarkRegion", not editable)
        region = Node("AXGroup", "", "", Rect(0, 0, 600, 700), subrole="AXLandmarkRegion", conversation=True)
        marker = (Node("AXGroup", "", "app-shell-tab-panel-app-shell-tab:68", None, subrole="AXTabPanel")
                  if side else Node("AXGroup", "", "_r_3rkn_-chat-panel", None))
        return replace(self.sample, nodes=(leaf,) + (region,) + (Node("AXGroup", "", "", None),) * 30
                       + (marker, Node("AXWindow", "", "", self.sample.window)), focus_stable=True, **kwargs)

    def classify_measured(self, sample):
        return self.model.classify(sample, "ChatGPT.app", "26.1013.31256 / 20586")

    def test_actual_main_and_side_markers_beyond_old_depth(self):
        self.assertEqual(self.classify_measured(self.measured())[0], "Main chat")
        self.assertEqual(self.classify_measured(self.measured(side=True))[0], "Side chat")

    def test_measured_markers_require_exact_host_and_version(self):
        for host, version in [("Codex.app", "26.1013.31256 / 20586"), ("ChatGPT.app", "new"), ("", "")]:
            self.assertEqual(self.model.classify(self.measured(), host, version)[0], "Unknown")

    def test_panel_without_conversation_is_not_a_side_chat(self):
        sample = self.measured(side=True)
        sample = replace(sample, nodes=tuple(replace(n, conversation=False) for n in sample.nodes))
        self.assertEqual(self.classify_measured(sample)[0], "Unknown")

    def test_nearest_side_scope_wins_over_enclosing_main(self):
        sample = self.measured(side=True)
        sample = replace(sample, nodes=sample.nodes[:-1] +
                         (Node("AXGroup", "", "_r_outer_-chat-panel", None), sample.nodes[-1]))
        self.assertEqual(self.classify_measured(sample)[0], "Side chat")

    def test_conversation_focus_identifies_pane_but_never_claims_input(self):
        sample = self.measured(editable=False)
        observation = Observation(sample, sample, 1, host="ChatGPT.app", version="26.1013.31256 / 20586")
        result = describe(self.model, observation)
        self.assertEqual((result[0], result[2]), ("Main chat", "Main chat"))
        self.assertEqual(result[4], "Same pane · no editable input focused")
        self.assertIn("not an input", result[5])
        self.assertEqual(self.model.classify_focus(sample, observation.host, observation.version)[0], "Unknown")

    def test_partial_path_keeps_real_marker_and_explicit_warning(self):
        for error in ("Read timed out", "Ancestor limit reached", "Ancestor path incomplete"):
            sample = self.measured(error=error)
            pane, reason = self.classify_measured(sample)
            self.assertEqual(pane, "Main chat")
            self.assertIn(error, reason)
            self.assertEqual(self.model.classify_focus(sample, "ChatGPT.app", "26.1013.31256 / 20586")[0], "Main chat")

    def test_body_click_uses_current_containing_conversation_after_coarse_hit_test(self):
        focused = self.measured(editable=False)
        clicked = replace(self.sample, x=100, y=620,
                          nodes=(Node("AXGroup", "", "", self.sample.window),))
        result = describe(self.model, Observation(clicked, focused, 1, host="ChatGPT.app",
                                                  version="26.1013.31256 / 20586"))
        self.assertEqual(result[0], "Main chat")
        self.assertIn("region contains click", result[1])
        self.assertEqual(result[4], "Same pane · no editable input focused")
        for changed in (replace(focused, focus_stable=False), replace(focused, window_key=9),
                        self.measured(editable=True)):
            result = describe(self.model, Observation(clicked, changed, 1, host="ChatGPT.app",
                                                      version="26.1013.31256 / 20586"))
            self.assertEqual(result[0], "Unknown")
        result = describe(self.model, Observation(replace(clicked, x=900), focused, 1,
                                                  host="ChatGPT.app", version="26.1013.31256 / 20586"))
        self.assertEqual(result[0], "Unknown")

    def test_partial_path_without_window_or_stable_focus_is_not_proof(self):
        sample = self.measured(error="Ancestor limit reached")
        self.assertEqual(self.classify_measured(replace(sample, window=None))[0], "Unknown")
        self.assertEqual(self.model.classify_focus(replace(sample, focus_stable=None),
                         "ChatGPT.app", "26.1013.31256 / 20586")[0], "Unknown")

    def test_partial_read_can_learn_only_fresh_in_window_container(self):
        sample = replace(self.sample, error="Ancestor limit reached")
        self.assertTrue(self.model.learn("Main chat", sample, 1))
        self.assertFalse(self.model.learn("Side chat", replace(sample, window=None), 1))

    def test_owner_change_is_fatal_even_with_known_markers(self):
        self.assertEqual(self.classify_measured(self.measured(error="Click owner changed"))[0], "Unknown")

    def test_export_keeps_deep_safe_metadata_and_original_verdict(self):
        diagnostics = Diagnostics()
        sample = self.measured(error="Ancestor limit reached")
        diagnostics.append(Observation(sample, sample, 1, host="ChatGPT.app", version="26.1013.31256 / 20586"), self.model)
        report = diagnostics.report(self.model)
        parsed = json.loads(report)
        self.assertEqual(parsed["schema"], 3)
        row = parsed["samples"][0]
        self.assertTrue(row["focus"]["partial"])
        self.assertTrue(row["focus"]["focus_stable"])
        self.assertEqual(len(row["focus"]["nodes"]), 34)
        self.assertEqual(row["input_state"], "Editable input focused")
        self.assertNotIn("_r_3rkn_", report)

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
        self.assertNotIn('self.copy(self.system, "AXFocusedUIElement")', source)
        self.assertIn("self.create_app(expected_pid)", source)


if __name__ == "__main__":
    unittest.main()
