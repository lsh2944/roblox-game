"""シミュ設定（config/personas.json）の読み込みと検証."""
from __future__ import annotations

from pathlib import Path
from typing import Any

from . import jsonio
from .model import Model, sim_unsupported
from .schema import ID, Arr, Int, Issue, Obj, Str

ACTIVITIES = ("gather", "hunt", "capture", "decor", "manage")
# 研究モード: off=研究なし / natural=自然研究（方策がコスト・時間を払う） / cap=上限試験（条件を満たした瞬間にコスト・待ちなしで完了）
RESEARCH_MODES = ("off", "natural", "cap")
# 条件付き購入: 生産研究（speedup_allowed）の進行中に管理時点ごとに買う（商品の日次上限まで）
PURCHASE_TRIGGERS = ("production_research_active",)
# 芯モード（段階 2・3 の最小設定、既定 required）: required=試行ごとに芯を消費・不足なら遭遇を始めない / unlimited=芯を消費しない（比較用）
WICK_MODES = ("required", "unlimited")
# 消費先の購入方針（段階 4、既定 normal）: none=買わない / normal=有限品目をカタログ順→全部買ったら反復の最安 / high=有限・反復を合わせて最安
SINK_PREFERENCES = ("none", "normal", "high")
# 比較用の機能停止（12 節 ablation）: weaken_level_off=弱体化のレベル効果なし（Lv1 扱い） / vigor_off=活力の消費・効率・給餌なし
ABLATIONS = ("weaken_level_off", "vigor_off")
# 捕獲補助道具の自動使用（2026-11-11 ユーザー決定、既定 off）: off=使わない・作らない / star4=★4 の遭遇だけで使う
CAPTURE_TOOL_MODES = ("off", "star4")

PERSONAS_SCHEMA = Obj(req={
    "schema_version": Int(min=1),
    "master_seed": Int(min=0),
    "horizon_days": Int(min=1, max=365),
    "extract_days": Arr(Int(min=1), min_items=1),
    "replicates_quick": Int(min=1),
    "replicates_default": Int(min=1),
    "start": Obj(req={"spirits": Arr(Obj(req={"species": ID, "level": Int(min=1)}), min_items=1)}),
    "policy": Obj(req={
        "step_minutes": Int(min=1), "manage_every_steps": Int(min=1), "flex_pool": Arr(Str(enum=list(ACTIVITIES))),
        "post_goal_payback_max_minutes": Int(min=1), "max_purchases_per_manage": Int(min=1),
        "hub_rank_when_free_slots_at_most": Int(min=0),
    }, opt={"max_sinks_per_manage": Int(min=1),
           # 捕獲補助道具の在庫目安（1 日の見込み使用量の日数、既定 2 = 2 日分を超えて作らない、placeholder）
           "capture_tool_stock_days": Int(min=1),
           # 捕獲補助道具の使用側の在庫下限（個、既定 0 = 在庫を使い切る。2026-11-11 決定 M1）
           "capture_tool_min_stock": Int(min=0)}),
    "personas": Arr(Obj(req={
        "id": ID, "pairing_group": ID,
        "sessions": Arr(Obj(req={"start_minute": Int(min=0, max=1439), "minutes": Int(min=1)}), min_items=1),
        "activity_minutes": Obj(req={a: Int(min=0) for a in ACTIVITIES}),
        "purchases": Arr(Obj(req={"product_id": ID, "day": Int(min=0), "every_days": Int(min=0), "until_day": Int(min=0)},
                             opt={"when": Str(enum=list(PURCHASE_TRIGGERS))})),
    }, opt={"research": Str(enum=list(RESEARCH_MODES)), "wick_mode": Str(enum=list(WICK_MODES)),
         "sink_preference": Str(enum=list(SINK_PREFERENCES)), "ablation": Arr(Str(enum=list(ABLATIONS))),
         "capture_tool": Str(enum=list(CAPTURE_TOOL_MODES))}), min_items=1, unique_id=True),
})


class SimConfigError(ValueError):
    pass


def load_personas(path: Path, model: Model) -> tuple[dict[str, Any], str]:
    raw = Path(path).read_bytes()
    doc = jsonio.loads_strict(raw.decode("utf-8"))
    issues: list[Issue] = []
    PERSONAS_SCHEMA.check(doc, "personas.json:", issues)
    if not issues:
        step = doc["policy"]["step_minutes"]
        if step != model.constants["activity_step_minutes"]:
            issues.append(Issue("ERROR", "SIM_CONFIG", "personas.json:/policy/step_minutes",
                                f"rules.constants.activity_step_minutes({model.constants['activity_step_minutes']})와 다름"))
        for path, reason in sim_unsupported(model):
            issues.append(Issue("ERROR", "SIM_UNSUPPORTED", path, reason))
        for sp in doc["start"]["spirits"]:
            if sp["species"] not in model.spirits:
                issues.append(Issue("ERROR", "REF_UNKNOWN", "personas.json:/start", f"정령 없음: {sp['species']}"))
        for p in doc["personas"]:
            path_p = f"personas.json:/personas/{p['id']}"
            sessions = sorted(p["sessions"], key=lambda s: s["start_minute"])
            total = sum(s["minutes"] for s in sessions)
            if sum(p["activity_minutes"].values()) != total:
                issues.append(Issue("ERROR", "SIM_CONFIG", path_p, "activity_minutes 합이 세션 분 합과 다름"))
            if any(s["minutes"] % step for s in sessions) or any(v % step for v in p["activity_minutes"].values()):
                issues.append(Issue("ERROR", "SIM_CONFIG", path_p, f"세션·활동 분은 {step}의 배수여야 함"))
            for a, b in zip(sessions, sessions[1:]):
                if a["start_minute"] + a["minutes"] > b["start_minute"]:
                    issues.append(Issue("ERROR", "SIM_CONFIG", path_p, "세션이 겹침"))
            if sessions[-1]["start_minute"] + sessions[-1]["minutes"] > 1440:
                issues.append(Issue("ERROR", "SIM_CONFIG", path_p, "세션이 하루를 넘김"))
            for pu in p["purchases"]:
                if pu["product_id"] not in model.products:
                    issues.append(Issue("ERROR", "REF_UNKNOWN", path_p, f"상품 없음: {pu['product_id']}"))
                elif pu.get("when") and model.products[pu["product_id"]]["kind"] != "research_time_skip":
                    issues.append(Issue("ERROR", "SIM_CONFIG", path_p, f"when 조건 구매는 research_time_skip 상품만: {pu['product_id']}"))
                elif not pu.get("when") and model.products[pu["product_id"]]["kind"] == "research_time_skip":
                    issues.append(Issue("ERROR", "SIM_CONFIG", path_p, f"연구 단축 상품은 when 조건이 필요: {pu['product_id']}"))
            if p.get("capture_tool", "off") != "off" and not (model.capture_rules or {}).get("capture_tool"):
                issues.append(Issue("ERROR", "SIM_CONFIG", path_p, "capture.json에 capture_tool이 없는데 capture_tool이 off가 아님"))
            if p.get("research", "natural") != "off" and not model.research_nodes:
                issues.append(Issue("ERROR", "SIM_CONFIG", path_p, "research.json이 없는데 연구 모드가 off가 아님"))
    if issues:
        raise SimConfigError("\n".join(i.format() for i in issues))
    return doc, jsonio.sha256_hex(raw)
