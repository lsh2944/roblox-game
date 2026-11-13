"""4 段階: R 分類（移行区間×超過/未定義、最大 R 分離）、方策 3 種、個体値の共通乱数、放流順、消化到達、_rankings 同等性."""
import copy
import random
import unittest

from econ_sim import jsonio
from econ_sim.data_load import load_data
from econ_sim.economy import Economy
from econ_sim.model import Model
from econ_sim.policy import Action
from econ_sim.sim import Simulator
from econ_sim.sim_config import load_personas
from econ_sim.state import SpiritInst
from _support import CONFIG_DIR, DATA_DIR

REF = jsonio.load_strict(CONFIG_DIR / "static_reference.json")


class Base(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.model = Model(load_data(DATA_DIR))
        cls.econ = Economy(cls.model)
        cls.cfg, _ = load_personas(CONFIG_DIR / "personas.json", cls.model)

    def make(self, pid="balanced", rep=0, days=3):
        persona = copy.deepcopy(next(p for p in self.cfg["personas"] if p["id"] == pid))
        return Simulator(self.econ, self.cfg, persona, rep, days, REF)


class RClassificationTest(Base):
    def run_step(self, sim, idle, in_transition):
        node = self.model.fields["meadow"]["gather_nodes"][0]
        # 実際の直接採集率（2026-11-12 から図鑑ボーナス込み）を基準に R を作る
        rate = sim.direct_rate(node, [])
        sim.idle_rates = lambda exclude, night: {"dew": idle(rate)}
        sim.best_idle_rate = lambda res, night: idle(rate)
        sim.in_transition = lambda t: in_transition
        sim.online = True
        sim.do_step(Action("gather", field_id="meadow", node=node, party=()), 0)
        return sim.day_acc(0)

    def test_outside_and_transition_split(self):
        for trans in (False, True):
            for kind, idle in (("over", lambda r: r // 4), ("undef", lambda r: 0), ("ok", lambda r: r)):
                with self.subTest(trans=trans, kind=kind):
                    acc = self.run_step(self.make(), idle, trans)
                    rs = acc.r_best
                    over = (rs.over_transition if trans else rs.over_outside)
                    undef = (rs.undefined_transition if trans else rs.undefined_outside)
                    self.assertEqual(over, 5 if kind == "over" else 0)
                    self.assertEqual(undef, 5 if kind == "undef" else 0)
                    # 反対側の区間には何も入らない
                    self.assertEqual(rs.over_outside if trans else rs.over_transition, 0)
                    self.assertEqual(rs.undefined_outside if trans else rs.undefined_transition, 0)
                    if kind == "over":
                        self.assertAlmostEqual(rs.max_transition if trans else rs.max_outside, 4.0, places=2)
                        self.assertEqual(rs.max_outside if trans else rs.max_transition, 0.0)

    def test_best_vs_actual_basis(self):
        sim = self.make()
        node = self.model.fields["meadow"]["gather_nodes"][0]
        rate = self.econ.direct_rate(node, sim.tool_id, sim.state.tool_level, [])
        sim.idle_rates = lambda exclude, night: {"dew": rate // 5}  # 実配置: R=5
        sim.best_idle_rate = lambda res, night: rate // 2  # 最善配置: R=2
        sim.in_transition = lambda t: False
        sim.online = True
        sim.do_step(Action("gather", field_id="meadow", node=node, party=()), 0)
        acc = sim.day_acc(0)
        self.assertEqual((acc.r_actual.over_outside, acc.r_best.over_outside), (5, 0))


class PolicyTest(Base):
    def test_gate_hunt_reservation(self):
        sim = self.make()
        st = sim.state
        st.fac_level["dew_spring"] = 3  # Lv4 ゲート: 草原素材 9
        for r in ("dew", "bloom"):
            st.wallet[r] = 10_000_000
        st.wallet["hunt_meadow"] = 0
        sim.touch()
        self.assertEqual(sim.policy.hunt_targets().get("hunt_meadow"), 9000)
        self.assertEqual(sim.policy.bottleneck()[0], "hunt_meadow")

    def test_hunt_first_when_direct_below_idle(self):
        pol = self.make().policy
        pol.goal = lambda: {"dew": 900_000_000, "hunt_forest": 5_000}
        pol.hunt_targets = lambda: {}
        pol.wick_hunt_need = lambda: {}  # 芯の調達はこの順位付けの対象外
        for direct, want in ((50_000, "hunt_forest"), (500_000, "dew")):
            rv = {"idle": {"dew": 100_000}, "direct": {"dew": direct}, "hunt": {"hunt_forest": 20_000}, "quest": {}, "home": {}, "frac": 1.0}
            pol.rate_view = lambda rv=rv: rv
            self.assertEqual(pol.bottleneck()[0], want)

    def test_zero_effect_hub_rank_not_bought(self):
        sim = self.make()
        st = sim.state
        for r in st.wallet:
            st.wallet[r] = 10**9
        sim.capacity = lambda: len(st.roster)  # 満杯
        self.assertFalse(sim.policy._try_hub_rank())
        self.assertEqual(st.hub_rank, 1)


class IndividualCrnTest(Base):
    def test_paired_individual_draws(self):
        a, b = self.make("balanced"), self.make("balanced_paid")
        for day in (0, 9):
            self.assertEqual([a.individual_rng(day).random() for _ in range(10)], [b.individual_rng(day).random() for _ in range(10)])
        self.assertNotEqual(self.make("hardcore").individual_rng(0).random(), self.make("balanced").individual_rng(0).random())


class ReleaseOrderTest(Base):
    def test_victim_order(self):
        sim = self.make()
        st = sim.state
        st.roster = {
            1: SpiritInst(1, "sparkle", 1, 12000, 12000),  # 重複 ★1 個体値高
            2: SpiritInst(2, "sparkle", 1, 10000, 10000),  # 重複 ★1 個体値低 ← 放流対象
            3: SpiritInst(3, "sparkle", 5, 10000, 10000),  # 重複 ★1 Lv 高
            4: SpiritInst(4, "moon_fox", 1, 10000, 10000),  # 重複 ★3
            5: SpiritInst(5, "moon_fox", 1, 10000, 10000),
            6: SpiritInst(6, "aurora_deer", 1, 10000, 10000),  # 唯一 ★4
        }
        st.assignment = {fid: [] for fid in st.assignment}
        sim._release_one(0)
        self.assertNotIn(2, st.roster)
        sim._release_one(0)
        self.assertNotIn(1, st.roster)  # 次は Lv1 の残り（Lv5 より先）
        self.assertIn(6, st.roster)


class ExhaustionTest(Base):
    def maxed(self, pid):
        sim = self.make(pid)
        st, m = sim.state, self.model
        st.unlocked = list(m.field_order)
        sim._open_facilities()
        for fid, fac in m.facilities.items():
            st.fac_level[fid] = fac["max_level"]
            st.fac_slots[fid] = fac["slots"]["max"]
        st.tool_level = m.tools[sim.tool_id]["max_level"]
        return sim

    def test_reachable_with_zero_benefit_upgrades_left(self):
        sim = self.maxed("balanced")  # セッション間隔はすべて 12 時間未満 → オフライン上限強化の利得 0
        self.assertEqual(sim.state.hub_rank, 1)  # 効果 0 の拠点等級は残っている
        self.assertTrue(sim.policy.is_exhausted())

    def test_offline_upgrade_with_benefit_blocks(self):
        sim = self.maxed("light_1h")  # 20:30〜翌 8:00 の 11.5 時間 + 8:30〜20:00 の 11.5 時間
        frac12 = sim.policy.credited_frac(12)
        if sim.policy.credited_frac(16) > frac12:
            self.assertFalse(sim.policy.is_exhausted())
            sim.state.offline_cap_hours = 24
        self.assertTrue(sim.policy.is_exhausted())


class RankingsEquivalenceTest(Base):
    def test_matches_full_sort(self):
        rnd = random.Random(5)
        species = list(self.model.spirit_order)
        for trial in range(20):
            sim = self.make(rep=trial)
            st = sim.state
            st.roster = {u: SpiritInst(u, rnd.choice(species), rnd.randint(1, 30), rnd.randint(10000, 12000), rnd.randint(10000, 12000))
                         for u in range(1, rnd.randint(5, 60))}
            uids = list(st.roster)
            rnd.shuffle(uids)
            st.assignment = {fid: [] for fid in st.assignment}
            for fid in st.assignment:
                st.assignment[fid] = [uids.pop() for _ in range(min(3, len(uids)))]
            sim.touch()
            bench, combat, assigned = sim.policy._rankings()
            k = self.econ.companion_slots
            ro = st.roster
            bench_all = [u for u in ro if u not in assigned]
            for r in self.model.basic_ids:
                full = sorted(bench_all, key=lambda u: (-self.econ.companion_power(ro[u].species, ro[u].level, r, ro[u].gather_bps), u))
                self.assertEqual(bench[r], full[: k + 1])
            ckey = lambda u: (-self.econ.combat_power(ro[u].species, ro[u].level, ro[u].combat_bps), u)  # noqa: E731
            full_c = sorted(ro, key=ckey)
            self.assertEqual(combat[: k + 2], full_c[: k + 2])
            bonus = [u for u in full_c[k:] if self.econ.trait(ro[u].species, "companion_hunt_drop_bps") > 0]
            got = [u for u in combat[k:] if self.econ.trait(ro[u].species, "companion_hunt_drop_bps") > 0]
            self.assertEqual(got[:1], bonus[:1])  # 狩りの入れ替え候補（上位 k 外で最良のボーナス精霊）が一致


if __name__ == "__main__":
    unittest.main()
