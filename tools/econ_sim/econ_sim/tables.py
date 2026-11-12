"""曲線設定（curves.json）から決定的な整数強化表を生成する.

生成表が実行時の権威（静的分析・シミュ・ゲームが同じ表を使う）で、曲線設定は生成根拠として残す。
curves_sha256 は曲線設定の正準ハッシュ、tables_sha256 は表本体の正準ハッシュ。
"""
from __future__ import annotations

from typing import Any

from . import formulas, jsonio

GENERATOR = "econ_sim.tables/1"
SINK_GENERATOR = "econ_sim.sink_tables/1"
SINK_FORMULAS = ("exp_ceil_capped", "linear_ceil_capped")  # 消費先の反復コストは上限付き公式だけ（RULE_SINK_REPEAT）


def per_level_to_bps(per_level: Any) -> int:
    v = formulas.to_fraction(per_level) * formulas.BPS
    if v.denominator != 1:
        raise formulas.FormulaError(f"per_level×10000이 정수가 아님: {per_level}")
    return int(v)


def build_cost_table(curve: dict[str, Any]) -> dict[str, Any]:
    levels = []
    for lv in range(1, curve["max_level"]):
        exponent = lv + curve["exponent_offset"]
        costs = [
            {"resource": b["resource"], "amount": formulas.exp_ceil_cost(b["amount"], curve["growth"], exponent)}
            for b in curve["base"]
        ]
        levels.append({"from_level": lv, "to_level": lv + 1, "costs": costs})
    return {"id": curve["id"], "max_level": curve["max_level"], "levels": levels}


def build_bonus_table(curve: dict[str, Any]) -> dict[str, Any]:
    per_bps = per_level_to_bps(curve["per_level"])
    milestones = [(m["level"], m["mult"]) for m in curve["milestones"]]
    levels = [
        {"level": lv, "mult_bps": formulas.linear_milestone_bps(per_bps, lv, milestones)}
        for lv in range(1, curve["max_level"] + 1)
    ]
    return {"id": curve["id"], "max_level": curve["max_level"], "levels": levels}


def generate(curves_doc: dict[str, Any]) -> dict[str, Any]:
    body = {
        "cost_tables": [build_cost_table(c) for c in curves_doc["cost_curves"]],
        "bonus_tables": [build_bonus_table(c) for c in curves_doc["bonus_curves"]],
    }
    return {
        "schema_version": 1,
        "generator": GENERATOR,
        "notes": "자동 생성 파일. 직접 수정하지 말고 curves.json을 고친 뒤 gen-tables를 실행한다.",
        "curves_sha256": jsonio.canonical_sha256(curves_doc),
        "tables_sha256": jsonio.canonical_sha256(body),
        **body,
    }


def table_body(tables_doc: dict[str, Any]) -> dict[str, Any]:
    return {"cost_tables": tables_doc.get("cost_tables"), "bonus_tables": tables_doc.get("bonus_tables")}


def staleness(curves_doc: dict[str, Any], tables_doc: dict[str, Any]) -> list[str]:
    """生成表が現在の曲線設定・自身のハッシュと一致しない理由の一覧（空なら最新）."""
    reasons = []
    if tables_doc.get("curves_sha256") != jsonio.canonical_sha256(curves_doc):
        reasons.append("curves.json이 표 생성 이후 변경됨")
    if tables_doc.get("tables_sha256") != jsonio.canonical_sha256(table_body(tables_doc)):
        reasons.append("표 본문이 tables_sha256과 불일치(직접 수정됨)")
    if not reasons:
        regenerated = generate(curves_doc)
        if table_body(regenerated) != table_body(tables_doc):
            reasons.append("재생성 결과와 표 본문이 불일치(생성기 버전 차이 가능)")
    return reasons


# ---- 消費先の反復コスト表（curves.json sink_curves → generated/sink_tables.json） ----


def sink_rows(curve: dict[str, Any]) -> int:
    """表の行数（それ以降は最終行と同じコスト）。exp_ceil_capped は cap_level 行、linear_ceil_capped は cap_steps+1 行."""
    return curve["cap_level"] if curve["formula"] == "exp_ceil_capped" else curve["cap_steps"] + 1


def build_sink_table(curve: dict[str, Any]) -> dict[str, Any]:
    rows = []
    for n in range(1, sink_rows(curve) + 1):
        if curve["formula"] == "exp_ceil_capped":
            costs = [{"resource": b["resource"], "amount": formulas.exp_ceil_capped_cost(b["amount"], b["growth"], n, curve["cap_level"])}
                     for b in curve["base"]]
        else:
            costs = [{"resource": b["resource"], "amount": formulas.linear_ceil_capped_cost(b["amount"], curve["step"], n, curve["cap_steps"])}
                     for b in curve["base"]]
        rows.append({"n": n, "costs": costs})
    return {"id": curve["id"], "formula": curve["formula"], "rows": rows}


def generate_sinks(curves_doc: dict[str, Any]) -> dict[str, Any]:
    body = {"sink_tables": [build_sink_table(c) for c in curves_doc.get("sink_curves", [])]}
    return {
        "schema_version": 1,
        "generator": SINK_GENERATOR,
        "notes": "자동 생성 파일. 직접 수정하지 말고 curves.json sink_curves를 고친 뒤 gen-tables를 실행한다. "
                 "n번째 구매(레벨 n) 비용이며 마지막 행 이후는 마지막 행과 같다(비용 상한).",
        "curves_sha256": jsonio.canonical_sha256(curves_doc),
        "tables_sha256": jsonio.canonical_sha256(body),
        **body,
    }


def sink_body(doc: dict[str, Any]) -> dict[str, Any]:
    return {"sink_tables": doc.get("sink_tables")}


def sink_staleness(curves_doc: dict[str, Any], doc: dict[str, Any]) -> list[str]:
    """消費先表が現在の曲線設定・自身のハッシュと一致しない理由の一覧（空なら最新）."""
    reasons = []
    if doc.get("curves_sha256") != jsonio.canonical_sha256(curves_doc):
        reasons.append("curves.json이 소비처 표 생성 이후 변경됨")
    if doc.get("tables_sha256") != jsonio.canonical_sha256(sink_body(doc)):
        reasons.append("소비처 표 본문이 tables_sha256과 불일치(직접 수정됨)")
    if not reasons and sink_body(generate_sinks(curves_doc)) != sink_body(doc):
        reasons.append("재생성 결과와 소비처 표 본문이 불일치(생성기 버전 차이 가능)")
    return reasons


def sink_cost(doc: dict[str, Any], curve_id: str, n: int) -> list[dict[str, Any]]:
    """n 回目（レベル n、≥1）の購入コスト。表の最終行を超えたら最終行（上限）."""
    table = next(t for t in doc["sink_tables"] if t["id"] == curve_id)
    rows = table["rows"]
    return rows[min(max(n, 1), len(rows)) - 1]["costs"]


class Tables:
    """生成表の参照用インデックス."""

    def __init__(self, tables_doc: dict[str, Any]):
        self.cost: dict[str, dict[int, list[dict[str, Any]]]] = {}
        self.cost_max: dict[str, int] = {}
        for t in tables_doc["cost_tables"]:
            self.cost[t["id"]] = {row["from_level"]: row["costs"] for row in t["levels"]}
            self.cost_max[t["id"]] = t["max_level"]
        self.bonus: dict[str, dict[int, int]] = {}
        for t in tables_doc["bonus_tables"]:
            self.bonus[t["id"]] = {row["level"]: row["mult_bps"] for row in t["levels"]}
