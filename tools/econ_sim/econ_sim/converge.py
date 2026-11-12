"""収束分析: 少数の代表状態で施設配置を厳密に解き、精霊 1 種を除いたときの損失を測る.

代表状態 = config/static_reference.json の g2_states（フィールド × 入口/出口）× ボトルネック重み 4 種。
在庫モード（レベルは状態の staff.spirit_level）:
- one_of_each_available: そのフィールドまでの捕獲表に出る種 + 開始精霊を各 1 体。部分集合 DP で厳密、ヒューリスティックとの差も記録。
  枠が余ると全種が自動的に使われるため、収束判定には使わない（参考）。部分集合 DP は placement.EXACT_MAX_SPIRITS 体までで、
  それを超える状態（2026-11-12 の 20 種拡張後の cave・ridge）は厳密解・除外損失を省き、ヒューリスティック行だけを
  gap 空欄・proven_optimal=false で出す（gap 集計の対象外）。
- unlimited_copies: 同じ種を何体でも使える（重複所持が進んだ状態）。施設間で在庫を共有しないので
  施設ごとの重複組合せ全列挙で厳密。収束判定（使用・除外損失）はこのモードだけで行う。
同行（パーティ）は対象外（施設配置のみ）。
"""
from __future__ import annotations

import itertools
import json
from pathlib import Path
from typing import Any

from . import placement
from .economy import Economy
from .model import Model
from .placement import Slot

COLUMNS = ["case_id", "state_id", "stage_field", "bottleneck", "inventory_mode", "method", "objective_value",
           "upper_bound", "gap", "proven_optimal", "excluded_species_id", "exclusion_loss_pct", "species_used",
           "assignment_json"]
MODES = ("balanced", "dew", "bloom", "crystal")


def representative_cases(model: Model, ref: dict[str, Any], start_species: list[str]) -> list[dict[str, Any]]:
    cases = []
    for st in ref["g2_states"]:
        fid = st["field_id"]
        rank = model.field_rank(fid)
        species = set(start_species)
        for f in model.field_order[: rank + 1]:
            species |= {e["spirit_id"] for e in model.fields[f]["capture"]["table"] if e["weight"] > 0}
        species_list = [s for s in model.spirit_order if s in species]
        facs = []
        for fac_id in model.facility_order:
            fac = model.facilities[fac_id]
            if model.field_rank(fac["unlock_field"]) <= rank:
                facs.append(Slot(fac_id, min(st["facility_level"], model.level_cap_at_field(fac, fid)),
                                 min(st["staff"]["slots"], fac["slots"]["max"])))
        for mode in MODES:
            weights = {r: (3.0 if mode == r else 1.0) for r in model.basic_ids}
            cases.append({"case_id": f"{st['id']}:{mode}", "state_id": st["id"], "field_id": fid, "mode": mode,
                          "species": species_list, "level": st["staff"]["spirit_level"], "facs": facs, "weights": weights})
    return cases


def _unlimited(econ: Economy, case: dict[str, Any], species_levels: list[tuple[str, int]]) -> list[list[str]]:
    """重複組合せの全列挙（施設ごとに独立）。除外損失は同じ列挙から除外種を含まない最大値を取る."""
    model = econ.m
    per_fac: list[list[tuple[float, tuple[str, ...]]]] = []
    for f in case["facs"]:
        w = case["weights"][model.facilities[f.fid]["produces"]]
        combos = []
        for combo in itertools.combinations_with_replacement(range(len(species_levels)), f.slots):
            members = [species_levels[i] for i in combo]
            combos.append((w * econ.facility_rate(f.fid, f.level, members), tuple(species_levels[i][0] for i in combo)))
        per_fac.append(combos)

    def best(excluded: str | None) -> tuple[float, list[tuple[str, ...]]]:
        total, picks = 0.0, []
        for combos in per_fac:
            v, sp = max(((v, sp) for v, sp in combos if excluded not in sp), key=lambda x: (x[0], x[1]))
            total += v
            picks.append(sp)
        return total, picks

    value, picks = best(None)
    used = sorted({sp for p in picks for sp in p}, key=model.spirit_order.index)
    assign = {f.fid: sorted(p) for f, p in zip(case["facs"], picks)}
    base = [case["case_id"] + ":unlimited", case["state_id"], case["field_id"], case["mode"], "unlimited_copies"]
    rows = [base + ["exact_enumeration", _fmt(value), _fmt(value), "0.0000", "true", "", "", ";".join(used),
                    json.dumps(assign, sort_keys=True, ensure_ascii=False)]]
    for sp, _ in species_levels:
        ex_value = best(sp)[0] if sp in used else value
        loss = 1 - ex_value / value if value > 0 else 0.0
        rows.append(base + ["exact_excluding", _fmt(ex_value), _fmt(value), "", "true", sp, format(loss * 100, ".2f"), "", ""])
    return rows


def _fmt(x: float) -> str:
    return format(x, ".3f")


def analyze(econ: Economy, ref: dict[str, Any], start_species: list[str]) -> list[list[str]]:
    model = econ.m
    rows: list[list[str]] = []
    for case in representative_cases(model, ref, start_species):
        spirits = [(sp, min(case["level"], econ.max_spirit_level(sp))) for sp in case["species"]]
        base = [case["case_id"], case["state_id"], case["field_id"], case["mode"], "one_of_each_available"]
        if len(spirits) > placement.EXACT_MAX_SPIRITS:
            # 部分集合 DP の対応数を超える: 厳密解なしでヒューリスティックだけ記録（gap は空欄＝集計対象外）
            heur = placement.heuristic(econ, case["facs"], spirits, case["weights"])
            h_used = sorted({spirits[i][0] for idxs in heur.assign.values() for i in idxs}, key=model.spirit_order.index)
            rows.append(base + ["heuristic_greedy_2swap", _fmt(heur.value), "", "", "false", "", "",
                                ";".join(h_used), json.dumps(placement.describe(heur.assign, spirits), sort_keys=True, ensure_ascii=False)])
            rows.extend(_unlimited(econ, case, spirits))
            continue
        best = placement.exact(econ, case["facs"], spirits, case["weights"])
        heur = placement.heuristic(econ, case["facs"], spirits, case["weights"])
        used = sorted({spirits[i][0] for idxs in best.assign.values() for i in idxs}, key=model.spirit_order.index)
        rows.append(base + ["exact_subset_dp", _fmt(best.value), _fmt(best.value), "0.0000", "true", "", "",
                            ";".join(used), json.dumps(placement.describe(best.assign, spirits), sort_keys=True, ensure_ascii=False)])
        gap = 1 - heur.value / best.value if best.value > 0 else 0.0
        h_used = sorted({spirits[i][0] for idxs in heur.assign.values() for i in idxs}, key=model.spirit_order.index)
        rows.append(base + ["heuristic_greedy_2swap", _fmt(heur.value), _fmt(best.value), format(gap, ".4f"), "false", "", "",
                            ";".join(h_used), json.dumps(placement.describe(heur.assign, spirits), sort_keys=True, ensure_ascii=False)])
        for k, (sp, _) in enumerate(spirits):
            if sp in used:
                ex_value = placement.exact(econ, case["facs"], spirits[:k] + spirits[k + 1:], case["weights"]).value
            else:
                ex_value = best.value  # 最適解に使われない種を除いても最適値は変わらない
            loss = 1 - ex_value / best.value if best.value > 0 else 0.0
            rows.append(base + ["exact_excluding", _fmt(ex_value), _fmt(best.value), "", "true", sp, format(loss * 100, ".2f"),
                                "", ""])
        rows.extend(_unlimited(econ, case, spirits))
    return rows
