"""段階 2・3: 捕獲の状態機械（遭遇秒・持ち越し・共通乱数）、活力・餌、芯・道標・消費先.

期待値は計画書（docs/sinks_capture_impl_plan.md 3〜4 節・12 節）と委任の契約から決め、実装の出力を写さない。
"""
import copy
import random
import unittest

from econ_sim import formulas, jsonio, rng
from econ_sim.data_load import load_data
from econ_sim.economy import Economy
from econ_sim.model import Model
from econ_sim.sim import DAY, VIGOR_TICK, Simulator
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

    def make(self, pid="balanced", rep=0, **over):
        persona = copy.deepcopy(next(p for p in self.cfg["personas"] if p["id"] == pid))
        persona.update(over)
        return Simulator(self.econ, self.cfg, persona, rep, 3, REF)


class InvarianceTest(Base):
    def test_result_attempts_independent_of_weaken_seconds(self):
        # 対象・H（簡易モードの停止点）・芯の数・乱数を固定すれば、攻撃者の成長・活力（= 弱体化秒）を変えても
        # result・attempts・芯は同じで seconds だけが弱体化秒の差だけ違う（C5）
        r = random.Random(7)
        k = formulas.capture_k_max(self.rule)
        for _ in range(300):
            grade = r.randint(1, 4)
            u = [r.random() for _ in range(2 * k)]
            wicks = r.choice([-1, 1, 2, 5, 30])
            outs = []
            for lv, vig in ((1, 100), (30, 100), (1, 40), (15, 60)):
                ws = formulas.weaken_seconds(4, lv, grade, vig, self.rule)
                outs.append((formulas.resolve_encounter(grade, self.rule, u, wicks, ws), ws))
            base = outs[0][0]
            for o, ws in outs[1:]:
                self.assertEqual(o[:3], base[:3])
                self.assertEqual(o[3] - base[3], ws - outs[0][1])

    def test_weaken_bounds(self):
        # 最終秒は [2, 12]（活力込み）。活力 0 は行動不可
        for ag in range(1, 5):
            for tg in range(1, 5):
                for lv in (1, 10, 21, 60):
                    for vig in (1, 50, 51, 100):
                        s = formulas.weaken_seconds(ag, lv, tg, vig, self.rule)
                        self.assertTrue(2 <= s <= 12, (ag, tg, lv, vig, s))
        self.assertEqual(formulas.weaken_seconds(4, 1, 4, 0, self.rule), -1)


class EncounterTest(Base):
    def test_block_consumed_per_encounter(self):
        # 遭遇ごとに固定ブロック 1 + 2·K_max（=21）を必ず消費する: 次の遭遇は試行数に依らずブロック i+1 から始まる
        sim = self.make()
        k = formulas.capture_k_max(self.rule)
        self.assertEqual(k, 10)
        sim._start_encounter("meadow", 0, sim.t, (), sim.t + 5)
        ref = rng.make_rng(sim.master_seed, sim.group, sim.replicate_id, "capture:day0")
        for _ in range(1 + 2 * k):
            ref.random()
        self.assertEqual(sim.capture_rng(0).random(), ref.random())

    def test_paired_personas_share_blocks(self):
        # balanced と balanced_paid は同じ比較群: 同じ日の i 番目の遭遇は同じブロック（種・結果・試行数が同じ）
        a, b = self.make("balanced"), self.make("balanced_paid")
        for sim in (a, b):
            sim.state.wallet["wick"] = 50_000
        for _ in range(5):
            a.pending = b.pending = None
            a._start_encounter("meadow", 3, a.t, (), a.t + 5)
            b._start_encounter("meadow", 3, b.t, (), b.t + 5)
            pa, pb = a.pending, b.pending
            self.assertEqual((pa["species"], pa["result"], pa["attempts"]), (pb["species"], pb["result"], pb["attempts"]))

    def test_pending_carries_and_success_applies_at_completion(self):
        # 50 秒しか残っていない状態で 73 秒の遭遇 → 次のステップで完了。成功は完了するまで付与しない
        sim = self.make()
        sim.state.wallet["wick"] = 0  # 新しい遭遇を始めない（狩り素材もないので芯は作れない）
        n0 = len(sim.state.roster)
        t0 = sim.t
        sim.pending = {"field": "meadow", "species": "sunset_bird", "grade": 2, "result": "success", "attempts": 1,
                       "seconds": 73, "remaining": 350, "start": t0, "index": 1}
        sim._capture("meadow", 0, t0=t0)
        self.assertEqual(sim.pending["remaining"], 50)
        self.assertEqual(len(sim.state.roster), n0)
        self.assertNotIn("sunset_bird", sim.state.first_capture)
        sim._capture("meadow", 0, t0=t0 + 5)
        self.assertIsNone(sim.pending)
        self.assertEqual(len(sim.state.roster), n0 + 1)
        self.assertEqual(sim.state.first_capture["sunset_bird"], (t0 + 5, 1))  # 完了時刻 = 完了秒（ステップ内 50 秒目）を含む分 = ステップ開始
        acc = sim.day_acc(0)
        self.assertEqual((acc.cap_budget_s, acc.cap_used_s), (600, 350))

    def test_encounter_started_with_50s_left_completes_next_step(self):
        # 実際の _capture 経路: 前の遭遇が 250 秒消化 → 残り 50 秒で新しい遭遇を開始 → 次のステップで完了
        sim = self.make(wick_mode="unlimited")
        t0 = sim.t
        sim.pending = {"field": "meadow", "species": "sparkle", "grade": 1, "result": "flee", "attempts": 1,
                       "seconds": 250, "remaining": 250, "start": t0, "index": 0}
        sim._capture("meadow", 0, t0=t0)
        pe = sim.pending
        self.assertIsNotNone(pe)
        self.assertEqual(pe["start"], t0 + 250 // 60)
        self.assertEqual(pe["remaining"], pe["seconds"] - 50)
        self.assertEqual(sim.day_acc(0).cap_used_s, 300)
        idx, n_done = pe["index"], sim.day_acc(0).enc_done.get("meadow", 0)
        sim._capture("meadow", 0, t0=t0 + 5)
        self.assertTrue(sim.pending is None or sim.pending["index"] > idx)  # 50 秒前に始めた遭遇は完了している
        self.assertGreaterEqual(sim.day_acc(0).enc_done["meadow"], n_done + 1)

    def test_pending_survives_day_boundary(self):
        sim = self.make()
        sim.state.wallet["wick"] = 0
        sim.pending = {"field": "meadow", "species": "sparkle", "grade": 1, "result": "success", "attempts": 1,
                       "seconds": 64, "remaining": 340, "start": sim.t, "index": 1}
        sim._capture("meadow", 0, t0=DAY - 5)
        self.assertEqual(sim.pending["remaining"], 40)
        sim._capture("meadow", 1, t0=DAY + 420)
        self.assertIsNone(sim.pending)
        self.assertEqual(sim.day_acc(1).enc_done.get("meadow"), 1)
        self.assertEqual(sim.state.first_capture["sparkle"][0], DAY + 420)  # 開始精霊とは別に記録される（初獲得は完了時刻）

    def test_time_conservation_over_run(self):
        # 1 日の使用秒 ≤ その日の予算秒、完了した遭遇秒の合計 + 持ち越しの消化分 = 使用秒の合計
        sim = self.make("hardcore")
        sim.days = 3
        sim.run()
        used = sum(a.cap_used_s for a in sim.acc.values())
        for a in sim.acc.values():
            self.assertLessEqual(a.cap_used_s, a.cap_budget_s)
        done = sum(sum(a.enc_seconds.values()) for a in sim.acc.values())
        pend = sim.pending["seconds"] - sim.pending["remaining"] if sim.pending else 0
        self.assertEqual(done + pend, used)
        self.assertGreater(used, 0)

    def test_no_wick_no_encounter_and_unlimited(self):
        sim = self.make()
        sim.state.wallet["wick"] = 0
        sim._capture("meadow", 0, t0=sim.t)
        self.assertEqual(sim.state.encounters, 0)
        sim = self.make(wick_mode="unlimited")
        sim.state.wallet["wick"] = 0
        sim._capture("meadow", 0, t0=sim.t)
        self.assertGreater(sim.state.encounters, 0)
        self.assertEqual(sim.state.wallet["wick"], 0)
        self.assertGreater(sim.state.attempts, 0)

    def test_released_companion_is_skipped(self):
        # 同じ捕獲ステップ内の放出で同行が名簿から消えても、攻撃者の候補から外して続ける
        sim = self.make(wick_mode="unlimited")
        for _ in range(40):
            sim.pending = None
            sim._start_encounter("meadow", 0, sim.t, (9999,), sim.t + 5)
        self.assertGreater(sim.day_acc(0).weaken_n, 0)
        self.assertEqual(sim.day_acc(0).assist_weaken, sim.day_acc(0).weaken_n)  # 同行なし → 全て灯籠

    def test_start_supply_recorded_as_grant(self):
        sim = self.make()
        self.assertEqual(sim.state.wallet["wick"], 21_000)
        self.assertEqual(sim.day_acc(sim.game_start // DAY).earned[("grant", "wick")], 21_000)


class AttackerInvarianceTest(Base):
    def test_start_encounter_result_independent_of_attacker(self):
        # _start_encounter 水準: 攻撃者のレベル・活力だけを変えても種・結果・試行数は同じで、秒だけが変わりうる
        runs = []
        for level, vigor in ((1, 100), (30, 100), (1, 30)):
            sim = self.make(wick_mode="unlimited")
            u = sim._add_spirit("shadow_lantern", level)
            sim.state.vigor[u] = vigor * VIGOR_TICK
            out = []
            for _ in range(40):
                sim.pending = None
                sim._start_encounter("cave", 2, sim.t, (u,), sim.t + 5)
                out.append((sim.pending["species"], sim.pending["result"], sim.pending["attempts"], sim.pending["seconds"]))
                sim.state.vigor[u] = vigor * VIGOR_TICK  # 活力を固定（消費の影響を除く）
            runs.append(out)
        for other in runs[1:]:
            self.assertEqual([x[:3] for x in other], [x[:3] for x in runs[0]])
        self.assertNotEqual([x[3] for x in runs[1]], [x[3] for x in runs[0]])  # Lv30 は弱体化が速い
        self.assertNotEqual([x[3] for x in runs[2]], [x[3] for x in runs[0]])  # 活力 ≤50 は遅い


class ReserveTest(Base):
    def test_progress_reserve_not_used_for_wick(self):
        # 進行の予約（次の解禁の展開コスト + 予約中の強化の狩り素材）を超える分だけで芯を作る
        sim = self.make()
        st, pol = sim.state, sim.policy
        st.wallet["wick"] = 0
        st.wallet["hunt_meadow"] = 20_000  # forest 解禁（key_meadow = hunt_meadow 15）を差し引くと余裕 5
        pol.hunt_targets = lambda: {}
        self.assertEqual(pol.progress_reserve().get("hunt_meadow"), 15_000)
        pol.ensure_wick()
        self.assertEqual(st.wallet["hunt_meadow"], 15_000)
        self.assertEqual(st.wallet["wick"], 25_000)
        st.wallet["wick"] = 0
        st.wallet["hunt_meadow"] = 20_000
        pol.hunt_targets = lambda: {"hunt_meadow": 3_000}  # 予約 18 → 余裕 2 < 1 回分 5
        pol.ensure_wick()
        self.assertEqual((st.wallet["hunt_meadow"], st.wallet["wick"]), (20_000, 0))

    def test_wick_hunt_ranked_below_progress(self):
        # 時間配分も 進行 > 芯: 進行の不足がある間は芯用の狩り素材を順位の後ろに置く
        sim = self.make()
        pol = sim.policy
        sim.state.wallet["wick"] = 0
        need = pol.wick_hunt_need()
        self.assertTrue(need)
        order = pol.bottleneck()
        prog = [r for r in order if r not in need]
        self.assertTrue(prog)
        self.assertGreater(min(order.index(r) for r in need if r in order), order.index(prog[0]))


class VigorPartyTest(Base):
    def test_exhausted_spirit_left_out_of_party(self):
        sim = self.make()
        party = sim.policy.capture_party()
        top = party[0]
        sim.state.vigor[top] = 0
        self.assertNotIn(top, sim.policy.capture_party())
        self.assertNotIn(top, sim.policy.hunt_party_live("meadow", self.model.fields["meadow"]["hunt"]["drops"][0]))

    def test_recovery_and_hunt_cost(self):
        sim = self.make()
        u = next(iter(sim.state.roster))
        t = sim.t
        sim.state.vigor[u], sim.state.vigor_t[u] = 0, t
        self.assertEqual(sim.vigor_at(u, t + 60), 20 * VIGOR_TICK)  # 非活動 1 時間で 20
        self.assertEqual(sim.vigor_at(u, t + 600), 100 * VIGOR_TICK)  # 上限 100
        # 狩り: 参加精霊は分あたり 2（5 分ステップで 10）、ステップ中は回復しない
        sim.state.vigor[u] = 80 * VIGOR_TICK
        sim.use_vigor(u, t, sim.vigor_rule["hunt_cost_per_minute"] * 5 * VIGOR_TICK, t + 5)
        self.assertEqual(sim.vigor_at(u, t + 5), 70 * VIGOR_TICK)

    def test_low_vigor_scales_hunt_output_not_power(self):
        sim = self.make()
        party = tuple(sorted(sim.state.roster))[:3]
        drop = self.model.fields["meadow"]["hunt"]["drops"][0]
        full = sim.hunt_rate_live("meadow", drop, party, sim.t)
        self.assertEqual(full, self.econ.hunt_rate("meadow", drop, sim.members(party)))
        for u in party:
            sim.state.vigor[u] = 50 * VIGOR_TICK  # ≤50 → 産出 75%
        self.assertEqual(sim.hunt_rate_live("meadow", drop, party, sim.t), full * 7500 // 10000)

    def test_feed_limit_per_window(self):
        sim = self.make()
        u = next(iter(sim.state.roster))
        t = sim.t
        sim.state.wallet["food"] = 10_000
        sim.state.vigor[u], sim.state.vigor_t[u] = 10 * VIGOR_TICK, t
        sim.feed_party((u,), t)
        self.assertEqual(sim.state.vigor[u], 60 * VIGOR_TICK)  # 10 → 35 → 60 で ≤50 を抜ける（2 個）
        self.assertEqual(sim.state.wallet["food"], 8_000)
        sim.state.vigor[u] = 0
        sim.feed_party((u,), t + 30)  # 直近 60 分で 2 個済み → 与えない
        self.assertEqual(sim.state.wallet["food"], 8_000)
        sim.feed_party((u,), t + 60)  # 窓を抜けたら再開（回復分 30 分 = 10 点も入る）
        self.assertLess(sim.state.wallet["food"], 8_000)

    def test_food_not_crafted_while_wick_short(self):
        # 予約優先: 芯が 1 日の見込みに足りないうちは餌を作らない（芯 > 餌）
        sim = self.make()
        sim.state.wallet["hunt_meadow"] = 100_000
        sim.state.wallet["wick"] = 0
        sim.policy.goal = lambda: None
        sim.policy.hunt_targets = lambda: {}
        self.assertFalse(sim.policy.ensure_food(1))
        sim.state.wallet["wick"] = 1_000_000
        self.assertTrue(sim.policy.ensure_food(1))
        self.assertGreater(sim.day_acc(sim.t // DAY).spent["hunt_meadow"], 0)

    def test_attacker_selection_and_assist(self):
        sim = self.make()
        st = sim.state
        a4 = sim._add_spirit("shadow_lantern")
        a2 = sim._add_spirit("shard_light")
        t = sim.t
        # ★2 対象: ★4（コスト 4+2×2=8、6 秒）より ★2（コスト 4、8 秒）を選ぶ（活力消費最小）
        u, sec, cost = sim.pick_attacker((a4, a2), 2, t)
        self.assertEqual((u, sec, cost), (a2, 8, 4 * VIGOR_TICK))
        # ★2 の活力が 50 以下なら候補外（★4 を使う）
        st.vigor[a2] = 50 * VIGOR_TICK
        self.assertEqual(sim.pick_attacker((a4, a2), 2, t)[0], a4)
        # 全員活力 0 → 灯籠の補助弱体化（12 秒、活力消費なし）
        st.vigor[a2] = st.vigor[a4] = 0
        self.assertEqual(sim.pick_attacker((a4, a2), 2, t), (None, 12, 0))
        # ★1 は弱体化しない（成功率が上がらない）
        self.assertFalse(formulas.weaken_needed(1, self.rule))

    def test_idle_production_ignores_vigor(self):
        sim = self.make()
        before = dict(sim.idle_rates(frozenset(), False))
        for u in sim.state.roster:
            sim.state.vigor[u] = 0
        sim.touch()
        self.assertEqual(sim.idle_rates(frozenset(), False), before)


class ToolOrderTest(Base):
    """G2 残余（2026-11-10 ユーザー決定）: 道具強化で R（最善配置基準）が 3 を超えるなら見送り、施設強化などを優先する."""

    def test_tool_r_exceeds_detects_overshoot(self):
        from econ_sim.policy import Candidate
        sim = self.make()
        st = sim.state
        self.assertFalse(sim.policy.tool_r_exceeds(Candidate("tool:noop", [], lambda: None)))
        big = Candidate("tool:max", [], lambda: setattr(st, "tool_level", sim.m.tools[sim.tool_id]["max_level"]), frozenset({"direct"}))
        self.assertTrue(sim.policy.tool_r_exceeds(big))
        self.assertEqual(st.tool_level, 1)  # 仮適用は元に戻る

    def test_pick_skips_overshooting_tool(self):
        from econ_sim.policy import Candidate
        pol = self.make().policy
        tool = Candidate("tool:gather:lv2", [], lambda: None)
        fac = Candidate("facility:x:lv2", [], lambda: None)
        pol._pick_once = lambda cands, goal: cands[0] if cands else None
        pol.tool_r_exceeds = lambda c: True
        self.assertIs(pol._pick([tool, fac], None), fac)
        pol.tool_r_exceeds = lambda c: False
        self.assertIs(pol._pick([tool, fac], None), tool)


class CraftSinkTest(Base):
    def test_key_expansion_equals_previous_unlock_costs(self):
        # 道標を展開した解禁コスト = 段階 3 以前の解禁コスト（計画書 2.2 節の等価）
        before = {
            "forest": {"dew": 1500, "bloom": 1500, "hunt_meadow": 15},
            "cave": {"dew": 15000, "bloom": 15000, "crystal": 3000, "hunt_forest": 24, "hunt_meadow": 30},
            "ridge": {"dew": 600000, "bloom": 600000, "crystal": 240000, "hunt_cave": 20, "hunt_forest": 24, "hunt_meadow": 30},
        }
        for fid, want in before.items():
            got = {c["resource"]: c["amount"] for c in self.model.expand_costs(self.model.fields[fid]["unlock"]["costs"])}
            self.assertEqual(got, want, fid)

    def test_unlock_crafts_keys_atomically(self):
        sim = self.make()
        st = sim.state
        for r in st.wallet:
            if self.model.resources[r]["kind"] in ("basic", "hunt"):
                st.wallet[r] = 10**9
        sim.unlock_field("forest")
        sim.unlock_field("cave")
        acc = sim.day_acc(sim.t // DAY)
        for k in ("key_meadow", "key_forest"):
            self.assertEqual(st.wallet[k], 0)  # 解禁直後の在庫は 0
        # 解禁ごとに新しく作る: forest で key_meadow 1、cave で key_forest 1（その材料に key_meadow 2）
        self.assertEqual(acc.earned[("craft", "key_meadow")], 3_000)
        self.assertEqual(acc.earned[("craft", "key_forest")], 1_000)
        self.assertEqual(acc.spent["hunt_meadow"], 45_000)
        self.assertEqual(acc.spent["hunt_forest"], 24_000)
        self.assertEqual(sim.policy.goal()["hunt_cave"], 20_000)  # 次の目標（ridge）も展開済み

    def test_craft_wick_records(self):
        sim = self.make()
        sim.state.wallet["hunt_meadow"] = 10_000
        sim.craft("wick_from_meadow", 2)
        acc = sim.day_acc(sim.t // DAY)
        self.assertEqual(sim.state.wallet["hunt_meadow"], 0)
        self.assertEqual(sim.state.wallet["wick"], 21_000 + 50_000)
        self.assertEqual(acc.earned[("craft", "wick")], 50_000)
        with self.assertRaises(ValueError):
            sim.craft("key_meadow")  # atomic は在庫制作しない

    def rich(self, **over):
        sim = self.make(**over)
        st = sim.state
        for r in st.wallet:
            if self.model.resources[r]["kind"] in ("basic", "hunt"):
                st.wallet[r] = 10**12
        return sim

    def test_buy_sink_has_no_effect(self):
        sim = self.rich()
        st = sim.state
        for fid in ("forest", "cave", "ridge"):
            sim.unlock_field(fid)
        snap = (sim.snapshot(), dict(sim.idle_rates(frozenset(), False)), sim.policy.is_exhausted(), sim.capacity())
        sim.buy_sink("furniture_forest_1")  # comp_meadow を原子的に制作して消費
        sim.buy_sink("altar_meadow")
        sim.buy_sink("altar_meadow")
        self.assertEqual(st.wallet["comp_meadow"], 0)
        self.assertEqual(st.repeat_levels["altar_meadow"], 2)
        self.assertIn("furniture_forest_1", st.sinks_owned)
        self.assertEqual((sim.snapshot(), dict(sim.idle_rates(frozenset(), False)), sim.policy.is_exhausted(), sim.capacity()), snap)
        with self.assertRaises(ValueError):
            sim.buy_sink("furniture_forest_1")
        with self.assertRaises(ValueError):
            sim.buy_sink("house_5")  # 先行品目 house_4 が未購入
        for x in sim.finite_catalog():
            if not sim.sink_owned(x):
                sim.buy_sink(x)
        self.assertIsNotNone(st.finite_completed_time)
        self.assertEqual(st.hub_rank, len(self.model.hub["ranks"]))  # 家 1〜3 = 拠点等級（効果 0）
        ev = [e for e in sim.extra_events if e["event_type"] == "sink_purchase"]
        self.assertEqual(len(ev), len(sim.finite_catalog()))  # 有限品目だけイベント（反復は日次列）


class SinkPolicyTest(Base):
    def rich(self, **over):
        sim = self.make(**over)
        for r in sim.state.wallet:
            if self.model.resources[r]["kind"] == "basic":
                sim.state.wallet[r] = 10**12
        return sim

    def test_none_buys_nothing(self):
        sim = self.rich(sink_preference="none")
        sim.state.wallet["hunt_meadow"] = 10**9
        sim.policy.buy_sinks()
        self.assertEqual((sim.state.sinks_owned, sim.state.repeat_levels, sim.state.hub_rank), ({}, {}, 1))

    def test_eta_not_worse_and_reserves_kept(self):
        # 最後のフィールド前: 目標 ETA を悪化させず、進行・芯 3 日分の予約を割らない
        sim = self.rich()
        pol, st = sim.policy, sim.state
        st.wallet["hunt_meadow"] = 10**6  # 餌の予約は余裕の大きい材料に付くので、hunt_meadow が最大の状態で予約を求める
        res = pol.sink_reserve()
        st.wallet["hunt_meadow"] = res.get("hunt_meadow", 0) + 2_000  # 初原の家具（hunt_meadow 3）には 1 足りない
        goal = dict(pol.goal())
        before = pol.eta(st.wallet, goal, pol.rate_view())
        pol.buy_sinks()
        self.assertNotIn("furniture_meadow_1", st.sinks_owned)
        self.assertGreaterEqual(st.wallet["hunt_meadow"], res.get("hunt_meadow", 0))
        st.wallet["hunt_meadow"] += 3_000
        pol.buy_sinks()
        self.assertIn("furniture_meadow_1", st.sinks_owned)
        self.assertLessEqual(pol.eta(st.wallet, goal, pol.rate_view())[1], before[1] * (1 + 1e-9) + 1e-9)

    def test_normal_waits_high_buys_repeat(self):
        # normal は有限品目をカタログ順に待つ（反復は全部買ってから）。high は有限・反復を同時に候補にする
        for pref, want_repeat in (("normal", False), ("high", True)):
            sim = self.rich(sink_preference=pref)
            sim.state.wallet["hunt_meadow"] = 0  # 初原の家具・衣装は買えない（狩り素材なし）
            sim.policy.buy_sinks()
            self.assertEqual(bool(sim.state.repeat_levels), want_repeat, pref)

    def test_exhausted_meaning_unchanged(self):
        sim = self.rich()
        sim.state.wallet["hunt_meadow"] = 10**9
        before = sim.policy.is_exhausted()
        sim.policy.buy_sinks()
        self.assertTrue(sim.state.sinks_owned)
        self.assertEqual(sim.policy.is_exhausted(), before)

    def test_dex_records_after_research_tree(self):
        sim = self.make()
        rp = self.model.research_resource
        sim.state.wallet[rp] = 10**9
        sim.policy.buy_dex_records()
        self.assertEqual(sim.state.dex_pages, {})
        sim.state.research_done = set(self.model.research_order)
        sim.policy.buy_dex_records()
        pages = len(self.model.sinks["dex_records"]["pages_cost"])
        self.assertEqual(sim.state.dex_pages, {sp: pages for sp in sim.state.dex})


class SinkReserveTest(Base):
    """2 次レビュー Minor 8: ridge 後の回収予約・餌の予約・high の順序・購入後も予約を割らない."""

    def rich_all_fields(self, **over):
        sim = self.make(**over)
        st = sim.state
        for r in st.wallet:
            if self.model.resources[r]["kind"] in ("basic", "hunt"):
                st.wallet[r] = 10**12
        for fid in ("forest", "cave", "ridge"):
            sim.unlock_field(fid)
        return sim

    def test_post_goal_payback_reserve(self):
        from econ_sim.policy import Candidate
        sim = self.rich_all_fields()
        pol = sim.policy
        self.assertIsNone(pol.goal())
        fast = Candidate("facility:x:lv2", [{"resource": "dew", "amount": 7000}], lambda: None)
        slow = Candidate("facility:y:lv2", [{"resource": "bloom", "amount": 9000}], lambda: None)
        pol.candidates = lambda: [fast, slow]
        limit = sim.cfg["policy"]["post_goal_payback_max_minutes"]
        # 回収期間: fast = 7000000 / 1000 = 7000 分 ≤ 上限、slow = 9000000 / 100 = 90000 分 > 上限
        pol._evaluate = lambda c, goal: ((0, 0.0), 1.0, 1000.0 if c is fast else 100.0)
        self.assertLessEqual(7000, limit)
        res = pol.sink_reserve()
        base = pol.progress_reserve()
        self.assertEqual(res.get("dew", 0) - base.get("dew", 0), 7_000_000)
        self.assertEqual(res.get("bloom", 0) - base.get("bloom", 0), 0)

    def test_food_reserve_and_vigor_off(self):
        for abl, want in (([], 3_000), (["vigor_off"], 0)):
            sim = self.make(ablation=abl)
            st, pol = sim.state, sim.policy
            st.wallet["food"] = 0
            st.wallet["hunt_meadow"] = 10**9
            pol.hunt_targets = lambda: {}
            pol.goal = lambda: None
            sim.wick_unlimited = True  # 芯の予約を除いて餌だけを見る
            self.assertEqual(pol.sink_reserve().get("hunt_meadow", 0), want, abl)  # 餌 6 個 = hunt 1 → 餌 2 のレシピで 3 個

    def test_high_tries_finite_before_repeat(self):
        sim = self.rich_all_fields(sink_preference="high")
        order = sim.policy._next_sinks()
        fin = set(sim.finite_catalog())
        kinds = ["finite" if x in fin else "repeat" for x in order]
        self.assertIn("repeat", kinds)
        self.assertEqual(kinds, sorted(kinds))  # "finite" が全て "repeat" より前
        top = sim.policy.highest_field()
        reps = [x for x in order if x not in fin]
        self.assertTrue(all(next(rs for rs in self.model.sinks["repeat_sinks"] if rs["id"] == x).get("field_id") == top for x in reps))

    def test_reserve_kept_after_purchases(self):
        sim = self.rich_all_fields(sink_preference="high")
        st, pol = sim.state, sim.policy
        for h in self.model.hunt_resource_ids():
            st.wallet[h] = 0
        res = pol.sink_reserve()
        for h in self.model.hunt_resource_ids():
            st.wallet[h] = res.get(h, 0) + 40_000
        pol.buy_sinks()
        self.assertTrue(st.sinks_owned or st.repeat_levels)
        for h in self.model.hunt_resource_ids():
            self.assertGreaterEqual(st.wallet[h], res.get(h, 0), h)


class AblationTest(Base):
    def test_level_off_keeps_result_attempts(self):
        # C5: 攻撃者のレベル効果を切っても、同じブロックの result・attempts は同じ（秒だけが変わる）
        outs = []
        for abl in ([], ["weaken_level_off"]):
            sim = self.make(wick_mode="unlimited", ablation=abl)
            u = sim._add_spirit("shadow_lantern", 30)
            seq = []
            for _ in range(30):
                sim.pending = None
                sim.state.vigor[u] = sim.vig_max
                sim._start_encounter("cave", 1, sim.t, (u,), sim.t + 5)
                seq.append((sim.pending["species"], sim.pending["result"], sim.pending["attempts"], sim.pending["seconds"]))
            outs.append(seq)
        self.assertEqual([x[:3] for x in outs[0]], [x[:3] for x in outs[1]])
        self.assertNotEqual([x[3] for x in outs[0]], [x[3] for x in outs[1]])

    def test_level_off_and_vigor_off(self):
        sim = self.make(ablation=["weaken_level_off"])
        u = sim._add_spirit("shadow_lantern", 30)
        self.assertEqual(sim.pick_attacker((u,), 4, sim.t)[1], formulas.weaken_seconds(4, 1, 4, 100, self.rule))
        sim = self.make(ablation=["vigor_off"])
        u = next(iter(sim.state.roster))
        sim.use_vigor(u, sim.t, 100 * VIGOR_TICK, sim.t + 5)
        self.assertEqual(sim.vigor_at(u, sim.t + 1), sim.vig_max)


if __name__ == "__main__":
    unittest.main()


class VigorValidatorTest(unittest.TestCase):
    def issues(self, ops):
        from econ_sim.validate import validate
        return [i for i in validate(load_data(DATA_DIR, ops)) if i.level == "ERROR"]

    def test_applies_to_must_be_exact(self):
        # シミュは常に弱体化・狩りの両方に適用するので、片方の欠落も RULE_VIGOR_SCOPE
        got = self.issues([{"op": "set", "file": "capture", "path": "/vigor/applies_to", "value": ["weaken"]}])
        self.assertEqual({i.code for i in got}, {"RULE_VIGOR_SCOPE"})

    def test_paid_food_input(self):
        # 餌の材料が購入可能資源なら餌 → 弱体化 → 捕獲の有料経路（2026-11-11 から基本素材は非売なので dew を購入可能に戻して検査）
        ops = [{"op": "set", "file": "resources", "path": "/resources/id:dew/purchasable", "value": True},
               {"op": "set", "file": "crafting", "path": "/recipes/id:food_from_meadow/inputs", "value": [{"resource": "dew", "amount": 1}]}]
        got = self.issues(ops)
        self.assertTrue(any(i.code == "RULE_PAID_CAPTURE" and "food" in i.path for i in got), [i.format() for i in got])
