"""Check Sparkle's preparation/quit transition without launching an app."""
import unittest

from walk import preparation_handoff_seen


class SparklePreparationTests(unittest.TestCase):
    def test_extraction_does_not_start_quit_deadline(self):
        status = {"installer_visible": True, "controls": {}, "dialog_text": ["Extracting update…"]}
        self.assertFalse(preparation_handoff_seen(status, True))

    def test_normal_window_before_extraction_does_not_start_quit_deadline(self):
        status = {"installer_visible": False, "controls": {}, "dialog_text": []}
        self.assertFalse(preparation_handoff_seen(status, False))
        self.assertTrue(preparation_handoff_seen(status, True))

    def test_ready_or_installing_starts_quit_deadline(self):
        ready = {"installer_visible": True, "controls": {"Install and Relaunch": True}, "dialog_text": []}
        installing = {"installer_visible": True, "controls": {}, "dialog_text": ["Installing update…"]}
        self.assertTrue(preparation_handoff_seen(ready, False))
        ready["controls"]["Install and Relaunch"] = False
        self.assertFalse(preparation_handoff_seen(ready, False))
        self.assertTrue(preparation_handoff_seen(installing, False))


if __name__ == "__main__":
    unittest.main()
