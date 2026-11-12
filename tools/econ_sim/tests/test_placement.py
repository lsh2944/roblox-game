"""配置: 部分集合 DP は総当たりと一致し、ヒューリスティックは小さい全探索の最適値に近い."""
import itertools
import random
import unittest

from econ_sim import placement
from econ_sim.data_load import load_data
from econ_sim.economy import Economy
from econ_sim.model import Model
from econ_sim.placement import Slot
from _support import DATA_DIR


def brute_force(econ, facs, spirits, weights):
    """各精霊を控え(-1)か施設 k に置く全割り当て（DP と独立な実装）."""
    best = 0.0
    for choice in itertools.product(range(-1, len(facs)), repeat=len(spirits)):
        groups = [[] for _ in facs]
        ok = True
        for i, k in enumerate(choice):
            if k >= 0:
                groups[k].append(spirits[i])
                if len(groups[k]) > facs[k].slots:
                    ok = False
                    break
        if not ok:
            continue
        v = sum(weights[econ.m.facilities[f.fid]["produces"]] * econ.facility_rate(f.fid, f.level, g) for f, g in zip(facs, groups))
        best = max(best, v)
    return best


class PlacementTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.econ = Economy(Model(load_data(DATA_DIR)))

    def instances(self, count, seed=7):
        rnd = random.Random(seed)
        species = list(self.econ.m.spirit_order)
        for _ in range(count):
            n = rnd.randint(4, 7)
            spirits = [(rnd.choice(species), rnd.randint(1, 20)) for _ in range(n)]
            facs = [Slot("dew_spring", rnd.randint(1, 30), rnd.randint(1, 3)), Slot("bloom_garden", rnd.randint(1, 30), rnd.randint(1, 3)),
                    Slot("crystal_forge", rnd.randint(1, 30), rnd.randint(1, 2))]
            weights = {r: float(rnd.choice([1, 2, 3])) for r in self.econ.m.basic_ids}
            yield facs, spirits, weights

    def test_exact_matches_brute_force(self):
        for facs, spirits, weights in self.instances(25):
            with self.subTest(spirits=spirits):
                self.assertAlmostEqual(placement.exact(self.econ, facs, spirits, weights).value,
                                       brute_force(self.econ, facs, spirits, weights), places=6)

    def test_heuristic_close_to_optimum(self):
        ratios = []
        for facs, spirits, weights in self.instances(25):
            opt = brute_force(self.econ, facs, spirits, weights)
            h = placement.heuristic(self.econ, facs, spirits, weights)
            self.assertFalse(h.proven_optimal)
            self.assertLessEqual(h.value, opt + 1e-6)
            ratios.append(h.value / opt if opt else 1.0)
        # 貪欲+2-swap+連鎖移動は小さい問題の大半で最適（実測: 別 200 例で 188 例一致、最悪 91.7%）
        self.assertGreaterEqual(min(ratios), 0.90, ratios)
        self.assertGreaterEqual(sum(1 for r in ratios if r > 1 - 1e-9), 22)

    def test_best_single_matches_exact_with_mixed(self):
        # G2 分母（1 施設の厳密最適）: 混合ボーナス精霊・適性 X（寄与 0 でも種数に数える）を含む小さいロスターで exact と一致
        rnd = random.Random(11)
        species = list(self.econ.m.spirit_order)
        self.assertIn("rainbow_butterfly", self.econ.mixed_traits())
        for case in range(120):
            n = rnd.randint(1, 10)
            spirits = [(rnd.choice(species), rnd.randint(1, 25), rnd.randint(8000, 12000), 10_000) for _ in range(n)]
            if case % 2 == 0:
                spirits[rnd.randrange(n)] = ("rainbow_butterfly", rnd.randint(1, 3), rnd.randint(8000, 12000), 10_000)
            fid = rnd.choice(["dew_spring", "bloom_garden", "crystal_forge"])
            fac = Slot(fid, rnd.randint(1, 30), rnd.randint(1, 5))
            night = bool(case % 3 == 0)
            res = self.econ.m.facilities[fid]["produces"]
            with self.subTest(case=case, fac=fac, spirits=spirits):
                got = placement.best_single(self.econ, fac, spirits, night)
                want = placement.exact(self.econ, [fac], spirits, {res: 1.0}, night)
                self.assertTrue(got.proven_optimal)
                self.assertAlmostEqual(got.value, want.value, places=6)
                members = [spirits[i] for i in got.assign[fid]]
                self.assertLessEqual(len(members), fac.slots)
                self.assertEqual(got.value, float(self.econ.facility_rate(fid, fac.level, members, night)))

    def test_best_single_includes_low_power_mixed_spirit(self):
        # 診断事例の形: 寄与上位（枠+3）に入らない Lv1 butterfly でも、+10% が勝るので最適に入る（旧分母はこれを落とした）
        spirits = [("flower_lamp", 20), ("sparkle", 20), ("sparkle", 19), ("sparkle", 18), ("sparkle", 17), ("sparkle", 16),
                   ("sparkle", 15), ("sparkle", 14), ("sparkle", 13), ("rainbow_butterfly", 1)]
        fac = Slot("bloom_garden", 20, 5)
        got = placement.best_single(self.econ, fac, spirits)
        want = placement.exact(self.econ, [fac], spirits, {"bloom": 1.0})
        self.assertAlmostEqual(got.value, want.value, places=6)
        self.assertIn(9, got.assign["bloom_garden"])
        top8 = sorted(range(len(spirits)), key=lambda i: -self.econ.slot_power(spirits[i][0], spirits[i][1], "bloom"))[:8]
        self.assertNotIn(9, top8)
        old = placement.heuristic(self.econ, [fac], [spirits[i] for i in top8], {"bloom": 1.0})
        self.assertGreater(got.value, old.value)

    def test_assignment_respects_slots(self):
        for facs, spirits, weights in self.instances(10, seed=3):
            for res in (placement.exact(self.econ, facs, spirits, weights), placement.heuristic(self.econ, facs, spirits, weights)):
                used = [i for idxs in res.assign.values() for i in idxs]
                self.assertEqual(len(used), len(set(used)))
                for f in facs:
                    self.assertLessEqual(len(res.assign[f.fid]), f.slots)


if __name__ == "__main__":
    unittest.main()
