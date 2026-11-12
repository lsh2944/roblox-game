"""static 段階: シミュレーション前の解析表（施設回収期間・精霊支配・捕獲分位数・G3 狩り分・G2 比率）.

全ての値は生成済み整数表（upgrade_tables）と formulas の整数式から求める。
ここでの値は基準状態（config/static_reference.json）に対する正規化値であり、
実際の停滞・到達時期は 2 段階のシミュレーションで判定する（synthesis C7）。
"""
from __future__ import annotations

import csv
import io
import platform
from decimal import ROUND_HALF_EVEN, Decimal, localcontext
from fractions import Fraction
from pathlib import Path
from typing import Any

from . import formulas, jsonio, report_html, tables
from .data_load import GameData, collect_placeholders
from .dominance import dominance_rows
from .model import Model, field_encounter_expectation
from .economy import Economy
from .schema import ID, AnyValue, Arr, Bool, Int, Issue, MapOf, Num, Obj, Str

STATIC_VERSION = "econ_sim.static/1"
CSV_FILES = (
    "facility_payback.csv",
    "dominance.csv",
    "capture_quantiles.csv",
    "sink_catalog.csv",
    "g3_hunt_minutes.csv",
    "g2_ratio.csv",
)
QUANTILES = (("p50", Fraction(1, 2)), ("p90", Fraction(9, 10)), ("p99", Fraction(99, 100)))

_STAFF = Obj(req={"slots": Int(min=0), "gather": Int(min=0), "aptitude": Str(enum=["S", "A", "B", "C", "D", "X"]), "spirit_level": Int(min=1)})
_COMPANIONS = Obj(req={"count": Int(min=0), "gather": Int(min=0), "aptitude": Str(enum=["S", "A", "B", "C", "D", "X"]), "spirit_level": Int(min=1)})
_MEMBERS = Arr(Obj(req={"species": ID, "level": Int(min=1)}))
REFERENCE_SCHEMA = Obj(req={
    "schema_version": Int(min=1), "ability_curve": ID, "gather_tool": ID, "payback_staff": _STAFF,
    "hunt": Obj(req={"power_ratio_bps": Int(min=0), "bonus_spirit_id": ID}),
    "capture_minutes_per_day": Int(min=1),
    "g2_daily_reference": Obj(req={"direct_gather_minutes_per_day": Int(min=0), "idle_minutes_per_day": Int(min=0)}),
    "g2_states": Arr(Obj(req={"id": ID, "field_id": ID, "facility_level": Int(min=1), "tool_level": Int(min=1),
                              "staff": _STAFF, "companions": _COMPANIONS},
                         opt={"facility_levels_by_resource": MapOf(ID, Int(min=1)),
                              "staff_members_by_resource": MapOf(ID, _MEMBERS),
                              "companion_members_by_resource": MapOf(ID, _MEMBERS),
                              "transition_exempt": Bool()}), min_items=1, unique_id=True),
})
_APPROVAL = Str(enum=["approved", "draft"])
CRITERIA_SCHEMA = Obj(req={
    "schema_version": Int(min=1),
    "g2": Obj(req={"max_ratio": Num(min=0), "max_ratio_approval": _APPROVAL, "target_ratio": Num(min=0), "target_approval": _APPROVAL,
                   "warn_below_ratio": Num(min=0), "warn_below_approval": _APPROVAL},
              opt={"transition_minutes": Int(min=0), "transition_approval": _APPROVAL, "field_band_min": Num(min=0),
                   "field_band_max": Num(min=0), "field_band_approval": _APPROVAL}),
    "g3": Obj(req={"pass_min_minutes": Num(min=0), "pass_max_minutes": Num(min=0), "pass_approval": _APPROVAL,
                   "warn_min_minutes": Num(min=0), "warn_max_minutes": Num(min=0), "warn_approval": _APPROVAL,
                   "idle_wait_days_max": Num(min=0), "idle_wait_approval": _APPROVAL}, opt={"notes": Str()}),
}, opt={"sim": AnyValue()})


class StaticConfigError(ValueError):
    pass


# ---- 書式（バイト単位で再現できるよう固定桁の 10 進文字列にする） ------------------------------


def dec(value: Fraction | int | None, places: int = 2) -> str:
    if value is None:
        return ""
    fr = Fraction(value)
    with localcontext() as ctx:
        ctx.prec = 60
        d = Decimal(fr.numerator) / Decimal(fr.denominator)
        return str(d.quantize(Decimal(1).scaleb(-places), rounding=ROUND_HALF_EVEN))


def _bool(v: bool) -> str:
    return "true" if v else "false"


# ---- 設定読み込み ------------------------------------------------------------------


def load_config(config_dir: Path, model: Model) -> tuple[dict[str, Any], dict[str, Any], dict[str, str]]:
    ref_path, crit_path = Path(config_dir) / "static_reference.json", Path(config_dir) / "criteria.json"
    issues: list[Issue] = []
    ref = jsonio.load_strict(ref_path)
    crit = jsonio.load_strict(crit_path)
    REFERENCE_SCHEMA.check(ref, "static_reference.json:", issues)
    CRITERIA_SCHEMA.check(crit, "criteria.json:", issues)
    if not issues:
        if ref["ability_curve"] not in model.tables.bonus:
            issues.append(Issue("ERROR", "REF_UNKNOWN", "static_reference.json:/ability_curve", "보너스 표 없음"))
        if ref["gather_tool"] not in model.tools:
            issues.append(Issue("ERROR", "REF_UNKNOWN", "static_reference.json:/gather_tool", "도구 없음"))
        if ref["hunt"]["bonus_spirit_id"] not in model.spirits:
            issues.append(Issue("ERROR", "REF_UNKNOWN", "static_reference.json:/hunt/bonus_spirit_id", "정령 없음"))
        for st in ref["g2_states"]:
            if st["field_id"] not in model.fields:
                issues.append(Issue("ERROR", "REF_UNKNOWN", f"static_reference.json:/g2_states/{st['id']}", "필드 없음"))
    if issues:
        raise StaticConfigError("\n".join(i.format() for i in issues))
    hashes = {
        "static_reference.json": jsonio.sha256_hex(ref_path.read_bytes()),
        "criteria.json": jsonio.sha256_hex(crit_path.read_bytes()),
    }
    return ref, crit, hashes


# ---- 共通計算 ------------------------------------------------------------------


def _ability(model: Model, ref: dict[str, Any], level: int) -> int:
    table = model.tables.bonus[ref["ability_curve"]]
    return table[min(level, max(table))]


def _virtual_powers(model: Model, ref: dict[str, Any], spec: dict[str, Any], n_key: str) -> list[int]:
    """仮想基準精霊（採集力・適性・Lv 指定）の枠寄与を n 個並べる."""
    p = formulas.slot_power_bps(spec["gather"], _ability(model, ref, spec["spirit_level"]), model.apt_bps[spec["aptitude"]], 0)
    return [p] * spec[n_key]


# ---- 施設回収期間 --------------------------------------------------------------


def facility_payback(model: Model, ref: dict[str, Any]) -> tuple[list[str], list[list[str]]]:
    basics = model.basic_ids
    headers = (["facility_id", "resource", "from_level", "to_level", "field_required"]
               + [f"cost_{r}" for r in basics]
               + ["cost_basic_total_normalized", "extra_costs", "mult_bps_from", "mult_bps_to",
                  "idle_per_hour_from", "idle_per_hour_to", "delta_per_hour", "payback_hours_normalized",
                  "payback_ratio_vs_prev", "milestone", "basis"])
    rows: list[list[str]] = []
    staff = _virtual_powers(model, ref, ref["payback_staff"], "slots")
    g_ref = model.constants["gather_ref"]
    basis = "normalized:basic_unit=1,ref_staff={slots}x(g{gather},{aptitude},lv{spirit_level})".format(**ref["payback_staff"])
    for fid in model.facility_order:
        fac = model.facilities[fid]
        cost_tbl = model.tables.cost[fac["cost_curve"]]
        out_tbl = model.tables.bonus[fac["output_curve"]]
        milestones = {m["level"] for m in model.bonus_curves[fac["output_curve"]]["milestones"]}
        gates = {g["to_level"]: g["costs"] for g in fac["hunt_gates"]}
        prev: Fraction | None = None
        for lv in range(1, fac["max_level"]):
            costs = {c["resource"]: c["amount"] for c in cost_tbl[lv]}
            basic_total = sum(costs.get(r, 0) for r in basics)
            extra = [f"{r}x{a}" for r, a in costs.items() if r not in basics]
            extra += [f"{c['resource']}x{c['amount']}" for c in gates.get(lv + 1, [])]
            idle_from = formulas.idle_rate_milli_per_hour(fac["base_per_hour"], out_tbl[lv], staff, g_ref)
            idle_to = formulas.idle_rate_milli_per_hour(fac["base_per_hour"], out_tbl[lv + 1], staff, g_ref)
            delta = idle_to - idle_from
            payback = Fraction(basic_total * formulas.MILLI, delta) if delta > 0 else None
            ratio = payback / prev if (payback is not None and prev) else None
            rows.append([
                fid, fac["produces"], str(lv), str(lv + 1), model.first_field_allowing(fac, lv + 1),
                *[str(costs.get(r, 0)) for r in basics],
                str(basic_total), ";".join(extra), str(out_tbl[lv]), str(out_tbl[lv + 1]),
                dec(Fraction(idle_from, 1000), 3), dec(Fraction(idle_to, 1000), 3), dec(Fraction(delta, 1000), 3),
                dec(payback, 2), dec(ratio, 3), _bool(lv + 1 in milestones), basis,
            ])
            prev = payback
    return headers, rows


# ---- 精霊支配表 ----------------------------------------------------------------


def dominance_table(model: Model) -> tuple[list[str], list[list[str]]]:
    headers = ["spirit_a", "grade_a", "spirit_b", "grade_b", "relation", "raw_dominates", "dims_ge", "dims_gt",
               "dims_total", "protecting_traits", "higher_grade_dominates"]
    rows = [[r["spirit_a"], str(r["grade_a"]), r["spirit_b"], str(r["grade_b"]), r["relation"], _bool(r["raw_dominates"]),
             str(r["dims_ge"]), str(r["dims_gt"]), str(r["dims_total"]), ";".join(r["protecting_traits"]),
             _bool(r["higher_grade_dominates"])] for r in dominance_rows(model)]
    return headers, rows


# ---- 捕獲分位数（遭遇あたり確率 × 期待遭遇秒） ----------------------------------------------------------


def capture_quantiles(model: Model, ref: dict[str, Any]) -> tuple[list[str], list[list[str]]]:
    """種別の初獲得に要る遭遇数の分位（幾何分布、遭遇あたり q = (w/W)·Q_等級）と分換算.

    段階 2（2026-11-10）: Q_等級 は簡易モードの遭遇あたり捕獲確率（capture.json、試行成功率 × 光区間・逃走込み）。
    success_bps 列は簡易モードの試行 1 回の成功率。分 = 遭遇数 × そのフィールドの期待遭遇秒 / 60（攻撃者 = 対象と同等級 Lv1・
    活力満タンの静的見込み、★1 は弱体化なし）。芯の不足・保留遭遇の持ち越しは含まない。
    """
    headers = ["scope", "field_id", "spirit_id", "grade", "availability", "weight", "weight_total", "success_bps",
               "q_per_encounter", "encounters_p50", "encounters_p90", "encounters_p99",
               "minutes_p50", "minutes_p90", "minutes_p99", "days_p99_at_ref_minutes", "method", "encounter_seconds_mean"]
    per_day = ref["capture_minutes_per_day"]
    rule = model.capture_rules
    rows: list[list[str]] = []
    best: dict[str, dict[str, Any]] = {}
    for fid in model.field_order:
        cap = model.fields[fid]["capture"]
        total = sum(e["weight"] for e in cap["table"])
        _, secs = field_encounter_expectation(model, fid, rule)
        sec_f = secs
        for e in cap["table"]:
            sid = e["spirit_id"]
            grade = model.spirits[sid]["grade"]
            if e["weight"] == 0:
                continue
            bps = formulas.capture_attempt_bps(grade, formulas.easy_attempt_light(grade, rule), rule)
            qg = formulas.encounter_expectation(grade, rule)[0]
            if bps == 0 or qg == 0:
                continue
            q = Fraction(e["weight"], total) * qg
            ns = [formulas.geometric_quantile(q, p) for _, p in QUANTILES]
            mins = [n * sec_f / 60 for n in ns]
            rec = {"field_id": fid, "sid": sid, "grade": grade, "avail": e["availability"], "w": e["weight"], "total": total,
                   "bps": bps, "q": q, "ns": ns, "mins": mins, "secs": sec_f}
            rows.append(_capture_row("field", rec, per_day))
            if e["availability"] == "always":
                best.setdefault(fid, {})[sid] = rec
    for rid, rel in model.releases.items():
        for sid in rel["spirit_ids"]:
            cands = [best[f][sid] for f in rel["field_ids"] if sid in best.get(f, {})]
            if not cands:
                rows.append([f"release:{rid}", "", sid, str(model.spirits[sid]["grade"]), "", "", "", "", "", "", "", "", "", "", "", "",
                             "unavailable", ""])
                continue
            pick = min(cands, key=lambda r: (r["mins"][2], model.field_rank(r["field_id"])))
            rows.append(_capture_row(f"release:{rid}", pick, per_day, method="best_single_field"))
    return headers, rows


def _capture_row(scope: str, r: dict[str, Any], per_day: int, method: str = "geometric_encounter_mean_seconds") -> list[str]:
    return [scope, r["field_id"], r["sid"], str(r["grade"]), r["avail"], str(r["w"]), str(r["total"]), str(r["bps"]),
            dec(r["q"], 6), *[str(n) for n in r["ns"]], *[dec(m, 1) for m in r["mins"]],
            dec(r["mins"][2] / per_day, 2), method, dec(r["secs"], 1)]


# ---- 消費先カタログ（段階 5） ----------------------------------------------------------


def sink_catalog(model: Model) -> tuple[list[str], list[list[str]]]:
    """消費先の一覧（素材展開後のコスト）。有限品目（家 1〜3 = 拠点等級を含む）と反復消費先の 1 レベル目・上限レベル."""
    res = list(model.basic_ids) + model.hunt_resource_ids() + ([model.research_resource] if model.research_resource else [])
    headers = ["kind", "id", "category", "field_id", "requires_fields", "requires_items", "level"] + [f"cost_{r}" for r in res]
    rows: list[list[str]] = []

    def row(kind: str, sid: str, cat: str, field: str, rf: list[str], ri: list[str], level: str, costs: list[dict[str, Any]]) -> None:
        amt: dict[str, int] = {}
        for c in model.expand_costs(costs):
            amt[c["resource"]] = amt.get(c["resource"], 0) + c["amount"]
        rows.append([kind, sid, cat, field, ";".join(rf), ";".join(ri), level, *[str(amt.get(r, 0)) for r in res]])

    for rk in model.hub["ranks"]:
        if rk["rank"] > 1:
            row("finite", f"house_rank:{rk['rank']}", "house", "", [], [], "", rk["costs"])
    doc = model.sinks or {}
    for it in doc.get("items", []):
        row("finite", it["id"], it["category"], it["field_id"], it["requires_fields"], it["requires_items"], "", it["costs"])
    tdoc = model.sink_tables_doc
    for rs in doc.get("repeat_sinks", []):
        if tdoc is None:
            continue
        n_rows = len(next(t for t in tdoc["sink_tables"] if t["id"] == rs["cost_curve"])["rows"])
        for lv in (1, n_rows):
            row("repeat", rs["id"], rs["category"], rs.get("field_id", ""), rs["requires_fields"], [], f"{lv}{'+' if lv == n_rows else ''}",
                tables.sink_cost(tdoc, rs["cost_curve"], lv))
    if doc.get("dex_records"):
        dx = doc["dex_records"]
        for i, c in enumerate(dx["pages_cost"], 1):
            row("dex_record", "dex:<species>", "dex_record", "", [], [], str(i), [{"resource": dx["resource"], "amount": c}])
    total = {r: sum(int(x[7 + i]) for x in rows if x[0] == "finite") for i, r in enumerate(res)}
    rows.append(["finite_total", "", "", "", "", "", "", *[str(total[r]) for r in res]])
    return headers, rows


# ---- G3 狩り分換算 ---------------------------------------------------------------


def _evaluate_g3(minutes: Fraction | None, crit: dict[str, Any]) -> tuple[str, str]:
    """承認範囲（pass_min〜pass_max 分）だけで判定する。approval_state は結果に依らず範囲の承認状態."""
    g = crit["g3"]
    lo, hi = formulas.to_fraction(g["pass_min_minutes"]), formulas.to_fraction(g["pass_max_minutes"])
    ok = minutes is not None and lo <= minutes <= hi
    return ("PASS" if ok else "FAIL"), g["pass_approval"]


def requirement_stage(model: Model, req: Any) -> str:
    """その要求が最初に購入可能になるフィールド（日次依頼が「解禁済み最高フィールド」の素材だけを出す規則との照合用）."""
    start = model.field_order[0]
    if req.source_kind == "field_unlock":
        reqs = model.fields[req.source_id]["unlock"]["requires_fields"]
        return max(reqs, key=model.field_rank) if reqs else start
    if req.source_kind in ("facility_level", "facility_slot"):
        fac = model.facilities[req.source_id]
        stage = fac["unlock_field"]
        if req.source_kind == "facility_level":
            lv_field = model.first_field_allowing(fac, int(req.detail.removeprefix("to_lv")))
            if lv_field and model.field_rank(lv_field) > model.field_rank(stage):
                stage = lv_field
        return stage
    return start


def g3_hunt_minutes(model: Model, ref: dict[str, Any], crit: dict[str, Any]) -> tuple[list[str], list[list[str]]]:
    headers = ["requirement_id", "source_kind", "source_id", "detail", "resource", "required", "drop_field",
               "recommended_power", "drop_per_hour_ref", "minutes_ref", "minutes_with_bonus_spirit", "bonus_spirit",
               "daily_quest_per_day", "idle_wait_days", "draft_evaluation", "approval_state", "idle_wait_evaluation",
               "evidence_status"]
    c = model.constants
    bonus_sid = ref["hunt"]["bonus_spirit_id"]
    bonus_bps = model.trait_value(bonus_sid, "companion_hunt_drop_bps")
    # 日次依頼: 解禁済み最高フィールドの報酬だけが出る → (フィールド, 資源) ごとの 1 日量
    quest_amount: dict[tuple[str, str], int] = {}
    for q in model.quests.values():
        for rbf in q["rewards_by_field"]:
            for r in rbf["rewards"]:
                key = (rbf["field_id"], r["resource"])
                quest_amount[key] = quest_amount.get(key, 0) + r["amount"]
    rows: list[list[str]] = []
    for req in model.iter_requirements():
        if model.resources[req.resource]["kind"] != "hunt":
            continue
        drop_field, drop = "", None
        for fid in model.field_order:
            for d in model.fields[fid]["hunt"]["drops"]:
                if d["resource"] == req.resource and drop is None:
                    drop_field, drop = fid, d
        if drop is None:
            rows.append([req.requirement_id, req.source_kind, req.source_id, req.detail, req.resource, str(req.amount),
                         "", "", "", "", "", bonus_sid, "", "", "FAIL", "approved", "", "no_drop_source"])
            continue
        rec = model.fields[drop_field]["hunt"]["recommended_power"]
        power = rec * ref["hunt"]["power_ratio_bps"]  # 推奨戦闘力 × 比率（bps 単位の戦闘力）
        args = (drop["base_per_hour"], power, rec)
        rate = formulas.hunt_rate_milli_per_hour(*args, 0, c["hunt_min_ratio_bps"], c["hunt_max_ratio_bps"])
        rate_b = formulas.hunt_rate_milli_per_hour(*args, bonus_bps, c["hunt_min_ratio_bps"], c["hunt_max_ratio_bps"])
        minutes = Fraction(req.amount * formulas.MILLI * 60, rate) if rate else None
        minutes_b = Fraction(req.amount * formulas.MILLI * 60, rate_b) if rate_b else None
        # 素材のフィールドが要求の段階より前なら、その時点の最高フィールドの依頼では出ない（直接狩りのみ）
        stage = requirement_stage(model, req)
        daily = quest_amount.get((drop_field, req.resource), 0) if model.field_rank(drop_field) >= model.field_rank(stage) else 0
        wait = -(-req.amount // daily) if daily else None
        ev, appr = _evaluate_g3(minutes, crit)
        if wait is None:
            wait_ev = "NO_QUEST_PATH"
        else:
            wait_ev = "PASS" if wait <= formulas.to_fraction(crit["g3"]["idle_wait_days_max"]) else "WARN"
        rows.append([req.requirement_id, req.source_kind, req.source_id, req.detail, req.resource, str(req.amount),
                     drop_field, str(rec), dec(Fraction(rate, 1000), 3), dec(minutes, 1), dec(minutes_b, 1), bonus_sid,
                     str(daily) if daily else "", str(wait) if wait is not None else "", ev, appr, wait_ev,
                     "static_reference"])
    return headers, rows


# ---- G2 比率 -----------------------------------------------------------------


def g2_ratio_table(model: Model, ref: dict[str, Any], crit: dict[str, Any]) -> tuple[list[str], list[list[str]]]:
    headers = ["state_id", "field_id", "node_id", "resource", "facility_id", "facility_level", "tool_level",
               "staff_slots", "companion_count", "direct_per_hour", "idle_per_hour", "r_ratio", "s_daily_ref",
               "target_r", "max_r", "draft_evaluation", "approval_state", "band_evaluation", "band_approval_state",
               "evidence_status", "note"]
    g = crit["g2"]
    max_r, target, warn_below = (formulas.to_fraction(g[k]) for k in ("max_ratio", "target_ratio", "warn_below_ratio"))
    daily = ref["g2_daily_reference"]
    h = Fraction(daily["direct_gather_minutes_per_day"], 60)
    big_h = Fraction(daily["idle_minutes_per_day"], 60)
    c = model.constants
    tool = model.tools[ref["gather_tool"]]
    tool_tbl = model.tables.bonus[tool["bonus_curve"]]
    econ = Economy(model)
    rows: list[list[str]] = []
    for st in ref["g2_states"]:
        # 実在の種で指定された状態（*_by_resource）があればそれを使い、なければ仮想基準精霊
        lv_by_res = st.get("facility_levels_by_resource", {})
        staff_m = st.get("staff_members_by_resource", {})
        comp_m = st.get("companion_members_by_resource", {})
        field = model.fields[st["field_id"]]
        tool_lv = min(st["tool_level"], model.level_cap_at_field(tool, st["field_id"]))
        staff = _virtual_powers(model, ref, st["staff"], "slots")
        for node in field["gather_nodes"]:
            r = node["resource"]
            comp_spec = st["companions"]
            if r in comp_m:
                comp = [econ.companion_power(x["species"], x["level"], r) for x in comp_m[r]]
            else:
                comp = _virtual_powers(model, ref, comp_spec, "count")
            bonus = formulas.companion_bonus_bps(comp, c["companion_gather_k_bps"], c["gather_ref"])
            direct = formulas.direct_rate_milli_per_hour(node["base_per_hour"], tool_tbl[tool_lv], bonus)
            fac = model.facility_for_resource(r)
            note = []
            if node.get("requires_node_trait"):
                note.append(f"needs_node_kind:{node.get('node_kind', '')}")
            fac_lv, idle = 0, 0
            if fac is not None and model.field_rank(fac["unlock_field"]) <= model.field_rank(st["field_id"]):
                fac_lv = min(lv_by_res.get(r, st["facility_level"]), model.level_cap_at_field(fac, st["field_id"]))
                if r in staff_m:
                    idle = econ.facility_rate(fac["id"], fac_lv, [(x["species"], x["level"]) for x in staff_m[r]])
                else:
                    idle = formulas.idle_rate_milli_per_hour(fac["base_per_hour"], model.tables.bonus[fac["output_curve"]][fac_lv],
                                                             staff, c["gather_ref"])
            else:
                note.append("no_facility_for_resource")
            ratio = formulas.g2_ratio(direct, idle)
            share = formulas.direct_share(h, ratio, big_h) if ratio is not None else None
            # 最大倍率（承認規則）: 方置 0 は R=∞ と見なして FAIL（厳格解釈）。目標帯（草案）は別列
            ev = "FAIL" if (ratio is None or ratio > max_r) else "PASS"
            # 解禁直後の入口状態はシミュと同じく移行区間として免除し、参考値(INFO)にする（ユーザー決定 2026-11-09）
            if ev == "FAIL" and st.get("transition_exempt"):
                ev = "INFO"
                note.append("transition_exempt:해금 직후 전환 구간(시뮬과 같은 면제)")
            band = "N/A" if ratio is None else ("WARN" if ratio < warn_below else "PASS")
            rows.append([st["id"], st["field_id"], node["id"], r, fac["id"] if fac else "", str(fac_lv), str(tool_lv),
                         str(len(staff_m[r]) if r in staff_m else st["staff"]["slots"]),
                         str(len(comp_m[r]) if r in comp_m else comp_spec["count"]), dec(Fraction(direct, 1000), 3),
                         dec(Fraction(idle, 1000), 3), dec(ratio, 3), dec(share, 4), dec(target, 2), dec(max_r, 2),
                         ev, g["max_ratio_approval"], band, g["warn_below_approval"], "static_reference", ";".join(note)])
    return headers, rows


# ---- 出力 -------------------------------------------------------------------


def to_csv(headers: list[str], rows: list[list[str]]) -> str:
    buf = io.StringIO()
    w = csv.writer(buf, lineterminator="\n")
    w.writerow(headers)
    w.writerows(rows)
    return buf.getvalue()


def run_static(gd: GameData, config_dir: Path, out_dir: Path, warnings: list[Issue]) -> dict[str, Path]:
    model = Model(gd)
    ref, crit, cfg_hashes = load_config(config_dir, model)
    out_dir = Path(out_dir)
    if out_dir.is_symlink():
        raise OSError(f"출력 디렉터리가 심볼릭 링크임: {out_dir}")
    out_dir.mkdir(parents=True, exist_ok=True)
    tables_out = {
        "facility_payback.csv": facility_payback(model, ref),
        "dominance.csv": dominance_table(model),
        "capture_quantiles.csv": capture_quantiles(model, ref),
        "g3_hunt_minutes.csv": g3_hunt_minutes(model, ref, crit),
        "g2_ratio.csv": g2_ratio_table(model, ref, crit),
        "sink_catalog.csv": sink_catalog(model),
    }
    written: dict[str, Path] = {}
    for name in CSV_FILES:
        path = out_dir / name
        jsonio.write_text_atomic(path, to_csv(*tables_out[name]))
        written[name] = path
    placeholders = collect_placeholders(gd)
    meta = {
        "generator": STATIC_VERSION,
        "python": platform.python_version(),
        "data_patched": gd.patched,
        "data_file_sha256": {gd.label(k): v for k, v in sorted(gd.file_sha256.items())},
        "curves_sha256": gd.docs["upgrade_tables"]["curves_sha256"],
        "tables_sha256": gd.docs["upgrade_tables"]["tables_sha256"],
        "config_sha256": cfg_hashes,
        "validation_warnings": [i.format() for i in warnings],
        "placeholders": placeholders,
        "notes": [
            "모든 값은 기준 상태(config/static_reference.json)에 대한 정규화 추정이다(evidence_status=static_reference).",
            "approval_state=draft인 판정은 초안 기준이며 공식 합격이 아니다.",
            "포획 분위수는 고정 확률(천장 없음) 기하분포 해석식이다.",
        ],
    }
    jsonio.write_text_atomic(out_dir / "static_meta.json", jsonio.dump_pretty(meta))
    written["static_meta.json"] = out_dir / "static_meta.json"
    html = report_html.static_page(model, tables_out, meta)
    jsonio.write_text_atomic(out_dir / "static.html", html)
    written["static.html"] = out_dir / "static.html"
    return written
