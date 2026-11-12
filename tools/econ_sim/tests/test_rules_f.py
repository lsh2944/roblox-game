"""사용자 규칙 F: 개체값(F2)·보유 상한(F4)·고유 필드 특수재화(F1)·도감 보너스(F5)와 전환 구간."""
import copy
import unittest

from econ_sim import jsonio
from econ_sim.data_load import load_data
from econ_sim.economy import Economy
from econ_sim.model import Model
from econ_sim.sim import Simulator
from econ_sim.sim_config import load_personas
from _support import CONFIG_DIR, DATA_DIR

REF = jsonio.load_strict(CONFIG_DIR / "static_reference.json")


class FBase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.model = Model(load_data(DATA_DIR))
        cls.econ = Economy(cls.model)
        cls.cfg, _ = load_personas(CONFIG_DIR / "personas.json", cls.model)

    def make(self, pid="balanced", rep=0):
        persona = copy.deepcopy(next(p for p in self.cfg["personas"] if p["id"] == pid))
        return Simulator(self.econ, self.cfg, persona, rep, 3, REF)


class IndividualTest(FBase):
    def captured(self, rep):
        sim = self.make(rep=rep)
        for _ in range(6):
            sim._capture("meadow", 0, False)
        start = {u for u in range(1, 4)}
        return [(s.species, s.gather_bps, s.combat_bps) for u, s in sorted(sim.state.roster.items()) if u not in start]

    def test_range_and_determinism(self):
        a, b = self.captured(0), self.captured(0)
        self.assertEqual(a, b)
        self.assertGreater(len(a), 10)
        ind = self.model.gd.docs["rules"]["individual_stats"]
        for _, g, c in a:
            self.assertTrue(ind["gather_bps_min"] <= g <= ind["gather_bps_max"])
            self.assertTrue(ind["combat_bps_min"] <= c <= ind["combat_bps_max"])
        self.assertGreater(len({g for _, g, _ in a}), 5)  # 個体ごとに異なる
        self.assertNotEqual([x[1:] for x in a], [x[1:] for x in self.captured(1)])

    def test_individual_stream_does_not_shift_capture_draws(self):
        # 個体値は別ストリームなので、捕獲（種・成否）の系列は個体値の消費に影響されない
        sim = self.make()
        sim._capture("meadow", 0, False)
        species = [s.species for u, s in sorted(sim.state.roster.items())]
        sim2 = self.make()
        sim2.ind = dict(sim2.ind, gather_bps_max=10000, combat_bps_max=10000)  # 値の範囲を変えても
        sim2._capture("meadow", 0, False)
        self.assertEqual(species, [s.species for u, s in sorted(sim2.state.roster.items())])

    def test_individual_scales_power(self):
        e = self.econ
        base = e.slot_power("dewdrop", 1, "dew", False, 10000)
        high = e.slot_power("dewdrop", 1, "dew", False, 12000)
        self.assertEqual(high, base * 12000 // 10000)
        self.assertEqual(e.combat_power("lighthouse_bear", 1, 11000), 12 * 10000 * 11000 // 10000)


class StorageTest(FBase):
    def test_base_and_paid_cap(self):
        sim = self.make("balanced_paid")
        self.assertEqual(sim.capacity(), 100)
        sim.state.hub_rank = 3
        self.assertEqual(sim.capacity(), 100)  # 拠点等級の保管箱ボーナスは 0（無料上限 100 固定）
        bought = sum(sim.buy_product("storage_plus_10", d) for d in range(12))
        self.assertEqual(bought, 10)  # 総購入上限 10 → +100
        self.assertEqual(sim.capacity(), 200)
        sim.state.storage_bonus = 999
        self.assertEqual(sim.capacity(), 200)  # max_capacity で頭打ち


class HomeMaterialTest(FBase):
    def test_working_spirits_produce_home_material(self):
        sim = self.make("light_1h")
        working = [u for us in sim.state.assignment.values() for u in us]
        self.assertEqual(len(working), 3)  # 開始精霊 ★1×3（固有フィールド meadow）
        sim.advance(480 + 720)  # ゲーム開始から 12 時間（オフライン上限内）
        # ★1 0.5 個/日 × 3 体 × 720/1440 日 = 0.75 個
        self.assertEqual(sim.state.wallet["hunt_meadow"], 750)
        self.assertEqual(sim.day_acc(0).earned[("idle", "hunt_meadow")], 750)

    def test_party_does_not_produce(self):
        sim = self.make("light_1h")
        u = sim.state.assignment["dew_spring"][0]
        self.assertEqual(sim.home_rates(frozenset({u})).get("hunt_meadow"), 1000)
        self.assertEqual(sim.home_rates(frozenset()).get("hunt_meadow"), 1500)


class DexTest(FBase):
    def test_bonus_and_cap(self):
        e = self.econ
        members = [("dewdrop", 1)] * 3
        base = e.facility_rate("dew_spring", 1, members, False, 0)
        self.assertEqual(e.facility_rate("dew_spring", 1, members, False, 300), base * 10300 // 10000)
        self.assertEqual(e.dex_bps(3), 300)
        self.assertEqual(e.dex_bps(50), self.model.gd.docs["rules"]["dex_bonus"]["max_bps"])

    def test_registration(self):
        sim = self.make()
        self.assertEqual(sim.state.dex, {"sparkle", "dewdrop", "flower_lamp"})  # 開始精霊も登録
        for _ in range(6):
            sim._capture("meadow", 0, False)
        self.assertGreater(len(sim.state.dex), 3)
        self.assertEqual(sim.state.dex, {s.species for s in sim.state.roster.values()} | {"sparkle", "dewdrop", "flower_lamp"})


class TransitionTest(FBase):
    def test_window(self):
        sim = self.make()
        self.assertFalse(sim.in_transition(10_000))  # 開始フィールドの解禁は移行区間に数えない
        sim.state.field_unlock_time["forest"] = 2000
        self.assertTrue(sim.in_transition(2000 + 1439))
        self.assertFalse(sim.in_transition(2000 + 1440))



class FlagTest(FBase):
    """F1 の個体値・図鑑適用と開始精霊の個体値抽選はデータのフラグで切り替わる（既定 false）."""

    def test_home_material_flags(self):
        members = [("dewdrop", 1, 12000, 10000)]
        self.assertEqual(self.econ.home_material_per_day(members, 500), {"hunt_meadow": 500})
        model = Model(load_data(DATA_DIR, [
            {"op": "set", "file": "rules", "path": "/home_material/apply_individual_to_home_material", "value": True},
            {"op": "set", "file": "rules", "path": "/home_material/apply_dex_to_home_material", "value": True}]))
        econ = Economy(model)
        # 500 × 1.2 = 600 → 図鑑 +5% = 630
        self.assertEqual(econ.home_material_per_day(members, 500), {"hunt_meadow": 630})

    def test_start_spirit_roll_flag(self):
        sim = self.make()
        self.assertEqual({(s.gather_bps, s.combat_bps) for s in sim.state.roster.values()}, {(10000, 10000)})
        model = Model(load_data(DATA_DIR, [{"op": "set", "file": "rules", "path": "/individual_stats/roll_start_spirits", "value": True}]))
        persona = copy.deepcopy(next(p for p in self.cfg["personas"] if p["id"] == "balanced"))
        rolled = Simulator(Economy(model), self.cfg, persona, 0, 3, REF)
        vals = [(s.gather_bps, s.combat_bps) for s in rolled.state.roster.values()]
        self.assertTrue(all(10000 <= g <= 12000 and 10000 <= c <= 12000 for g, c in vals))
        self.assertNotEqual(set(vals), {(10000, 10000)})


if __name__ == "__main__":
    unittest.main()
