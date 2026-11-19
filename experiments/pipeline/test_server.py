"""Unit tests for the demo status of server.py (the strip "Live demo · step N of 4" on the page).

  python3 -m unittest test_server
"""
import unittest

import server


class DemoStatusTest(unittest.TestCase):
    def test_keeps_known_fields_and_adds_age(self):
        demo = server.DemoStatus()
        demo.set({"step": 2, "total": 4, "steps": ["a", "b", "c", "d"], "title": "Approve GW02", "detail": "waiting",
                  "tab": "trust", "state": "running", "unknown": "dropped"})
        got = demo.get()
        self.assertEqual(got["step"], 2)
        self.assertEqual(got["tab"], "trust")
        self.assertNotIn("unknown", got)
        self.assertGreaterEqual(got["age"], 0)

    def test_off_means_no_strip(self):
        demo = server.DemoStatus()
        self.assertIsNone(demo.get())
        demo.set({"step": 1, "total": 4, "state": "off"})
        self.assertIsNone(demo.get())

    def test_refuses_bad_values(self):
        for bad in ({"step": "2"}, {"step": 99}, {"step": True}, {"tab": "secret"}, {"state": "exploded"},
                    {"steps": "abc"}, {"title": 5}):
            with self.assertRaises(ValueError, msg=str(bad)):
                server.DemoStatus.clean(bad)

    def test_long_texts_are_cut(self):
        status = server.DemoStatus.clean({"title": "x" * 1000, "detail": "y" * 1000})
        self.assertEqual(len(status["title"]), 200)
        self.assertEqual(len(status["detail"]), 300)


if __name__ == "__main__":
    unittest.main()
