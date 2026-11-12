"""状態に依存しない経済計算（生成表 + formulas の組み合わせ）.

シミュ・配置ヒューリスティック・収束分析が同じ関数を使う。精霊は (種 ID, レベル) の組で表す。
2 段階の仮定:
- 混合配置ボーナスはその施設の生産全体に掛かる（複数あっても最大値 1 つだけ、重複しない）。
- 夜ボーナスは夜区間の配置枠の特性に加算する（初期データでは 0）。
"""
from __future__ import annotations

from typing import Iterable

from . import formulas
from .formulas import BPS
from .model import Model

Member = tuple  # (species, level) または (species, level, gather_bps, combat_bps)


def norm_member(m: Member) -> tuple[str, int, int, int]:
    """(種, Lv) を個体値 1.00 の 4 要素に揃える（収束分析・テストは個体値なしで呼ぶ）."""
    return (m[0], m[1], BPS, BPS) if len(m) == 2 else (m[0], m[1], m[2], m[3])


class Economy:
    def __init__(self, model: Model):
        self.m = model
        self.tables = model.tables
        c = model.constants
        self.g_ref = c["gather_ref"]
        self.k_comp = c["companion_gather_k_bps"]
        self.hunt_min = c["hunt_min_ratio_bps"]
        self.hunt_max = c["hunt_max_ratio_bps"]
        self.companion_slots = c["companion_slots"]
        self._trait: dict[tuple[str, str], int] = {}
        for sid in model.spirits:
            for t in model.spirits[sid]["traits"]:
                key = (sid, t["type"])
                self._trait[key] = self._trait.get(key, 0) + t["value_bps"]
        self._mixed: dict[str, tuple[int, int]] = {}
        for sid, s in model.spirits.items():
            for t in s["traits"]:
                if t["type"] == "mixed_placement_bps":
                    self._mixed[sid] = (t["value_bps"], t["params"].get("min_distinct_species", 2))
        # 純粋関数の結果キャッシュ（(種, レベル, 資源, 夜) → 値）。シミュの方針評価で大量に呼ばれるため
        self._slot_cache: dict[tuple[str, int, str, bool], int] = {}
        self._comp_cache: dict[tuple[str, int, str], int] = {}
        self._combat_cache: dict[tuple[str, int], int] = {}
        self._fac_cache: dict[tuple[str, int, tuple[Member, ...], bool], int] = {}
        # 固有フィールドの狩り素材（F1）: 種 → 資源、等級 → milli/日
        self._home_res = {sid: model.fields[s["home_field"]]["hunt"]["drops"][0]["resource"]
                          for sid, s in model.spirits.items() if model.fields[s["home_field"]]["hunt"]["drops"]}
        self._home_rate = {g["grade"]: g["milli"] for g in model.gd.docs["rules"]["home_material"]["per_day_milli_by_grade"]}
        self._node_kinds: dict[str, set[str]] = {
            sid: {t["params"].get("node_kind", "") for t in s["traits"] if t["type"] == "special_node"}
            for sid, s in model.spirits.items()
        }

    # ---- 精霊 ----
    def mixed_traits(self) -> dict[str, tuple[int, int]]:
        """混合配置ボーナスを持つ種 → (ボーナス bps, 必要な異なる種数)."""
        return self._mixed

    def trait(self, species: str, trait_type: str) -> int:
        return self._trait.get((species, trait_type), 0)

    def ability_bps(self, species: str, level: int) -> int:
        return self.tables.bonus[self.m.spirits[species]["ability_curve"]][level]

    def max_spirit_level(self, species: str) -> int:
        return self.tables.cost_max[self.m.spirits[species]["level_cost_curve"]]

    def spirit_level_cost(self, species: str, level: int) -> list[dict]:
        return self.tables.cost[self.m.spirits[species]["level_cost_curve"]][level]

    def slot_power(self, species: str, level: int, resource: str, night: bool = False, gather_bps: int = BPS) -> int:
        key = (species, level, resource, night, gather_bps)
        v = self._slot_cache.get(key)
        if v is None:
            v = self._slot_cache[key] = self._slot_power(species, level, resource, night, gather_bps)
        return v

    def _ability_ind(self, species: str, level: int, ind_bps: int) -> int:
        """能力倍率 × 個体値（F2）。個体値 10000 なら能力倍率そのまま."""
        return self.ability_bps(species, level) * ind_bps // BPS

    def _slot_power(self, species: str, level: int, resource: str, night: bool, gather_bps: int) -> int:
        s = self.m.spirits[species]
        trait = self.trait(species, "facility_output_bps") + (self.trait(species, "night_output_bps") if night else 0)
        return formulas.slot_power_bps(s["gather"], self._ability_ind(species, level, gather_bps),
                                       self.m.apt_bps[s["aptitude"][resource]], trait)

    def companion_power(self, species: str, level: int, resource: str, gather_bps: int = BPS) -> int:
        key = (species, level, resource, gather_bps)
        v = self._comp_cache.get(key)
        if v is None:
            s = self.m.spirits[species]
            v = self._comp_cache[key] = formulas.slot_power_bps(
                s["gather"], self._ability_ind(species, level, gather_bps), self.m.apt_bps[s["aptitude"][resource]],
                self.trait(species, "companion_gather_bps"))
        return v

    def combat_power(self, species: str, level: int, combat_bps: int = BPS) -> int:
        key = (species, level, combat_bps)
        v = self._combat_cache.get(key)
        if v is None:
            v = self._combat_cache[key] = self.m.spirits[species]["combat"] * self._ability_ind(species, level, combat_bps)
        return v

    # ---- 施設 ----
    def mixed_bonus(self, members: Iterable[Member]) -> int:
        species = {m[0] for m in members}
        best = 0
        for sp in species:
            if sp in self._mixed:
                value, need = self._mixed[sp]
                if len(species) >= need:
                    best = max(best, value)
        return best

    def facility_rate(self, fid: str, level: int, members: list[Member], night: bool = False, dex_bps: int = 0) -> int:
        """施設 1 つの放置生産（milli/時）。members は (種, Lv[, 採集個体値bps, 戦闘個体値bps]).

        混合配置ボーナスと図鑑ボーナス（F5, dex_bps）は施設全体の生産に掛ける（混合 → 図鑑の順に切り捨て）。
        """
        if level <= 0 or not members:
            return 0
        norm = tuple(sorted(norm_member(m) for m in members))
        key = (fid, level, norm, night, dex_bps)
        v = self._fac_cache.get(key)
        if v is None:
            if len(self._fac_cache) > 200_000:
                self._fac_cache.clear()
            v = self._fac_cache[key] = self._facility_rate(fid, level, norm, night, dex_bps)
        return v

    def _facility_rate(self, fid: str, level: int, members: tuple[Member, ...], night: bool, dex_bps: int) -> int:
        fac = self.m.facilities[fid]
        powers = [self.slot_power(sp, lv, fac["produces"], night, g) for sp, lv, g, _ in members]
        mult = self.tables.bonus[fac["output_curve"]][level]
        rate = formulas.idle_rate_milli_per_hour(fac["base_per_hour"], mult, powers, self.g_ref)
        rate = rate * max(0, BPS + self.mixed_bonus(members)) // BPS
        return rate * (BPS + dex_bps) // BPS

    def dex_bps(self, registered: int) -> int:
        """図鑑登録種数 → 生産ボーナス（F5、上限あり）."""
        d = self.m.gd.docs["rules"]["dex_bonus"]
        return min(d["max_bps"], d["per_species_bps"] * registered)

    def home_material_per_day(self, members: Iterable[Member], dex_bps: int = 0) -> dict[str, int]:
        """施設で働く精霊の固有フィールド狩り素材（milli/日、F1）.

        個体値（採集倍率）・図鑑ボーナスは rules.home_material の apply_* フラグが true のときだけ掛ける（既定 false）。
        """
        out: dict[str, int] = {}
        for (res, _), v in self.home_material_detail(members, dex_bps).items():
            out[res] = out.get(res, 0) + v
        return out

    def home_material_detail(self, members: Iterable[Member], dex_bps: int = 0) -> dict[tuple[str, int], int]:
        """(資源, 等級) 別の方置特殊財（milli/日）。等級別の比重報告用."""
        hm = self.m.gd.docs["rules"]["home_material"]
        out: dict[tuple[str, int], int] = {}
        for m in members:
            sp, _, g, _ = norm_member(m)
            res = self._home_res.get(sp)
            if res:
                grade = self.m.spirits[sp]["grade"]
                v = self._home_rate[grade]
                if hm["apply_individual_to_home_material"]:
                    v = v * g // BPS
                out[(res, grade)] = out.get((res, grade), 0) + v
        if hm["apply_dex_to_home_material"]:
            out = {k: v * (BPS + dex_bps) // BPS for k, v in out.items()}
        return out

    def facility_level_cost(self, fid: str, level: int) -> list[dict]:
        fac = self.m.facilities[fid]
        costs = list(self.tables.cost[fac["cost_curve"]][level])
        for g in fac["hunt_gates"]:
            if g["to_level"] == level + 1:
                costs = costs + g["costs"]
        return costs

    # ---- 直接採集・狩り ----
    def tool_mult(self, tool_id: str, level: int) -> int:
        return self.tables.bonus[self.m.tools[tool_id]["bonus_curve"]][level]

    def node_open(self, node: dict, party: Iterable[Member]) -> bool:
        if not node.get("requires_node_trait"):
            return True
        kind = node.get("node_kind", "")
        return any(kind in self._node_kinds[m[0]] for m in party)

    def node_holders(self, node: dict) -> set[str]:
        kind = node.get("node_kind", "")
        return {sp for sp, kinds in self._node_kinds.items() if kind in kinds}

    def direct_rate(self, node: dict, tool_id: str, tool_level: int, party: list[Member]) -> int:
        if not self.node_open(node, party):
            return 0
        party = [norm_member(m) for m in party]
        bonus = formulas.companion_bonus_bps([self.companion_power(sp, lv, node["resource"], g) for sp, lv, g, _ in party],
                                             self.k_comp, self.g_ref)
        return formulas.direct_rate_milli_per_hour(node["base_per_hour"], self.tool_mult(tool_id, tool_level), bonus)

    def hunt_rate(self, field_id: str, drop: dict, party: list[Member]) -> int:
        party = [norm_member(m) for m in party]
        power = formulas.party_power_bps([(self.m.spirits[sp]["combat"], self._ability_ind(sp, lv, c)) for sp, lv, _, c in party])
        bonus = sum(max(0, self.trait(m[0], "companion_hunt_drop_bps")) for m in party)
        rec = self.m.fields[field_id]["hunt"]["recommended_power"]
        return formulas.hunt_rate_milli_per_hour(drop["base_per_hour"], power, rec, bonus, self.hunt_min, self.hunt_max)

    # ---- 基準状態（課金パックの「標準無課金放置率」） ----
    def reference_idle_rates(self, state_ref: dict, field_id: str, ability_curve: str) -> dict[str, int]:
        """static_reference の基準状態（仮想基準精霊）での資源別放置率（milli/時）."""
        staff = state_ref["staff"]
        lv_by_res = state_ref.get("facility_levels_by_resource", {})
        staff_m = state_ref.get("staff_members_by_resource", {})
        ability_tbl = self.tables.bonus[ability_curve]
        level = min(staff["spirit_level"], max(ability_tbl))
        p = formulas.slot_power_bps(staff["gather"], ability_tbl[level], self.m.apt_bps[staff["aptitude"]], 0)
        rates: dict[str, int] = {}
        for fid in self.m.facility_order:
            fac = self.m.facilities[fid]
            if self.m.field_rank(fac["unlock_field"]) > self.m.field_rank(field_id):
                continue
            r = fac["produces"]
            lv = min(lv_by_res.get(r, state_ref["facility_level"]), self.m.level_cap_at_field(fac, field_id))
            if r in staff_m:
                rate = self.facility_rate(fid, lv, [(x["species"], x["level"]) for x in staff_m[r]])
            else:
                slots = min(staff["slots"], fac["slots"]["max"])
                rate = formulas.idle_rate_milli_per_hour(fac["base_per_hour"], self.tables.bonus[fac["output_curve"]][lv], [p] * slots, self.g_ref)
            rates[fac["produces"]] = rates.get(fac["produces"], 0) + rate
        return rates
