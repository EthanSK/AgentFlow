"""Inspector-only keyboard routing; no live Accessibility reads."""
import unittest
import AppKit as K
from inspector import is_close_shortcut


class ShortcutTests(unittest.TestCase):
    def test_command_w_closes_only_key_inspector(self):
        self.assertTrue(is_close_shortcut(13, K.NSEventModifierFlagCommand, True))
        self.assertFalse(is_close_shortcut(13, K.NSEventModifierFlagCommand, False))

    def test_other_keys_and_modifiers_are_forwarded(self):
        for key, flags in [(13, 0), (12, K.NSEventModifierFlagCommand),
                           (13, K.NSEventModifierFlagCommand | K.NSEventModifierFlagShift),
                           (13, K.NSEventModifierFlagCommand | K.NSEventModifierFlagOption),
                           (13, K.NSEventModifierFlagCommand | K.NSEventModifierFlagControl)]:
            self.assertFalse(is_close_shortcut(key, flags, True))

    def test_caps_lock_does_not_break_close(self):
        self.assertTrue(is_close_shortcut(13, K.NSEventModifierFlagCommand | K.NSEventModifierFlagCapsLock, True))


if __name__ == "__main__":
    unittest.main()
