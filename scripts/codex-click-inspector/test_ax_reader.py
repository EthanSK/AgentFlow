"""Fake-AX adapter checks on the Mini. Never read the live desktop."""
import ctypes as C
import time
import unittest
from collections import Counter
from inspector import AXReader
from pane_model import Node, Rect, MAX_ANCESTORS


class FakeReader(AXReader):
    def __init__(self, depth=34):
        self.window = depth + 1
        rect = Rect(0, 0, 1000, 700)
        self.nodes = {i: Node("AXGroup", "", "", rect) for i in range(1, self.window)}
        self.nodes[1] = Node("AXTextArea", "", "", Rect(50, 600, 400, 50), True, True)
        self.nodes[7] = Node("AXGroup", "", "", rect, subrole="AXLandmarkRegion", conversation=True)
        self.nodes[10] = Node("AXGroup", "", "_r_main_-chat-panel", rect)
        self.nodes[self.window] = Node("AXWindow", "", "", rect)
        self.system, self.app = 800, 900
        self.refs = Counter()
        self.reads = []
        self.focus_reads = 0
        self.changed_focus = False
        self.owner = 42
        self.change_owner_on_recheck = False
        self.expire_at = None
        self.missing_parent = None
        self.unreadable_focus = False
        self.retain = lambda p: self.refs.update([p])
        self.release = lambda p: self.refs.subtract([p])
        self.hash = lambda p: p
        self.equal = lambda a, b: a == b
        self.timeout = lambda *args: 0
        self.trusted = lambda: True

    def create_app(self, pid):
        self.reads.append((pid, "create_app"))
        self.retain(self.app)
        return self.app

    def frontmost_pid(self):
        return self.owner

    def hit(self, root, x, y, result):
        result._obj.value = 1
        self.retain(1)
        return 0

    def get_pid(self, element, result):
        result._obj.value = 42
        return 0

    def copy(self, element, key):
        self.reads.append((element, key))
        if time.monotonic() >= self.deadline:
            return None
        if key == "AXFocusedUIElement":
            self.focus_reads += 1
            if self.unreadable_focus:
                self.errors.append("AXFocusedUIElement:-25204")
                return None
            if self.focus_reads > 1 and self.change_owner_on_recheck:
                self.owner = 43
            result = 2 if self.focus_reads > 1 and self.changed_focus else 1
        elif key == "AXWindow":
            result = self.window
        elif key == "AXParent":
            result = None if element == self.missing_parent else element + 1
        else:
            raise AssertionError(key)
        if result:
            self.retain(result)
        return result

    def text(self, element, key):
        node = self.nodes[element]
        if element == self.expire_at:
            self.deadline = time.monotonic() - 1
        return {"AXRole": node.role, "AXSubrole": node.subrole,
                "AXIdentifier": node.identifier, "AXDOMIdentifier": node.dom_identifier,
                "AXDescription": "Conversation" if node.conversation else ""}[key]

    def rect(self, element):
        return self.nodes[element].frame

    def boolean(self, element, key):
        return self.nodes[element].focused

    def editable(self, element, role):
        return self.nodes[element].editable


class AXReaderTests(unittest.TestCase):
    def assert_released(self, reader):
        self.assertTrue(all(n == 0 for n in reader.refs.values()), reader.refs)

    def test_deep_app_owned_focus_read_reaches_window(self):
        reader = FakeReader()
        sample = reader.sample(100, 200, 42, focus=True)
        self.assertEqual(len(sample.nodes), 35)
        self.assertEqual(sample.end, "window")
        self.assertEqual(sample.error, "")
        self.assertTrue(sample.focus_stable)
        self.assertEqual([owner for owner, key in reader.reads if key == "AXFocusedUIElement"], [900, 900])
        self.assert_released(reader)

    def test_bounded_partial_read_retains_nodes_and_rechecks_focus(self):
        reader = FakeReader(depth=60)
        sample = reader.sample(100, 200, 42, focus=True)
        self.assertEqual(len(sample.nodes), MAX_ANCESTORS)
        self.assertEqual(sample.error, "Ancestor limit reached")
        self.assertTrue(sample.focus_stable)
        self.assertEqual(sample.window_key, 61)
        self.assert_released(reader)

    def test_read_budget_retains_marker_and_reserves_focus_recheck(self):
        reader = FakeReader()
        reader.expire_at = 12
        sample = reader.sample(100, 200, 42, focus=True)
        self.assertEqual(sample.error, "Read timed out")
        self.assertTrue(any(n.dom_identifier.endswith("-chat-panel") for n in sample.nodes))
        self.assertTrue(sample.focus_stable)
        self.assert_released(reader)

    def test_parent_failure_retains_evidence(self):
        reader = FakeReader()
        reader.missing_parent = 12
        sample = reader.sample(100, 200, 42, focus=True)
        self.assertEqual(sample.error, "Ancestor path incomplete")
        self.assertEqual(len(sample.nodes), 12)
        self.assertTrue(sample.focus_stable)
        self.assert_released(reader)

    def test_changed_focus_is_fatal_even_when_partial(self):
        reader = FakeReader(depth=60)
        reader.changed_focus = True
        sample = reader.sample(100, 200, 42, focus=True)
        self.assertEqual(sample.error, "Keyboard focus changed during read")
        self.assertFalse(sample.usable_path)
        self.assert_released(reader)

    def test_current_app_change_invalidates_completed_read(self):
        reader = FakeReader()
        reader.change_owner_on_recheck = True
        sample = reader.sample(100, 200, 42, focus=True)
        self.assertEqual(sample.error, "Click owner changed")
        self.assertFalse(sample.usable_path)
        self.assert_released(reader)

    def test_unreadable_app_focus_does_not_fall_back_to_system(self):
        reader = FakeReader()
        reader.unreadable_focus = True
        sample = reader.sample(100, 200, 42, focus=True)
        self.assertEqual(sample.error, "Focused element unavailable")
        self.assertEqual(reader.focus_reads, 1)
        self.assertNotIn((reader.system, "AXFocusedUIElement"), reader.reads)
        self.assert_released(reader)


if __name__ == "__main__":
    unittest.main()
