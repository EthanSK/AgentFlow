"""Fake-AX checks for the Claude Prompt focus on Agent Flow's stop. Never touches the live desktop."""
import time
import unittest
from collections import Counter
from claude_prompt_focuser import ClaudePromptFocuser, MAX_PROMPT_NODES

CLAUDE_PID = 541


class FakeReader:
    def __init__(self):
        self.keys = {"AXFocused": "AXFocused", "AXSelectedTextRange": "AXSelectedTextRange"}
        self.deadline, self.errors = 0, []
        self.frontmost, self.refs = CLAUDE_PID, Counter()
        # Measured shape (Claude 2.42304.0): sidebar and one "Primary pane"; inside it the
        # conversation comes first and the composer footer last, Prompt several levels down.
        self.tree = {"window": ["sidebar", "web"], "sidebar": ["rename", "session-link"],
                     "web": ["pane"], "pane": ["conversation", "footer"],
                     "conversation": [f"msg{i}" for i in range(50)],
                     "footer": ["wrap1", "stop-button"]}
        for depth in range(1, 5):
            self.tree[f"wrap{depth}"] = [f"wrap{depth + 1}"] if depth < 4 else ["prompt"]
        self.attrs = {"pane": {"AXRole": "AXGroup", "AXDescription": "Primary pane"},
                      "prompt": {"AXRole": "AXTextArea", "AXDescription": "Prompt", "editable": True},
                      "rename": {"AXRole": "AXTextField", "editable": True},
                      "stop-button": {"AXRole": "AXButton"}, "web": {"AXRole": "AXWebArea"}}
        self.focused, self.flags, self.on_children = "msg3", {}, None
        self.system, self.owner, self.hits, self.handles = 900, CLAUDE_PID, ["msg3"], {}

    def hit(self, system, x, y, output):
        name = self.hits.pop(0) if len(self.hits) > 1 else self.hits[0]  # The last answer repeats, like a settled hit-test.
        handle = 7000 + len(self.handles)  # A c_void_p can only hold a number.
        self.handles[handle] = name
        self.refs.update([name])  # AXUIElementCopyElementAtPosition returns an owned element.
        output._obj.value = handle
        return 0

    def get_pid(self, element, output):
        output._obj.value = self.owner
        return 0

    def add_second_pane(self):
        # Split view: a second pane with its own conversation and Prompt.
        self.tree["web"] = ["pane", "pane2"]
        self.tree["pane2"] = ["conversation2", "prompt2"]
        self.tree["conversation2"] = ["other-msg"]
        self.attrs["pane2"] = {"AXRole": "AXGroup", "AXDescription": "Secondary pane"}
        self.attrs["prompt2"] = {"AXRole": "AXTextArea", "AXDescription": "Prompt", "editable": True}

    def parent(self, element):
        return next((p for p, kids in self.tree.items() if element in kids), None)

    def frontmost_pid(self):
        return self.frontmost

    def create_app(self, pid):
        self.refs.update(["app"])
        return "app"

    def copy(self, element, name):
        element = self.handles.get(element, element)
        value = {"AXFocusedUIElement": lambda: self.focused, "AXMainWindow": lambda: "window",
                 "AXParent": lambda: self.parent(element)}[name]()
        if value:
            self.refs.update([value])
        return value

    def text(self, element, name):
        return self.attrs.get(self.handles.get(element, element), {}).get(name, "")

    def boolean(self, element, name):
        assert name == "AXFocused", name
        return self.flags.get(element, False)

    def editable(self, element, role):
        return bool(self.attrs.get(element, {}).get("editable"))

    def equal(self, a, b):
        return a == b

    def retain(self, value):
        self.refs.update([self.handles.get(value, value)])

    def release(self, value):
        self.refs.subtract([self.handles.get(value, value)])


class FakeFocuser(ClaudePromptFocuser):
    def selection_length(self, target):
        return 0

    def __init__(self, reader):
        self.reader, self.arrays, self.writes, self.children_calls = reader, [], [], 0
        self.follow_write, self.caret_writes = True, []

    def character_count(self, element):
        return 12

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
            self.reader.flags[element] = True
        return 0


class ClaudePromptFocuserTests(unittest.TestCase):
    def setUp(self):
        self.reader = FakeReader()
        self.focuser = FakeFocuser(self.reader)

    def run_focus(self):
        status = self.focuser.focus_prompt(CLAUDE_PID)
        self.assertTrue(all(n == 0 for n in self.reader.refs.values()), self.reader.refs)
        return status

    def run_click(self, *hits, is_current=lambda: True):
        self.reader.hits = list(hits)
        status = self.focuser.focus_clicked_pane(CLAUDE_PID, (10.0, 20.0), is_current)
        self.assertTrue(all(n == 0 for n in self.reader.refs.values()), self.reader.refs)
        return status

    def test_plain_click_on_a_message_focuses_that_panes_prompt_with_caret_at_end(self):
        self.assertEqual(self.run_click("msg3"), "Focused Claude Prompt · verified · caret placed at end")
        self.assertEqual(self.focuser.writes, ["prompt"])
        self.assertEqual(self.focuser.caret_writes, [("prompt", "AXSelectedTextRange", ("range", 12))])

    def test_click_on_a_control_or_the_prompt_itself_is_left_alone(self):
        for hit in ("stop-button", "prompt"):
            with self.subTest(hit=hit):
                self.assertTrue(self.run_click(hit).startswith("Skipped · no chat pane"))
                self.assertEqual(self.focuser.writes, [])

    def test_click_on_text_inside_a_button_is_left_alone(self):
        self.reader.tree["stop-button"] = ["stop-label"]
        self.assertTrue(self.run_click("stop-label").startswith("Skipped · no chat pane"))
        self.assertEqual(self.focuser.writes, [])

    def test_sidebar_click_is_left_alone(self):
        self.assertTrue(self.run_click("session-link").startswith("Skipped · no chat pane"))
        self.assertEqual(self.focuser.writes, [])

    def test_click_owned_by_another_app_is_left_alone(self):
        self.reader.owner = 999
        self.assertTrue(self.run_click("msg3").startswith("Skipped · no chat pane"))
        self.assertEqual(self.focuser.writes, [])

    def test_split_view_click_chooses_the_clicked_pane_not_the_focused_one(self):
        self.reader.add_second_pane()
        self.assertTrue(self.run_click("other-msg").startswith("Focused Claude Prompt · verified"))
        self.assertEqual(self.focuser.writes, ["prompt2"])

    def test_other_panes_prompt_gives_way_to_the_clicked_pane(self):
        self.reader.add_second_pane()
        self.reader.focused = "prompt"
        self.assertTrue(self.run_click("other-msg").startswith("Focused Claude Prompt · verified"))
        self.assertEqual(self.focuser.writes, ["prompt2"])

    def test_coarse_window_answer_is_retried(self):
        self.assertTrue(self.run_click("window", "window", "msg3").startswith("Focused Claude Prompt · verified"))
        self.assertEqual(self.focuser.writes, ["prompt"])

    def test_newer_input_cancels_the_retry(self):
        self.assertEqual(self.run_click("window", "msg3", is_current=lambda: False), "Skipped · a newer click or key arrived")
        self.assertEqual(self.focuser.writes, [])

    def test_newer_input_during_the_lookup_blocks_the_write(self):
        self.assertEqual(self.run_click("msg3", is_current=lambda: False), "Skipped · a newer click, key or app switch arrived")
        self.assertEqual(self.focuser.writes, [])

    def test_click_keeps_a_rename_fields_caret(self):
        self.reader.focused = "rename"
        self.assertEqual(self.run_click("msg3"), "Skipped · another text input has focus")
        self.assertEqual(self.focuser.writes, [])

    def test_click_does_not_rewrite_an_already_focused_prompt(self):
        self.reader.flags["prompt"] = True
        self.assertEqual(self.run_click("msg3"), "Skipped · Prompt already focused")
        self.assertEqual(self.focuser.writes, [])

    def test_conversation_click_focuses_that_panes_prompt_with_caret_at_end(self):
        self.assertEqual(self.run_focus(), "Focused Claude Prompt · verified · caret placed at end")
        self.assertEqual(self.focuser.writes, ["prompt"])
        self.assertEqual(self.focuser.caret_writes, [("prompt", "AXSelectedTextRange", ("range", 12))])
        self.assertLess(self.focuser.children_calls, 10)  # Last child first: the conversation is not walked.

    def test_clicked_button_no_longer_swallows_the_paste(self):
        # Live 2026-10-19 15:05: a button click left focus off the Prompt, and the paste was lost.
        self.reader.focused = "stop-button"
        self.assertTrue(self.run_focus().startswith("Focused Claude Prompt · verified"))
        self.assertEqual(self.focuser.writes, ["prompt"])

    def test_no_write_when_prompt_already_has_focus(self):
        self.reader.focused = "prompt"
        self.assertEqual(self.run_focus(), "Skipped · Prompt already focused")
        self.reader.focused, self.reader.flags["prompt"] = None, True  # App focus unreadable, element still says focused.
        self.assertEqual(self.run_focus(), "Skipped · Prompt already focused")
        self.assertEqual(self.focuser.writes, [])

    def test_no_write_when_another_text_input_has_focus(self):
        self.reader.focused = "rename"
        self.assertEqual(self.run_focus(), "Skipped · another text input has focus")
        self.assertEqual(self.focuser.writes, [])

    def test_unreadable_focus_uses_the_only_pane(self):
        # Agent Flow's typing box can still hold the keyboard when the stop arrives.
        self.reader.focused = None
        self.assertTrue(self.run_focus().startswith("Focused Claude Prompt · verified"))
        self.assertEqual(self.focuser.writes, ["prompt"])

    def test_sidebar_focus_uses_the_only_pane(self):
        self.reader.focused = "session-link"
        self.assertTrue(self.run_focus().startswith("Focused Claude Prompt · verified"))

    def test_split_view_focuses_the_pane_ethan_is_in(self):
        self.reader.add_second_pane()
        self.reader.focused = "other-msg"
        self.assertTrue(self.run_focus().startswith("Focused Claude Prompt · verified"))
        self.assertEqual(self.focuser.writes, ["prompt2"])

    def test_split_view_without_a_focused_pane_is_left_alone(self):
        self.reader.add_second_pane()
        for focused in (None, "session-link"):
            self.reader.focused = focused
            self.assertEqual(self.run_focus(), "Skipped · 2 panes and none holds focus")
        self.assertEqual(self.focuser.writes, [])

    def test_no_write_when_claude_is_not_frontmost(self):
        self.reader.frontmost = 7
        self.assertEqual(self.run_focus(), "Skipped · Claude is not frontmost")
        self.assertEqual(self.focuser.writes, [])

    def test_no_write_when_focus_moves_during_lookup(self):
        def move():
            self.reader.focused = "rename"
        self.reader.on_children = move
        self.assertEqual(self.run_focus(), "Skipped · focus moved during the lookup")
        self.assertEqual(self.focuser.writes, [])

    def test_no_write_when_a_text_input_takes_unreadable_focus_during_lookup(self):
        self.reader.focused = None
        def move():
            self.reader.focused = "rename"
        self.reader.on_children = move
        self.assertEqual(self.run_focus(), "Skipped · a text input took focus during the lookup")
        self.assertEqual(self.focuser.writes, [])

    def test_unconfirmed_write_is_reported_and_leaves_the_caret_alone(self):
        self.focuser.follow_write = False
        self.assertEqual(self.run_focus(), "Focus sent to Claude Prompt · not confirmed")
        self.assertEqual(self.focuser.writes, ["prompt"])  # Waiting never re-writes.
        self.assertEqual(self.focuser.caret_writes, [])

    def test_missing_prompt_is_skipped(self):
        self.reader.attrs["prompt"]["AXDescription"] = "Edit message"  # A changed Claude tree.
        self.assertEqual(self.run_focus(), "Skipped · no Prompt box found within the search limit")
        self.assertEqual(self.focuser.writes, [])

    def test_search_is_bounded_in_a_huge_pane(self):
        self.reader.tree["pane"] = [f"n{i}" for i in range(5000)]
        self.reader.focused = "n0"  # Inside the pane, so only the bounded Prompt search walks.
        start = time.monotonic()
        self.assertEqual(self.run_focus(), "Skipped · no Prompt box found within the search limit")
        self.assertLessEqual(self.focuser.children_calls, MAX_PROMPT_NODES + 1)
        self.assertLess(time.monotonic() - start, 1.0)


if __name__ == "__main__":
    unittest.main()
