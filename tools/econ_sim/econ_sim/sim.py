"""イベント駆動の 1 プレイヤー・シミュレーション（整数分）.

時間進行:
- オンライン中は活動決定間隔（5 分）ごとに進め、その間は生産率一定として閉じた式で積算する。
- オフライン区間はログアウト時刻から上限時間までを認定し、超過分は失効として記録する。
- 積算区間は夜/昼境界（rules.night のゲーム内時計、UTC 通算分）と日境界で分割する。
- 活動中の同行精霊はその間だけ施設から外れる（配置と同行は排他、ログアウト時に戻る）。
2 段階の仮定（run メタにも記録）: 狩りドロップは期待値の決定的積算、捕獲だけが乱数。
捕獲（2026-11-10 段階 2）: 遭遇ごとの状態機械（capture.json）。捕獲ステップは 300 秒の予算を持ち、遭遇秒 = 60 + 弱体化秒 + 4×試行数。
未完了の遭遇は pending として次の捕獲ステップ（日をまたいでも）へ持ち越し、成功・初獲得・放出は完了時刻に適用する。
活力（vigor）は精霊別の整数 tick（1 点 = 60 tick、回復 20/時 = 20 tick/分）で遅延評価する。
"""
from __future__ import annotations

import random
from typing import Any

from fractions import Fraction

from . import formulas, placement, rng, tables
from .economy import Economy, Member
from .policy import Action, Candidate, Policy
from .state import DayAcc, SpiritInst, State

DAY = formulas.MINUTES_PER_DAY
VIGOR_TICK = 60  # 活力 1 点 = 60 tick（回復 20/時を分単位の整数で扱うため）


def split_days(start: int, end: int) -> list[tuple[int, int]]:
    out = []
    t = start
    while t < end:
        e = min(end, (t // DAY + 1) * DAY)
        out.append((t, e))
        t = e
    return out


class Simulator:
    def __init__(self, econ: Economy, cfg: dict[str, Any], persona: dict[str, Any], replicate_id: int, days: int,
                 static_ref: dict[str, Any]):
        self.econ, self.cfg, self.persona, self.replicate_id, self.days = econ, cfg, persona, replicate_id, days
        self.static_ref = static_ref
        m = self.m = econ.m
        self.master_seed = cfg["master_seed"]
        self.group = persona["pairing_group"]
        self.tool_id = next(t for t in m.tools if m.tools[t]["kind"] == "gather")
        # ゲーム内時計（rules.night、2026-11-11 決定: 現実 60 分 = ゲーム内 1 日、UTC 通算分で全世界同期）
        self.night = (m.night["cycle_minutes"], m.night["night_start_offset_minutes"], m.night["night_minutes"])
        self.step = cfg["policy"]["step_minutes"]
        self.r_threshold = float(cfg.get("r_threshold", 3.0))
        self.transition_minutes = int(cfg.get("transition_minutes", 1440))
        self.research_id = next((r for r in m.resource_order if m.resources[r]["kind"] == "research"), None)
        # 捕獲規則・活力（capture.json）。試行コストは 1 資源（芯）だけを扱う（sim_unsupported で検査）
        cr = self.capture_rule = m.capture_rules
        self.k_max = formulas.capture_k_max(cr)
        self.wick_id = cr["attempt_cost"][0]["resource"]
        self.wick_per_attempt = cr["attempt_cost"][0]["amount"]
        self.wick_unlimited = persona.get("wick_mode", "required") == "unlimited"
        # 捕獲補助道具（2026-11-11 決定）: 自動使用モード off/star4。off は道具を作らず使わない（乱数の消費順は同じ）
        ct = cr.get("capture_tool")
        self.tool_mode = persona.get("capture_tool", "off")
        self.tool_rule = ct if (ct and self.tool_mode != "off") else None
        self.lure_field = {it["resource"]: it["field_id"] for it in ct["items"]} if ct else {}
        # 使用側の在庫下限（2026-11-11 ユーザー決定 M1、既定 0）: 在庫のうち下限を超える分だけを遭遇で使える（乱数の順序は不変）
        self.tool_min_stock = int(cfg["policy"].get("capture_tool_min_stock", 0))
        vg = self.vigor_rule = cr["vigor"]
        self.vig_max = vg["max"] * VIGOR_TICK
        self.vig_rec = vg["rest_recovery_per_hour"] * VIGOR_TICK // 60  # tick/分
        self.vig_low = vg["low_at_or_below"] * VIGOR_TICK
        self.food_id = vg["food"]["resource"]
        abl = set(persona.get("ablation", []))
        self.abl_level = "weaken_level_off" in abl  # 弱体化のレベル効果を切る（攻撃者を Lv1 として計算）
        self.abl_vigor = "vigor_off" in abl  # 活力を切る（常に満タン、消費・効率低下・給餌なし）
        self.sink_pref = persona.get("sink_preference", "normal")
        self._catalog: list[str] | None = None
        # 仮定(M1): 最初のセッション開始 = ゲーム開始。それ以前は生産も失効もない
        self.game_start = min(s["start_minute"] for s in persona["sessions"])
        start_fields = [f for f in m.field_order if not m.fields[f]["unlock"]["requires_fields"]]
        st = self.state = State(
            wallet={r: 0 for r in m.resource_order}, unlocked=list(start_fields), fac_level={}, fac_slots={},
            tool_level=1, roster={}, next_uid=1, assignment={}, hub_rank=1,
            offline_cap_hours=m.hub["offline_cap"]["base_hours"],
        )
        self.t = self.game_start
        self.acc: dict[int, DayAcc] = {}
        for f in start_fields:
            st.field_unlock_time[f] = self.game_start
        self._open_facilities()
        ind = m.gd.docs["rules"]["individual_stats"]
        self.ind = ind
        start_rng = rng.make_rng(self.master_seed, self.group, self.replicate_id, f"{ind['stream']}:start")
        for sp in cfg["start"]["spirits"]:
            # 開始精霊の個体値: roll_start_spirits=false なら start_spirit_bps 固定（既定、ユーザー確認中）
            if ind["roll_start_spirits"]:
                g = start_rng.randint(ind["gather_bps_min"], ind["gather_bps_max"])
                c = start_rng.randint(ind["combat_bps_min"], ind["combat_bps_max"])
            else:
                g = c = ind["start_spirit_bps"]
            self._add_spirit(sp["species"], sp["level"], g, c)
        self.online = False
        self.logout_time = self.game_start
        self.carry: dict[tuple[str, str], int] = {}
        self.pending: dict[str, Any] | None = None  # 未完了の遭遇（日・セッションをまたいで保持する）
        # 開始時の芯の支給（capture.supply.start、earned_grant_<資源>）
        acc0 = self.day_acc(self.game_start // DAY)
        for c in cr["supply"]["start"]:
            st.wallet[c["resource"]] += c["amount"] * 1000
            acc0.add_earned("grant", c["resource"], c["amount"] * 1000)
        self.extra_events: list[dict[str, Any]] = []
        self._rate_cache: dict[tuple[Any, ...], dict[str, int]] = {}
        self._rate_version = -1
        self._rng_day = -1
        self._rng: random.Random | None = None
        self._ind_day = -1
        self._best_cache: dict[tuple[Any, ...], int] = {}
        self._ind_rng: random.Random | None = None
        self.day_snapshots: list[dict[str, Any]] = []
        # 研究: モード（off/natural/cap）、完了済み効果の資源別 bps（方置 I・直接 A）
        self.research_mode = persona.get("research", "natural") if m.research_nodes else "off"
        self.research_slots = m.research["slots"]["free_shared"] if m.research else 0
        self.r_idle: dict[str, int] = {}
        self.r_direct: dict[str, int] = {}
        self.policy = Policy(self)
        self.research_tick_cap()
        self.policy.reassign()

    # ---- 状態操作 ----
    def touch(self) -> None:
        self.state.version += 1

    def members(self, uids: tuple[int, ...] | list[int]) -> list[Member]:
        r = self.state.roster
        return [(r[u].species, r[u].level, r[u].gather_bps, r[u].combat_bps) for u in uids]

    def _open_facilities(self) -> None:
        st = self.state
        for fid in self.m.facility_order:
            fac = self.m.facilities[fid]
            if fid not in st.fac_level and fac["unlock_field"] in st.unlocked:
                st.fac_level[fid] = 1
                st.fac_slots[fid] = fac["slots"]["base"]
                st.assignment[fid] = []

    def _add_spirit(self, species: str, level: int = 1, gather_bps: int = 10_000, combat_bps: int = 10_000) -> int:
        st = self.state
        uid = st.next_uid
        st.next_uid += 1
        st.roster[uid] = SpiritInst(uid, species, level, gather_bps, combat_bps)
        st.vigor[uid] = self.vig_max  # 活力は満タンで加入
        st.vigor_t[uid] = self.t
        st.dex.add(species)  # 図鑑登録（F5）。開始精霊も登録する
        self.touch()
        return uid

    def capacity(self) -> int:
        st = self.state
        bonus = sum(r["storage_bonus"] for r in self.m.hub["ranks"] if r["rank"] <= st.hub_rank)
        cfg = self.m.hub["storage"]
        return min(cfg["max_capacity"], cfg["base_capacity"] + bonus + st.storage_bonus)

    def snapshot(self) -> tuple[Any, ...]:
        st = self.state
        return (dict(st.fac_level), dict(st.fac_slots), st.tool_level, st.offline_cap_hours, st.hub_rank,
                {u: s.level for u, s in st.roster.items()}, {f: list(v) for f, v in st.assignment.items()})

    def restore(self, snap: tuple[Any, ...]) -> None:
        st = self.state
        st.fac_level, st.fac_slots, st.tool_level, st.offline_cap_hours, st.hub_rank, levels, assign = (
            dict(snap[0]), dict(snap[1]), snap[2], snap[3], snap[4], snap[5], snap[6])
        for u, lv in levels.items():
            st.roster[u].level = lv
        st.assignment = {f: list(v) for f, v in assign.items()}
        self.touch()

    def open_slot(self, fid: str) -> None:
        """枠を 1 つ開け、控えから寄与が最大の精霊を入れる（what-if 評価でも使う簡易補充）."""
        st = self.state
        st.fac_slots[fid] += 1
        assigned = {u for us in st.assignment.values() for u in us}
        res = self.m.facilities[fid]["produces"]
        bench = [u for u in st.roster if u not in assigned]
        if bench:
            best = max(bench, key=lambda u: (self.econ.slot_power(st.roster[u].species, st.roster[u].level, res, False,
                                                                  st.roster[u].gather_bps), -u))
            st.assignment[fid] = st.assignment[fid] + [best]

    def spend(self, costs: list[dict]) -> None:
        acc = self.day_acc(self.t // DAY)
        for c in costs:
            milli = c["amount"] * 1000
            self.state.wallet[c["resource"]] -= milli
            acc.spent[c["resource"]] = acc.spent.get(c["resource"], 0) + milli

    def buy_upgrade(self, cand: Candidate) -> None:
        self.spend(cand.costs)
        cand.apply()
        self.touch()
        self.policy.reassign()

    def unlock_field(self, fid: str) -> None:
        """解禁: コスト中の atomic 品目（道標）はその場で原子的に制作して即消費する（解禁ごとに新しく作り、在庫は 0 に戻る）."""
        st = self.state
        costs = self.m.fields[fid]["unlock"]["costs"]
        for c in costs:
            if self.m.resources[c["resource"]].get("stack") == "atomic":
                self.craft_atomic(c["resource"], c["amount"])
        self.spend(costs)
        acc = self.day_acc(self.t // DAY)
        for g in self.capture_rule["supply"]["unlock_grants"]:
            if g["field_id"] == fid:
                for c in g["grants"]:
                    st.wallet[c["resource"]] += c["amount"] * 1000
                    acc.add_earned("grant", c["resource"], c["amount"] * 1000)
        st.unlocked.append(fid)
        st.field_unlock_time[fid] = self.t
        self._open_facilities()
        self.touch()
        self.research_tick_cap()
        self.policy.reassign()

    # ---- 制作・消費先（段階 3） ----
    def craft(self, recipe_id: str, times: int = 1) -> None:
        """stock レシピを times 回制作する（投入は spent_<素材>、産出は earned_craft_<産出物>）。払えなければ ValueError."""
        rec = self.m.recipes[recipe_id]
        if rec["mode"] != "stock" or times < 1:
            raise ValueError(f"stock 레시피만 제작 가능: {recipe_id}")
        costs = [{"resource": x["resource"], "amount": x["amount"] * times} for x in rec["inputs"]]
        if not self.can_afford(costs):
            raise ValueError(f"재료 부족: {recipe_id}×{times}")
        self.spend(costs)
        milli = rec["output"]["amount"] * times * 1000
        self.state.wallet[rec["output"]["resource"]] += milli
        acc = self.day_acc(self.t // DAY)
        acc.add_earned("craft", rec["output"]["resource"], milli)
        if rec["output"]["resource"] == self.wick_id:  # 芯の制作に使った狩り素材（用途内訳、判定には使わない）
            acc.wick_craft_hunt += sum(x["amount"] * 1000 for x in costs if self.m.resources[x["resource"]]["kind"] == "hunt")
        lf = self.lure_field.get(rec["output"]["resource"])
        if lf is not None:  # 捕獲補助道具の制作（フィールド別の個数と投入した狩り素材）
            acc.lure_craft[lf] = acc.lure_craft.get(lf, 0) + milli
            acc.lure_craft_hunt += sum(x["amount"] * 1000 for x in costs if self.m.resources[x["resource"]]["kind"] == "hunt")

    def craft_atomic(self, resource: str, amount: int) -> None:
        """atomic 品目を唯一のレシピで amount 個作る（入力の atomic 品目も再帰的にその場で作る）。払えなければ ValueError.

        先に全体を素材へ展開して払えるか確かめ、途中まで作って中間品が残ることを防ぐ（レビュー Minor 1）。
        """
        if not self.can_afford(self.m.expand_costs([{"resource": resource, "amount": amount}])):
            raise ValueError(f"재료 부족: {resource}×{amount}")
        self._craft_atomic(resource, amount)

    def _craft_atomic(self, resource: str, amount: int) -> None:
        rec = self.m.recipes_for(resource)[0]
        times = -(-amount // rec["output"]["amount"])
        for x in rec["inputs"]:
            if self.m.resources[x["resource"]].get("stack") == "atomic":
                self._craft_atomic(x["resource"], x["amount"] * times)
        self.spend([{"resource": x["resource"], "amount": x["amount"] * times} for x in rec["inputs"]])
        milli = rec["output"]["amount"] * times * 1000
        self.state.wallet[resource] += milli
        self.day_acc(self.t // DAY).add_earned("craft", resource, milli)

    def sink_costs(self, sink_id: str) -> tuple[str, list[dict]]:
        """消費先 1 回分のコスト（("item"|"house_rank"|"repeat"|"dex", コスト)）。反復消費先は次のレベルの表の行（上限付き）.

        house_rank:<n> = 家 2・3 段階（既存の拠点等級 hub rank、効果 0、計画書 Q5）。dex:<種> = 図鑑記録の次のページ（研究ポイント）。
        """
        doc = self.m.sinks or {}
        if sink_id.startswith("house_rank:"):
            n = int(sink_id.split(":")[1])
            return "house_rank", next(r["costs"] for r in self.m.hub["ranks"] if r["rank"] == n)
        if sink_id.startswith("dex:"):
            dx = doc["dex_records"]
            page = self.state.dex_pages.get(sink_id[4:], 0)
            if page >= len(dx["pages_cost"]):
                raise ValueError(f"도감 기록 페이지 상한: {sink_id}")
            return "dex", [{"resource": dx["resource"], "amount": dx["pages_cost"][page]}]
        for it in doc.get("items", []):
            if it["id"] == sink_id:
                return "item", it["costs"]
        for rs in doc.get("repeat_sinks", []):
            if rs["id"] == sink_id:
                n = self.state.repeat_levels.get(sink_id, 0) + 1
                return "repeat", tables.sink_cost(self.m.sink_tables_doc, rs["cost_curve"], n)
        raise KeyError(sink_id)

    def house_rank_field(self, rank: int) -> str:
        """家 2・3 段階（拠点等級）の必要フィールド: コストの狩り素材を落とす最初のフィールド（なければ開始フィールド）."""
        costs = next(r["costs"] for r in self.m.hub["ranks"] if r["rank"] == rank)
        need = [c["resource"] for c in costs if self.m.resources[c["resource"]]["kind"] == "hunt"]
        best = self.m.field_order[0]
        for res in need:
            f = next((x for x in self.m.field_order if any(d["resource"] == res for d in self.m.fields[x]["hunt"]["drops"])), best)
            best = max(best, f, key=self.m.field_rank)
        return best

    def finite_catalog(self) -> list[str]:
        """有限の外形品目（カタログ順）: フィールド順に、そのフィールドの家（拠点等級 2・3 = 家 2・3 段階）→ sinks.items（データ順）.

        家 4〜9 は ridge の品目。拠点等級はコストの狩り素材が出るフィールドに属させる（未解禁フィールドの素材を待たないため）。
        """
        if self._catalog is None:
            entries: list[tuple[int, int, int, str]] = []
            for r in self.m.hub["ranks"]:
                if r["rank"] > 1:
                    entries.append((self.m.field_rank(self.house_rank_field(r["rank"])), 0, r["rank"], f"house_rank:{r['rank']}"))
            for i, it in enumerate((self.m.sinks or {}).get("items", [])):
                entries.append((self.m.field_rank(it["field_id"]), 1, i, it["id"]))
            self._catalog = [e[3] for e in sorted(entries)]
        return self._catalog

    def sink_owned(self, sink_id: str) -> bool:
        if sink_id.startswith("house_rank:"):
            return self.state.hub_rank >= int(sink_id.split(":")[1])
        return sink_id in self.state.sinks_owned

    def sink_available(self, sink_id: str) -> bool:
        """前提（フィールド・先行品目・拠点等級・研究ツリー完了）を満たし、未所持（有限）か上限内（図鑑記録）か."""
        st, doc = self.state, self.m.sinks or {}
        if sink_id.startswith("house_rank:"):
            # 外形の家として買うのは効果 0（保管箱ボーナス 0）の拠点等級だけ。効果のある等級は _try_hub_rank の領分（2 次レビュー Minor 7）
            n = int(sink_id.split(":")[1])
            rank = next(r for r in self.m.hub["ranks"] if r["rank"] == n)
            return rank["storage_bonus"] == 0 and st.hub_rank == n - 1 and self.house_rank_field(n) in st.unlocked
        if sink_id.startswith("dex:"):
            dx = doc.get("dex_records")
            return (dx is not None and self.research_tree_complete() and sink_id[4:] in st.dex
                    and st.dex_pages.get(sink_id[4:], 0) < len(dx["pages_cost"]))
        for it in doc.get("items", []):
            if it["id"] == sink_id:
                return (sink_id not in st.sinks_owned and all(f in st.unlocked for f in it["requires_fields"])
                        and all(self.sink_owned(x) for x in it["requires_items"]) and st.hub_rank >= it.get("requires_hub_rank", 1))
        for rs in doc.get("repeat_sinks", []):
            if rs["id"] == sink_id:
                return all(f in st.unlocked for f in rs["requires_fields"])
        return False

    def research_tree_complete(self) -> bool:
        return bool(self.m.research_order) and all(n in self.state.research_done for n in self.m.research_order)

    def finite_done_count(self) -> int:
        return sum(1 for x in self.finite_catalog() if self.sink_owned(x))

    def buy_sink(self, sink_id: str) -> None:
        """消費先を 1 回買う（効果なし）。atomic 部品は原子的に制作して消費する。有限品目は 1 回だけ.

        支出は spent_<資源> に加え、日次の sink_spent にも記録する（消費先の吸収率用）。
        """
        st = self.state
        kind, costs = self.sink_costs(sink_id)
        if kind in ("item", "house_rank") and self.sink_owned(sink_id):
            raise ValueError(f"이미 보유: {sink_id}")
        if not self.sink_available(sink_id):
            raise ValueError(f"조건 미충족: {sink_id}")
        if not self.can_afford(self.m.expand_costs(costs)):
            raise ValueError(f"재료 부족: {sink_id}")
        for c in costs:
            if self.m.resources[c["resource"]].get("stack") == "atomic":
                self.craft_atomic(c["resource"], c["amount"])
        self.spend(costs)
        acc = self.day_acc(self.t // DAY)
        bucket = acc.sink_spent_repeat if kind == "repeat" else acc.sink_spent  # 有限（家・家具・衣装・図鑑）/ 反復
        for c in self.m.expand_costs(costs):
            bucket[c["resource"]] = bucket.get(c["resource"], 0) + c["amount"] * 1000
        if kind == "house_rank":
            st.hub_rank = int(sink_id.split(":")[1])
            self.touch()
        elif kind == "item":
            st.sinks_owned[sink_id] = self.t
        elif kind == "dex":
            st.dex_pages[sink_id[4:]] = st.dex_pages.get(sink_id[4:], 0) + 1
        else:
            st.repeat_levels[sink_id] = st.repeat_levels.get(sink_id, 0) + 1
        if kind in ("item", "house_rank"):
            self.extra_events.append({"event_type": "sink_purchase", "target_id": sink_id, "time": self.t, "value": 1})
            if st.finite_completed_time is None and all(self.sink_owned(x) for x in self.finite_catalog()):
                st.finite_completed_time = self.t

    # ---- 研究 ----
    def _recompute_research(self) -> None:
        done = self.state.research_done
        self.r_idle = {r: v for r, v in self.m.research_effect_bps(done, "basic_idle_bps").items() if v}
        self.r_direct = {r: v for r, v in self.m.research_effect_bps(done, "basic_gather_bps").items() if v}

    def direct_rate(self, node: dict, members: list[Member]) -> int:
        """直接採集（milli/時）。既存計算（道具・同行）に研究 A を経路別に 1 回だけ掛ける."""
        rate = self.econ.direct_rate(node, self.tool_id, self.state.tool_level, members)
        a = self.r_direct.get(node["resource"], 0)
        return formulas.research_scaled_milli(rate, a) if a else rate

    def research_available(self, nid: str) -> bool:
        """開始条件（フィールド・図鑑登録種数・先行）を満たし、未完了・未着手か（コストは別判定）."""
        st, n = self.state, self.m.research_nodes[nid]
        return (nid not in st.research_done and nid not in st.research_active
                and all(f in st.unlocked for f in n["required_fields"]) and len(st.dex) >= n["required_dex_count"]
                and all(p in st.research_done for p in n["prerequisites"]))

    def complete_research(self, nid: str, t: int) -> None:
        st = self.state
        st.research_active.pop(nid, None)
        st.research_done.add(nid)
        st.research_done_time[nid] = t
        self._recompute_research()
        self.touch()

    def _complete_due(self, t: int) -> None:
        for nid, end in sorted(self.state.research_active.items(), key=lambda kv: (kv[1], kv[0])):
            if end <= t:
                self.complete_research(nid, end)

    def start_research(self, nid: str) -> None:
        """自然研究: コストを払って開始（スロット数まで同時進行）."""
        n = self.m.research_nodes[nid]
        self.spend(n["costs"])
        self.state.research_active[nid] = self.t + n["duration_minutes"]
        self.extra_events.append({"event_type": "research_start", "target_id": nid, "time": self.t, "value": 0})
        self.touch()

    def research_tick_cap(self) -> None:
        """上限試験（cap）: 条件を満たしたノードを即座にコスト・待ちなしで完了（連鎖も同じ時刻に）."""
        if self.research_mode != "cap":
            return
        progressed = True
        while progressed:
            progressed = False
            for nid in self.m.research_order:
                if self.research_available(nid):
                    self.complete_research(nid, self.t)
                    progressed = True

    def skip_target(self) -> str | None:
        """研究時間短縮の対象: 進行中の speedup_allowed ノード（完了の早い順）。なければ None."""
        act = [(end, nid) for nid, end in self.state.research_active.items()
               if self.m.research_nodes[nid]["speedup_allowed"] and end > self.t]
        return min(act)[1] if act else None

    def buy_research_skips(self) -> bool:
        """条件付き購入（when=production_research_active）を商品の日次上限まで買う。1 件でも買えば True."""
        day = self.t // DAY
        bought = False
        for pu in self.persona["purchases"]:
            if pu.get("when") != "production_research_active" or day < pu["day"] or day > pu["until_day"]:
                continue
            while self.skip_target() is not None and self.buy_product(pu["product_id"], day):
                bought = True
        return bought

    # ---- 生産 ----
    def idle_rates(self, exclude: frozenset[int], night: bool) -> dict[str, int]:
        st = self.state
        if self._rate_version != st.version:
            self._rate_cache.clear()
            self._rate_version = st.version
        key = (exclude, night)
        hit = self._rate_cache.get(key)
        if hit is not None:
            return hit
        rates: dict[str, int] = {}
        for fid, uids in st.assignment.items():
            members = self.members([u for u in uids if u not in exclude])
            r = self.m.facilities[fid]["produces"]
            rates[r] = rates.get(r, 0) + self.econ.facility_rate(fid, st.fac_level[fid], members, night, self.econ.dex_bps(len(st.dex)))
        if self.r_idle:
            # 研究（決定 C2）: 図鑑ボーナス込みの資源別方置に 1 回だけ掛ける
            rates = {r: formulas.research_scaled_milli(v, self.r_idle.get(r, 0)) for r, v in rates.items()}
        self._rate_cache[key] = rates
        return rates

    def day_acc(self, day: int) -> DayAcc:
        acc = self.acc.get(day)
        if acc is None:
            acc = self.acc[day] = DayAcc()
        return acc

    def _accrue(self, source: str, res: str, rate: int, minutes: int, day: int) -> None:
        key = (source, res)
        gained, self.carry[key] = formulas.accrue_milli(rate, minutes, self.carry.get(key, 0))
        self.state.wallet[res] += gained
        self.day_acc(day).add_earned(source, res, gained)

    def home_rates(self, exclude: frozenset[int]) -> dict[str, int]:
        """施設で働く（同行中でない）精霊の固有フィールド狩り素材（milli/日、F1）."""
        uids = [u for us in self.state.assignment.values() for u in us if u not in exclude]
        return self.econ.home_material_per_day(self.members(uids), self.econ.dex_bps(len(self.state.dex)))

    def _accrue_daily(self, source: str, res: str, per_day: int, minutes: int, day: int, tag: str = "") -> int:
        key = ("daily:" + source + tag, res)
        gained, self.carry[key] = divmod(per_day * minutes + self.carry.get(key, 0), DAY)
        self.state.wallet[res] += gained
        self.day_acc(day).add_earned(source, res, gained)
        return gained

    def advance(self, t_to: int, exclude: frozenset[int] = frozenset()) -> None:
        """t_to まで進める。研究の完了時刻を区間境界にし、完了効果をそれ以前の区間へ遡及しない."""
        if t_to <= self.t:
            return
        while self.state.research_active:
            due = min(self.state.research_active.values())
            if due > t_to:
                break
            self._advance(due, exclude)
            self._complete_due(due)
        self._advance(t_to, exclude)

    def _advance(self, t_to: int, exclude: frozenset[int] = frozenset()) -> None:
        if t_to <= self.t:
            return
        st = self.state
        windows: list[tuple[int, int]] = []
        lost: tuple[int, int] | None = None
        if self.online:
            windows.append((self.t, t_to))
        else:
            cap_end = self.logout_time + st.offline_cap_hours * 60
            if self.t < cap_end:
                windows.append((self.t, min(t_to, cap_end)))
            if t_to > cap_end:
                lost = (max(self.t, cap_end), t_to)
        for a, b in windows:
            for s, e, night in formulas.night_segments(a, b, *self.night):
                rates = self.idle_rates(exclude, night)
                for s2, e2 in split_days(s, e):
                    day, mins = s2 // DAY, e2 - s2
                    for r, rate in rates.items():
                        self._accrue("idle", r, rate, mins, day)
                    uids = [u for us in st.assignment.values() for u in us if u not in exclude]
                    detail = self.econ.home_material_detail(self.members(uids), self.econ.dex_bps(len(st.dex)))
                    for (r, grade), per_day in detail.items():
                        gained = self._accrue_daily("idle", r, per_day, mins, day, f"g{grade}")
                        acc_g = self.day_acc(day).home_by_grade
                        acc_g[grade] = acc_g.get(grade, 0) + gained
                    acc = self.day_acc(day)
                    if not self.online:
                        acc.add_min("off_credited", mins)
                    for uids in st.assignment.values():
                        for u in uids:
                            if u not in exclude:
                                sp = st.roster[u].species
                                acc.fac_minutes[sp] = acc.fac_minutes.get(sp, 0) + mins
        if lost:
            for s2, e2 in split_days(*lost):
                self.day_acc(s2 // DAY).add_min("off_lost", e2 - s2)
        self.t = t_to

    def best_idle_rate(self, res: str, night: bool) -> int:
        """その資源の施設に、現在の保有精霊から最善の組（1 施設の厳密最適、placement.best_single）を置いたときの方置量（milli/時）.

        G2 の判定分母。実配置（他資源との配分・同行中の離脱）に左右されない「その状態で到達可能な方置」を表す。
        以前は寄与上位（枠+3）に絞ったヒューリスティックで、混合ボーナス精霊（例: Lv1 の rainbow_butterfly）が候補から漏れ、
        分母が最適より最大 7.9% 小さかった（2026-11-10 診断）。全保有精霊を対象に厳密に求める。
        """
        st = self.state
        key = ("best", res, night, st.version)
        hit = self._best_cache.get(key)
        if hit is not None:
            return hit
        self._best_cache.clear() if len(self._best_cache) > 64 else None
        fac = self.m.facility_for_resource(res)
        value = 0
        if fac is not None and fac["id"] in st.fac_level:
            fid = fac["id"]
            uids = sorted(st.roster)
            spirits = self.members(uids)
            found = placement.best_single(self.econ, placement.Slot(fid, st.fac_level[fid], st.fac_slots[fid]), spirits, night)
            members = [spirits[i] for i in found.assign[fid]]
            value = self.econ.facility_rate(fid, st.fac_level[fid], members, night, self.econ.dex_bps(len(st.dex)))
            value = formulas.research_scaled_milli(value, self.r_idle.get(res, 0))
        self._best_cache[key] = value
        return value

    def in_transition(self, t: int) -> bool:
        """新フィールド（開始フィールド以外）解禁から transition_minutes 以内か（ユーザー決定: この区間の R>3 は許容）."""
        times = [v for f, v in self.state.field_unlock_time.items() if self.m.fields[f]["unlock"]["requires_fields"]]
        return bool(times) and t - max(times) < self.transition_minutes

    def is_night(self, t: int) -> bool:
        return formulas.night_segments(t, t + 1, *self.night)[0][2]

    # ---- セッション ----
    def quest_rewards_now(self) -> dict[str, int]:
        """今日受け取れる日次依頼報酬（milli/日）。仮定: 解禁済み最高フィールドの報酬のみ."""
        out: dict[str, int] = {}
        top = max(self.state.unlocked, key=self.m.field_rank)
        for q in self.m.quests.values():
            for rbf in q["rewards_by_field"]:
                if rbf["field_id"] == top:
                    for r in rbf["rewards"]:
                        out[r["resource"]] = out.get(r["resource"], 0) + r["amount"] * 1000
        return out

    def claim_quest(self, day: int) -> None:
        st = self.state
        if st.quest_day == day:
            return
        st.quest_day = day
        for r, milli in self.quest_rewards_now().items():
            st.wallet[r] += milli
            self.day_acc(day).add_earned("quest", r, milli)
        self.touch()

    def buy_product(self, product_id: str, day: int) -> bool:
        st, prod = self.state, self.m.products[product_id]
        if prod["kind"] == "research_time_skip" and self.skip_target() is None:
            return False  # 短縮できる進行中の生産研究がなければ買わない
        total = st.purchase_total.get(product_id, 0)
        today = st.purchase_day.get((product_id, day), 0)
        if (prod["purchase_limit_total"] and total >= prod["purchase_limit_total"]) or \
                (prod["purchase_limit_per_day"] and today >= prod["purchase_limit_per_day"]):
            return False
        st.purchase_total[product_id] = total + 1
        st.purchase_day[(product_id, day)] = today + 1
        st.robux += prod["price_robux"]
        acc = self.day_acc(day)
        for eff in prod["effects"]:
            if eff["type"] == "storage_capacity":
                st.storage_bonus += eff["amount"]
            # basic_material_hours・mission_rewards は 2026-11-11 ユーザー決定で商品ごと削除（検証器の禁止 kind）。
            # 現データでは実行されない休眠分岐。daily.csv の pass_claims_cum 列（常に 0）を保つため残す
            elif eff["type"] == "basic_material_hours":
                # 仮定: 購入直前の最高フィールドの「標準無課金放置率」= static_reference の <field>_entry 基準状態
                top = max(st.unlocked, key=self.m.field_rank)
                ref_state = self._reference_state(top)
                rates = self.econ.reference_idle_rates(ref_state, top, self.static_ref["ability_curve"])
                for r in eff["resources"]:
                    milli = rates.get(r, 0) * eff["hours"]
                    st.wallet[r] += milli
                    acc.add_earned("paid", r, milli)
            elif eff["type"] == "mission_rewards":
                st.pass_owned = True
            elif eff["type"] == "research_time_minutes":
                # 残り時間だけを減らす（コスト・条件は開始時に支払い済み、免除しない）
                nid = self.skip_target()
                if nid is not None:
                    st.research_active[nid] = max(self.t, st.research_active[nid] - eff["minutes"])
        self.extra_events.append({"event_type": "purchase", "target_id": product_id, "time": self.t, "value": prod["price_robux"]})
        self.touch()
        self._complete_due(self.t)
        self.claim_pass_missions()
        return True

    def _reference_state(self, field_id: str) -> dict[str, Any]:
        states = [s for s in self.static_ref["g2_states"] if s["field_id"] == field_id]
        entry = [s for s in states if s["id"].endswith("_entry")]
        return (entry or states)[0]

    def _pass_missions(self) -> list[dict[str, Any]]:
        out = []
        for p in self.m.products.values():
            for eff in p["effects"]:
                if eff["type"] == "mission_rewards":
                    out.extend(eff["missions"])
        return out

    def mission_done(self, cond: dict[str, Any]) -> bool:
        st = self.state
        t, amount, target = cond["type"], cond["amount"], cond.get("target_id")
        if t == "capture_count":
            return st.captures >= amount
        if t == "facility_level":
            return st.fac_level.get(target, 0) >= amount
        if t == "field_unlocked":
            return target in st.unlocked
        if t == "spirit_level":
            return any(s.level >= amount and (target is None or s.species == target) for s in st.roster.values())
        return False

    def claim_pass_missions(self) -> int:
        """パス所有時、達成済み（購入前の達成も含む＝遡及）で未受領のミッション報酬を 1 回だけ付与する."""
        st = self.state
        if not st.pass_owned:
            return 0
        n = 0
        for mis in self._pass_missions():
            if mis["id"] in st.pass_claimed or not self.mission_done(mis["condition"]):
                continue
            st.pass_claimed.add(mis["id"])
            acc = self.day_acc(self.t // DAY)
            for r in mis["rewards"]:
                st.wallet[r["resource"]] += r["amount"] * 1000
                acc.add_earned("paid", r["resource"], r["amount"] * 1000)
            self.extra_events.append({"event_type": "pass_claim", "target_id": mis["id"], "time": self.t, "value": 0})
            n += 1
        if n:
            self.touch()
        return n

    def _apply_purchases(self, day: int) -> None:
        for pu in self.persona["purchases"]:
            if pu.get("when") or day < pu["day"] or day > pu["until_day"]:
                continue  # 条件付き購入（研究短縮）は管理時点で buy_research_skips が扱う
            if pu["every_days"] == 0 and day != pu["day"]:
                continue
            if pu["every_days"] > 0 and (day - pu["day"]) % pu["every_days"]:
                continue
            self.buy_product(pu["product_id"], day)

    # ---- 活動 ----
    def individual_rng(self, day: int) -> random.Random:
        """個体値の乱数（stream '<individual>:day<N>'、捕獲の系列とは独立）."""
        if self._ind_day != day:
            self._ind_rng = rng.make_rng(self.master_seed, self.group, self.replicate_id, f"{self.ind['stream']}:day{day}")
            self._ind_day = day
        return self._ind_rng  # type: ignore[return-value]

    def capture_rng(self, day: int) -> random.Random:
        """日ごとに派生した捕獲乱数（比較群で同じ日・同じ遭遇順なら同じ抽選値）."""
        if self._rng_day != day:
            self._rng = rng.make_rng(self.master_seed, self.group, self.replicate_id, f"capture:day{day}")
            self._rng_day = day
        return self._rng  # type: ignore[return-value]

    def capture_table(self, field_id: str, night: bool) -> list[dict]:
        """その時点で出現する捕獲表（night_only は夜だけ。event は run 開始時に拒否済み）."""
        return [e for e in self.m.fields[field_id]["capture"]["table"]
                if e["weight"] > 0 and (e["availability"] == "always" or (night and e["availability"] == "night_only"))]

    def can_afford(self, costs: list[dict]) -> bool:
        need: dict[str, int] = {}
        for c in costs:
            need[c["resource"]] = need.get(c["resource"], 0) + c["amount"] * 1000
        return all(self.state.wallet[r] >= a for r, a in need.items())

    # ---- 活力（vigor、整数 tick で遅延評価） ----
    def vigor_at(self, uid: int, t: int) -> int:
        """時刻 t の活力（tick）。最後の更新以降の非活動時間ぶん回復する（上限 max）。状態は変えない."""
        if self.abl_vigor:
            return self.vig_max
        st = self.state
        v, vt = st.vigor[uid], st.vigor_t[uid]
        return min(self.vig_max, v + self.vig_rec * (t - vt)) if t > vt else v

    def settle_vigor(self, uid: int, t: int) -> int:
        st = self.state
        v = st.vigor[uid] = self.vigor_at(uid, t)
        st.vigor_t[uid] = max(st.vigor_t[uid], t)
        return v

    def use_vigor(self, uid: int, t: int, ticks: int, busy_until: int) -> None:
        """t 時点で ticks を消費し、busy_until までは回復しない（活動中）."""
        if self.abl_vigor:
            return
        st = self.state
        st.vigor[uid] = max(0, self.settle_vigor(uid, t) - ticks)
        st.vigor_t[uid] = max(st.vigor_t[uid], busy_until)

    def vigor_mult_bps(self, ticks: int) -> int:
        return self.vigor_rule["low_mult_bps"] if ticks <= self.vig_low else formulas.BPS

    def feed_party(self, party: tuple[int, ...] | list[int], t: int) -> None:
        """自動給餌: 活力が auto_feed_at_or_below 以下の同行に餌を与える（個体ごとに直近 window 分で max_per_window 個まで）."""
        food = self.vigor_rule["food"]
        thr = food["auto_feed_at_or_below"] * VIGOR_TICK
        st = self.state
        for u in party:
            while self.settle_vigor(u, t) <= thr:
                recent = [x for x in st.feed_times.get(u, []) if t - x < food["window_minutes"]]
                st.feed_times[u] = recent
                if len(recent) >= food["max_per_window"]:
                    self.day_acc(t // DAY).food_short_window += 1  # 直近窓の給餌上限で与えられない（単位: 不足した給餌機会）
                    break
                if not self.policy.ensure_food(1):
                    self.day_acc(t // DAY).food_short_stock += 1  # 在庫も制作もできない
                    break
                self.spend([{"resource": self.food_id, "amount": 1}])
                st.vigor[u] = min(self.vig_max, st.vigor[u] + food["restore"] * VIGOR_TICK)
                recent.append(t)
                self.day_acc(t // DAY).food_eaten += 1

    def hunt_rate_live(self, field_id: str, drop: dict, party: tuple[int, ...] | list[int], t: int) -> int:
        """狩りの実産出（milli/時）: 名目の狩り率に、同行の活力倍率を戦闘力で加重して掛ける（戦闘力ではなく産出に掛ける）."""
        rate = self.econ.hunt_rate(field_id, drop, self.members(party))
        ro = self.state.roster
        powers = [self.econ.combat_power(ro[u].species, ro[u].level, ro[u].combat_bps) for u in party]
        mults = [self.vigor_mult_bps(self.vigor_at(u, t)) for u in party]
        return formulas.vigor_hunt_scaled_milli(rate, powers, mults)

    def pick_attacker(self, party: tuple[int, ...] | list[int], target_grade: int, t: int) -> tuple[int | None, int, int]:
        """簡易モードの自動攻撃者 (uid|None=灯籠の補助弱体化, 秒, 活力消費 tick).

        候補: 活力 > vigor_above かつ 弱体化 ≤ max_seconds の同行 → 活力消費最小 → 秒 → 活力の余裕 → uid。
        候補がなければ行動可能（活力 > 0）な同行のうち秒が最小のもの。それも灯籠（assist_seconds）より速くなければ灯籠。
        """
        cr, wk = self.capture_rule, self.capture_rule["weaken"]
        aa = wk["auto_attacker"]
        ro = self.state.roster
        best = None
        fallback = None
        for u in party:
            v = self.vigor_at(u, t)
            if v <= 0:
                continue
            g = self.m.spirits[ro[u].species]["grade"]
            lv = 1 if self.abl_level else ro[u].level
            sec = formulas.weaken_seconds(g, lv, target_grade, Fraction(v, VIGOR_TICK), cr)
            if sec < 0:
                continue
            cost = formulas.weaken_vigor_cost(g, target_grade, cr) * VIGOR_TICK
            if v > aa["vigor_above"] * VIGOR_TICK and sec <= aa["max_seconds"]:
                key = (cost, sec, -v, u)
                if best is None or key < best[0]:
                    best = (key, u, sec, cost)
            key2 = (sec, cost, -v, u)
            if fallback is None or key2 < fallback[0]:
                fallback = (key2, u, sec, cost)
        if best is not None:
            return best[1], best[2], best[3]
        if fallback is not None and fallback[2] < wk["assist_seconds"]:
            return fallback[1], fallback[2], fallback[3]
        return None, wk["assist_seconds"], 0

    # ---- 捕獲（遭遇の状態機械） ----
    def tool_for(self, species: str, grade: int) -> str | None:
        """この遭遇で自動使用する捕獲補助道具（資源 ID）。モード off・★4 以外（star4）・条件（formulas.capture_tool_item）不成立は None."""
        if self.tool_rule is None or (self.tool_mode == "star4" and grade != 4):
            return None
        st = self.state
        return formulas.capture_tool_item(self.m.spirits[species]["home_field"], grade, st.unlocked, species in st.first_capture,
                                          self.capture_rule)

    def wicks_ok(self) -> bool:
        return self.wick_unlimited or self.state.wallet[self.wick_id] >= self.wick_per_attempt * 1000

    def _start_encounter(self, field_id: str, day: int, t: int, party: tuple[int, ...], busy_until: int,
                         night: bool | None = None) -> bool:
        """遭遇を開始する: 日の捕獲乱数から固定ブロック（種 1 + 試行成功 K + 逃走 K）を必ず消費し、結果を確定して pending にする.

        種は開始時刻の出現表、芯は開始時に試行数分を差し引く（結果は完了時刻に適用）。出現表が空なら開始しない。
        """
        st = self.state
        table = self.capture_table(field_id, self.is_night(t) if night is None else night)
        wsum = sum(e["weight"] for e in table)
        if wsum <= 0:
            return False
        r = self.capture_rng(day)
        u = [r.random() for _ in range(1 + 2 * self.k_max)]
        x = u[0] * wsum
        pick = table[-1]["spirit_id"]
        for e in table:
            if x < e["weight"]:
                pick = e["spirit_id"]
                break
            x -= e["weight"]
        grade = self.m.spirits[pick]["grade"]
        acc = self.day_acc(day)
        attacker, wsec = None, 0
        if formulas.weaken_needed(grade, self.capture_rule):
            party = tuple(u for u in party if u in st.roster)  # 同じステップ内の放出で抜けた同行は除く
            attacker, wsec, cost = self.pick_attacker(party, grade, t)
            if attacker is None:
                acc.assist_weaken += 1
            else:
                self.use_vigor(attacker, t, cost, busy_until)
            acc.weaken_n += 1
            acc.weaken_seconds += wsec
        avail = -1 if self.wick_unlimited else st.wallet[self.wick_id] // 1000
        # 捕獲補助道具: 確率の値だけを変え、乱数ブロック（上の u）と消費順は変えない。道具なしは resolve_encounter と同じ結果
        tool_res = self.tool_for(pick, grade)
        tools = max(0, st.wallet[tool_res] // 1000 - self.tool_min_stock) if tool_res is not None else 0
        result, attempts, used, seconds, tused = formulas.resolve_encounter_tool(grade, self.capture_rule, u[1:], avail, wsec, tools)
        if used:
            self.spend([{"resource": self.wick_id, "amount": used}])
        if tused:
            self.spend([{"resource": tool_res, "amount": tused}])
            lf = self.lure_field[tool_res]
            acc.lure_used[lf] = acc.lure_used.get(lf, 0) + tused
            if self.tool_rule["unlock_after_field"] not in st.unlocked:
                acc.tool_pre_unlock += 1  # 番人（tool_for が弾くので常に 0）
        st.encounters += 1
        st.attempts += attempts
        full_wick = avail < 0 or avail >= self.k_max * self.wick_per_attempt
        self.pending = {"field": field_id, "species": pick, "grade": grade, "result": result, "attempts": attempts,
                        "seconds": seconds, "remaining": seconds, "start": t, "index": st.encounters,
                        # 開始時に芯が K_max 回分以上（または無制限）: 芯の数で結果が切れない遭遇（確率適合度の集計対象）
                        "full_wick": full_wick,
                        # 道具を使った試行数（0 = 道具なしの遭遇）。開始時に道具も K_max 回分以上 = 全試行が道具付き（道具の適合度用）
                        "tool_attempts": tused // self.tool_rule["per_attempt"] if tused else 0,
                        "full_tool": bool(tused) and full_wick and tools >= self.k_max * self.tool_rule["per_attempt"]}
        return True

    def _complete_encounter(self, pe: dict[str, Any], t: int) -> bool:
        """遭遇の完了（時刻 t）: 結果を適用する。捕獲した精霊は完了日の個体値系列で個体値を引く。精霊が増えたら True."""
        st = self.state
        day = t // DAY
        acc = self.day_acc(day)
        acc.enc_done[pe["field"]] = acc.enc_done.get(pe["field"], 0) + 1
        acc.enc_seconds[pe["field"]] = acc.enc_seconds.get(pe["field"], 0) + pe["seconds"]
        st.result_counts[pe["result"]] = st.result_counts.get(pe["result"], 0) + 1
        key = (pe["grade"], pe["result"])
        acc.grade_results[key] = acc.grade_results.get(key, 0) + 1
        acc.grade_attempts[pe["grade"]] = acc.grade_attempts.get(pe["grade"], 0) + pe["attempts"]
        acc.field_attempts[pe["field"]] = acc.field_attempts.get(pe["field"], 0) + pe["attempts"]
        tool_n = pe.get("tool_attempts", 0)
        if tool_n:
            # 道具を使った遭遇は道具なしの確率適合度（grade_results_full）から外し、道具の集計に分ける（off では常に 0 件）
            tg = acc.tool_grade
            g = pe["grade"]
            tg[(g, "enc")] = tg.get((g, "enc"), 0) + 1
            acc.tool_attempts += tool_n
            if pe["result"] == "success":
                tg[(g, "success")] = tg.get((g, "success"), 0) + 1
            if pe.get("full_tool"):
                tg[(g, "full_enc")] = tg.get((g, "full_enc"), 0) + 1
                if pe["result"] == "success":
                    tg[(g, "full_success")] = tg.get((g, "full_success"), 0) + 1
        elif pe.get("full_wick", True):
            acc.grade_results_full[(pe["grade"], "enc")] = acc.grade_results_full.get((pe["grade"], "enc"), 0) + 1
            if pe["result"] == "success":
                acc.grade_results_full[(pe["grade"], "success")] = acc.grade_results_full.get((pe["grade"], "success"), 0) + 1
        if pe["result"] != "success":
            return False
        pick = pe["species"]
        st.captures += 1
        if pick not in st.first_capture:
            st.first_capture[pick] = (t, pe["index"])
            if tool_n:
                acc.tool_first_capture += 1  # 番人: 初捕獲に道具が効いた（tool_for が直接捕獲の履歴を要求するので常に 0）
        ir = self.individual_rng(day)
        g = ir.randint(self.ind["gather_bps_min"], self.ind["gather_bps_max"])  # 独立な一様（整数 bps）
        c = ir.randint(self.ind["combat_bps_min"], self.ind["combat_bps_max"])
        self._add_spirit(pick, 1, g, c)
        if len(st.roster) >= self.capacity() and st.storage_full_time is None:
            st.storage_full_time = t
        if len(st.roster) > self.capacity():
            self._release_one(day)
        return True

    def _capture(self, act_or_field: Any, day: int, night: bool | None = None, t0: int | None = None) -> None:
        """捕獲ステップ 1 回（予算 step×60 秒）。pending を先に進め、残り秒で新しい遭遇を始める.

        night を与えると出現表の昼夜をその値に固定する（テスト用。None なら遭遇の開始時刻で判定）。

        秒の保存: その日に使った秒 ≤ その日の捕獲予算秒（未完了分は pending.remaining として翌ステップへ）。
        """
        if isinstance(act_or_field, Action):
            field_id, party = act_or_field.field_id, tuple(act_or_field.party)
        else:
            field_id, party = act_or_field, ()
        st = self.state
        t0 = self.t - self.step if t0 is None else t0
        t1 = t0 + self.step
        budget = self.step * 60
        used = 0
        acc = self.day_acc(day)
        changed = False
        while used < budget:
            if self.pending is None:
                if not self.wicks_ok():
                    self.policy.ensure_wick()
                    if not self.wicks_ok():
                        break
                if not self._start_encounter(field_id, day, t0 + used // 60, party, t1, night):
                    break
            pe = self.pending
            take = min(pe["remaining"], budget - used)
            pe["remaining"] -= take
            used += take
            if pe["remaining"] == 0:
                self.pending = None
                # 完了時刻 = 完了した秒を含む分（[t0, t1) に収まるので、ステップ終端が 0 時でも日付はステップの日）
                changed |= self._complete_encounter(pe, t0 + (used - 1) // 60)
        acc.cap_budget_s += budget
        acc.cap_used_s += used
        if changed:
            self.research_tick_cap()
            self.policy.reassign()

    def facility_keepers(self) -> set[int]:
        """施設に有用な精霊（各施設の最大枠で、その資源の 1 施設厳密最適に入る個体の和集合）.

        方針「施設に役立つ精霊は残して配置する」（2026-11-10 ユーザー決定 B）。最大枠で選ぶのは、枠が開いた後に置く精霊を
        先に手放さないため。未開放の施設も Lv1 として数える（選ばれる組は施設 Lv に依存しない）。昼の寄与で選ぶ。
        """
        st = self.state
        uids = sorted(st.roster)
        spirits = self.members(uids)
        keep: set[int] = set()
        for fid in self.m.facility_order:
            fac = self.m.facilities[fid]
            slot = placement.Slot(fid, max(1, st.fac_level.get(fid, 0)), fac["slots"]["max"])
            keep.update(uids[i] for i in placement.best_single(self.econ, slot, spirits).assign[fid])
        return keep

    def _release_one(self, day: int) -> None:
        st = self.state
        counts: dict[str, int] = {}
        for s in st.roster.values():
            counts[s.species] = counts.get(s.species, 0) + 1
        assigned = {u for us in st.assignment.values() for u in us}
        keep = self.facility_keepers()
        # 個体値（F2）も考慮: 重複種 → 施設に有用でない → 低等級 → 低レベル → 個体値合計が低い → 未配置 → 新しい順
        # （施設に有用な個体の保護は 2026-11-10 追加。以前は低等級の重複が常に先に手放され、bloom 適性 A の flower_lamp が
        #  1 体に固定されて bloom の最善方置が細り、G2 が超過した）
        victim = min(st.roster.values(), key=lambda s: (counts[s.species] <= 1, s.uid in keep,
                                                         self.m.spirits[s.species]["grade"], s.level,
                                                         s.gather_bps + s.combat_bps,
                                                         s.uid in assigned, -s.uid))
        del st.roster[victim.uid]
        st.vigor.pop(victim.uid, None)
        st.vigor_t.pop(victim.uid, None)
        st.feed_times.pop(victim.uid, None)
        for fid in st.assignment:
            st.assignment[fid] = [u for u in st.assignment[fid] if u != victim.uid]
        grade = self.m.spirits[victim.species]["grade"]
        acc = self.day_acc(day)
        if self.research_id:
            milli = 1000 * next(g["amount"] for g in self.m.gd.docs["spirits"]["release_research_by_grade"] if g["grade"] == grade)
            st.wallet[self.research_id] += milli
            acc.add_earned("release", self.research_id, milli)
        st.releases += 1
        acc.released[victim.species] = acc.released.get(victim.species, 0) + 1
        self.touch()

    def do_step(self, act: Action, day: int) -> None:
        t0, t1 = self.t, self.t + self.step
        night = self.is_night(t0)
        party = frozenset(act.party)
        self.advance(t1, party)
        acc = self.day_acc(day)
        acc.add_min("online", self.step)
        acc.add_min(act.kind, self.step)
        if act.purpose == "wick":
            acc.add_min("wick_procure", self.step)  # 芯の材料の調達狩り（捕獲予算・flex のどちらからでも）
        for u in act.party:
            sp = self.state.roster[u].species
            acc.party_minutes[sp] = acc.party_minutes.get(sp, 0) + self.step
        if act.kind == "gather":
            res = act.node["resource"]
            rate = self.direct_rate(act.node, self.members(act.party))
            self._accrue("direct", res, rate, self.step, day)
            transition = self.in_transition(t0)
            idle_act = self.idle_rates(frozenset(), night).get(res, 0)
            idle_best = self.best_idle_rate(res, night)
            acc.r_actual.add(rate / idle_act if idle_act > 0 else None, self.step, transition, self.r_threshold)
            acc.r_best.add(rate / idle_best if idle_best > 0 else None, self.step, transition, self.r_threshold)
        elif act.kind == "hunt":
            # 活力: 開始時に自動給餌 → 活力倍率で産出を縮める → 参加精霊は分あたり消費、ステップ中は回復しない
            self.feed_party(act.party, t0)
            rate = self.hunt_rate_live(act.field_id, act.drop, act.party, t0)
            self._accrue("hunt", act.drop["resource"], rate, self.step, day)
            cost = self.vigor_rule["hunt_cost_per_minute"] * self.step * VIGOR_TICK
            for u in act.party:
                acc.hunt_party_min += self.step
                if self.vigor_at(u, t0) <= self.vig_low:
                    acc.vigor_low_hunt_min += self.step
                self.use_vigor(u, t0, cost, t1)
        elif act.kind == "capture":
            self.feed_party(act.party, t0)
            self._capture(act, day, t0=t0)

    # ---- 実行 ----
    def run(self) -> None:
        sessions = sorted(self.persona["sessions"], key=lambda s: s["start_minute"])
        every = self.cfg["policy"]["manage_every_steps"]
        for day in range(self.days):
            budget = dict(self.persona["activity_minutes"])
            for i, sess in enumerate(sessions):
                t_in = day * DAY + sess["start_minute"]
                self.advance(t_in)
                self.online = True
                if i == 0:
                    self.claim_quest(day)
                    self._apply_purchases(day)
                self.policy.reassign()
                self.policy.manage()
                for k in range(sess["minutes"] // self.step):
                    act = self.policy.choose(budget)
                    self._consume(budget, act.budget_kind or act.kind)
                    self.do_step(act, day)
                    if (k + 1) % every == 0:
                        self.policy.manage()
                self.policy.manage()
                self.logout_time = self.t
                self.online = False
            self.advance((day + 1) * DAY)
            # 芯切れで捕獲に使えなかった捕獲予算（分）= その日の捕獲予算 − 捕獲に使った分（調達狩りに回した分を含む）
            acc_d = self.day_acc(day)
            acc_d.add_min("wick_blocked", max(0, self.persona["activity_minutes"]["capture"] - acc_d.minutes.get("capture", 0)))
            if self.state.exhausted_time is None and self.policy.is_exhausted():
                self.state.exhausted_time = self.t
            self.day_snapshots.append(self._snapshot_day(day))

    def _consume(self, budget: dict[str, int], kind: str) -> None:
        """予算を 1 ステップ分減らす（同じ種類 → flex_pool 内の別種類 → 残っている予算の順）."""
        flex = self.cfg["policy"]["flex_pool"]
        order = [kind] + ([a for a in flex if a != kind] if kind in flex else []) + ["manage", "decor", "capture", "gather", "hunt"]
        for a in order:
            if budget.get(a, 0) >= self.step:
                budget[a] -= self.step
                return

    def _snapshot_day(self, day: int) -> dict[str, Any]:
        st, econ = self.state, self.econ
        species: dict[str, list[int]] = {}
        for s in st.roster.values():
            v = species.setdefault(s.species, [0, 0])
            v[0] += 1
            v[1] += s.level
        top = sorted((econ.combat_power(s.species, s.level, s.combat_bps) for s in st.roster.values()), reverse=True)[: econ.companion_slots]
        return {
            "day": day, "wallet": dict(st.wallet), "fields_unlocked": len(st.unlocked),
            "highest_field": max(st.unlocked, key=self.m.field_rank), "spirit_count": len(st.roster),
            "capacity": self.capacity(), "encounters": st.encounters, "captures": st.captures, "releases": st.releases,
            "robux": st.robux, "pass_claims": len(st.pass_claimed),
            "exhausted": st.exhausted_time is not None, "facility_level_sum": sum(st.fac_level.values()),
            "tool_level": st.tool_level, "offline_cap_h": st.offline_cap_hours, "hub_rank": st.hub_rank,
            "best_party_combat": sum(top) // formulas.BPS, "species": species, "dex": len(st.dex),
            "research_done": len(st.research_done),
            "attempts": st.attempts, "results": dict(st.result_counts),
            "pending_seconds": self.pending["remaining"] if self.pending else 0,
            "wick_wallet": st.wallet[self.wick_id], "sinks_owned": len(st.sinks_owned),
            "repeat_levels": sum(st.repeat_levels.values()), "finite_done": self.finite_done_count(),
            "repeat_open": sum(1 for rs in (self.m.sinks or {}).get("repeat_sinks", []) if self.sink_available(rs["id"])),
            "dex_pages": sum(st.dex_pages.values()),
        }
