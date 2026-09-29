import unittest, datetime as dt
from brief import slack_post as sp, charts

class Blocks(unittest.TestCase):
    def test_blocks_shape(self):
        b = sp.brief_blocks("Thu Sep 25", "story", [("Sessions", "1,000 (+5%)")], "$10 · 3 clicks", ["⚠ x"], ["Boston: $9"])
        self.assertEqual(b[0]["type"], "header"); self.assertIn("story", b[1]["text"]["text"])
        self.assertTrue(any(x.get("fields") for x in b)); self.assertEqual(b[-1]["type"], "context")
    def test_chunks_respect_limit(self):
        text = "\n".join("line %d %s" % (i, "x" * 100) for i in range(100))
        ch = sp._chunks(text, 1000); self.assertTrue(all(len(c) <= 1000 for c in ch)); self.assertEqual("".join(ch).strip(), text)
    def test_no_credentials_returns_none(self):
        import os; os.environ.pop("SLACK_BOT_TOKEN", None); os.environ.pop("SLACK_WEBHOOK_URL", None)
        self.assertEqual(sp.post_brief([], "t"), "none")

class Charts(unittest.TestCase):
    def test_line_chart_returns_png(self):
        d = [dt.date(2026, 9, 1) + dt.timedelta(days=i) for i in range(5)]
        png = charts.line_chart(d, {"Sessions": [1, 2, 3, 2, 4]}, "t", "sessions", right=("Orders", [0, 1, 1, 0, 2]))
        self.assertTrue(png.startswith(b"\x89PNG")); self.assertGreater(len(png), 5000)

if __name__ == "__main__": unittest.main()
