"""精霊の Pareto 支配表.

比較次元（全て整数、同じ Lv1 前提）:
- fac_<資源>: 拠点配置時の寄与 = 採集力×適性×(1+facility_output 特性)
- comp_<資源>: 同行時の直接採集寄与 = 採集力×適性（facility_output 特性は掛からない）
- combat: 戦闘力
A が全次元で B 以上かつ 1 次元以上で上回れば数値上の支配（raw）。
ただし B が A にない正の固有特性（special_node・同行狩りボーナスなど）を持てば「特性で保護」とする。
値 0 の特性（例: 初期データの夜ボーナス）は保護に数えない。
"""
from __future__ import annotations

from typing import Any

from .formulas import BPS
from .model import Model

# 正の効果として保護に数える特性（facility_output の負値は保護にならない）
_PROTECTIVE = {
    "special_node",
    "companion_hunt_drop_bps",
    "companion_gather_bps",
    "mixed_placement_bps",
    "night_output_bps",
    "facility_output_bps",
}


def spirit_vector(model: Model, spirit_id: str) -> dict[str, int]:
    s = model.spirits[spirit_id]
    fac_trait = model.trait_value(spirit_id, "facility_output_bps")
    vec: dict[str, int] = {}
    for rid in model.basic_ids:
        apt = model.apt_bps[s["aptitude"][rid]]
        raw = s["gather"] * apt
        vec[f"fac_{rid}"] = raw * max(0, BPS + fac_trait) // BPS
        vec[f"comp_{rid}"] = raw
    vec["combat"] = s["combat"] * BPS
    return vec


def protective_traits(model: Model, spirit_id: str) -> dict[str, int]:
    """保護に数える特性 → 強さ（special_node は 1 として扱う）."""
    out: dict[str, int] = {}
    for t in model.spirits[spirit_id]["traits"]:
        if t["type"] not in _PROTECTIVE:
            continue
        if t["type"] == "special_node":
            key = f"special_node:{t['params'].get('node_kind', '')}"
            out[key] = 1
        elif t["value_bps"] > 0:
            out[t["type"]] = out.get(t["type"], 0) + t["value_bps"]
    return out


def relation(model: Model, a: str, b: str) -> dict[str, Any]:
    va, vb = spirit_vector(model, a), spirit_vector(model, b)
    dims = list(va)
    ge = sum(1 for k in dims if va[k] >= vb[k])
    gt = sum(1 for k in dims if va[k] > vb[k])
    raw = ge == len(dims) and gt > 0
    ta, tb = protective_traits(model, a), protective_traits(model, b)
    unmatched = sorted(k for k, v in tb.items() if ta.get(k, 0) < v)
    if raw and unmatched:
        rel = "trait_protected"
    elif raw:
        rel = "dominates"
    else:
        rel = "none"
    return {
        "dims_total": len(dims),
        "dims_ge": ge,
        "dims_gt": gt,
        "raw_dominates": raw,
        "protecting_traits": unmatched,
        "relation": rel,
    }


def dominance_rows(model: Model) -> list[dict[str, Any]]:
    rows = []
    for a in model.spirit_order:
        for b in model.spirit_order:
            if a == b:
                continue
            r = relation(model, a, b)
            ga, gb = model.spirits[a]["grade"], model.spirits[b]["grade"]
            rows.append(
                {
                    "spirit_a": a,
                    "grade_a": ga,
                    "spirit_b": b,
                    "grade_b": gb,
                    **r,
                    "higher_grade_dominates": r["relation"] == "dominates" and ga > gb,
                }
            )
    return rows
