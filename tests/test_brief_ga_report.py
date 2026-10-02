import unittest
from brief import ga_report as g

class Dedupe(unittest.TestCase):
    def test_counts_each_transaction_once_and_splits_revenue(self):
        rows = [(("y",), "t1", 2, 130.0), (("y",), "t2", 1, 65.0), (("y",), "(not set)", 1, 10.0), (("ylw",), "t1", 1, 65.0)]
        self.assertEqual(g.dedupe(rows), {("y",): (2, 130.0), ("ylw",): (1, 65.0)})
    def test_same_id_repeated_across_rows_counted_once(self):
        rows = [(("y",), "t1", 1, 65.0), (("y",), "t1", 1, 65.0)]
        self.assertEqual(g.dedupe(rows), {("y",): (1, 65.0)})

class NoiseLanding(unittest.TestCase):
    def test_blank_not_set_and_confirmation_are_noise(self):
        for pg in ("", "(not set)", " ", "/order-confirmation", "/order-confirmation?orderGuid=abc"):
            self.assertTrue(g.is_noise_landing(pg), pg)
    def test_real_pages_are_kept(self):
        for pg in ("/", "/events", "/metros/boston/", "/events/order-confirmation-party"):
            self.assertFalse(g.is_noise_landing(pg), pg)

class Text(unittest.TestCase):
    cur = {"sessions": 1000, "users": 800, "purchases": 20, "revenue": 1300.0}
    prev = {"sessions": 1200, "users": 900, "purchases": 30, "revenue": 1950.0}
    def test_pct_and_headline(self):
        self.assertEqual(g.pct(110, 100), "+10%"); self.assertEqual(g.pct(5, 0), "new"); self.assertEqual(g.pct(0, 0), "n/a")
        h = g.headline(self.cur, self.prev)
        self.assertIn("1,000 sessions (-17%)", h); self.assertIn("20 orders (-33%)", h); self.assertIn("CVR 2.00% (was 2.50%)", h); self.assertIn("AOV $65", h)
    def test_flags(self):
        f = g.flags(self.cur, self.prev)
        self.assertTrue(any("orders down" in x for x in f)); self.assertTrue(any("revenue down" in x for x in f)); self.assertFalse(any("sessions down" in x for x in f))
        self.assertTrue(any("purchase tracking" in x for x in g.flags({"sessions": 500, "users": 1, "purchases": 0, "revenue": 0}, self.prev)))
    def test_build_text_has_sections(self):
        import datetime as dt
        t = g.build_text((self.cur, self.prev), (self.cur, self.prev), {"Paid Search": (10, 1, 65.0), "Email": (0, 0, 0.0)}, [("/metros/boston/", 40, 2)], dt.date(2026, 9, 25))
        self.assertIn("Fri Sep 25", t); self.assertIn("Paid Search: 10 sess", t); self.assertNotIn("Email:", t); self.assertIn("/metros/boston/ (40 sess, 2 orders)", t)

if __name__ == "__main__": unittest.main()
