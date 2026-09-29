import unittest
from brief import sync_radii as s

def cls(lat, lng, city="X", state="ST"): return {"lat": lat, "lng": lng, "city": city, "state": state}

class Rules(unittest.TestCase):
    def test_haversine_known_distance(self):
        self.assertAlmostEqual(s.haversine_miles(40.7128, -74.0060, 42.3601, -71.0589), 190, delta=3)  # NYC-Boston
    def test_metro_pauses_at_zero_and_reenables_only_if_sync_paused(self):
        metros = [{"id": 1, "name": "A", "status": "ENABLED", "lat": 0, "lng": 0, "miles": 40, "sync_paused": False},
                  {"id": 2, "name": "B", "status": "PAUSED", "lat": 10, "lng": 10, "miles": 40, "sync_paused": True},
                  {"id": 3, "name": "C", "status": "PAUSED", "lat": 20, "lng": 20, "miles": 40, "sync_paused": False}]
        plan = s.decide(metros, [], [cls(10.1, 10.1), cls(20.1, 20.1)], {})
        self.assertEqual([m["id"] for m in plan["pause"]], [1])
        self.assertEqual([m["id"] for m in plan["enable"]], [2])   # C was paused by a human: untouched
    def test_radius_removed_at_zero_and_cluster_added_for_uncovered(self):
        radii = [{"criterion_id": 9, "lat": 0, "lng": 0, "miles": 40, "name": "Empty, ST"}]
        classes = [cls(30, 30, "Town", "TX"), cls(30.2, 30.2, "Town", "TX"), cls(30.1, 29.9, "Other", "TX")]
        plan = s.decide([], radii, classes, {})
        self.assertEqual([r["criterion_id"] for r in plan["remove_radii"]], [9])
        self.assertEqual(len(plan["add_radii"]), 1)
        self.assertEqual((plan["add_radii"][0]["name"], plan["add_radii"][0]["count"]), ("Town", 3))
    def test_covered_classes_do_not_spawn_new_radius(self):
        radii = [{"criterion_id": 9, "lat": 30, "lng": 30, "miles": 40, "name": "Town, TX"}]
        plan = s.decide([], radii, [cls(30.1, 30.1)], {})
        self.assertEqual(plan["add_radii"], []); self.assertEqual(plan["remove_radii"], [])
    def test_radius_reaching_into_a_metro_circle_is_trimmed_or_removed(self):
        metros = [{"id": 1, "name": "M", "status": "ENABLED", "lat": 0, "lng": 0, "miles": 40, "sync_paused": False}]
        radii = [{"criterion_id": 1, "lat": 1.0, "lng": 0, "miles": 40, "name": "a"},    # 69 mi out: 29 mi of room
                 {"criterion_id": 2, "lat": 0.65, "lng": 0, "miles": 40, "name": "b"},   # 45 mi out: floor
                 {"criterion_id": 3, "lat": 3.0, "lng": 0, "miles": 40, "name": "c"},    # far away: untouched
                 {"criterion_id": 4, "lat": 0.3, "lng": 0, "miles": 40, "name": "d"}]    # centre inside the metro
        classes = [cls(0, 0), cls(1.0, 0), cls(0.65, 0), cls(3.0, 0), cls(0.3, 0)]
        plan = s.decide(metros, radii, classes, {})
        trims = {r["criterion_id"]: r["new_miles"] for r in plan["trim_radii"]}
        self.assertEqual(sorted(trims), [1, 2])
        self.assertAlmostEqual(trims[1], 29.1, delta=0.3); self.assertEqual(trims[2], s.MIN_RADIUS_MILES)
        self.assertEqual([r["criterion_id"] for r in plan["remove_radii"]], [4])
        self.assertEqual(plan["add_radii"], [])
        self.assertIn("Trimmed radii", s.summarize(plan, "d"))
    def test_new_cluster_next_to_a_metro_gets_a_trimmed_radius(self):
        metros = [{"id": 1, "name": "M", "status": "ENABLED", "lat": 0, "lng": 0, "miles": 40, "sync_paused": False}]
        plan = s.decide(metros, [], [cls(0, 0), cls(1.0, 0, "Edge", "ST"), cls(5, 5, "Far", "ST")], {})
        got = {a["name"]: a["miles"] for a in plan["add_radii"]}
        self.assertAlmostEqual(got["Edge"], 29.1, delta=0.3); self.assertEqual(got["Far"], s.NEW_RADIUS_MILES)
    def test_cluster_splits_distant_groups(self):
        out = s.cluster([cls(0, 0, "A", "S"), cls(0.1, 0.1, "A", "S"), cls(5, 5, "B", "S")])
        self.assertEqual(sorted((c["name"], c["count"]) for c in out), [("A", 2), ("B", 1)])
    def test_promotion_requires_streak(self):
        radii = [{"criterion_id": 1, "lat": 0, "lng": 0, "miles": 40, "name": "Big, ST"}]
        classes = [cls(0.01 * i, 0) for i in range(13)]
        k = "radius:0.00,0.00"   # history is keyed by rounded coordinates, not by the (mutable) display name
        self.assertEqual(s.decide([], radii, classes, {k: [13, 13]})["promote"], [])
        promo = s.decide([], radii, classes, {k: [13, 13, 13]})["promote"]
        self.assertEqual([(p["key"], p["name"]) for p in promo], [(k, "X, ST")])
    def test_summary_mentions_no_changes(self):
        self.assertIn("No changes", s.summarize({"pause": [], "enable": [], "remove_radii": [], "add_radii": [], "promote": [], "counts": {}, "names": {}}, "d"))
    def test_inventory_dedupes_and_skips_sold_out(self):
        calls = []
        def fake(url):
            calls.append(url); return {"results": [{"key": "k1", "latitude": 1, "longitude": 1, "city": "C", "state": "S", "isSoldOut": False},
                                                  {"key": "k2", "latitude": 2, "longitude": 2, "city": "C", "state": "S", "isSoldOut": True}]}
        inv = s.fetch_inventory(fetch=fake, sleep=0)
        self.assertEqual(len(calls), len(s.STATES)); self.assertEqual(inv, [{"lat": 1, "lng": 1, "city": "C", "state": "S"}])

if __name__ == "__main__": unittest.main()

class Naming(unittest.TestCase):
    def test_radius_named_after_dominant_city(self):
        r = {"lat": 0, "lng": 0, "miles": 40}
        classes = [cls(0.01, 0, "Big", "TX"), cls(0.02, 0, "Big", "TX"), cls(0.03, 0, "Small", "TX"), cls(9, 9, "Far", "TX")]
        self.assertEqual(s.name_radius(classes, r), "Big, TX")
        self.assertIsNone(s.name_radius([cls(9, 9)], r))

class Stability(unittest.TestCase):
    def test_every_member_is_inside_its_new_radius(self):
        classes = [cls(0, 0), cls(0.5, 0), cls(0.55, 0), cls(0.3, 0.3)]   # spread ~38 mi across
        for c in s.cluster(classes):
            members = [x for x in classes if s.haversine_miles(c["lat"], c["lng"], x["lat"], x["lng"]) <= s.NEW_RADIUS_MILES]
            self.assertEqual(len(members), c["count"])
        # a second pass over the same classes with those radii must add nothing
        radii = [{"criterion_id": i, "lat": c["lat"], "lng": c["lng"], "miles": s.NEW_RADIUS_MILES, "name": "n"} for i, c in enumerate(s.cluster(classes))]
        self.assertEqual(s.decide([], radii, classes, {})["add_radii"], [])

class InventoryGuard(unittest.TestCase):
    def test_blocks_on_collapse_and_on_tiny_counts(self):
        self.assertEqual(s.inventory_guard(826, 830)[0], True)
        self.assertEqual(s.inventory_guard(500, 830)[0], True)      # -40%: allowed
        ok, why = s.inventory_guard(300, 830); self.assertFalse(ok); self.assertIn("fell from 830 to 300", why)
        ok, why = s.inventory_guard(0, 830); self.assertFalse(ok); self.assertIn("looks broken", why)
        self.assertTrue(s.inventory_guard(826, None)[0])            # first run: nothing to compare
