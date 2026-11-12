"""研究ツリー: 公式の乗算順・検証器規則・完了境界での生産分割・ペルソナ（cap/off/短縮）・共通乱数・決定性・CI."""
import copy
import tempfile
import unittest
from pathlib import Path

from econ_sim import formulas, jsonio, metrics, runner
from econ_sim.data_load import load_data
from econ_sim.economy import Economy
from econ_sim.model import Model
from econ_sim.sim import Simulator
from econ_sim.sim_config import SimConfigError, load_personas
from econ_sim.validate import research_r_neutral, validate
from _support import CONFIG_DIR, DATA_DIR, FIXTURES_DIR

NEW_PERSONAS = ("balanced_noresearch", "balanced_research_cap")
# MVP では研究短縮商品を除外（ユーザー決定 2026-11-09）。kind・検証規則・シミュ機能は残すので、試験用商品をパッチで足して検査する
SKIP_PRODUCT = {"id": "test_skip_60", "name": "시험용 연구 단축", "kind": "research_time_skip", "price_robux": 25,
                "purchase_limit_total": 0, "purchase_limit_per_day": 3, "effects": [{"type": "research_time_minutes", "minutes": 60}]}
SKIP_OPS = [{"op": "append", "file": "products", "path": "/products", "value": SKIP_PRODUCT}]
SKIP_BUY = {"product_id": "test_skip_60", "day": 0, "every_days": 0, "until_day": 59, "when": "production_research_active"}


def error_codes(issues):
    return {i.code for i in issues if i.level == "ERROR"}


class FormulaOrderTest(unittest.TestCase):
    def test_multiplicative_not_additive(self):
        # 図鑑 +3% の後に研究 +4% を掛ける（決定 C2）。加算 +7% とは値が違う
        raw = 357990
        dex_then = raw * 10300 // 10000
        self.assertEqual(formulas.idle_dex_research_milli(raw, 300, 400), dex_then * 10400 // 10000)
        self.assertNotEqual(formulas.idle_dex_research_milli(raw, 300, 400), raw * 10700 // 10000)

    def test_floor_and_zero(self):
        self.assertEqual(formulas.research_scaled_milli(24, 400), 24)  # 24.96 → 切り捨て
        self.assertEqual(formulas.research_scaled_milli(25, 400), 26)
        self.assertEqual(formulas.research_scaled_milli(12345, 0), 12345)
        with self.assertRaises(formulas.FormulaError):
            formulas.research_scaled_milli(-1, 400)


class ResearchValidatorTest(unittest.TestCase):
    def check(self, ops, code):
        issues = validate(load_data(DATA_DIR, ops))
        self.assertIn(code, error_codes(issues), "\n".join(i.format() for i in issues))

    def test_required_fixtures_exist(self):
        names = {p.name for p in FIXTURES_DIR.glob("broken_*.json")}
        for n in ("broken_research_budget.json", "broken_research_r_neutral.json", "broken_research_forbidden_effect.json",
                  "broken_research_paid_product.json", "broken_research_ecology_speedup.json", "broken_subscription_progress.json",
                  "broken_research_hunt_resource_effect.json"):
            self.assertIn(n, names)

    def test_real_data_r_neutral_both_methods(self):
        m = Model(load_data(DATA_DIR))
        self.assertEqual(research_r_neutral(m), ("enumeration", []))
        method, viol = research_r_neutral(m, limit=1)  # 列挙上限を超えさせて保守検査に切り替える
        self.assertEqual((method, viol), ("conservative", []))

    def test_conservative_check_catches_violation(self):
        ops = [{"op": "set", "file": "research", "path": "/nodes/id:a1/prerequisites", "value": []}]
        method, viol = research_r_neutral(Model(load_data(DATA_DIR, ops)), limit=1)
        self.assertEqual(method, "conservative")
        self.assertTrue(viol)

    def test_reserve_cannot_be_used(self):
        # 1200 + 予備 300 = 1500 でも ERROR（予備は未検証候補）
        ops = [{"op": "set", "file": "research", "path": "/nodes/id:i3/effects", "value": [{"type": "basic_idle_bps", "value_bps": 700}]}]
        self.check(ops, "RULE_RESEARCH_BUDGET")

    def test_purchasable_research_resource(self):
        self.check([{"op": "set", "file": "resources", "path": "/resources/id:research/purchasable", "value": True}], "RULE_RESEARCH_PAID")

    def test_pass_granting_research(self):
        # 2026-11-11 初心者パス削除後は、外形商品に付けたミッション報酬形の効果で検査する（missions の付与資源も対象）
        ops = [{"op": "append", "file": "products", "path": "/products/id:lantern_skin_glow/effects",
                "value": {"type": "mission_rewards", "retroactive": True, "missions": [
                    {"id": "bp_rp", "condition": {"type": "capture_count", "amount": 1}, "rewards": [{"resource": "research", "amount": 5}]}]}}]
        self.check(ops, "RULE_RESEARCH_PAID")

    def test_offline_cap_product_forbidden(self):
        ops = [{"op": "append", "file": "products", "path": "/products/id:monthly_membership/effects", "value": {"type": "offline_cap_hours", "amount": 12}}]
        self.check(ops, "RULE_PAID_OFFLINE_CAP")

    def test_skip_product_rules(self):
        self.assertNotIn("research_skip_60", Model(load_data(DATA_DIR)).products)  # MVP から除外
        self.assertFalse(error_codes(validate(load_data(DATA_DIR, SKIP_OPS))))  # kind 自体は許可のまま
        ops = SKIP_OPS + [{"op": "set", "file": "products", "path": "/products/id:test_skip_60/effects",
                           "value": [{"type": "research_time_minutes", "minutes": 60, "amount": 1}]}]
        self.check(ops, "RULE_PRODUCT_EFFECT")  # コスト・条件の免除は不可

    def test_duration_multiple_of_step(self):
        self.check([{"op": "set", "file": "research", "path": "/nodes/id:i1/duration_minutes", "value": 32}], "RULE_RESEARCH_DURATION")

    def test_cycle_and_track(self):
        self.check([{"op": "set", "file": "research", "path": "/nodes/id:i1/prerequisites", "value": ["a1"]}], "RULE_RESEARCH_GRAPH")
        self.check([{"op": "set", "file": "research", "path": "/nodes/id:e1/effects",
                     "value": [{"type": "basic_idle_bps", "value_bps": 100}]}], "RULE_RESEARCH_TRACK")

    def test_forbidden_effect_types(self):
        for et in ("offline_cap_hours", "storage_capacity", "production_slot", "spirit_stat_bonus", "hunt_drop_bonus", "encounter_rate_bonus"):
            with self.subTest(et):
                self.check([{"op": "set", "file": "research", "path": "/nodes/id:e1/effects", "value": [{"type": et, "value_bps": 100}]}],
                           "RULE_RESEARCH_EFFECT")


class ResearchSimBase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        model = Model(load_data(DATA_DIR))
        cls.model = model
        cls.econ = Economy(model)
        cls.cfg, _ = load_personas(CONFIG_DIR / "personas.json", model)
        cls.ref = jsonio.load_strict(CONFIG_DIR / "static_reference.json")

    def make(self, persona_id, patch=None, days=2):
        persona = copy.deepcopy(next(p for p in self.cfg["personas"] if p["id"] == persona_id))
        persona.update(patch or {})
        return Simulator(self.econ, self.cfg, persona, 0, days, self.ref)


class CompletionBoundaryTest(ResearchSimBase):
    def test_offline_split_without_retroactive_effect(self):
        sim = self.make("balanced")  # 開始 07:00=420、オフライン扱い（上限 720 分）
        t0 = sim.t
        rate0 = sim.idle_rates(frozenset(), False)["dew"]
        sim.state.research_active["i1"] = t0 + 100  # 進行中（コストは支払い済みとみなす）
        sim.advance(t0 + 300)
        rate1 = formulas.research_scaled_milli(rate0, 400)
        g0, c0 = divmod(rate0 * 100, 60)
        g1, _ = divmod(rate1 * 200 + c0, 60)
        self.assertEqual(sim.state.research_done_time, {"i1": t0 + 100})
        self.assertEqual(sim.state.wallet["dew"], g0 + g1)
        self.assertLess(sim.state.wallet["dew"], rate1 * 300 // 60)  # 完了効果を前の区間に遡及していない
        self.assertEqual(sim.idle_rates(frozenset(), False)["dew"], rate1)

    def test_completion_before_offline_cap_end(self):
        sim = self.make("balanced")  # 開始 420、上限 720 分 → 認定は 1140 まで（夜 1200 より前）
        t0 = sim.t
        rate0 = sim.idle_rates(frozenset(), False)["dew"]
        sim.state.research_active["i1"] = t0 + 600  # 1020: 上限内で完了
        sim.advance(t0 + 800)  # 1220: 80 分は失効
        rate1 = formulas.research_scaled_milli(rate0, 400)
        g0, c0 = divmod(rate0 * 600, 60)
        g1, _ = divmod(rate1 * 120 + c0, 60)
        acc = sim.day_acc(0)
        self.assertEqual(sim.state.wallet["dew"], g0 + g1)
        self.assertEqual((acc.minutes["off_credited"], acc.minutes["off_lost"]), (720, 80))
        self.assertEqual(sim.state.research_done_time["i1"], t0 + 600)

    def test_completion_after_offline_cap_end(self):
        sim = self.make("balanced")
        t0 = sim.t
        rate0 = sim.idle_rates(frozenset(), False)["dew"]
        sim.state.research_active["i1"] = t0 + 760  # 1180: 上限（1140）後の失効区間で完了
        sim.advance(t0 + 800)
        acc = sim.day_acc(0)
        self.assertEqual(sim.state.wallet["dew"], rate0 * 720 // 60)  # 認定分は全て旧生産率（完了効果なし）
        self.assertEqual((acc.minutes["off_credited"], acc.minutes["off_lost"]), (720, 80))
        self.assertEqual(sim.state.research_done_time["i1"], t0 + 760)  # タイマーは実時間で進む
        self.assertEqual(sim.idle_rates(frozenset(), False)["dew"], formulas.research_scaled_milli(rate0, 400))

    def test_completion_exactly_at_window_end(self):
        sim = self.make("balanced")
        t0 = sim.t
        rate0 = sim.idle_rates(frozenset(), False)["dew"]
        sim.state.research_active["i1"] = t0 + 60
        sim.advance(t0 + 60)
        self.assertEqual(sim.state.wallet["dew"], rate0 * 60 // 60)
        self.assertIn("i1", sim.state.research_done)

    def test_direct_rate_uses_gather_research(self):
        sim = self.make("balanced")
        node = self.model.fields["meadow"]["gather_nodes"][0]
        base = sim.direct_rate(node, [])
        sim.complete_research("i1", sim.t)
        self.assertEqual(sim.direct_rate(node, []), base)  # 方置研究は直接に効かない
        sim.complete_research("a1", sim.t)
        self.assertEqual(sim.direct_rate(node, []), formulas.research_scaled_milli(base, 400))


class PersonaModeTest(ResearchSimBase):
    def test_cap_completes_instantly_without_cost(self):
        sim = self.make("balanced_research_cap", days=3)
        start = sim.game_start
        # 開始時点で草原・図鑑 3 の条件を満たすノードは即完了（コスト・待ちなし）
        self.assertEqual({n for n, t in sim.state.research_done_time.items() if t == start}, {"i1", "a1", "e1"})
        self.assertEqual(sim.r_idle, {"dew": 400, "bloom": 400, "crystal": 400})
        sim.run()
        self.assertFalse(sim.state.research_active)
        rp = self.model.research_resource
        self.assertEqual(sum(acc.spent.get(rp, 0) for acc in sim.acc.values()), 0)
        for nid, t in sim.state.research_done_time.items():
            for f in self.model.research_nodes[nid]["required_fields"]:
                self.assertLessEqual(sim.state.field_unlock_time[f], t)
        if "forest" in sim.state.unlocked and len(sim.state.dex) >= 4:
            self.assertIn("i2", sim.state.research_done)

    def test_noresearch_has_zero_research(self):
        sim = self.make("balanced_noresearch", days=8)
        sim.run()
        rp = self.model.research_resource
        self.assertEqual((sim.state.research_done, sim.state.research_active, sim.r_idle, sim.r_direct), (set(), {}, {}, {}))
        earned = sum(acc.earned.get(("release", rp), 0) for acc in sim.acc.values())
        self.assertEqual(sim.state.wallet[rp], earned)
        self.assertGreater(earned, 0)  # 研究ポイントは貯まるが使わない

    def test_natural_priority_and_ecology_reservation(self):
        sim = self.make("balanced")
        w = sim.state.wallet
        rp = self.model.research_resource
        w[rp] = 18_000  # 生態 e1(6) は払えるが、条件を満たした生産 i1(12) の予約後は 6 しか残らない
        self.assertEqual(sim.policy.pick_research(), "e1")  # i1 は露・花光不足で開始不可 → 予約 12 + e1 6 = 18 で可
        w[rp] = 17_000
        self.assertIsNone(sim.policy.pick_research())  # 予約分を食うので生態研究は始めない
        w.update({rp: 100_000, "dew": 1_000_000, "bloom": 1_000_000})
        # 森解禁目標（各 1500 個）に不足がある間は、回収 1 日超の i1 は ETA を悪化させるので始めない
        self.assertEqual(sim.policy.pick_research(), "e1")
        w.update({"dew": 10_000_000, "bloom": 10_000_000})
        self.assertEqual(sim.policy.pick_research(), "i1")  # 目標を損なわなければ production（I→A のデータ順）が先

class SkipMechanicsTest(unittest.TestCase):
    """研究時間短縮（MVP 商品なし、試験用商品で機能だけ検査）."""

    @classmethod
    def setUpClass(cls):
        cls.model = Model(load_data(DATA_DIR, SKIP_OPS))
        cls.econ = Economy(cls.model)
        cls.cfg, _ = load_personas(CONFIG_DIR / "personas.json", cls.model)
        cls.ref = jsonio.load_strict(CONFIG_DIR / "static_reference.json")

    def make(self):
        persona = copy.deepcopy(next(p for p in self.cfg["personas"] if p["id"] == "balanced"))
        persona.update({"id": "balanced_skip_test", "purchases": [dict(SKIP_BUY)]})
        return Simulator(self.econ, self.cfg, persona, 0, 2, self.ref)

    def test_skip_reduces_remaining_only(self):
        sim = self.make()
        w = sim.state.wallet
        rp = self.model.research_resource
        day = sim.t // 1440
        self.assertFalse(sim.buy_product("test_skip_60", day))  # 進行中の研究がなければ買えない
        self.assertEqual(sim.state.robux, 0)
        w.update({rp: 100_000, "dew": 1_000_000, "bloom": 1_000_000})
        sim.start_research("e1")
        self.assertFalse(sim.buy_product("test_skip_60", day))  # 生態研究は短縮不可
        sim.complete_research("e1", sim.t)
        before = dict(w)
        sim.start_research("i1")
        self.assertEqual(before["dew"] - w["dew"], 60_000)  # コストは免除されない
        self.assertTrue(sim.buy_product("test_skip_60", day))  # 30 分 → 60 分短縮で即完了
        self.assertIn("i1", sim.state.research_done)
        self.assertEqual(sim.state.research_done_time["i1"], sim.t)
        self.assertEqual(before["dew"] - w["dew"], 60_000)

    def test_skip_daily_limit(self):
        sim = self.make()
        w = sim.state.wallet
        w.update({"research": 100_000, "dew": 10_000_000, "bloom": 10_000_000, "crystal": 1_000_000})
        sim.complete_research("i1", sim.t)
        sim.complete_research("a1", sim.t)
        sim.state.unlocked.append("forest")
        for sp in ("shard_light", "sunset_bird"):
            sim._add_spirit(sp)
        sim.start_research("i2")  # 120 分
        sim.state.research_active["i2"] = sim.t + 1000
        self.assertTrue(sim.buy_research_skips())
        self.assertEqual(sim.state.purchase_day[("test_skip_60", sim.t // 1440)], 3)  # 日次上限 3
        self.assertEqual(sim.state.research_active["i2"], sim.t + 1000 - 180)

    def test_config_rejects_skip_without_trigger(self):
        doc = jsonio.load_strict(CONFIG_DIR / "personas.json")
        p = copy.deepcopy(next(x for x in doc["personas"] if x["id"] == "balanced"))
        p.update({"id": "skip_no_trigger", "purchases": [{k: v for k, v in SKIP_BUY.items() if k != "when"}]})
        doc["personas"].append(p)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "personas.json"
            path.write_text(jsonio.dump_pretty(doc), encoding="utf-8")
            with self.assertRaises(SimConfigError):
                load_personas(path, self.model)


class CommonRandomTest(ResearchSimBase):
    def test_new_personas_share_rng_keys(self):
        # 乱数キーは (master_seed, pairing_group, replicate, stream)。persona_id・購入・研究モードは含まない
        base = self.make("balanced")
        for pid in NEW_PERSONAS + ("balanced_paid",):
            with self.subTest(pid):
                sim = self.make(pid)
                self.assertEqual(sim.group, "balanced")
                for day in (0, 9, 40):
                    self.assertEqual([sim.capture_rng(day).random() for _ in range(5)], [base.capture_rng(day).random() for _ in range(5)])
                    self.assertEqual(sim.individual_rng(day).random(), base.individual_rng(day).random())
        renamed = self.make("balanced_research_cap", {"id": "x", "purchases": []})
        self.assertEqual(renamed.capture_rng(2).random(), base.capture_rng(2).random())


class ResearchDeterminismTest(unittest.TestCase):
    def test_same_csv_bytes(self):
        names = ("daily.csv", "events.csv", "spirit_daily.csv")
        outs = []
        with tempfile.TemporaryDirectory() as tmp:
            for i, workers in enumerate((1, 2)):
                out = Path(tmp) / f"r{i}"
                runner.run_all(DATA_DIR, CONFIG_DIR / "personas.json", CONFIG_DIR / "static_reference.json", out,
                               replicates=2, days=8, workers=workers, persona_ids=list(NEW_PERSONAS) + ["balanced_paid"])
                outs.append({n: (out / n).read_bytes() for n in names})
        for n in names:
            with self.subTest(n):
                self.assertEqual(outs[0][n], outs[1][n])
        self.assertIn(b"research_complete", outs[0]["events.csv"])


class SegmentCensorTest(unittest.TestCase):
    """segment_pairs: base だけ未到達は下限値、test だけ未到達は上限値、両方未到達・未進入は除外（件数は別）."""

    def test_censor_conventions(self):
        rd = metrics.RunData.__new__(metrics.RunData)
        rd.model = Model(load_data(DATA_DIR))
        rd.censor_minutes = 10_000
        rd.reps = {"t": [0, 1, 2, 3, 4], "b": [0, 1, 2, 3, 4]}
        unlock = {("t", 0): 1000, ("b", 0): 2000, ("t", 1): 1000, ("b", 1): None, ("t", 2): None, ("b", 2): 5000,
                  ("t", 3): None, ("b", 3): None, ("t", 4): 3000, ("b", 4): 4000}
        rd.events = {}
        for (p, rep), v in unlock.items():
            rd.events.setdefault((p, "field_unlock", "forest"), {})[rep] = (None, v, None) if v is not None else (None, None, None)
            rd.events.setdefault((p, "game_start", "first_session"), {})[rep] = (1, 0, None)
        rd.events[("t", "field_unlock", "cave")] = {4: (None, 3500, None)}
        rd.events[("b", "field_unlock", "cave")] = {4: (None, 5000, None)}
        sp = metrics.segment_pairs(rd, "t", "b", "meadow", "forest")
        self.assertEqual((sp["both"], sp["base_censored"], sp["test_censored"], sp["neither"]), (2, 1, 1, 1))
        self.assertEqual(sorted(sp["vals"]), sorted([0.5, 0.25, 1 - 1000 / 10_000, 1 - 10_000 / 5000]))
        sp2 = metrics.segment_pairs(rd, "t", "b", "forest", "cave")  # rep 0〜3 は区間未進入または両方未到達
        self.assertEqual((sp2["both"], sp2["vals"]), (1, [1 - 500 / 1000]))


class MedianCiTest(unittest.TestCase):
    def test_order_statistic_ranks(self):
        # n=20: P(B≤5)=0.0207 ≤ 0.025 < P(B≤6) → 区間 [x_(6), x_(15)]
        med, lo, hi = metrics.median_ci([float(x) for x in range(20, 0, -1)])
        self.assertEqual((med, lo, hi), (10.0, 6.0, 15.0))

    def test_small_n_has_no_interval(self):
        self.assertEqual(metrics.median_ci([1.0, 2.0, 3.0, 4.0, 5.0]), (3.0, None, None))
        self.assertEqual(metrics.median_ci([]), (None, None, None))


if __name__ == "__main__":
    unittest.main()
