"""捕獲補助道具（2026-11-11 ユーザー決定、docs/late_sinks_showcase_debate_20261111.md 末尾）.

期待値は決定文（★2 ×1.10 / ★3 ×1.15 / ★4 ×1.20・上限 100%・試行ごとに 1 個・home_field・全体 ridge 解禁後・直接捕獲の履歴が必要・
off は完全回帰）から決め、実装の出力を写さない。
"""
import copy
import random
import unittest

from econ_sim import formulas, jsonio
from econ_sim.data_load import load_data
from econ_sim.economy import Economy
from econ_sim.model import Model
from econ_sim.runner import TOOL_COLS, _daily_rows, daily_columns
from econ_sim.sim import DAY, Simulator
from econ_sim.sim_config import load_personas
from _support import CONFIG_DIR, DATA_DIR

REF = jsonio.load_strict(CONFIG_DIR / "static_reference.json")


class Base(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.model = Model(load_data(DATA_DIR))
        cls.econ = Economy(cls.model)
        cls.cfg, _ = load_personas(CONFIG_DIR / "personas.json", cls.model)
        cls.rule = cls.model.capture_rules

    def make(self, pid="balanced", rep=0, days=3, **over):
        persona = copy.deepcopy(next(p for p in self.cfg["personas"] if p["id"] == pid))
        persona.update(over)
        return Simulator(self.econ, self.cfg, persona, rep, days, REF)

    def unlock_all(self, sim):
        # 解禁コストを払わずに全フィールドを解禁した状態にする（道具の条件だけを見るため）
        for f in self.model.field_order:
            if f not in sim.state.unlocked:
                sim.state.unlocked.append(f)


class FormulaTest(Base):
    def test_multiplier_and_cap(self):
        # 試行成功率 = min(10000, 基本 × 等級倍率)。基本 = 等級 bps × 光区間倍率。★1 は変わらない
        mult = {1: 10000, 2: 11000, 3: 11500, 4: 12000}
        for grade in (1, 2, 3, 4):
            for light in (0, 1, 20, 21, 60, 61, 100):
                base = formulas.capture_attempt_bps(grade, light, self.rule)
                tool = formulas.capture_tool_attempt_bps(grade, light, self.rule)
                self.assertEqual(tool, min(10000, base * mult[grade] // 10000), (grade, light))
                self.assertGreaterEqual(tool, base)
                self.assertLessEqual(tool, 10000)

    def test_encounter_q_star4(self):
        # ★4 p=0.18（逃走 3%+12%p/失敗）の遭遇あたり獲得 ≈ 0.5291（手計算の決定値）、★3 ≈ 0.8542
        q4, _ = formulas.encounter_expectation(4, self.rule, with_tool=True)
        q3, _ = formulas.encounter_expectation(3, self.rule, with_tool=True)
        self.assertAlmostEqual(float(q4), 0.5291, places=4)
        self.assertAlmostEqual(float(q3), 0.8542, places=4)
        self.assertEqual(formulas.encounter_expectation(4, self.rule), formulas.encounter_expectation(4, self.rule, with_tool=False))

    def test_no_tool_identical_to_base(self):
        # 道具 0 個なら道具版は道具なしの結果と同じ（乱数位置・逃走・芯切れ）
        r = random.Random(11)
        k = formulas.capture_k_max(self.rule)
        for _ in range(500):
            grade = r.randint(1, 4)
            u = [r.random() for _ in range(2 * k)]
            wicks = r.choice([-1, 0, 1, 3, 30])
            base = formulas.resolve_encounter(grade, self.rule, u, wicks, 6)
            self.assertEqual(formulas.resolve_encounter_tool(grade, self.rule, u, wicks, 6, 0), base + [0])

    def test_per_attempt_consumption_and_stockout(self):
        # 試行ごとに 1 個。在庫が尽きた後の試行は道具なし（基本成功率）で続き、逃走の乱数は同じ位置を使う
        r = random.Random(5)
        k = formulas.capture_k_max(self.rule)
        p_tool = formulas.capture_tool_attempt_bps(4, 20, self.rule)
        p_base = formulas.capture_attempt_bps(4, 20, self.rule)
        for _ in range(500):
            u = [r.random() for _ in range(2 * k)]
            stock = r.randint(0, 4)
            res, att, wused, _, tused = formulas.resolve_encounter_tool(4, self.rule, u, 30, 0, stock)
            self.assertEqual(tused, min(att, stock))
            self.assertEqual(wused, att)  # 芯は道具と別に試行ごと 1 個
            # 成功した試行の判定値は、その試行が道具付きなら p_tool 未満、道具なしなら p_base 未満
            if res == "success":
                self.assertLess(u[att - 1] * 10000, p_tool if att <= stock else p_base)
            # それより前の試行はすべて失敗（道具付きは p_tool 以上、道具なしは p_base 以上）
            for i in range(1, att if res == "success" else att + 1):
                if i <= att and not (res == "success" and i == att):
                    self.assertGreaterEqual(u[i - 1] * 10000, p_tool if i <= stock else p_base)

    def test_star1_does_not_consume(self):
        u = [0.5] * (2 * formulas.capture_k_max(self.rule))
        self.assertEqual(formulas.resolve_encounter_tool(1, self.rule, u, 5, 0, 5)[4], 0)

    def test_dex_capture_bonus_after_tool(self):
        # 図鑑の捕獲確率ボーナス（2026-11-12 決定）: 道具の後に加算、p > 0 のときだけ、上限 10000、逃走・道具消費は不変
        r = random.Random(23)
        k = formulas.capture_k_max(self.rule)
        p_tool = min(10000, formulas.capture_tool_attempt_bps(4, 20, self.rule) + 50)
        p_base = min(10000, formulas.capture_attempt_bps(4, 20, self.rule) + 50)
        for _ in range(500):
            u = [r.random() for _ in range(2 * k)]
            stock = r.randint(0, 4)
            grade = r.randint(1, 4)
            # ボーナス 0 は従来と同じ結果（完全回帰）
            self.assertEqual(formulas.resolve_encounter_tool(grade, self.rule, u, 30, 0, stock, 0),
                             formulas.resolve_encounter_tool(grade, self.rule, u, 30, 0, stock))
            res, att, _, _, tused = formulas.resolve_encounter_tool(4, self.rule, u, 30, 0, stock, 50)
            self.assertEqual(tused, min(att, stock))
            if res == "success":
                self.assertLess(u[att - 1] * 10000, p_tool if att <= stock else p_base)
            for i in range(1, att + (0 if res == "success" else 1)):
                self.assertGreaterEqual(u[i - 1] * 10000, p_tool if i <= stock else p_base)
        # 期待値: ボーナスで Q が上がり、散り（0）にはボーナスが付かない
        self.assertGreater(formulas.encounter_expectation(4, self.rule, capture_bonus_bps=50)[0],
                           formulas.encounter_expectation(4, self.rule)[0])
        self.assertEqual(formulas.capture_bonus_attempt_bps(formulas.capture_attempt_bps(4, 0, self.rule), 300), 0)


class ConditionTest(Base):
    def test_first_capture_invalid(self):
        sim = self.make(capture_tool="star4")
        self.unlock_all(sim)
        self.assertNotIn("aurora_deer", sim.state.first_capture)
        self.assertIsNone(sim.tool_for("aurora_deer", 4))  # 直接捕獲の履歴なし = 初捕獲は無効
        sim.state.first_capture["aurora_deer"] = (0, 1)
        self.assertEqual(sim.tool_for("aurora_deer", 4), "lure_ridge")

    def test_start_spirit_is_not_direct_capture(self):
        sim = self.make(capture_tool="star4")
        self.unlock_all(sim)
        start = {s["species"] for s in self.cfg["start"]["spirits"]}
        for sp in start:
            self.assertNotIn(sp, sim.state.first_capture)

    def test_before_ridge_invalid(self):
        sim = self.make(capture_tool="star4")
        for f in ("forest", "cave"):
            sim.state.unlocked.append(f)
        sim.state.first_capture["shadow_lantern"] = (0, 1)
        self.assertIsNone(sim.tool_for("shadow_lantern", 4))
        sim.state.unlocked.append("ridge")
        self.assertEqual(sim.tool_for("shadow_lantern", 4), "lure_cave")

    def test_home_field_not_encounter_field(self):
        # ridge で出会う shadow_lantern（固有 cave）は cave の道具。遭遇フィールドには依らない
        sim = self.make(capture_tool="star4")
        self.unlock_all(sim)
        sim.state.first_capture["shadow_lantern"] = (0, 1)
        sim.state.wallet["lure_cave"] = 3000
        sim.state.wallet["lure_ridge"] = 3000
        sim.capture_table = lambda fid, night: [{"spirit_id": "shadow_lantern", "weight": 1, "availability": "always"}]
        sim.state.wallet[sim.wick_id] = 30_000
        self.assertTrue(sim._start_encounter("ridge", 0, sim.t, (), sim.t + 10))
        pe = sim.pending
        self.assertGreaterEqual(pe["tool_attempts"], 1)
        self.assertEqual(sim.state.wallet["lure_ridge"], 3000)
        self.assertEqual(sim.state.wallet["lure_cave"], 3000 - 1000 * pe["tool_attempts"])
        self.assertEqual(sim.day_acc(0).lure_used, {"cave": pe["tool_attempts"]})

    def test_star4_mode_skips_other_grades_and_off(self):
        sim = self.make(capture_tool="star4")
        self.unlock_all(sim)
        sim.state.first_capture["moon_fox"] = (0, 1)
        self.assertIsNone(sim.tool_for("moon_fox", 3))  # star4 は ★4 だけ
        off = self.make()
        self.unlock_all(off)
        off.state.first_capture["aurora_deer"] = (0, 1)
        self.assertIsNone(off.tool_for("aurora_deer", 4))  # 既定 off

    def test_stockout_mid_encounter(self):
        # 在庫 1 個: 1 回目の試行だけ道具、残りは道具なし。芯は試行数ぶん
        sim = self.make(capture_tool="star4")
        self.unlock_all(sim)
        sim.state.first_capture["aurora_deer"] = (0, 1)
        sim.state.wallet["lure_ridge"] = 1000
        sim.capture_table = lambda fid, night: [{"spirit_id": "aurora_deer", "weight": 1, "availability": "always"}]
        seen_multi = False
        for day in range(40):
            sim.state.wallet["lure_ridge"] = 1000
            sim.state.wallet[sim.wick_id] = 30_000
            sim.pending = None
            sim._start_encounter("ridge", day, day * DAY, (), day * DAY + 10)
            pe = sim.pending
            self.assertEqual(pe["tool_attempts"], 1)
            self.assertEqual(sim.state.wallet["lure_ridge"], 0)
            self.assertEqual(sim.state.wallet[sim.wick_id], 30_000 - 1000 * pe["attempts"])
            seen_multi |= pe["attempts"] > 1
        self.assertTrue(seen_multi)


class PolicyTest(Base):
    def test_craft_respects_stock_target_and_reserve(self):
        sim = self.make(capture_tool="star4")
        self.unlock_all(sim)
        st = sim.state
        st.first_capture["aurora_deer"] = (0, 1)
        need = sim.policy.lure_per_day()
        self.assertEqual(set(need), {"lure_ridge"})  # 直接捕獲済みの ★4 は aurora_deer（固有 ridge）だけ
        target = need["lure_ridge"] * sim.policy.CAPTURE_TOOL_STOCK_DAYS
        # 予約ちょうどの狩り素材では作らない
        reserve = sim.policy.tool_reserve()
        st.wallet["hunt_ridge"] = reserve.get("hunt_ridge", 0)
        sim.policy.craft_lures()
        self.assertEqual(st.wallet["lure_ridge"], 0)
        # 余裕があれば目安まで作り、目安を超えて持たない（レシピ 1 → out 個なので最大 out−1 個不足で止まる）
        recipes = jsonio.load_strict(DATA_DIR / "crafting.json")["recipes"]
        out = next(r["output"]["amount"] for r in recipes if r["id"] == "lure_from_ridge")
        st.wallet["hunt_ridge"] = reserve.get("hunt_ridge", 0) + 1_000_000
        sim.policy.craft_lures()
        self.assertLessEqual(st.wallet["lure_ridge"], target * 1000)
        self.assertGreaterEqual(st.wallet["lure_ridge"], (target - (out - 1)) * 1000)
        self.assertEqual(st.wallet["lure_ridge"] % (out * 1000), 0)
        self.assertEqual(st.wallet["hunt_ridge"], reserve.get("hunt_ridge", 0) + 1_000_000 - st.wallet["lure_ridge"] // out)

    def test_off_never_crafts(self):
        sim = self.make()
        self.unlock_all(sim)
        sim.state.first_capture["aurora_deer"] = (0, 1)
        sim.state.wallet["hunt_ridge"] = 10_000_000
        sim.policy.craft_lures()
        self.assertEqual(sim.state.wallet["lure_ridge"], 0)


class ReviewAdditionsTest(Base):
    """2026-11-11 レビュー m4・ユーザー決定 M1/M2 の追加テスト."""

    def _pe(self, sim, **kw):
        pe = {"field": "ridge", "species": "aurora_deer", "grade": 4, "result": "flee", "attempts": 3, "seconds": 80,
              "remaining": 0, "start": sim.t, "index": 1, "full_wick": True, "tool_attempts": 0, "full_tool": False}
        pe.update(kw)
        return pe

    def test_complete_separates_tool_conformance(self):
        # 道具を使った遭遇は道具なしの適合度（grade_results_full）に入れず、full_tool のものだけ道具の full に入る
        sim = self.make(capture_tool="star4")
        sim.state.first_capture["aurora_deer"] = (0, 1)
        acc = sim.day_acc(sim.t // DAY)
        sim._complete_encounter(self._pe(sim, tool_attempts=3, full_tool=True, result="success"), sim.t)
        sim._complete_encounter(self._pe(sim, tool_attempts=2, full_tool=False), sim.t)
        sim._complete_encounter(self._pe(sim), sim.t)  # 道具なし
        self.assertEqual(acc.tool_grade, {(4, "enc"): 2, (4, "success"): 1, (4, "full_enc"): 1, (4, "full_success"): 1})
        self.assertEqual(acc.tool_attempts, 5)
        self.assertEqual(acc.grade_results_full, {(4, "enc"): 1})
        self.assertEqual(acc.tool_first_capture, 0)

    def test_release_keeps_direct_capture_history(self):
        # 直接捕獲の履歴は保有ではなく初捕獲の記録で判定する: 捕まえた個体を手放しても道具は効く
        sim = self.make(capture_tool="star4")
        self.unlock_all(sim)
        sim._complete_encounter(self._pe(sim, result="success"), sim.t)
        uids = [u for u, s in sim.state.roster.items() if s.species == "aurora_deer"]
        self.assertEqual(len(uids), 1)
        del sim.state.roster[uids[0]]  # 放出の代わり（放出順の規則に依らず、保有 0 の状態を作る）
        self.assertEqual(sim.tool_for("aurora_deer", 4), "lure_ridge")

    def test_min_stock_floor(self):
        # 使用側の在庫下限: 在庫 − 下限だけを遭遇で使う。在庫 ≤ 下限なら道具なし（決定 M1）
        cfg = copy.deepcopy(self.cfg)
        cfg["policy"]["capture_tool_min_stock"] = 2
        persona = copy.deepcopy(next(p for p in cfg["personas"] if p["id"] == "balanced"))
        persona["capture_tool"] = "star4"
        sim = Simulator(self.econ, cfg, persona, 0, 3, REF)
        self.unlock_all(sim)
        sim.state.first_capture["aurora_deer"] = (0, 1)
        sim.capture_table = lambda fid, night: [{"spirit_id": "aurora_deer", "weight": 1, "availability": "always"}]
        for day, stock in ((0, 3), (1, 2), (2, 1)):
            sim.pending = None
            sim.state.wallet["lure_ridge"] = stock * 1000
            sim.state.wallet[sim.wick_id] = 30_000
            sim._start_encounter("ridge", day, day * DAY, (), day * DAY + 10)
            self.assertEqual(sim.pending["tool_attempts"], min(sim.pending["attempts"], max(0, stock - 2)), stock)
            self.assertGreaterEqual(sim.state.wallet["lure_ridge"], min(stock, 2) * 1000)

    def test_wick_avoids_finite_reserve_only_when_tool_on(self):
        # 決定 M2: 道具 on では芯の制作が有限外形の狩り素材を残す余りを先に使い、off は進行予約だけ（finite_hunt_reserve を呼ばない）
        on = self.make(capture_tool="star4")
        self.unlock_all(on)
        pol = on.policy
        st = on.state
        finite = pol.finite_hunt_reserve()
        prog = pol.progress_reserve()
        self.assertTrue(finite)
        need_wick = pol.wick_per_day()
        st.wallet[on.wick_id] = 0
        for h in self.model.hunt_resource_ids():
            st.wallet[h] = prog.get(h, 0) + finite.get(h, 0)
        rec = self.model.recipes["wick_from_meadow"]
        extra = -(-need_wick // rec["output"]["amount"]) * rec["inputs"][0]["amount"] * 1000
        st.wallet["hunt_meadow"] += extra
        before = dict(st.wallet)
        pol.ensure_wick()
        self.assertGreaterEqual(st.wallet[on.wick_id], need_wick * 1000)
        for h in ("hunt_forest", "hunt_cave", "hunt_ridge"):
            self.assertEqual(st.wallet[h], before[h], h)  # 有限外形の分に手を付けない
        # 余りが無ければ進行予約だけで作り、芯は不足させない（進行 > 芯 > 有限外形）
        st.wallet[on.wick_id] = 0
        for h in self.model.hunt_resource_ids():
            st.wallet[h] = prog.get(h, 0) + finite.get(h, 0)
        pol.ensure_wick()
        self.assertGreaterEqual(st.wallet[on.wick_id], need_wick * 1000)

        off = self.make()
        self.unlock_all(off)

        def boom():
            raise AssertionError("off で有限外形予約を参照した")
        off.policy.finite_hunt_reserve = boom
        off.state.wallet[off.wick_id] = 0
        for h in self.model.hunt_resource_ids():
            off.state.wallet[h] = 10_000_000
        off.policy.ensure_wick()
        self.assertGreaterEqual(off.state.wallet[off.wick_id], off.policy.wick_per_day() * 1000)


class OffRegressionTest(Base):
    def test_star4_identical_before_unlock(self):
        # 道具は全体 ridge 解禁前に作らず使わないので、star4 でも解禁前の日次行は off と完全に同じ（乱数の消費順も同じ）
        days = 10
        off = self.make(days=days)
        on = self.make(days=days, capture_tool="star4")
        off.run()
        on.run()
        self.assertNotIn("ridge", off.state.unlocked)
        self.assertEqual(_daily_rows(off, self.model), _daily_rows(on, self.model))

    def test_off_columns_zero(self):
        sim = self.make(days=3)
        sim.run()
        cols = daily_columns(self.model)
        for row in _daily_rows(sim, self.model):
            r = dict(zip(cols, row))
            for c in cols:
                if c in TOOL_COLS or c.startswith("lure_") or (c.startswith(("wallet_", "earned_", "spent_")) and "_lure_" in c + "_"):
                    self.assertIn(r[c], ("0", "0.000"), c)


if __name__ == "__main__":
    unittest.main()
