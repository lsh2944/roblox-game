"""プレイヤー行動方針.

- 目標: 次のフィールド解禁コスト。目標 ETA = max_資源(不足量 / 実効獲得率)（獲得率 0 の不足は無限大として件数で比較）。
- 購入: 購入後 ETA が悪化せず獲得率が上がる強化のうち ETA が最小のものを繰り返し買う。最後のフィールド解禁後は
  回収期間（基本資源合計 / 基本資源獲得率の増分）が上限以内のものを回収期間順に買う。
- 活動: 捕獲予算を先に使い、採集・狩りは目標のボトルネック資源で選ぶ（flex_pool 内では予算を融通）。
- 配置: 貪欲 + 2-swap（placement.heuristic）。結果は「発見した配置」で、最適の証明ではない。
- 同行: 採集は控え精霊から同行寄与の高い順（特殊ノードは保有者を必ず含める）、狩りは全精霊から戦闘力順（ボーナス精霊の入れ替えも比較）。
"""
from __future__ import annotations

import heapq
import math
from dataclasses import dataclass
from fractions import Fraction
from typing import TYPE_CHECKING, Any, Callable

from . import formulas, placement
from .model import field_encounter_expectation
from .placement import Slot

if TYPE_CHECKING:
    from .sim import Simulator

INF = float("inf")


@dataclass
class Action:
    kind: str  # gather / hunt / capture / decor / manage
    field_id: str = ""
    node: dict | None = None
    drop: dict | None = None
    party: tuple[int, ...] = ()
    purpose: str = ""  # "wick" = 芯の調達狩り
    budget_kind: str = ""  # 消費する予算の種類（空なら kind）。芯切れで捕獲できない捕獲予算での調達は "capture"


@dataclass
class Candidate:
    label: str
    costs: list[dict]
    apply: Callable[[], None]
    affects: frozenset[str] = frozenset({"idle", "direct", "hunt", "frac"})  # what-if で再計算する成分


class Policy:
    def __init__(self, sim: "Simulator"):
        self.sim = sim
        self.econ = sim.econ
        self.m = sim.econ.m
        self.cfg = sim.cfg["policy"]
        am = sim.persona["activity_minutes"]
        self.G = am["gather"]
        self.H = am["hunt"]
        if "gather" in self.cfg["flex_pool"] and "hunt" in self.cfg["flex_pool"]:
            self.G = self.H = am["gather"] + am["hunt"]
        self._rv_cache: tuple[int, dict] | None = None
        self._rank_cache: tuple[int, dict[str, list[int]], list[int], set[int]] | None = None
        self._hunt_target_cache: tuple[int, dict[str, int]] | None = None
        self._hunt_target_label = ""
        self._idle_ema: dict[str, float] = {}
        self._frac: dict[int, float] = {}
        cr = sim.capture_rule
        # 簡易モードの遭遇あたり捕獲確率 Q（等級別、成長・活力に依らない）
        self._q = {g["grade"]: formulas.encounter_expectation(g["grade"], cr)[0] for g in cr["base_success_bps_by_grade"]}
        self._wick_per_day: dict[str, int] = {}
        self._lure_cache: dict[tuple[Any, ...], dict[str, int]] = {}

    # ---- 実効獲得率 ----
    def credited_frac(self, cap_hours: int) -> float:
        """1 日のうち放置生産が認定される分の割合（オンライン分 + 各オフライン間隔の上限内分）."""
        if cap_hours not in self._frac:
            ss = sorted(self.sim.persona["sessions"], key=lambda s: s["start_minute"])
            total = 0
            for i, s in enumerate(ss):
                end = s["start_minute"] + s["minutes"]
                nxt = ss[i + 1]["start_minute"] if i + 1 < len(ss) else ss[0]["start_minute"] + 1440
                total += s["minutes"] + min(nxt - end, cap_hours * 60)
            self._frac[cap_hours] = min(1.0, total / 1440)
        return self._frac[cap_hours]

    def _rankings(self) -> tuple[dict[str, list[int]], list[int], set[int]]:
        """状態バージョンごとに 1 回だけ作る並び: 資源別の控え上位・戦闘力順・配置済み集合."""
        st = self.sim.state
        if self._rank_cache and self._rank_cache[0] == st.version:
            return self._rank_cache[1], self._rank_cache[2], self._rank_cache[3]
        # 使うのは上位数体だけなので全体ソートではなく nsmallest（同じキー・同じ順で結果は sorted の先頭と一致）
        k = self.econ.companion_slots
        ro = st.roster
        assigned = {u for us in st.assignment.values() for u in us}
        bench_all = [u for u in ro if u not in assigned]
        bench: dict[str, list[int]] = {}
        for r in self.m.basic_ids:
            bench[r] = heapq.nsmallest(k + 1, bench_all, key=lambda u: (
                -self.econ.companion_power(ro[u].species, ro[u].level, r, ro[u].gather_bps), u))
        ckey = lambda u: (-self.econ.combat_power(ro[u].species, ro[u].level, ro[u].combat_bps), u)  # noqa: E731
        combat = heapq.nsmallest(k + 2, ro, key=ckey)
        # 狩りの同行ボーナス精霊の入れ替え候補（上位 k 体の外で最良の 1 体）を末尾に足す
        top = set(combat[:k])
        bonus = [u for u in ro if u not in top and self.econ.trait(ro[u].species, "companion_hunt_drop_bps") > 0]
        if bonus:
            b = min(bonus, key=ckey)
            if b not in combat:
                combat.append(b)
        self._rank_cache = (st.version, bench, combat, assigned)
        return bench, combat, assigned

    def gather_party(self, node: dict, resource: str) -> tuple[int, ...]:
        st = self.sim.state
        ranks, _, assigned = self._rankings()
        bench = ranks[resource]
        k = self.econ.companion_slots
        if not node.get("requires_node_trait"):
            return tuple(bench[:k])
        holders = self.econ.node_holders(node)
        cands = sorted((u for u in st.roster if st.roster[u].species in holders),
                       key=lambda u: (u in assigned, -st.roster[u].level, u))
        if not cands or k == 0:
            return ()
        h = cands[0]
        return tuple([h] + [u for u in bench if u != h][: k - 1])

    def hunt_party(self, field_id: str, drop: dict) -> tuple[int, ...]:
        st = self.sim.state
        k = self.econ.companion_slots
        order = self._rankings()[1]
        best = tuple(order[:k])
        best_rate = self.econ.hunt_rate(field_id, drop, self.sim.members(best))
        bonus = [u for u in order[k:] if self.econ.trait(st.roster[u].species, "companion_hunt_drop_bps") > 0]
        if bonus and k > 0:
            alt = tuple(order[: k - 1] + [bonus[0]])
            r = self.econ.hunt_rate(field_id, drop, self.sim.members(alt))
            if r > best_rate:
                best = alt
        return best

    def rate_view(self) -> dict[str, Any]:
        st = self.sim.state
        if self._rv_cache and self._rv_cache[0] == st.version:
            return self._rv_cache[1]
        rv = {"idle": self.sim.idle_rates(frozenset(), False), "direct": self._direct_view(), "hunt": self._hunt_view(),
              "home": self.sim.home_rates(frozenset()),
              "quest": self.sim.quest_rewards_now(), "frac": self.credited_frac(st.offline_cap_hours)}
        self._rv_cache = (st.version, rv)
        return rv

    def _direct_view(self) -> dict[str, int]:
        st = self.sim.state
        direct: dict[str, int] = {}
        for fid in st.unlocked:
            for node in self.m.fields[fid]["gather_nodes"]:
                party = self.gather_party(node, node["resource"])
                rate = self.sim.direct_rate(node, self.sim.members(party))
                direct[node["resource"]] = max(direct.get(node["resource"], 0), rate)
        return direct

    def _hunt_view(self) -> dict[str, int]:
        hunt: dict[str, int] = {}
        for fid in self.sim.state.unlocked:
            for d in self.m.fields[fid]["hunt"]["drops"]:
                rate = self.econ.hunt_rate(fid, d, self.sim.members(self.hunt_party(fid, d)))
                hunt[d["resource"]] = max(hunt.get(d["resource"], 0), rate)
        return hunt

    def eff_rates(self, rv: dict[str, Any], deficit_basic: int = 1, deficit_hunt: int = 1) -> dict[str, float]:
        """資源別の実効獲得率（milli/分）."""
        eff: dict[str, float] = {}
        for r in self.m.resource_order:
            kind = self.m.resources[r]["kind"]
            if kind == "basic":
                eff[r] = rv["idle"].get(r, 0) / 60 * rv["frac"] + self.G / 1440 * rv["direct"].get(r, 0) / 60 / max(1, deficit_basic)
            elif kind == "hunt":
                eff[r] = (self.H / 1440 * rv["hunt"].get(r, 0) / 60 / max(1, deficit_hunt) + rv["quest"].get(r, 0) / 1440
                          + rv["home"].get(r, 0) / 1440 * rv["frac"])
            else:
                eff[r] = 0.0
        return eff

    def eta(self, wallet: dict[str, int], goal: dict[str, int], rv: dict[str, Any]) -> tuple[int, float]:
        deficit = {r: goal[r] - wallet.get(r, 0) for r in goal if goal[r] > wallet.get(r, 0)}
        if not deficit:
            return (0, 0.0)
        nb = sum(1 for r in deficit if self.m.resources[r]["kind"] == "basic")
        nh = sum(1 for r in deficit if self.m.resources[r]["kind"] == "hunt")
        eff = self.eff_rates(rv, nb, nh)
        inf, worst = 0, 0.0
        for r, d in deficit.items():
            if eff[r] <= 0:
                inf += 1
            else:
                worst = max(worst, d / eff[r])
        return (inf, worst)

    def bottleneck(self) -> list[str]:
        """不足資源を ETA 寄与の大きい順に返す（目標なし・不足なしなら基本資源の残高が少ない順）.

        活動用の目標 = 次フィールド解禁コスト + 狩り素材だけが足りない有益な強化（施設ゲート・枠・上限など）の狩り素材。
        下位フィールドの素材でも、その素材を落とすフィールドへ狩りに行けるようにする。
        """
        st = self.sim.state
        base_goal = self.goal() or {}
        targets = self.hunt_targets()
        # 芯の調達: 予約優先「進行 > 芯 > 餌 > 消費先」を時間配分にも適用する（2026-11-10 レビュー Major 1）。
        # 芯の不足分の狩り素材は進行の不足がないときだけ先頭、進行の不足があればその後ろ（下位）に置く
        wick_need = self.wick_hunt_need()
        goal = dict(base_goal)
        for r, a in targets.items():
            goal[r] = goal.get(r, 0) + a
        rv = self.rate_view()
        if goal:
            deficit = {r: goal[r] - st.wallet[r] for r in goal if goal[r] > st.wallet[r]}
            if deficit:
                eff = self.eff_rates(rv)
                # 強化 1 件を即座に開く狩り素材（ゲート等）を先に集める。ETA 比だけで並べると、量の大きい基本資源が
                # 常に先頭になり、少量のゲート素材を狩りに行かないまま施設が Lv9 で止まる（3 段階の不具合）
                order = sorted(deficit, key=lambda r: (r not in targets,
                                                       -(deficit[r] / eff[r]) if eff[r] > 0 else -INF, r))
                # 先頭が基本資源でも、その直接採集が同じ時間の方置より少ない（R<1）なら、採集は待ち時間をほとんど縮めない。
                # 狩り素材は能動プレイでしか貯まらないので、不足があれば先に狩る（flex 予算の二重計上で狩り不足を
                # 過小評価し、ヘビーユーザーが採集だけを続けて解禁が遅れる 3 段階の不具合への対処）
                top = order[0]
                hunt_def = [r for r in order if self.m.resources[r]["kind"] == "hunt"]
                if hunt_def and self.m.resources[top]["kind"] == "basic":
                    idle_r = rv["idle"].get(top, 0)
                    if idle_r > 0 and rv["direct"].get(top, 0) < idle_r:
                        order = hunt_def + [r for r in order if r not in hunt_def]
                return order + self._wick_order(wick_need, goal, order)
        wick = self._wick_order(wick_need, goal, [])
        return wick + sorted(self.m.basic_ids, key=lambda r: (st.wallet[r], r))

    def wick_procure_action(self) -> Action | None:
        """芯の不足分の材料（進行の予約を超えて足りない狩り素材）を狩る行動。捕獲予算で行う（budget_kind="capture"）."""
        for r in self._wick_order(self.wick_hunt_need(), self.progress_reserve(), []):
            act = self._hunt_action(r)
            if act is not None:
                act.purpose, act.budget_kind = "wick", "capture"
                return act
        return None

    def _wick_order(self, wick_need: dict[str, int], goal: dict[str, int], already: list[str]) -> list[str]:
        """芯の不足分を作る狩り素材のうち、進行の予約を満たしたうえでまだ足りないもの（既に順位にある素材は除く）."""
        w = self.sim.state.wallet
        return [r for r, a in wick_need.items() if r not in already and goal.get(r, 0) + a > w[r]]

    def hunt_targets(self) -> dict[str, int]:
        """狩り素材が要る強化のうち、基本資源は払えて、取れば目標 ETA が悪化せず獲得率が上がる最良 1 件の狩り素材（milli）.

        手持ちで足りていても対象にする（解禁目標と同じ素材を取り合うとき、その強化の分を予約として目標に上乗せする）。
        """
        st = self.sim.state
        if self._hunt_target_cache and self._hunt_target_cache[0] == st.version:
            return self._hunt_target_cache[1]
        goal = self.goal()
        base = self.eta(st.wallet, goal, self.rate_view()) if goal else None
        best = None
        for c in self.candidates():
            hunt = [x for x in c.costs if self.m.resources[x["resource"]]["kind"] == "hunt"]
            basic = [x for x in c.costs if self.m.resources[x["resource"]]["kind"] != "hunt"]
            if not hunt or not self._affordable(basic):
                continue
            rv = self.rate_view()
            # ドロップ元が未解禁で、F1 方置・日次依頼でも入らない素材は予約しない（取りに行けない）
            if any(rv["hunt"].get(x["resource"], 0) <= 0 and rv["home"].get(x["resource"], 0) <= 0
                   and rv["quest"].get(x["resource"], 0) <= 0 for x in hunt):
                continue
            eta, rel, gain = self._evaluate(Candidate(c.label, basic, c.apply, c.affects), goal)
            if rel <= 0 or (base is not None and not self._eta_acceptable(eta, base, basic, gain)):
                continue
            key = (eta, -rel, c.label)
            if best is None or key < best[0]:
                best = (key, hunt, c.label)
        out: dict[str, int] = {}
        for x in best[1] if best else []:
            out[x["resource"]] = out.get(x["resource"], 0) + x["amount"] * 1000
        self._hunt_target_cache = (st.version, out)
        self._hunt_target_label = best[2] if best else ""
        return out

    # ---- 目標・候補 ----
    def next_field(self) -> str | None:
        st = self.sim.state
        for fid in self.m.field_order:
            if fid not in st.unlocked and all(r in st.unlocked for r in self.m.fields[fid]["unlock"]["requires_fields"]):
                return fid
        return None

    def goal(self) -> dict[str, int] | None:
        nf = self.next_field()
        if nf is None:
            return None
        # 道標（atomic）は素材に展開した費用・ETA で扱う（I6、段階 3）
        return {c["resource"]: c["amount"] * 1000 for c in self.m.expand_costs(self.m.fields[nf]["unlock"]["costs"])}

    def highest_field(self) -> str:
        return max(self.sim.state.unlocked, key=self.m.field_rank)

    def level_cap(self, entity: dict) -> int:
        return self.m.level_cap_at_field(entity, self.highest_field())

    def candidates(self) -> list[Candidate]:
        st, econ, m = self.sim.state, self.econ, self.m
        out: list[Candidate] = []
        for fid in m.facility_order:
            if fid not in st.fac_level:
                continue
            fac = m.facilities[fid]
            lv = st.fac_level[fid]
            if lv < self.level_cap(fac):
                out.append(Candidate(f"facility:{fid}:lv{lv + 1}", econ.facility_level_cost(fid, lv),
                                     lambda fid=fid: st.fac_level.__setitem__(fid, st.fac_level[fid] + 1), frozenset({"idle"})))
            if st.fac_slots[fid] < fac["slots"]["max"]:
                nxt = next(u for u in fac["slots"]["unlock"] if u["slot"] == st.fac_slots[fid] + 1)
                out.append(Candidate(f"slot:{fid}:{nxt['slot']}", nxt["costs"], lambda fid=fid: self.sim.open_slot(fid),
                                     frozenset({"idle", "direct"})))
        tool = m.tools[self.sim.tool_id]
        if st.tool_level < self.level_cap(tool):
            out.append(Candidate(f"tool:{self.sim.tool_id}:lv{st.tool_level + 1}",
                                 m.tables.cost[tool["cost_curve"]][st.tool_level],
                                 lambda: setattr(st, "tool_level", st.tool_level + 1), frozenset({"direct"})))
        ups = [u for u in m.hub["offline_cap"]["upgrades"] if u["hours"] > st.offline_cap_hours]
        if ups:
            u = ups[0]
            out.append(Candidate(f"offline_cap:{u['hours']}h", u["costs"], lambda h=u["hours"]: setattr(st, "offline_cap_hours", h),
                                 frozenset({"frac"})))
        _, combat_order, assigned = self._rankings()
        near_top = set(combat_order[: econ.companion_slots + 2])
        uids = [u for us in st.assignment.values() for u in us] + combat_order[: econ.companion_slots]
        seen: set[int] = set()
        for uid in uids:
            if uid in seen:
                continue
            seen.add(uid)
            sp = st.roster[uid]
            if sp.level < econ.max_spirit_level(sp.species):
                aff = {"idle"} if uid in assigned else {"direct"}
                if uid in near_top:
                    aff.add("hunt")
                out.append(Candidate(f"spirit:{uid}:{sp.species}:lv{sp.level + 1}", econ.spirit_level_cost(sp.species, sp.level),
                                     lambda sp=sp: setattr(sp, "level", sp.level + 1), frozenset(aff)))
        return out

    def _affordable(self, costs: list[dict]) -> bool:
        w = self.sim.state.wallet
        need: dict[str, int] = {}
        for c in costs:
            need[c["resource"]] = need.get(c["resource"], 0) + c["amount"] * 1000
        return all(w[r] >= a for r, a in need.items())

    def _evaluate(self, cand: Candidate, goal: dict[str, int] | None) -> tuple[tuple[int, float], float, float]:
        """(購入後 ETA, 相対獲得率増分の合計, 基本資源の獲得率増分 milli/分) を what-if で求める."""
        sim = self.sim
        base = self.rate_view()
        before = self.eff_rates(base)
        snap = sim.snapshot()
        cand.apply()
        sim.touch()
        # 候補が影響する成分だけ再計算する（施設は放置、道具は直接採集、配置済み精霊は放置、控え精霊は直接採集、上位戦闘力は狩り）
        rv = dict(base)
        if "idle" in cand.affects:
            rv["idle"] = sim.idle_rates(frozenset(), False)
            rv["home"] = sim.home_rates(frozenset())
        if "direct" in cand.affects:
            rv["direct"] = self._direct_view()
        if "hunt" in cand.affects:
            rv["hunt"] = self._hunt_view()
        if "frac" in cand.affects:
            rv["frac"] = self.credited_frac(sim.state.offline_cap_hours)
        after = self.eff_rates(rv)
        wallet = dict(sim.state.wallet)
        for c in cand.costs:
            wallet[c["resource"]] -= c["amount"] * 1000
        eta = self.eta(wallet, goal, rv) if goal else (0, 0.0)
        sim.restore(snap)
        rel = sum((after[r] - before[r]) / max(before[r], 1e-6) for r in before if after[r] > before[r] + 1e-12)
        basic = sum(after[r] - before[r] for r in self.m.basic_ids)
        return eta, rel, basic

    # ---- 管理（購入・配置） ----
    def manage(self) -> None:
        sim, st = self.sim, self.sim.state
        sim.claim_pass_missions()
        self.research_step()
        for _ in range(self.cfg["max_purchases_per_manage"]):
            goal = self.goal()
            if goal is not None and self._affordable([{"resource": r, "amount": a // 1000} for r, a in goal.items()]):
                sim.unlock_field(self.next_field())
                continue
            if self._try_hub_rank():
                continue
            cands = [c for c in self.candidates() if self._affordable(c.costs)]
            if not cands:
                break
            pick = self._pick(cands, goal)
            if pick is None:
                break
            sim.buy_upgrade(pick)
        self.research_step()
        sim.claim_pass_missions()
        self.ensure_wick()
        self.craft_lures()  # 予約順: 進行 > 芯 > 餌 > 有限外形 > 道具 > 反復消費先（道具は消費先の購入より先に在庫目安まで作る）
        self.buy_sinks()

    # ---- 消費先の購入（段階 4、予約優先の最下位） ----
    SINK_WICK_RESERVE_DAYS = 3  # 消費先を買っても残す芯の材料（日数分、計画書 5 節）
    FOOD_RESERVE_UNITS = 6  # 消費先を買っても残す餌の材料（餌 6 個 = 同行 3 体 × 2 個、placeholder）

    def sink_reserve(self) -> dict[str, int]:
        """消費先に使えない予約（milli）: 進行（解禁目標の展開コスト + 予約中の強化の狩り素材）+ 芯 3 日分 + 餌の材料.

        最後のフィールド解禁後は、回収期間 post_goal_payback_max_minutes 以内の未購入強化の費用も予約する（計画書 5 節）。
        """
        res = self.progress_reserve()
        for r, a in self.wick_hunt_need(self.SINK_WICK_RESERVE_DAYS).items():
            res[r] = res.get(r, 0) + a
        sim = self.sim
        short = 0 if sim.abl_vigor else self.FOOD_RESERVE_UNITS * 1000 - sim.state.wallet[sim.food_id]  # 活力 off は餌不要
        recs = [r for r in self.m.recipes_for(sim.food_id) if r["mode"] == "stock" and len(r["inputs"]) == 1]
        if short > 0 and recs:
            rec = max(recs, key=lambda r: (sim.state.wallet[r["inputs"][0]["resource"]], r["id"]))  # 余裕の大きい材料
            x = rec["inputs"][0]
            res[x["resource"]] = res.get(x["resource"], 0) + -(-short // (rec["output"]["amount"] * 1000)) * x["amount"] * 1000
        if self.goal() is None:
            for c in self.candidates():
                # 実際に買う規則と同じく、R 超過で見送る道具強化は予約しない（移行区間は見送らない、2 次レビュー Minor 3）
                if c.label.startswith("tool:") and not sim.in_transition(sim.t) and self.tool_r_exceeds(c):
                    continue
                _, _, gain = self._evaluate(c, None)
                cost = sum(x["amount"] * 1000 for x in c.costs if self.m.resources[x["resource"]]["kind"] == "basic")
                if gain > 0 and cost / gain <= self.cfg["post_goal_payback_max_minutes"]:
                    for x in c.costs:
                        res[x["resource"]] = res.get(x["resource"], 0) + x["amount"] * 1000
        return res

    def _sink_ok(self, costs: list[dict], reserve: dict[str, int], goal: dict[str, int] | None) -> bool:
        """買えて、予約を割らず、（最後のフィールド前は）目標 ETA を悪化させないか."""
        w = self.sim.state.wallet
        need: dict[str, int] = {}
        for c in costs:
            need[c["resource"]] = need.get(c["resource"], 0) + c["amount"] * 1000
        if any(w[r] - a < reserve.get(r, 0) for r, a in need.items()):
            return False
        if goal is not None:
            combined = dict(goal)
            for r, a in self.hunt_targets().items():
                combined[r] = combined.get(r, 0) + a
            rv = self.rate_view()
            base = self.eta(w, combined, rv)
            after = self.eta({r: w[r] - need.get(r, 0) for r in w}, combined, rv)
            if after[0] > base[0] or (after[0] == base[0] and after[1] > base[1] * (1 + 1e-9) + 1e-9):
                return False
        return True

    def _repeat_order(self, reserve: dict[str, int] | None) -> list[str]:
        """反復消費先の候補: 解禁済み最高フィールドの消費先（モジュール・祭壇）だけを、予約を超える残り素材で
        次のレベルを何回買えるか（全素材の最小）の多い順に並べる。複数の資源（結晶を含む）を均等に使うため（2 次レビュー M1）."""
        sim = self.sim
        top = self.highest_field()
        w = sim.state.wallet
        res = reserve or {}
        out = []
        for rs in (self.m.sinks or {}).get("repeat_sinks", []):
            if rs.get("field_id", top) != top or not sim.sink_available(rs["id"]):
                continue
            costs = self.m.expand_costs(sim.sink_costs(rs["id"])[1])
            times = min(((w[c["resource"]] - res.get(c["resource"], 0)) / (c["amount"] * 1000) for c in costs), default=0.0)
            out.append((-times, rs["id"]))
        return [x for _, x in sorted(out)]

    def _next_sinks(self, reserve: dict[str, int] | None = None) -> list[str]:
        """方針別の次の購入候補（優先順）。normal: カタログ順で最初の購入可能な有限品目（買えるまで待つ）→ 有限を全部買ったら
        最高フィールドの反復消費先（_repeat_order）。high: 購入可能な有限品目（カタログ順・買えなければ飛ばす）に続けて
        最高フィールドの反復消費先を同時に候補にする（有限を先に試す）。図鑑記録は buy_dex_records が別に扱う."""
        sim = self.sim
        finite = [x for x in sim.finite_catalog() if not sim.sink_owned(x)]
        avail_finite = [x for x in finite if sim.sink_available(x)]
        if sim.sink_pref == "normal":
            return avail_finite[:1] if finite else self._repeat_order(reserve)[:1]
        return avail_finite + self._repeat_order(reserve)

    def buy_dex_records(self) -> None:
        """図鑑記録（研究ツリー完了後、研究ポイントだけを使う）を種の順に買えるだけ買う（Q3 の推奨: ツリー完了後のみ）."""
        sim = self.sim
        if not sim.research_tree_complete():
            return
        for sp in self.m.spirit_order:
            while sim.sink_available(f"dex:{sp}") and sim.can_afford(sim.sink_costs(f"dex:{sp}")[1]):
                sim.buy_sink(f"dex:{sp}")

    def buy_sinks(self) -> None:
        """消費先を予約・ETA の範囲で買う（none は買わない）。normal は次の有限品目が買えるまで待つ（後ろを飛ばさない）."""
        sim = self.sim
        if sim.sink_pref == "none":
            return
        self.buy_dex_records()
        reserve: dict[str, int] | None = None
        goal = self.goal()
        for _ in range(self.cfg.get("max_sinks_per_manage", 50)):
            bought = False
            for x in self._next_sinks(reserve):
                costs = self.m.expand_costs(sim.sink_costs(x)[1])
                if not sim.can_afford(costs):
                    if sim.sink_pref == "normal":
                        break
                    continue
                if reserve is None:
                    reserve = self.sink_reserve()  # 重いので買える候補が出たときだけ 1 回求める
                if self._sink_ok(costs, reserve, goal):
                    sim.buy_sink(x)
                    bought = True
                    if x.startswith("house_rank:"):
                        reserve = None  # 拠点等級（家 2・3）は状態を変えるので予約を求め直す（2 次レビュー Minor 2）
                    break
                if sim.sink_pref == "normal":
                    break
            if not bought:
                return
            # 予約（進行・研究・芯 3 日分・餌・回収強化）は消費先の購入で変わらない（芯・餌の在庫、目標、候補は不変）ので使い回す。
            # 例外は状態を変える拠点等級だけで、上で求め直す

    # ---- 芯・餌の制作（予約優先: 進行 > 芯 > 餌 > 消費先） ----
    def progress_reserve(self) -> dict[str, int]:
        """進行の予約（milli）: 次フィールド解禁（展開済み）+ 予約中の強化の狩り素材。芯・餌の制作はこれを超える分だけ使う."""
        out = dict(self.goal() or {})
        for r, a in self.hunt_targets().items():
            out[r] = out.get(r, 0) + a
        # 計画書 5 節: 進行には研究も含む。次に始められる研究ノード（自然研究・空きスロットあり）の費用を予約する（2 次レビュー Minor 1）
        nid = self.next_research_node()
        if nid is not None:
            for c in self.m.research_nodes[nid]["costs"]:
                out[c["resource"]] = out.get(c["resource"], 0) + c["amount"] * 1000
        return out

    def next_research_node(self) -> str | None:
        """自然研究で次に始められるノード（データ順で最初の、条件を満たす未着手ノード）。スロットが埋まっていれば None."""
        sim = self.sim
        if sim.research_mode != "natural" or len(sim.state.research_active) >= sim.research_slots:
            return None
        return next((n for n in self.m.research_order if sim.research_available(n)), None)

    def wick_per_day(self) -> int:
        """解禁済み最高フィールドで 1 日の捕獲予算を使い切るときの期待芯数（静的見込み: 同等級 Lv1 で弱体化）."""
        fid = self.highest_field()
        hit = self._wick_per_day.get(fid)
        if hit is None:
            ea, secs = field_encounter_expectation(self.m, fid, self.sim.capture_rule)
            minutes = self.sim.persona["activity_minutes"]["capture"]
            hit = self._wick_per_day[fid] = math.ceil(minutes * 60 / secs * ea) if secs > 0 else 0
        return hit

    def _craft_from_surplus(self, output: str, need_units: int, reserve: dict[str, int]) -> None:
        """output を need_units 個以上になるまで、予約を超える狩り素材の余裕が最も大きいレシピで制作する（足りなければ作れる分だけ）."""
        sim, st = self.sim, self.sim.state
        recipes = [r for r in self.m.recipes_for(output) if r["mode"] == "stock"]
        for _ in range(len(recipes) + 1):
            short = need_units * 1000 - st.wallet[output]
            if short <= 0 or not recipes:
                return
            best = None
            for rec in recipes:
                times = min((st.wallet[x["resource"]] - reserve.get(x["resource"], 0)) // (x["amount"] * 1000) for x in rec["inputs"])
                if times > 0 and (best is None or times > best[0]):
                    best = (times, rec)
            if best is None:
                return
            times, rec = best
            want = -(-short // (rec["output"]["amount"] * 1000))
            sim.craft(rec["id"], min(times, want))

    def wick_hunt_need(self, days: int = 1) -> dict[str, int]:
        """芯の不足分（days 日の見込み − 在庫）を作るのに要る狩り素材（milli）。狩り 1 時間あたりの芯が最も多いレシピで見積もる."""
        sim = self.sim
        if sim.wick_unlimited:
            return {}
        short = days * self.wick_per_day() * 1000 - sim.state.wallet[sim.wick_id]
        if short <= 0:
            return {}
        rv = self.rate_view()
        best = None
        for rec in self.m.recipes_for(sim.wick_id):
            if rec["mode"] != "stock" or len(rec["inputs"]) != 1:
                continue
            x = rec["inputs"][0]
            per_hour = rv["hunt"].get(x["resource"], 0) * rec["output"]["amount"] / x["amount"]
            if per_hour > 0 and (best is None or per_hour > best[0]):
                best = (per_hour, rec, x)
        if best is None:
            return {}
        _, rec, x = best
        times = -(-short // (rec["output"]["amount"] * 1000))
        return {x["resource"]: times * x["amount"] * 1000}

    def ensure_wick(self) -> None:
        """芯の在庫が 1 日の見込み使用量より少なければ、進行予約を超える狩り素材で制作する（芯無制限モードでは何もしない）."""
        sim = self.sim
        if sim.wick_unlimited:
            return
        target = self.wick_per_day()
        if sim.state.wallet[sim.wick_id] < target * 1000:
            progress = self.progress_reserve()
            if sim.tool_rule is not None:
                # 道具 on のときだけ（2026-11-11 ユーザー決定 M2）: まず「進行 + 未購入の有限外形の狩り素材」を残して作り、
                # 足りなければ進行予約だけで作る（進行 > 芯 は変えない）。道具が有限外形用の余りを先に使った後、芯が
                # 有限外形の狩り素材を食って完了を遅らせるのを避ける。off は従来どおり進行予約だけ（完全回帰）
                protected = dict(progress)
                for r, a in self.finite_hunt_reserve().items():
                    protected[r] = protected.get(r, 0) + a
                self._craft_from_surplus(sim.wick_id, target, protected)
            self._craft_from_surplus(sim.wick_id, target, progress)

    def ensure_food(self, n: int) -> bool:
        """餌を n 個用意できるか（在庫がなければ制作）。芯が見込みに足りないうちは餌を作らない（芯 > 餌）."""
        sim, st = self.sim, self.sim.state
        if st.wallet[sim.food_id] >= n * 1000:
            return True
        if not sim.wick_unlimited and st.wallet[sim.wick_id] < self.wick_per_day() * 1000:
            return False
        self._craft_from_surplus(sim.food_id, n, self.progress_reserve())
        return st.wallet[sim.food_id] >= n * 1000

    # ---- 捕獲補助道具の制作（2026-11-11 決定。capture_tool=off では何もしない） ----
    CAPTURE_TOOL_STOCK_DAYS = 2  # 道具ごとの在庫目安: 1 日の見込み使用量の何日分まで作るか（personas policy.capture_tool_stock_days で上書き、placeholder）

    def lure_per_day(self) -> dict[str, int]:
        """道具ごとの 1 日の見込み使用量（個、切り上げ）。静的見込み: 解禁済み最高フィールド（昼の出現表）で捕獲予算を使い切るとき、
        道具が効く遭遇（sim.tool_for）の期待試行数（全試行で道具を使う）× 1 試行あたりの消費数."""
        sim, st = self.sim, self.sim.state
        if sim.tool_rule is None:
            return {}
        fid = self.highest_field()
        table = sim.capture_table(fid, False)
        items = tuple((e["spirit_id"], e["weight"], sim.tool_for(e["spirit_id"], self.m.spirits[e["spirit_id"]]["grade"])) for e in table)
        key = (fid, items)
        hit = self._lure_cache.get(key)
        if hit is None:
            rule = sim.capture_rule
            total = sum(w for _, w, _ in items)
            _, secs = field_encounter_expectation(self.m, fid, rule)
            enc = Fraction(sim.persona["activity_minutes"]["capture"] * 60) / secs if secs > 0 and total > 0 else Fraction(0)
            acc: dict[str, Fraction] = {}
            for sp, w, res in items:
                if res is None:
                    continue
                ea = formulas.encounter_expectation(self.m.spirits[sp]["grade"], rule, with_tool=True)[1]
                acc[res] = acc.get(res, Fraction(0)) + enc * Fraction(w, total) * ea * sim.tool_rule["per_attempt"]
            hit = self._lure_cache[key] = {r: math.ceil(v) for r, v in acc.items() if v > 0}
        return hit

    def tool_reserve(self) -> dict[str, int]:
        """道具の制作に使えない予約（milli）: 消費先の予約（進行 + 芯 3 日分 + 餌 + 回収の速い強化）+ 未購入の有限外形品目すべての狩り素材.

        予約順「有限外形 > 道具」を、有限外形の狩り素材（部品は展開）を残り全部ぶん先に確保することで守る。
        """
        res = self.sink_reserve()
        for r, a in self.finite_hunt_reserve().items():
            res[r] = res.get(r, 0) + a
        return res

    def finite_hunt_reserve(self) -> dict[str, int]:
        """未購入の有限外形品目すべての狩り素材（milli、部品は展開）."""
        sim = self.sim
        res: dict[str, int] = {}
        for x in sim.finite_catalog():
            if sim.sink_owned(x):
                continue
            for c in self.m.expand_costs(sim.sink_costs(x)[1]):
                if self.m.resources[c["resource"]]["kind"] == "hunt":
                    res[c["resource"]] = res.get(c["resource"], 0) + c["amount"] * 1000
        return res

    def craft_lures(self) -> None:
        """道具ごとに在庫が「1 日の見込み × 在庫日数」未満なら、予約を超える狩り素材で目安を超えない範囲で作る（目安超過の保有はしない）."""
        sim, st = self.sim, self.sim.state
        need = self.lure_per_day()
        if not need:
            return
        days = self.cfg.get("capture_tool_stock_days", self.CAPTURE_TOOL_STOCK_DAYS)
        reserve: dict[str, int] | None = None
        for res, per_day in sorted(need.items()):
            target = per_day * days * 1000
            if st.wallet[res] >= target:
                continue
            if reserve is None:
                reserve = self.tool_reserve()  # 重いので作る必要があるときだけ 1 回求める（制作は狩り素材だけを減らし、予約は不変）
            for rec in self.m.recipes_for(res):
                if rec["mode"] != "stock":
                    continue
                short = target - st.wallet[res]
                times = min((short // (rec["output"]["amount"] * 1000)),
                            *[(st.wallet[x["resource"]] - reserve.get(x["resource"], 0)) // (x["amount"] * 1000) for x in rec["inputs"]])
                if times > 0:
                    sim.craft(rec["id"], times)

    ETA_TOLERANCE = 0.01  # 回収の速い強化に許す目標 ETA の悪化率
    QUICK_PAYBACK_MINUTES = 1440

    def _eta_acceptable(self, eta: tuple[int, float], base: tuple[int, float], costs: list[dict], basic_gain: float) -> bool:
        """目標 ETA を悪化させない強化は可。加えて、基本資源の回収期間が 1 日以内なら ETA 1% までの悪化を許す.

        最大 ETA だけで判断すると、ボトルネック資源（上限に達した施設の資源）の不足が費用分だけ増えるため、
        回収数時間のゲート強化まで永久に見送られ、ヘビーユーザーの施設 Lv が止まる（4 段階で確認）。
        """
        if eta[0] < base[0] or (eta[0] == base[0] and eta[1] <= base[1] * (1 + 1e-9) + 1e-9):
            return True
        if eta[0] != base[0] or basic_gain <= 0:
            return False
        cost = sum(x["amount"] * 1000 for x in costs if self.m.resources[x["resource"]]["kind"] == "basic")
        return cost / basic_gain <= self.QUICK_PAYBACK_MINUTES and eta[1] <= base[1] * (1 + self.ETA_TOLERANCE)

    def _pick(self, cands: list[Candidate], goal: dict[str, int] | None) -> Candidate | None:
        """購入候補を選ぶ。道具強化で R（最善配置基準）が上限を超える場合はその道具強化を見送り、次点（施設強化など）を選ぶ.

        2026-11-10 ユーザー決定（G2 残余）: 課金の素材パックで初日に道具だけが先に上がり、直接採集 R が 3 を超えた
        （balanced_paid rep73 1 日目 meadow、R=3.0014）。データ・承認基準は変えず、購入順の規則で避ける。
        （素材パックは 2026-11-11 ユーザー決定で削除したが、規則は購入順の一般規則として残す。）
        """
        pool = list(cands)
        while pool:
            pick = self._pick_once(pool, goal)
            # 移行区間（新フィールド解禁後 transition_minutes、R>3 はユーザー決定で許容）では見送らない（レビュー Minor 8）
            if (pick is None or not pick.label.startswith("tool:") or self.sim.in_transition(self.sim.t)
                    or not self.tool_r_exceeds(pick)):
                return pick
            pool = [c for c in pool if c is not pick]
        return None

    def tool_r_exceeds(self, cand: Candidate) -> bool:
        """道具強化を仮適用したとき、いずれかの基本資源で 直接採集 / 最善方置（昼・夜）が r_threshold を超えるか."""
        sim = self.sim
        snap = sim.snapshot()
        cand.apply()
        sim.touch()
        try:
            for r, d in self._direct_view().items():
                if d <= 0:
                    continue
                for night in (False, True):
                    best = sim.best_idle_rate(r, night)
                    if best > 0 and d / best > sim.r_threshold:
                        return True
            return False
        finally:
            sim.restore(snap)

    def _pick_once(self, cands: list[Candidate], goal: dict[str, int] | None) -> Candidate | None:
        if goal is not None:
            # 解禁目標 + 予約中の強化の狩り素材を合わせた目標で比べる。予約対象そのものを買うときは予約分も目標から外す
            targets = self.hunt_targets()
            combined = dict(goal)
            for r, a in targets.items():
                combined[r] = combined.get(r, 0) + a
            base = self.eta(self.sim.state.wallet, combined, self.rate_view())
            best = None
            for c in cands:
                goal_c = combined
                if targets and c.label == self._hunt_target_label:
                    goal_c = dict(combined)
                    for x in c.costs:
                        if x["resource"] in targets:
                            goal_c[x["resource"]] -= x["amount"] * 1000
                eta, rel, gain = self._evaluate(c, goal_c)
                if rel <= 0:
                    continue
                if not self._eta_acceptable(eta, base, c.costs, gain):
                    continue
                key = (eta, -rel)
                if best is None or key < best[0]:
                    best = (key, c)
            return best[1] if best else None
        best = None
        for c in cands:
            _, _, basic_gain = self._evaluate(c, None)
            cost = sum(x["amount"] * 1000 for x in c.costs if self.m.resources[x["resource"]]["kind"] == "basic")
            if basic_gain <= 0:
                continue
            payback = cost / basic_gain
            if payback <= self.cfg["post_goal_payback_max_minutes"] and (best is None or payback < best[0]):
                best = (payback, c)
        return best[1] if best else None

    # ---- 研究 ----
    def research_step(self) -> None:
        """管理時点の研究: cap は即時完了、natural は空きスロットに開始 → 条件付き短縮購入（完了で空けば繰り返す）."""
        sim = self.sim
        if sim.research_mode == "cap":
            sim.research_tick_cap()
            return
        if sim.research_mode != "natural":
            return
        for _ in range(2 * len(self.m.research_order) + 2):
            started = False
            if len(sim.state.research_active) < sim.research_slots:
                nid = self.pick_research()
                if nid is not None:
                    sim.start_research(nid)
                    started = True
            bought = sim.buy_research_skips()
            if not started and not bought:
                break

    def pick_research(self) -> str | None:
        """次に始める研究（優先: production をデータ順 I→A → ecology）。基本資源の支出は解禁・強化目標を損なわない範囲だけ.

        - production: 払えて、効果を完了時刻まで遅らせた目標 ETA（解禁目標 + 予約中の強化の狩り素材）が
          強化購入と同じ許容規則（_eta_acceptable: 悪化なし、または基本資源の回収 1 日以内で 1% まで）を満たすもの。
          最後のフィールド解禁後は (基本資源コスト / 獲得率増分 + 研究時間) ≤ post_goal_payback_max_minutes。
        - ecology: 条件を満たした未着手の production があれば、その研究ポイント・狩り素材を予約したうえで払え、
          かつ目標 ETA を悪化させないもの（効果 0 なので支出が目標資源にかかると開始しない）。
        """
        sim, m = self.sim, self.m
        avail = [n for n in m.research_order if sim.research_available(n)]
        if not avail:
            return None
        prod = [n for n in avail if m.research_nodes[n]["track"] == "production"]
        eco = [n for n in avail if m.research_nodes[n]["track"] != "production"]
        goal = self.goal()
        combined: dict[str, int] | None = None
        if goal is not None:
            combined = dict(goal)
            for r, a in self.hunt_targets().items():
                combined[r] = combined.get(r, 0) + a
        for nid in prod:
            costs = m.research_nodes[nid]["costs"]
            if self._affordable(costs) and self._research_ok(nid, combined):
                return nid
        reserve: list[dict] = []
        if prod:
            reserve = [c for c in m.research_nodes[prod[0]]["costs"] if m.resources[c["resource"]]["kind"] != "basic"]
        for nid in eco:
            costs = m.research_nodes[nid]["costs"]
            if not self._affordable(costs + reserve):
                continue
            if combined:
                base = self.eta(sim.state.wallet, combined, self.rate_view())
                wallet = dict(sim.state.wallet)
                for c in costs:
                    wallet[c["resource"]] -= c["amount"] * 1000
                after = self.eta(wallet, combined, self.rate_view())
                if after[0] > base[0] or (after[0] == base[0] and after[1] > base[1] * (1 + 1e-9) + 1e-9):
                    continue
            return nid
        return None

    def _research_ok(self, nid: str, goal: dict[str, int] | None) -> bool:
        sim, m = self.sim, self.m
        node = m.research_nodes[nid]
        base_rv = self.rate_view()
        before = self.eff_rates(base_rv)
        # what-if: 効果だけ一時的に適用して方置・直接の獲得率を求める（状態は元に戻す）
        sim.state.research_done.add(nid)
        sim._recompute_research()
        sim.touch()
        after_rv = dict(base_rv)
        after_rv["idle"] = sim.idle_rates(frozenset(), False)
        after_rv["direct"] = self._direct_view()
        sim.state.research_done.discard(nid)
        sim._recompute_research()
        sim.touch()
        after = self.eff_rates(after_rv)
        gain = sum(after[r] - before[r] for r in m.basic_ids)
        if gain <= 0:
            return False
        cost = sum(c["amount"] * 1000 for c in node["costs"] if m.resources[c["resource"]]["kind"] == "basic")
        if goal is None:
            return cost / gain + node["duration_minutes"] <= self.cfg["post_goal_payback_max_minutes"]
        base = self.eta(sim.state.wallet, goal, base_rv)
        wallet = dict(sim.state.wallet)
        for c in node["costs"]:
            wallet[c["resource"]] -= c["amount"] * 1000
        eta = self.eta_delayed(wallet, goal, base_rv, after_rv, node["duration_minutes"])
        return self._eta_acceptable(eta, base, node["costs"], gain)

    def eta_delayed(self, wallet: dict[str, int], goal: dict[str, int], rv0: dict[str, Any], rv1: dict[str, Any],
                    delay: int) -> tuple[int, float]:
        """効果が delay 分後に始まるときの目標 ETA（それまでは rv0、以後 rv1 の実効獲得率）."""
        deficit = {r: goal[r] - wallet.get(r, 0) for r in goal if goal[r] > wallet.get(r, 0)}
        if not deficit:
            return (0, 0.0)
        nb = sum(1 for r in deficit if self.m.resources[r]["kind"] == "basic")
        nh = sum(1 for r in deficit if self.m.resources[r]["kind"] == "hunt")
        e0, e1 = self.eff_rates(rv0, nb, nh), self.eff_rates(rv1, nb, nh)
        inf, worst = 0, 0.0
        for r, d in deficit.items():
            a, b = e0[r], e1[r]
            if a > 0 and a * delay >= d:
                t = d / a
            elif b <= 0:
                inf += 1
                continue
            else:
                t = delay + (d - max(0.0, a) * delay) / b
            worst = max(worst, t)
        return (inf, worst)

    def _try_hub_rank(self) -> bool:
        sim, st = self.sim, self.sim.state
        ranks = self.m.hub["ranks"]
        if st.hub_rank >= len(ranks):
            return False
        if sim.capacity() - len(st.roster) > self.cfg["hub_rank_when_free_slots_at_most"]:
            return False
        nxt = ranks[st.hub_rank]  # rank は 1 始まり、配列の st.hub_rank 番目が次
        if nxt["storage_bonus"] <= 0 or not self._affordable(nxt["costs"]):  # 効果のない等級は買わない
            return False
        sim.buy_upgrade(Candidate(f"hub_rank:{nxt['rank']}", nxt["costs"], lambda: setattr(st, "hub_rank", nxt["rank"])))
        return True

    def weights(self) -> dict[str, float]:
        st = self.sim.state
        goal = self.goal()
        w = {r: 1.0 for r in self.m.basic_ids}
        if goal:
            deficit = {r: max(0, goal.get(r, 0) - st.wallet[r]) for r in self.m.basic_ids}
            total = sum(deficit.values())
            if total > 0:
                for r in w:
                    w[r] = 1.0 + 3.0 * deficit[r] / total
        # 資源間の均衡補正: 現在の放置生産が平均より少ない資源ほど重くする（√比、0.5〜4 倍）。
        # 線形加重和だけだと高レベル施設へ精霊が集まり、低レベル施設の資源（例: 結晶）の放置が極端に細る
        # 振動対策: 直前の配置の方置量そのものではなく、指数平滑（半減）した値で補正する。
        # 現在値だけを使うと「少ない資源を重く → 配置が移る → 今度は別資源が少ない」を繰り返し、
        # ある施設が 1 体だけの瞬間ができて R が跳ねる（4 段階のレビュー指摘）
        now = self.sim.idle_rates(frozenset(), False)
        idle = {}
        for r in w:
            prev = self._idle_ema.get(r)
            idle[r] = now.get(r, 0) if prev is None else 0.5 * prev + 0.5 * now.get(r, 0)
            self._idle_ema[r] = idle[r]
        produced = [r for r in w if any(self.m.facilities[f]["produces"] == r for f in st.fac_level)]
        positive = [idle.get(r, 0) for r in produced if idle.get(r, 0) > 0]
        if positive:
            avg = sum(positive) / len(positive)
            for r in produced:
                v = idle.get(r, 0)
                w[r] *= 4.0 if v <= 0 else min(4.0, max(0.5, (avg / v) ** 0.5))
        return w

    def reassign(self) -> None:
        """全精霊を施設へ再配置する（ヒューリスティック、候補は上位の精霊に限定）."""
        sim, st = self.sim, self.sim.state
        facs = [Slot(fid, st.fac_level[fid], st.fac_slots[fid]) for fid in self.m.facility_order if fid in st.fac_level]
        w = self.weights()
        # 候補は施設ごとにその資源の寄与上位（枠数+1）を集める。全体上位だけだと、適性の偏った在庫で
        # 結晶施設に置ける精霊が候補から漏れて 0 体配置になる（2 段階の不具合）
        # 加えて種ごとの最上位 1 体も候補にする（2026-11-10 ユーザー決定 B）。寄与上位だけだと、寄与は低いが施設全体に
        # 効く混合ボーナス精霊（Lv1 の rainbow_butterfly）が候補から漏れ、配置されないので Lv も上がらない
        chosen: set[int] = set()
        species_top: dict[str, int] = {}
        for f in facs:
            r = self.m.facilities[f.fid]["produces"]
            power = {u: self.econ.slot_power(st.roster[u].species, st.roster[u].level, r, False, st.roster[u].gather_bps) for u in st.roster}
            ranked = sorted(st.roster, key=lambda u: (-power[u], u))
            chosen.update(u for u in ranked[: f.slots + 1] if power[u] > 0)
            for u in ranked:
                if power[u] > 0:
                    species_top.setdefault(st.roster[u].species, u)
        chosen.update(species_top.values())
        uids = sorted(chosen)
        spirits = self.sim.members(uids)
        found = placement.heuristic(self.econ, facs, spirits, w)
        st.assignment = {fid: [uids[i] for i in idxs] for fid, idxs in found.assign.items()}
        self._fill_empty_facilities(facs, w)
        sim.touch()

    def _fill_empty_facilities(self, facs: list[Slot], w: dict[str, float]) -> None:
        """開いた施設を空のままにしない（その資源に寄与 > 0 の精霊がいれば、加重生産の損失が最小の 1 体を移す）.

        加重和最大化だけだと、高レベル施設に置いた方が得な精霊が低レベルの新施設（例: 森解禁直後の結晶工房）に
        回らず、その資源の放置生産が 0 のまま直接採集だけになる（R 未定義）。
        """
        st, econ = self.sim.state, self.econ
        level = {f.fid: f.level for f in facs}
        for f in facs:
            if st.assignment.get(f.fid):
                continue
            res = self.m.facilities[f.fid]["produces"]
            best = None
            for u, sp in st.roster.items():
                if econ.slot_power(sp.species, sp.level, res, False, sp.gather_bps) <= 0:
                    continue
                src = next((fid for fid, us in st.assignment.items() if u in us), None)
                loss = 0.0
                if src is not None:
                    before = self.sim.members(st.assignment[src])
                    after = self.sim.members([x for x in st.assignment[src] if x != u])
                    r_src = self.m.facilities[src]["produces"]
                    loss = w[r_src] * (econ.facility_rate(src, level[src], before) - econ.facility_rate(src, level[src], after))
                gain = w[res] * econ.facility_rate(f.fid, f.level, self.sim.members([u]))
                key = (loss - gain, u)
                if best is None or key < best[0]:
                    best = (key, u, src)
            if best is not None:
                _, u, src = best
                if src is not None:
                    st.assignment[src] = [x for x in st.assignment[src] if x != u]
                st.assignment[f.fid] = [u]

    # ---- 活動選択 ----
    def choose(self, budget: dict[str, int]) -> Action:
        st = self.sim.state
        if budget["capture"] > 0:
            fid = self.capture_field()
            if fid is None and self.sim.pending is not None:
                fid = self.sim.pending["field"]  # 芯がなくても未完了の遭遇は続ける
            if fid is not None:
                return Action("capture", field_id=fid, party=self.capture_party())
            # 芯がなく捕獲できない捕獲予算は、芯の材料の調達狩りに使う（進行用の flex 予算は奪わない: 進行 > 芯）
            act = self.wick_procure_action()
            if act is not None:
                return act
        flex = self.cfg["flex_pool"]
        pool = sum(budget[a] for a in flex)
        for r in self.bottleneck():
            kind = self.m.resources[r]["kind"]
            cat = "hunt" if kind == "hunt" else "gather"
            if kind not in ("hunt", "basic"):
                continue
            ok = budget[cat] > 0 or (cat in flex and pool > 0)
            if not ok:
                continue
            act = self._hunt_action(r) if cat == "hunt" else self._gather_action(r)
            if act is not None:
                return act
        for cat in ("gather", "hunt"):
            if budget[cat] > 0 or (cat in flex and pool > 0):
                act = self._gather_action(None) if cat == "gather" else None
                if act is not None:
                    return act
        if budget["decor"] > 0:
            return Action("decor")
        return Action("manage")

    def _gather_action(self, resource: str | None) -> Action | None:
        st, econ = self.sim.state, self.econ
        best = None
        for fid in st.unlocked:
            for node in self.m.fields[fid]["gather_nodes"]:
                if resource is not None and node["resource"] != resource:
                    continue
                party = self.gather_party(node, node["resource"])
                rate = self.sim.direct_rate(node, self.sim.members(party))
                if rate > 0 and (best is None or rate > best[0]):
                    best = (rate, Action("gather", field_id=fid, node=node, party=party))
        return best[1] if best else None

    def _hunt_action(self, resource: str) -> Action | None:
        st = self.sim.state
        best = None
        for fid in st.unlocked:
            for d in self.m.fields[fid]["hunt"]["drops"]:
                if d["resource"] != resource:
                    continue
                party = self.hunt_party(fid, d)
                rate = self.econ.hunt_rate(fid, d, self.sim.members(party))
                if rate > 0 and (best is None or rate > best[0]):
                    best = (rate, fid, d)
        if best is None:
            return None
        _, fid, d = best
        # 行き先は名目の狩り率で選び、同行は活力込みで選び直す（無料の自動交代）
        return Action("hunt", field_id=fid, drop=d, party=self.hunt_party_live(fid, d))

    def _live_order(self, n: int) -> list[int]:
        """行動可能（活力 > 0）な精霊を 戦闘力 × 活力倍率 の降順に n 体."""
        sim, st = self.sim, self.sim.state
        t = sim.t
        ro = st.roster
        cands = []
        for u in ro:
            v = sim.vigor_at(u, t)
            if v > 0:
                cands.append((-(self.econ.combat_power(ro[u].species, ro[u].level, ro[u].combat_bps) * sim.vigor_mult_bps(v)), u))
        return [u for _, u in heapq.nsmallest(n, cands)]

    def hunt_party_live(self, field_id: str, drop: dict) -> tuple[int, ...]:
        """狩りの同行（活力込み）: 戦闘力×活力倍率の上位 k 体。ドロップボーナス精霊との入れ替えも実産出で比べる."""
        sim, st = self.sim, self.sim.state
        k = self.econ.companion_slots
        order = self._live_order(len(st.roster))
        best = tuple(order[:k])
        if k == 0 or not best:
            return best
        bonus = [u for u in order[k:] if self.econ.trait(st.roster[u].species, "companion_hunt_drop_bps") > 0]
        if bonus:
            alt = tuple(list(best[: k - 1]) + [bonus[0]])
            if sim.hunt_rate_live(field_id, drop, alt, sim.t) > sim.hunt_rate_live(field_id, drop, best, sim.t):
                return alt
        return best

    def capture_party(self) -> tuple[int, ...]:
        """捕獲の同行（弱体化の攻撃者候補）: 狩りと同じく戦闘力×活力倍率の上位 k 体（活力 0 は除く）。同行中は施設から外れる."""
        return tuple(self._live_order(self.econ.companion_slots))

    def capture_field(self) -> str | None:
        """未所持種を捕まえる期待値 Σ未所持 (w/W)·Q_等級 が最大のフィールド（今出現する表のみ、芯が必要なら芯があること）。なければ None."""
        sim, st = self.sim, self.sim.state
        if not sim.wicks_ok():
            self.ensure_wick()
            if not sim.wicks_ok():
                return None
        owned = {s.species for s in st.roster.values()}
        night = sim.is_night(sim.t)
        best = None
        for fid in st.unlocked:
            table = sim.capture_table(fid, night)
            total = sum(e["weight"] for e in table)
            if total <= 0:
                continue
            score = sum(e["weight"] / total * float(self._q[self.m.spirits[e["spirit_id"]]["grade"]])
                        for e in table if e["spirit_id"] not in owned)
            key = (score, self.m.field_rank(fid))
            if best is None or key > best[0]:
                best = (key, fid)
        return best[1] if best else None

    # ---- コンテンツ消化 ----
    def is_exhausted(self) -> bool:
        st, m = self.sim.state, self.m
        if self.next_field() is not None:
            return False
        for fid, fac in m.facilities.items():
            if st.fac_level.get(fid, 0) < fac["max_level"] or st.fac_slots.get(fid, 0) < fac["slots"]["max"]:
                return False
        tool = m.tools[self.sim.tool_id]
        if st.tool_level < tool["max_level"]:
            return False
        # 方策と同じ基準: 効果 0 の拠点等級と、このペルソナに認定時間の利得がないオフライン上限強化は残っていても消化扱い
        for r in m.hub["ranks"][st.hub_rank:]:
            if r["storage_bonus"] > 0:
                return False
        for u in m.hub["offline_cap"]["upgrades"]:
            if u["hours"] > st.offline_cap_hours and self.credited_frac(u["hours"]) > self.credited_frac(st.offline_cap_hours) + 1e-12:
                return False
        return True

