"""사용자 규칙 F: 개체값(F2)·보유 상한(F4)·고유 필드 특수재화(F1)·도감 보너스(2026-11-12 개편)와 전환 구간."""
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
    """図鑑ボーナス改編（2026-11-12 ユーザー決定、docs/spirit_roster_expansion_20261112.md の配分表・計算規則）."""

    # 設計書「다 모았을 때 종류별 합계」（配分表から手で合計した値）。費用減少 2 種は 2026-11-13 ユーザー決定で −1% → −5%
    ALL20 = {"resource_output": {"dew": 350, "bloom": 250, "crystal": 400, "hunt_meadow": 100, "hunt_forest": 150,
                                 "hunt_cave": 300, "hunt_ridge": 300},
             "upgrade_cost_down": 500, "craft_cost_down": 500, "capture_attempt_up": 50}

    def register(self, sim, *species):
        for sp in species:
            sim._add_spirit(sp)

    def test_facility_rate_uses_given_bps(self):
        e = self.econ
        members = [("dewdrop", 1)] * 3
        base = e.facility_rate("dew_spring", 1, members, False, 0)
        self.assertEqual(e.facility_rate("dew_spring", 1, members, False, 300), base * 10300 // 10000)

    def test_map_start_and_all(self):
        e = self.econ
        self.assertEqual(e.dex_map({"sparkle", "dewdrop", "flower_lamp"}),
                         {"resource_output": {"bloom": 100, "dew": 50}, "upgrade_cost_down": 0, "craft_cost_down": 0,
                          "capture_attempt_up": 0})
        self.assertEqual(e.dex_map(set(self.model.spirits)), self.ALL20)
        # 全部上限（自原 1000・特殊 1000/300）の下にある
        self.assertTrue(all(v < 1000 for v in self.ALL20["resource_output"].values()))

    def test_map_cap_per_resource(self):
        model = Model(load_data(DATA_DIR, [
            {"op": "set", "file": "rules", "path": "/dex_bonus/cap_bps/resource_output", "value": 300},
            {"op": "set", "file": "rules", "path": "/dex_bonus/cap_bps/upgrade_cost_down", "value": 40}]))
        got = Economy(model).dex_map(set(model.spirits))
        # 資源別に切る（dew 350→300, crystal 400→300, hunt_cave/hunt_ridge 300 はそのまま, bloom 250 はそのまま）
        self.assertEqual(got["resource_output"], {"dew": 300, "bloom": 250, "crystal": 300, "hunt_meadow": 100,
                                                  "hunt_forest": 150, "hunt_cave": 300, "hunt_ridge": 300})
        self.assertEqual(got["upgrade_cost_down"], 40)

    def test_idle_per_resource(self):
        sim = self.make()
        st = sim.state
        rates = sim.idle_rates(frozenset(), False)
        for fid, uids in st.assignment.items():
            res = self.model.facilities[fid]["produces"]
            if not uids:
                continue
            raw = self.econ.facility_rate(fid, st.fac_level[fid], sim.members(uids), False, 0)
            want = {"dew": 50, "bloom": 100}.get(res, 0)  # 開始 3 種: dewdrop=dew 50, sparkle・flower_lamp=bloom 100
            self.assertEqual(rates[res], raw * (10000 + want) // 10000, res)

    def test_direct_and_hunt_scaled(self):
        sim = self.make()
        node = next(n for n in self.model.fields["meadow"]["gather_nodes"] if n["resource"] == "bloom")
        raw = self.econ.direct_rate(node, sim.tool_id, sim.state.tool_level, [])
        self.assertEqual(sim.direct_rate(node, []), raw * 10100 // 10000)
        drop = self.model.fields["meadow"]["hunt"]["drops"][0]
        party = tuple(sorted(sim.state.roster))
        before = sim.hunt_rate_live("meadow", drop, party, sim.t)
        self.register(sim, "sunset_bird")  # hunt_meadow +100
        self.assertEqual(sim.hunt_rate_live("meadow", drop, party, sim.t), before * 10100 // 10000)

    def test_home_material_scaled(self):
        sim = self.make("light_1h")
        self.assertEqual(sim.home_rates(frozenset()).get("hunt_meadow"), 1500)
        self.register(sim, "sunset_bird")
        sim.policy.reassign()
        uids = [u for us in sim.state.assignment.values() for u in us]
        raw = self.econ.home_material_detail(sim.members(uids), None)
        want = {k: v * 10100 // 10000 if k[0] == "hunt_meadow" else v for k, v in raw.items()}
        self.assertEqual(self.econ.home_material_detail(sim.members(uids), sim.dex()["resource_output"]), want)

    def test_upgrade_and_craft_discount(self):
        sim = self.make()
        cands = {c.label: c.costs for c in sim.policy.candidates()}
        self.register(sim, "shadow_lantern")
        after = {c.label: c.costs for c in sim.policy.candidates()}
        checked = 0
        for label, costs in cands.items():
            if label.startswith(("facility:", "slot:")):
                self.assertEqual(after[label], [{**c, "amount": c["amount"] - c["amount"] * 500 // 10000} for c in costs])
                checked += 1
            elif label in after:
                self.assertEqual(after[label], costs, label)  # 道具・オフライン上限・精霊は対象外
        self.assertGreater(checked, 0)
        # 制作は材料 × 回数の総量に掛ける（−5%）: 草原素材 5 × 20 回 = 100 → 95（単位ごとなら 5 × 20 = 100 のまま）
        self.register(sim, "star_whale")
        sim.state.wallet["hunt_meadow"] = 100_000
        sim.craft("wick_from_meadow", 20)
        self.assertEqual(sim.state.wallet["hunt_meadow"], 100_000 - 95_000)
        sim.state.wallet["hunt_meadow"] = 10_000
        sim.craft("wick_from_meadow", 1)  # 5 → 5（割引額 5×500//10000 = 0、費用は切り上げ）
        self.assertEqual(sim.state.wallet["hunt_meadow"], 5_000)

    def test_capture_bonus_and_conformance_split(self):
        # 図鑑の捕獲確率ボーナス: 同じ乱数ブロックで、オーロラ鹿の登録前後の遭遇は確率だけが変わる（種・試行の乱数位置は不変）
        from unittest import mock
        from econ_sim import formulas
        a, b = self.make(), self.make()
        self.register(b, "aurora_deer")
        seen: dict[str, list[int]] = {"a": [], "b": []}
        for key, sim in (("a", a), ("b", b)):
            real = formulas.resolve_encounter_tool

            def spy(*args, _k=key, _real=real):
                seen[_k].append(args[6])
                return _real(*args)

            with mock.patch("econ_sim.sim.formulas.resolve_encounter_tool", side_effect=spy):
                for _ in range(8):
                    sim._capture("meadow", 0, False)
        self.assertTrue(seen["a"] and set(seen["a"]) == {0})
        self.assertTrue(seen["b"] and set(seen["b"]) == {50})  # オーロラ鹿 +0.5%p が全遭遇に渡る
        acc_a, acc_b = a.day_acc(0), b.day_acc(0)
        self.assertEqual(sum(acc_a.dex_capture_enc.values()), 0)
        self.assertGreater(sum(acc_a.grade_results_full.values()), 0)
        n_b = sum(v for (g, k), v in acc_b.grade_results.items())
        self.assertEqual(sum(acc_b.dex_capture_enc.values()), n_b)  # 完了した全遭遇を数える
        self.assertEqual(acc_b.grade_results_full, {})  # 確率適合度（基本規則 Q）の集計から外す
        # 代わりに (等級, bps) 別に別集計する（件数は完了遭遇以下、bps は全部 50）
        self.assertTrue(acc_b.dex_capture_full)
        self.assertEqual({b for (_, b) in acc_b.dex_capture_full}, {50})
        self.assertLessEqual(sum(v[0] for v in acc_b.dex_capture_full.values()), n_b)
        self.assertTrue(all(0 <= v[1] <= v[0] for v in acc_b.dex_capture_full.values()))
        self.assertEqual(acc_a.dex_capture_full, {})

    def test_dex_costs_kind_allowlist(self):
        sim = self.make()
        costs = [{"resource": "dew", "amount": 200}]
        for kind in ("resource_output", "capture_attempt_up", "nope"):
            with self.assertRaises(ValueError, msg=kind):
                sim.dex_costs(costs, kind)
        self.assertEqual(sim.dex_costs(costs, "upgrade_cost_down"), costs)  # 図鑑に該当種なし → 割引 0

    def test_registration(self):
        sim = self.make()
        self.assertEqual(sim.state.dex, {"sparkle", "dewdrop", "flower_lamp"})  # 開始精霊も登録
        for _ in range(6):
            sim._capture("meadow", 0, False)
        self.assertGreater(len(sim.state.dex), 3)
        self.assertEqual(sim.state.dex, {s.species for s in sim.state.roster.values()} | {"sparkle", "dewdrop", "flower_lamp"})


class DexConformanceTest(FBase):
    """図鑑ボーナス付き遭遇の適合度（2026-11-13 リビュー Minor 1）: (等級, bps) 別に集計し、Q はボーナス込みの解析値."""

    def test_encode_parse_roundtrip(self):
        from econ_sim.metrics_capture import encode_dex_full, parse_dex_full
        d = {(4, 50): [12, 5], (2, 300): [7, 7]}
        s = encode_dex_full(d)
        self.assertEqual(s, "2:300:7:7;4:50:12:5")
        self.assertEqual(parse_dex_full(s), d)
        self.assertEqual((encode_dex_full({}), parse_dex_full("")), ("", {}))

    def test_rows_per_grade_and_bps(self):
        from econ_sim import formulas
        from econ_sim.metrics import wilson
        from econ_sim.metrics_capture import dex_conformance
        rule = self.model.capture_rules
        q0 = formulas.encounter_expectation(4, rule)[0]
        q50 = formulas.encounter_expectation(4, rule, capture_bonus_bps=50)[0]
        self.assertGreater(q50, q0)
        n = 4000
        k = round(float(q50) * n)  # 観測 = ボーナス込みの Q
        k0 = round(float(q0) * n) - 120  # Q から大きく外れた観測
        data = {"a": {(4, 50): [n // 2, k // 2], (3, 50): [10, 8]}, "b": {(4, 50): [n - n // 2, k - k // 2]},
                "x": {(4, 50): [n, k0]}}  # x は比較群の 2 番目以降（合算しない）
        rows = dex_conformance(data, ["a", "b"], rule, 30, wilson)
        self.assertEqual([(r["grade"], r["bps"], r["n"], r["k"]) for r in rows], [(3, 50, 10, 8), (4, 50, n, k)])
        self.assertEqual(rows[0]["evaluation"], "INCONCLUSIVE")  # 件数不足
        self.assertEqual(rows[1]["evaluation"], "PASS")
        self.assertEqual(rows[1]["q"], q50)
        bad = dex_conformance({"x": {(4, 50): [n, k0]}}, ["x"], rule, 30, wilson)
        self.assertEqual(bad[0]["evaluation"], "WARN")


class TransitionTest(FBase):
    def test_window(self):
        sim = self.make()
        self.assertFalse(sim.in_transition(10_000))  # 開始フィールドの解禁は移行区間に数えない
        sim.state.field_unlock_time["forest"] = 2000
        self.assertTrue(sim.in_transition(2000 + 1439))
        self.assertFalse(sim.in_transition(2000 + 1440))



class FlagTest(FBase):
    """F1 の個体値・図鑑適用と開始精霊の個体値抽選はデータのフラグで切り替わる（個体値は既定 false、図鑑は 2026-11-12 から true）."""

    def test_home_material_flags(self):
        members = [("dewdrop", 1, 12000, 10000)]
        dex = {"hunt_meadow": 500, "hunt_forest": 900}  # 図鑑はその狩り素材の bps だけが掛かる
        # 既定: 図鑑 true・個体値 false → 500 × 1.05 = 525
        self.assertEqual(self.econ.home_material_per_day(members, dex), {"hunt_meadow": 525})
        self.assertEqual(self.econ.home_material_per_day(members, {"hunt_forest": 900}), {"hunt_meadow": 500})
        off = Economy(Model(load_data(DATA_DIR, [
            {"op": "set", "file": "rules", "path": "/home_material/apply_dex_to_home_material", "value": False}])))
        self.assertEqual(off.home_material_per_day(members, dex), {"hunt_meadow": 500})
        model = Model(load_data(DATA_DIR, [
            {"op": "set", "file": "rules", "path": "/home_material/apply_individual_to_home_material", "value": True}]))
        econ = Economy(model)
        # 500 × 1.2 = 600 → 図鑑 +5% = 630
        self.assertEqual(econ.home_material_per_day(members, dex), {"hunt_meadow": 630})

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
