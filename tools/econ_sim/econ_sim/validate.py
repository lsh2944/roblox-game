"""data/ の検証器（スキーマ → 参照 → ゲーム規則 → 生成表の鮮度 → 支配警告）.

ERROR が 1 件でもあれば不合格。スキーマ・読み込みエラーがあるときは規則検査を行わない
（壊れた構造に対する誤検出・例外を避けるため）。
"""
from __future__ import annotations

import copy
import re
from typing import Any

from . import formulas, tables
from .data_load import GameData
from .dominance import dominance_rows
from .model import Model, sim_unsupported
from .schema import ID, AnyValue, Arr, Bool, Int, Issue, MapOf, Num, Obj, Str, err, info, warn

APT_LETTERS = ["S", "A", "B", "C", "D", "X"]
TRAIT_TYPES = [
    "facility_output_bps",
    "companion_hunt_drop_bps",
    "companion_gather_bps",
    "mixed_placement_bps",
    "night_output_bps",
    "special_node",
]
ALLOWED_PRODUCT_KINDS = {
    "cosmetic": set(),
    "placement_preset": set(),
    "storage_expand": {"storage_capacity"},
    # basic_material_pack・beginner_pass は 2026-11-11 ユーザー決定で削除（FORBIDDEN_PRODUCT_KINDS へ移動）
    # 研究時間短縮: 進行中の speedup_allowed ノードの残り時間だけを減らす（コスト・条件は免除しない）
    "research_time_skip": {"research_time_minutes"},
    # 月額サブスク: 外形・イベントトラックのみ（シミュ効果 0）。進行効果は RULE_SUBSCRIPTION_EFFECT
    "subscription": {"cosmetic", "event_track"},
}
# オフライン上限を伸ばす課金効果は禁止（ユーザー確定規則: オフライン上限は無料強化のみ、有料化なし）
OFFLINE_CAP_EFFECT_TYPES = {"offline_cap_hours", "offline_cap", "offline_hours", "offline_cap_bonus"}
# 研究効果は基本資源の放置・直接採集の倍率と生態情報だけ（捕獲確率・保管箱・スロット・能力値・狩り素材などは禁止）
RESEARCH_EFFECT_TYPES = {"basic_idle_bps", "basic_gather_bps", "habitat_info"}
RESEARCH_PRODUCTION_EFFECTS = {"basic_idle_bps", "basic_gather_bps"}
RESEARCH_ENUM_LIMIT = 1 << 16  # 到達可能な完了状態の全列挙上限（超えたら先行グラフ基準の保守検査）
FORBIDDEN_PRODUCT_KINDS = {
    "spirit_sale",
    "paid_random",
    "gacha",
    "loot_box",
    "luck_boost",
    "probability_boost",
    "spirit_stat_buff",
    "stat_reroll",
    "individual_reroll",
    "production_slot",
    # 2026-11-11 ユーザー決定: 基本素材箱・初心者パスを商品候補から完全削除（BM は外形・便利のみ、進行効果なし）。
    # 黙って再追加されないよう禁止 kind として残す
    "basic_material_pack",
    "beginner_pass",
}
# 禁止 kind ごとの理由（既定は総称の理由）
FORBIDDEN_PRODUCT_KIND_REASONS = {
    "basic_material_pack": "진행 재료 판매 — 2026-11-11 사용자 결정으로 제거, BM은 외형·편의만",
    "beginner_pass": "진행 보상 패스 — 2026-11-11 사용자 결정으로 제거, BM은 외형·편의만",
}
FORBIDDEN_EFFECT_TYPES = {
    "grant_spirit",
    "spirit_sale",
    "random_reward",
    "gacha_roll",
    "capture_rate_bonus",
    "capture_attempts",
    "encounter_rate_bonus",
    "luck_bonus",
    "probability_bonus",
    "drop_rate_bonus",
    "hunt_drop_bonus",
    "spirit_stat_bonus",
    "spirit_level_up",
    # 사용자 규칙 F2: 개체값 재추첨(리롤)·확률 관련 유료 상품 금지
    "individual_reroll",
    "stat_reroll",
    "individual_bonus",
    # 생산 슬롯(시설 슬롯·일하는 정령 수)은 과금으로 늘릴 수 없음
    "facility_slot",
    "production_slot",
    "working_spirits",
    # 捕獲の投入物（芯）・試行回数の課金経路は禁止（2026-11-10 捕獲規則決定、RULE_PAID_CAPTURE の拡張と対）
    "grant_wick",
    "capture_supply",
    # 活力・餌の課金経路は禁止（2026-11-10 弱体化・空腹決定。餌は狩り素材でのみ制作、商品の food・vigor・回復効果は不可）
    "food",
    "grant_food",
    "vigor",
    "vigor_restore",
    "vigor_recovery",
    "recovery",
    "stamina",
}
# 捕獲の天井・失敗補正・フィールド別成功率の上書きを示すキー（RULE_CAPTURE_NO_PITY）。スキーマの未知キーより先に規則として報告する
PITY_KEY = re.compile(r"pity|ceiling|guarantee|success_bonus|fail_bonus|bad_luck|override", re.IGNORECASE)
# フィールド別の成功率・確率の上書きを示すキー（段階 2 以降は capture.json の全体規則だけ。RULE_CAPTURE_NO_PITY で報告）
FIELD_PROB_KEY = re.compile(r"success|bps|prob|rate", re.IGNORECASE)
# fields[].capture に置いてはならない捕獲補助道具のキー（道具は capture.json capture_tool だけ。RULE_CAPTURE_TOOL）
FIELD_TOOL_KEY = re.compile(r"tool|lure", re.IGNORECASE)
# 捕獲補助道具の等級倍率の上限（2026-11-11 決定 ★4 ×1.20 が最大。超えるにはユーザー決定が要る）
CAPTURE_TOOL_MULT_MAX_BPS = 12_000
# 活力（vigor）を適用してよい活動。方置生産・保有（idle/home/production/storage 等）は不可（RULE_VIGOR_SCOPE）
VIGOR_SCOPES = {"weaken", "hunt"}
CAPTURE_K_MAX_LIMIT = 20  # 失敗後の逃走確率がこの試行数以内に 100% に達すること
STACKS = ["stock", "atomic"]
ORIGINS = ["base", "craft", "event"]

COST = Obj(req={"resource": ID, "amount": Int(min=1)})
COSTS = Arr(COST)
LEVEL_CAPS = Arr(Obj(req={"field_id": ID, "max_level": Int(min=1)}), min_items=1)
VERSION = Int(min=1)

SCHEMAS: dict[str, Obj] = {
    "resources": Obj(req={
        "schema_version": VERSION,
        "resources": Arr(Obj(req={
            "id": ID, "name": Str(min_len=1), "kind": Str(enum=["basic", "hunt", "research", "craft"]), "purchasable": Bool(),
        }, opt={
            # 2026-11-10 追加: 積み方・取引予約（MVP は取引なし。trade_class の値は RULE_TRADE_RESERVED で検査）
            "stack": Str(enum=STACKS), "trade_class": Str(min_len=1), "bind": Str(enum=["account"]), "origin": Str(enum=ORIGINS),
        }), min_items=1, unique_id=True),
    }),
    "rules": Obj(req={
        "schema_version": VERSION,
        "aptitude_bps": Arr(Obj(req={"id": Str(enum=APT_LETTERS), "bps": Int(min=0, max=100000)}), min_items=6, unique_id=True),
        "constants": Obj(req={
            "gather_ref": Int(min=1), "companion_gather_k_bps": Int(min=0), "hunt_min_ratio_bps": Int(min=0),
            "hunt_max_ratio_bps": Int(min=1), "companion_slots": Int(min=0, max=10), "activity_step_minutes": Int(min=1),
        }),
        # ゲーム内時計（2026-11-11 決定）。値の組み合わせの意味検査は RULE_NIGHT_CLOCK
        "night": Obj(req={"cycle_minutes": Int(min=1, max=1440), "night_start_offset_minutes": Int(min=0), "night_minutes": Int(min=0)}),
        "home_material": Obj(req={"per_day_milli_by_grade": Arr(Obj(req={"grade": Int(min=1, max=4), "milli": Int(min=0)}), min_items=1),
                                  "apply_individual_to_home_material": Bool(), "apply_dex_to_home_material": Bool()}),
        "individual_stats": Obj(req={"gather_bps_min": Int(min=1), "gather_bps_max": Int(min=1), "combat_bps_min": Int(min=1),
                                     "combat_bps_max": Int(min=1), "stream": Str(pattern=r"[a-z_]+"), "start_spirit_bps": Int(min=1),
                                     "roll_start_spirits": Bool()}),
        "dex_bonus": Obj(req={"per_species_bps": Int(min=0), "max_bps": Int(min=0)}),
    }),
    "spirits": Obj(req={
        "schema_version": VERSION,
        "release_research_by_grade": Arr(Obj(req={"grade": Int(min=1, max=4), "amount": Int(min=0)}), min_items=1),
        "spirits": Arr(Obj(req={
            "id": ID, "name": Str(min_len=1), "grade": Int(min=1, max=4), "home_field": ID, "event": Bool(),
            "aptitude": MapOf(ID, Str(enum=APT_LETTERS)),
            "combat": Int(min=0), "gather": Int(min=0), "max_owned": Int(min=0), "placement_cost": Int(min=1),
            "level_cost_curve": ID, "ability_curve": ID,
            "traits": Arr(Obj(req={
                "type": Str(enum=TRAIT_TYPES), "value_bps": Int(min=-10000, max=100000),
                "params": Obj(opt={"node_kind": ID, "min_distinct_species": Int(min=2)}),
            })),
            "upkeep": COSTS,
        }), min_items=1, unique_id=True),
    }),
    "curves": Obj(req={
        "schema_version": VERSION,
        "cost_curves": Arr(Obj(req={
            "id": ID, "formula": Str(enum=["exp_ceil"]), "base": Arr(COST, min_items=1), "growth": Num(min=0, exclusive_min=True),
            "exponent_offset": Int(min=-1, max=1), "max_level": Int(min=2, max=1000),
        }), unique_id=True),
        "bonus_curves": Arr(Obj(req={
            "id": ID, "formula": Str(enum=["linear_milestone"]), "per_level": Num(min=0),
            "milestones": Arr(Obj(req={"level": Int(min=2), "mult": Int(min=1)})), "max_level": Int(min=1, max=1000),
        }), unique_id=True),
    }, opt={
        # 消費先の反復コスト（上限付き公式のみ）。公式ごとの必須パラメータは RULE_SINK_REPEAT で検査する
        "sink_curves": Arr(Obj(req={
            "id": ID, "formula": Str(enum=list(tables.SINK_FORMULAS)),
            "base": Arr(Obj(req={"resource": ID, "amount": Int(min=1)}, opt={"growth": Num(min=0, exclusive_min=True)}), min_items=1),
        }, opt={"cap_level": Int(min=1, max=1000), "step": Num(min=0), "cap_steps": Int(min=0, max=1000)}), unique_id=True),
    }),
    "facilities": Obj(req={
        "schema_version": VERSION,
        "facilities": Arr(Obj(req={
            "id": ID, "name": Str(min_len=1), "produces": ID, "base_per_hour": Int(min=1), "unlock_field": ID,
            "cost_curve": ID, "output_curve": ID, "max_level": Int(min=1), "level_cap_by_field": LEVEL_CAPS,
            "slots": Obj(req={"base": Int(min=1), "max": Int(min=1), "unlock": Arr(Obj(req={"slot": Int(min=2), "costs": COSTS}))}),
            "hunt_gates": Arr(Obj(req={"to_level": Int(min=2), "costs": COSTS})),
        }), min_items=1, unique_id=True),
    }),
    "tools": Obj(req={
        "schema_version": VERSION,
        "tools": Arr(Obj(req={
            "id": ID, "name": Str(min_len=1), "kind": Str(enum=["gather"]), "cost_curve": ID, "bonus_curve": ID,
            "max_level": Int(min=1), "level_cap_by_field": LEVEL_CAPS,
        }), unique_id=True),
    }),
    "fields": Obj(req={
        "schema_version": VERSION,
        "fields": Arr(Obj(req={
            "id": ID, "name": Str(min_len=1), "order": Int(min=1),
            "unlock": Obj(req={"requires_fields": Arr(ID), "costs": COSTS}),
            "gather_nodes": Arr(Obj(req={"id": ID, "resource": ID, "base_per_hour": Int(min=1)}, opt={"requires_node_trait": Bool(), "node_kind": ID}), min_items=1, unique_id=True),
            "hunt": Obj(req={"recommended_power": Int(min=1), "drops": Arr(Obj(req={"resource": ID, "base_per_hour": Int(min=1)}))}),
            # 2026-11-10 段階 2: 成功率・試行コスト・遭遇時間は capture.json（全体共通）へ移した。フィールドは出現表だけ
            "capture": Obj(req={
                "table": Arr(Obj(req={"spirit_id": ID, "weight": Int(min=0), "availability": Str(enum=["always", "night_only", "event"])}), min_items=1),
            }),
        }), min_items=1, unique_id=True),
    }),
    "hub": Obj(req={
        "schema_version": VERSION,
        "storage": Obj(req={"base_capacity": Int(min=1), "max_capacity": Int(min=1)}),
        "ranks": Arr(Obj(req={"rank": Int(min=1), "costs": COSTS, "storage_bonus": Int(min=0)}), min_items=1),
        "offline_cap": Obj(req={"base_hours": Int(min=1), "max_hours": Int(min=1), "upgrades": Arr(Obj(req={"hours": Int(min=1), "costs": COSTS}))}),
    }),
    "daily_quests": Obj(req={
        "schema_version": VERSION,
        "quests": Arr(Obj(req={
            "id": ID, "name": Str(min_len=1), "requires": Str(enum=["login"]), "reward_mode": Str(enum=["highest_unlocked_field"]),
            "rewards_by_field": Arr(Obj(req={"field_id": ID, "rewards": COSTS}), min_items=1),
        }), unique_id=True),
    }),
    "products": Obj(req={
        "schema_version": VERSION,
        "products": Arr(Obj(req={
            "id": ID, "name": Str(min_len=1), "kind": Str(min_len=1), "price_robux": Int(min=0),
            "purchase_limit_total": Int(min=0), "purchase_limit_per_day": Int(min=0),
            # 効果の type は文字列なら受け付け、許可・禁止の判定は規則検査で行う（禁止効果を明示的に報告するため）
            "effects": Arr(Obj(req={"type": Str(min_len=1)}, opt={
                "amount": Int(min=0), "hours": Int(min=1), "resources": Arr(ID), "bps": Int(),
                "rate_reference": Str(enum=["standard_free_idle_at_purchase"]), "retroactive": Bool(), "spirit_id": ID,
                "minutes": Int(min=1),
                "missions": Arr(Obj(req={
                    "id": ID,
                    "condition": Obj(req={"type": Str(enum=["capture_count", "facility_level", "field_unlocked", "spirit_level"]), "amount": Int(min=0)}, opt={"target_id": ID}),
                    "rewards": Arr(COST, min_items=1),
                }), min_items=1, unique_id=True),
            })),
        }), unique_id=True),
    }),
    "releases": Obj(req={
        "schema_version": VERSION,
        "releases": Arr(Obj(req={"id": ID, "name": Str(min_len=1), "field_ids": Arr(ID, min_items=1), "spirit_ids": Arr(ID)}), unique_id=True),
    }),
    "research": Obj(req={
        "schema_version": VERSION,
        "budget": Obj(req={"idle_cap_bps": Int(min=0), "gather_cap_bps": Int(min=0), "candidate_reserve_bps": Int(min=0)}),
        "slots": Obj(req={"free_shared": Int(min=1, max=10)}),
        "nodes": Arr(Obj(req={
            "id": ID, "name": Str(min_len=1), "track": Str(enum=["production", "ecology"]), "release_id": ID,
            "required_fields": Arr(ID), "required_dex_count": Int(min=0), "prerequisites": Arr(ID), "costs": COSTS,
            "duration_minutes": Int(min=1), "speedup_allowed": Bool(),
            # 効果 type は文字列なら受け付け、許可・禁止は規則検査で報告する（禁止効果を明示的に ERROR にするため）
            "effects": Arr(Obj(req={"type": Str(min_len=1)}, opt={"value_bps": Int(), "resources": Arr(ID), "field_id": ID})),
        }), unique_id=True),
    }),
    # 捕獲規則（全フィールド共通）。数値の意味的な範囲は RULE_CAPTURE_PARAMS で検査する（スキーマは型だけ）
    "capture": Obj(req={
        "schema_version": VERSION,
        "lantern": Obj(req={"id": ID, "permanent": Bool(), "start_granted": Bool(), "upgradable": Bool()}),
        "attempt_cost": Arr(COST, min_items=1),
        "base_success_bps_by_grade": Arr(Obj(req={"grade": Int(min=1, max=4), "bps": Int(min=0, max=10000)}), min_items=1),
        "light": Obj(req={"max": Int(), "standard_attack": Obj(req={"damage": Int(), "seconds": Int()}),
                          "bands": Arr(Obj(req={"above": Int(), "mult_bps": Int()}), min_items=1), "scatter_at_or_below": Int()}),
        "easy_mode": Obj(req={"stop_at_light": Int()}),
        "flee_after_failure": Obj(req={"first_bps": Int(), "step_bps": Int(), "max_bps": Int()}),
        "time": Obj(req={"encounter_base_seconds": Int(), "attempt_seconds": Int()}),
        "supply": Obj(req={"start": COSTS, "unlock_grants": Arr(Obj(req={"field_id": ID, "grants": COSTS}))}),
        # 弱体化時間・活力（2026-11-10 決定）。数値の意味的な範囲は RULE_WEAKEN_PARAMS / RULE_VIGOR_PARAMS・RULE_VIGOR_SCOPE
        "weaken": Obj(req={
            "grade_gap_mult_bps": Arr(Obj(req={"gap": Int(), "bps": Int()}), min_items=1),
            "level_bps_per_level": Int(), "level_bps_cap": Int(), "min_seconds": Int(), "max_seconds": Int(),
            "assist_seconds": Int(), "skip_when_no_gain": Bool(),
            "auto_attacker": Obj(req={"vigor_above": Int(), "max_seconds": Int()}),
        }),
        "vigor": Obj(req={
            "max": Int(), "applies_to": Arr(Str(min_len=1)), "weaken_cost": Obj(req={"base": Int(), "per_gap": Int()}),
            "hunt_cost_per_minute": Int(), "rest_recovery_per_hour": Int(), "low_at_or_below": Int(), "low_mult_bps": Int(),
            "food": Obj(req={"resource": ID, "restore": Int(), "window_minutes": Int(), "max_per_window": Int(),
                             "auto_feed_at_or_below": Int()}),
        }),
    }, opt={
        # 捕獲補助道具（2026-11-11 決定）。数値・条件の意味は RULE_CAPTURE_TOOL で検査する（スキーマは型だけ）
        "capture_tool": Obj(req={
            "items": Arr(Obj(req={"field_id": ID, "resource": ID}), min_items=1),
            "mult_bps_by_grade": Arr(Obj(req={"grade": Int(min=1, max=4), "bps": Int()}), min_items=1),
            "max_bps": Int(), "per_attempt": Int(), "applies_to": Str(min_len=1), "unlock_after_field": ID,
            "requires_prior_direct_capture": Bool(),
        }),
    }),
    "crafting": Obj(req={
        "schema_version": VERSION,
        "recipes": Arr(Obj(req={"id": ID, "output": COST, "inputs": Arr(COST, min_items=1), "mode": Str(enum=STACKS), "group": ID}),
                       unique_id=True),
    }),
    "sinks": Obj(req={
        "schema_version": VERSION,
        # effects は値を問わず受け付け、空でなければ RULE_SINK_EFFECT（MVP の消費先は効果 0）
        "items": Arr(Obj(req={
            "id": ID, "category": Str(enum=["house", "furniture", "outfit"]), "field_id": ID, "requires_fields": Arr(ID),
            "requires_items": Arr(ID), "costs": Arr(COST, min_items=1), "effects": Arr(AnyValue()),
            "trade_class": Str(min_len=1), "bind": Str(enum=["account"]), "origin": Str(enum=ORIGINS),
        }, opt={"requires_hub_rank": Int(min=1)}), unique_id=True),
        "repeat_sinks": Arr(Obj(req={
            "id": ID, "category": Str(enum=["altar", "basic_module"]), "requires_fields": Arr(ID), "cost_curve": ID,
            "reward_every": Int(min=0), "reward_until_level": Int(min=0), "effects": Arr(AnyValue()),
        }, opt={"field_id": ID, "trade_class": Str(min_len=1), "bind": Str(enum=["account"]), "origin": Str(enum=ORIGINS)}),
            unique_id=True),
        "dex_records": Obj(req={"pages_cost": Arr(Int(min=1), min_items=1), "resource": ID,
                                "requires": Str(enum=["research_tree_complete"])}),
    }),
    "sink_tables": Obj(req={
        "schema_version": VERSION, "generator": Str(), "curves_sha256": Str(pattern=r"[0-9a-f]{64}"), "tables_sha256": Str(pattern=r"[0-9a-f]{64}"),
        "sink_tables": Arr(Obj(req={"id": ID, "formula": Str(enum=list(tables.SINK_FORMULAS)),
                                    "rows": Arr(Obj(req={"n": Int(min=1), "costs": COSTS}), min_items=1)}), unique_id=True),
    }),
    "upgrade_tables": Obj(req={
        "schema_version": VERSION, "generator": Str(), "curves_sha256": Str(pattern=r"[0-9a-f]{64}"), "tables_sha256": Str(pattern=r"[0-9a-f]{64}"),
        "cost_tables": Arr(Obj(req={"id": ID, "max_level": Int(min=2), "levels": Arr(Obj(req={
            "from_level": Int(min=1), "to_level": Int(min=2), "costs": COSTS}))}), unique_id=True),
        "bonus_tables": Arr(Obj(req={"id": ID, "max_level": Int(min=1), "levels": Arr(Obj(req={
            "level": Int(min=1), "mult_bps": Int(min=0)}))}), unique_id=True),
    }),
    "test_vectors": Obj(req={
        "schema_version": VERSION,
        "vectors": Arr(Obj(req={"id": ID, "fn": Str(min_len=1), "args": AnyValue(), "expected": AnyValue()}), min_items=1, unique_id=True),
    }),
}


def validate(gd: GameData, check_tables: bool = True) -> list[Issue]:
    issues: list[Issue] = list(gd.issues)
    if any(i.level == "ERROR" for i in issues):
        return issues
    # 天井・失敗補正・フィールド別成功率のキーはスキーマの未知キーではなく規則違反として報告し、スキーマ検査からは除く
    schema_docs = _pity_scan(gd, issues)
    for name, spec in SCHEMAS.items():
        if name not in gd.docs:
            continue
        if name in ("upgrade_tables", "sink_tables") and not check_tables:
            continue
        spec.check(schema_docs.get(name, gd.docs[name]), f"{gd.label(name)}:", issues)
    if any(i.level == "ERROR" for i in issues):
        return issues
    model = Model(gd)
    _check_refs(model, issues)
    if any(i.level == "ERROR" for i in issues):
        return issues  # 参照が壊れていると規則検査で KeyError になるため止める
    _check_resource_rules(model, issues)
    _check_spirit_rules(model, issues)
    _check_curve_rules(model, issues)
    _check_facility_rules(model, issues)
    _check_unlock_graph(model, issues)
    _check_capture_rules(model, issues)
    _check_capture_tool(model, issues)
    _check_night_clock(model, issues)
    _check_capture_params(model, issues)
    _check_weaken_vigor(model, issues)
    _check_crafting(model, issues)
    _check_sinks(model, issues)
    _check_trade_reserved(model, issues)
    _check_hunt_rules(model, issues)
    _check_hub_rules(model, issues)
    _check_products(model, issues)
    _check_releases(model, issues)
    _check_research(model, issues)
    if check_tables:
        _check_tables(model, issues)
    _check_dominance(model, issues)
    for path, reason in sim_unsupported(model):
        warn(issues, "RULE_SIM_UNSUPPORTED", path, reason + " — run은 시작 시 중단됨")
    return issues


def has_errors(issues: list[Issue]) -> bool:
    return any(i.level == "ERROR" for i in issues)


# ---- 参照 -------------------------------------------------------------------


def _ref(issues: list[Issue], path: str, kind: str, value: str, valid: Any) -> None:
    if value not in valid:
        err(issues, "REF_UNKNOWN", path, f"존재하지 않는 {kind} 참조: {value}")


def _check_refs(m: Model, issues: list[Issue]) -> None:
    res, fields, spirits = m.resources, m.fields, m.spirits
    for req in m.iter_requirements(include_tables=False):
        _ref(issues, req.path, "자원", req.resource, res)
    for c in m.gd.docs["curves"]["cost_curves"]:
        for b in c["base"]:
            _ref(issues, f"curves/{c['id']}/base", "자원", b["resource"], res)
    for sid, s in spirits.items():
        p = f"spirits/{sid}"
        _ref(issues, p, "필드", s["home_field"], fields)
        _ref(issues, p, "비용 곡선", s["level_cost_curve"], m.cost_curves)
        _ref(issues, p, "보너스 곡선", s["ability_curve"], m.bonus_curves)
        for u in s["upkeep"]:
            _ref(issues, f"{p}/upkeep", "자원", u["resource"], res)
        for t in s["traits"]:
            if t["type"] == "special_node":
                kinds = {n.get("node_kind") for _, n in m.nodes.values() if n.get("node_kind")}
                _ref(issues, f"{p}/traits", "채집 노드 종류", t["params"].get("node_kind", ""), kinds)
    for fid, fac in m.facilities.items():
        p = f"facilities/{fid}"
        _ref(issues, p, "자원", fac["produces"], res)
        _ref(issues, p, "필드", fac["unlock_field"], fields)
        _ref(issues, p, "비용 곡선", fac["cost_curve"], m.cost_curves)
        _ref(issues, p, "보너스 곡선", fac["output_curve"], m.bonus_curves)
        for cap in fac["level_cap_by_field"]:
            _ref(issues, f"{p}/level_cap_by_field", "필드", cap["field_id"], fields)
    for tid, tool in m.tools.items():
        p = f"tools/{tid}"
        _ref(issues, p, "비용 곡선", tool["cost_curve"], m.cost_curves)
        _ref(issues, p, "보너스 곡선", tool["bonus_curve"], m.bonus_curves)
        for cap in tool["level_cap_by_field"]:
            _ref(issues, f"{p}/level_cap_by_field", "필드", cap["field_id"], fields)
    for fid, f in fields.items():
        p = f"fields/{fid}"
        for rf in f["unlock"]["requires_fields"]:
            _ref(issues, f"{p}/unlock", "필드", rf, fields)
        for n in f["gather_nodes"]:
            _ref(issues, f"{p}/gather_nodes/{n['id']}", "자원", n["resource"], res)
        for d in f["hunt"]["drops"]:
            _ref(issues, f"{p}/hunt/drops", "자원", d["resource"], res)
        for e in f["capture"]["table"]:
            _ref(issues, f"{p}/capture/table", "정령", e["spirit_id"], spirits)
    for qid, q in m.quests.items():
        for rbf in q["rewards_by_field"]:
            _ref(issues, f"daily_quests/{qid}", "필드", rbf["field_id"], fields)
            for r in rbf["rewards"]:
                _ref(issues, f"daily_quests/{qid}/{rbf['field_id']}", "자원", r["resource"], res)
    for pid, prod in m.products.items():
        for eff in prod["effects"]:
            for rid in eff.get("resources", []):
                _ref(issues, f"products/{pid}", "자원", rid, res)
            if "spirit_id" in eff:
                _ref(issues, f"products/{pid}", "정령", eff["spirit_id"], spirits)
            for mis in eff.get("missions", []):
                for r in mis["rewards"]:
                    _ref(issues, f"products/{pid}/missions/{mis['id']}", "자원", r["resource"], res)
                cond = mis["condition"]
                if "target_id" in cond:
                    valid = {"facility_level": m.facilities, "field_unlocked": fields}.get(cond["type"], spirits)
                    _ref(issues, f"products/{pid}/missions/{mis['id']}", cond["type"] + " 대상", cond["target_id"], valid)
    for rid, rel in m.releases.items():
        for fid in rel["field_ids"]:
            _ref(issues, f"releases/{rid}", "필드", fid, fields)
        for sid in rel["spirit_ids"]:
            _ref(issues, f"releases/{rid}", "정령", sid, spirits)
    seen_nodes: set[str] = set()
    for f in m.gd.docs["fields"]["fields"]:
        for n in f["gather_nodes"]:
            if n["id"] in seen_nodes:
                err(issues, "SCHEMA_DUP_ID", f"fields/{f['id']}/gather_nodes", f"노드 id 전역 중복: {n['id']}")
            seen_nodes.add(n["id"])
    dup_curves = (set(m.cost_curves) & set(m.bonus_curves)) | ((set(m.cost_curves) | set(m.bonus_curves)) & set(m.sink_curves))
    for cid in sorted(dup_curves):
        err(issues, "SCHEMA_DUP_ID", "curves", f"비용·보너스·소비처 곡선 id 중복: {cid}")
    for cid, c in m.sink_curves.items():
        for b in c["base"]:
            _ref(issues, f"curves/sink_curves/{cid}/base", "자원", b["resource"], res)
    cap = m.capture_rules
    if cap is not None:
        for c in cap["attempt_cost"]:
            _ref(issues, "capture/attempt_cost", "자원", c["resource"], res)
        for c in cap["supply"]["start"]:
            _ref(issues, "capture/supply/start", "자원", c["resource"], res)
        for g in cap["supply"]["unlock_grants"]:
            _ref(issues, "capture/supply/unlock_grants", "필드", g["field_id"], fields)
            for c in g["grants"]:
                _ref(issues, f"capture/supply/unlock_grants/{g['field_id']}", "자원", c["resource"], res)
    if m.sinks is not None:
        item_ids = {it["id"] for it in m.sinks["items"]}
        for it in m.sinks["items"]:
            p = f"sinks/items/{it['id']}"
            _ref(issues, p, "필드", it["field_id"], fields)
            for f in it["requires_fields"]:
                _ref(issues, f"{p}/requires_fields", "필드", f, fields)
            for q in it["requires_items"]:
                _ref(issues, f"{p}/requires_items", "소비처 품목", q, item_ids)
            for c in it["costs"]:
                _ref(issues, f"{p}/costs", "자원", c["resource"], res)
        for rs in m.sinks["repeat_sinks"]:
            p = f"sinks/repeat_sinks/{rs['id']}"
            if "field_id" in rs:
                _ref(issues, p, "필드", rs["field_id"], fields)
            for f in rs["requires_fields"]:
                _ref(issues, f"{p}/requires_fields", "필드", f, fields)
            # 通常の強化曲線を指すのは参照としては有効（上限なしなので RULE_SINK_REPEAT で拒否する）
            _ref(issues, f"{p}/cost_curve", "곡선", rs["cost_curve"], {**m.sink_curves, **m.cost_curves})
        _ref(issues, "sinks/dex_records", "자원", m.sinks["dex_records"]["resource"], res)


# ---- 規則 -------------------------------------------------------------------


def _check_resource_rules(m: Model, issues: list[Issue]) -> None:
    for rid, r in m.resources.items():
        if r["purchasable"] and r["kind"] != "basic":
            err(issues, "RULE_PURCHASABLE_KIND", f"resources/{rid}", "purchasable=true는 기본 재료(kind=basic)만 가능")
    if len(m.basic_ids) != 3:
        err(issues, "RULE_BASIC_RESOURCES", "resources", f"기본 재료는 정확히 3종이어야 함(현재 {len(m.basic_ids)})")


def _check_spirit_rules(m: Model, issues: list[Issue]) -> None:
    basic = set(m.basic_ids)
    grades_needed = set()
    for sid, s in m.spirits.items():
        p = f"spirits/{sid}"
        grades_needed.add(s["grade"])
        if set(s["aptitude"]) != basic:
            err(issues, "RULE_APTITUDE_KEYS", p, f"aptitude 키는 기본 재료 {sorted(basic)}와 같아야 함")
        if s["upkeep"]:
            err(issues, "RULE_UPKEEP", p, "유지비 없음(사용자 확정 규칙 8): upkeep은 빈 배열이어야 함")
        if s["max_owned"] != 0:
            err(issues, "RULE_MAX_OWNED", p, "중복 제한 없음(사용자 확정 규칙 6): max_owned는 0(무제한)")
        for t in s["traits"]:
            if t["type"] == "special_node" and "node_kind" not in t["params"]:
                err(issues, "RULE_TRAIT_PARAMS", p, "special_node에는 params.node_kind가 필요")
            if t["type"] == "mixed_placement_bps" and "min_distinct_species" not in t["params"]:
                err(issues, "RULE_TRAIT_PARAMS", p, "mixed_placement_bps에는 params.min_distinct_species가 필요")
    # 사용자 규칙 F1: 고유 필드 = 그 필드에서 포획되는 종, 고유 필드에는 사냥 재료 드롭이 있어야 함
    home_grades = {g["grade"] for g in m.gd.docs["rules"]["home_material"]["per_day_milli_by_grade"]}
    for sid, s in m.spirits.items():
        f = m.fields[s["home_field"]]
        if not any(e["spirit_id"] == sid and e["weight"] > 0 for e in f["capture"]["table"]):
            err(issues, "RULE_HOME_FIELD", f"spirits/{sid}", f"고유 필드 {s['home_field']}의 포획표에 이 종이 없음")
        if not f["hunt"]["drops"]:
            err(issues, "RULE_HOME_FIELD", f"spirits/{sid}", f"고유 필드 {s['home_field']}에 사냥 재료 드롭이 없음")
    if grades_needed - home_grades:
        err(issues, "RULE_HOME_FIELD", "rules/home_material", f"등급 {sorted(grades_needed - home_grades)}의 방치 특수재화량이 없음")
    ind = m.gd.docs["rules"]["individual_stats"]
    if ind["gather_bps_min"] > ind["gather_bps_max"] or ind["combat_bps_min"] > ind["combat_bps_max"]:
        err(issues, "RULE_INDIVIDUAL_STATS", "rules/individual_stats", "min > max")
    research_grades = {g["grade"] for g in m.gd.docs["spirits"]["release_research_by_grade"]}
    missing = sorted(grades_needed - research_grades)
    if missing:
        err(issues, "RULE_RELEASE_REWARD", "spirits/release_research_by_grade", f"등급 {missing}의 놓아주기 보상이 없음")
    for f in m.gd.docs["fields"]["fields"]:
        for n in f["gather_nodes"]:
            if n.get("requires_node_trait"):
                kind = n.get("node_kind", "")
                holders = [sid for sid, s in m.spirits.items()
                           if any(t["type"] == "special_node" and t["params"].get("node_kind") == kind for t in s["traits"])]
                if not kind or not holders:
                    err(issues, "RULE_NODE_TRAIT", f"fields/{f['id']}/gather_nodes/{n['id']}",
                        "requires_node_trait 노드에는 node_kind와 그것을 여는 special_node 특성 정령이 필요")


def _check_curve_rules(m: Model, issues: list[Issue]) -> None:
    for cid, c in m.bonus_curves.items():
        try:
            tables.per_level_to_bps(c["per_level"])
        except formulas.FormulaError as exc:
            err(issues, "RULE_CURVE_PRECISION", f"curves/{cid}", str(exc))
        levels = [ms["level"] for ms in c["milestones"]]
        if levels != sorted(set(levels)) or any(lv > c["max_level"] for lv in levels):
            err(issues, "RULE_CURVE_MILESTONES", f"curves/{cid}", "milestone 레벨은 오름차순·중복 없음·max_level 이하")
    for cid, c in m.cost_curves.items():
        try:
            for lv in (1, c["max_level"] - 1):
                for b in c["base"]:
                    formulas.exp_ceil_cost(b["amount"], c["growth"], lv + c["exponent_offset"])
        except formulas.FormulaError as exc:
            err(issues, "RULE_SAFE_INT", f"curves/{cid}", str(exc))
    for sid, s in m.spirits.items():
        if m.cost_curves[s["level_cost_curve"]]["max_level"] > m.bonus_curves[s["ability_curve"]]["max_level"]:
            err(issues, "RULE_CURVE_RANGE", f"spirits/{sid}", "레벨 비용 곡선 max_level이 능력 곡선보다 큼")


def _check_entity_levels(m: Model, issues: list[Issue], p: str, ent: dict[str, Any], cost_id: str, bonus_id: str) -> None:
    if ent["max_level"] > m.cost_curves[cost_id]["max_level"] or ent["max_level"] > m.bonus_curves[bonus_id]["max_level"]:
        err(issues, "RULE_CURVE_RANGE", p, "max_level이 참조 곡선의 max_level을 넘음")
    caps = [(m.field_rank(c["field_id"]), c["max_level"]) for c in ent["level_cap_by_field"]]
    caps.sort()
    if any(b[1] < a[1] for a, b in zip(caps, caps[1:])):
        err(issues, "RULE_LEVEL_CAPS", p, "필드 순서에 따라 level cap이 줄어듦")
    if caps and caps[-1][1] > ent["max_level"]:
        err(issues, "RULE_LEVEL_CAPS", p, "level cap이 max_level을 넘음")


def _check_facility_rules(m: Model, issues: list[Issue]) -> None:
    for fid, fac in m.facilities.items():
        p = f"facilities/{fid}"
        if m.resources[fac["produces"]]["kind"] != "basic":
            err(issues, "RULE_FACILITY_OUTPUT", p, "시설은 기본 재료만 생산(방치 생산 = 기본 재료)")
        _check_entity_levels(m, issues, p, fac, fac["cost_curve"], fac["output_curve"])
        if m.level_cap_at_field(fac, fac["unlock_field"]) < 1:
            err(issues, "RULE_LEVEL_CAPS", p, "해금 필드에서 level cap이 정의되지 않음")
        slots = fac["slots"]
        if slots["base"] > slots["max"]:
            err(issues, "RULE_SLOTS", p, "slots.base > slots.max")
        want = list(range(slots["base"] + 1, slots["max"] + 1))
        got = [u["slot"] for u in slots["unlock"]]
        if got != want:
            err(issues, "RULE_SLOTS", p, f"슬롯 해금 목록은 {want}이어야 함(현재 {got})")
        gates = [g["to_level"] for g in fac["hunt_gates"]]
        if gates != sorted(set(gates)) or any(g > fac["max_level"] for g in gates):
            err(issues, "RULE_HUNT_GATES", p, "hunt_gates to_level은 오름차순·중복 없음·max_level 이하")
    for tid, tool in m.tools.items():
        _check_entity_levels(m, issues, f"tools/{tid}", tool, tool["cost_curve"], tool["bonus_curve"])


def _check_unlock_graph(m: Model, issues: list[Issue]) -> None:
    roots = [fid for fid in m.field_order if not m.fields[fid]["unlock"]["requires_fields"]]
    if not roots:
        err(issues, "RULE_UNLOCK_GRAPH", "fields", "선행 조건 없는 시작 필드가 없음")
    for fid in roots:
        if m.fields[fid]["unlock"]["costs"]:
            warn(issues, "RULE_UNLOCK_GRAPH", f"fields/{fid}", "시작 필드에 해금 비용이 있음")
    done: set[str] = set()
    pending = list(m.field_order)
    progressed = True
    while pending and progressed:
        progressed = False
        for fid in list(pending):
            if all(r in done for r in m.fields[fid]["unlock"]["requires_fields"]):
                done.add(fid)
                pending.remove(fid)
                progressed = True
    for fid in pending:
        err(issues, "RULE_UNLOCK_GRAPH", f"fields/{fid}", "순환 의존 또는 도달 불가 필드")
    for fid, f in m.fields.items():
        for r in f["unlock"]["requires_fields"]:
            if m.fields[r]["order"] >= f["order"]:
                err(issues, "RULE_UNLOCK_GRAPH", f"fields/{fid}", f"선행 필드 {r}의 order가 같거나 큼")
        for c in m.expand_costs(f["unlock"]["costs"]):  # 道標（atomic）は素材に展開して検査する
            res = m.resources.get(c["resource"])
            if res is not None and res["kind"] == "hunt":
                drop_fields = [x for x in m.field_order if any(d["resource"] == c["resource"] for d in m.fields[x]["hunt"]["drops"])]
                if drop_fields and all(m.field_rank(x) >= m.field_rank(fid) for x in drop_fields):
                    err(issues, "RULE_UNLOCK_GRAPH", f"fields/{fid}/unlock", f"{c['resource']}는 이 필드 해금 후에만 얻을 수 있음")


def _check_capture_rules(m: Model, issues: list[Issue]) -> None:
    granted = m.product_granted_resources()
    rules = m.capture_rules or {}
    grades = {g["grade"] for g in rules.get("base_success_bps_by_grade", []) if g["bps"] > 0}
    for fid, f in m.fields.items():
        p = f"fields/{fid}/capture"
        cap = f["capture"]
        if sum(e["weight"] for e in cap["table"]) <= 0:
            err(issues, "RULE_CAPTURE_TABLE", p, "가중치 합이 0")
        seen: set[str] = set()
        for e in cap["table"]:
            if e["spirit_id"] in seen:
                err(issues, "RULE_CAPTURE_TABLE", p, f"정령 중복: {e['spirit_id']}")
            seen.add(e["spirit_id"])
            if e["weight"] > 0 and m.spirits[e["spirit_id"]]["grade"] not in grades:
                err(issues, "RULE_CAPTURE_TABLE", p, f"{e['spirit_id']} 등급의 성공 확률이 없음(capture.json)")
    # 2026-11-10 拡張: 試行コスト（芯）とそのレシピ入力を末端まで展開し、購入可能資源・商品付与資源・その制作物を禁止する
    # （段階 2 でフィールド別の捕獲コストは廃止し、試行コストは capture.json だけ）
    if m.capture_rules is not None:
        for rid in sorted(capture_input_closure(m)):
            r = m.resources.get(rid)
            if r is None:
                continue  # 未知参照は REF_UNKNOWN / RULE_CRAFT_GRAPH が報告する
            if r["purchasable"]:
                err(issues, "RULE_PAID_CAPTURE", "capture/attempt_cost",
                    f"포획 시도 비용을 전개하면 구매 가능 자원 {rid}가 들어감(간접 유료 랜덤)")
            elif rid in granted:
                err(issues, "RULE_PAID_CAPTURE", "capture/attempt_cost",
                    f"포획 시도 비용을 전개한 자원 {rid}를 상품 {granted[rid]}이 지급함")
    for rid, pids in sorted(granted.items()):
        r = m.resources.get(rid)
        if r is not None and r["kind"] == "craft":
            err(issues, "RULE_PAID_CAPTURE", f"products/{','.join(pids)}", f"상품이 제작물 {rid}를 지급함(심지·제작물 유료 지급 금지)")
        elif r is not None and r["kind"] == "hunt":
            # 2026-11-11 拡張: 狩り素材は芯・捕獲補助道具の材料なので商品で渡さない（道具→確率の有料経路）
            err(issues, "RULE_PAID_CAPTURE", f"products/{','.join(pids)}", f"상품이 사냥 재료 {rid}를 지급함(심지·포획 도구 재료 유료 지급 금지)")
    # 捕獲補助道具とそのレシピ入力を末端まで展開し、購入可能資源・商品付与資源を禁止する（確率を上げる投入物の有料経路）
    for rid in sorted(capture_tool_input_closure(m)):
        r = m.resources.get(rid)
        if r is None:
            continue
        if r["purchasable"]:
            err(issues, "RULE_PAID_CAPTURE", "capture/capture_tool",
                f"포획 도구를 전개하면 구매 가능 자원 {rid}가 들어감(확률을 올리는 투입물의 유료 경로)")
        elif rid in granted and r["kind"] not in ("craft", "hunt"):  # craft・hunt の付与は上で報告済み
            err(issues, "RULE_PAID_CAPTURE", "capture/capture_tool", f"포획 도구를 전개한 자원 {rid}를 상품 {granted[rid]}이 지급함")


def capture_tool_input_closure(m: Model) -> set[str]:
    """捕獲補助道具（capture_tool.items の資源）を、それを産出する全レシピの入力まで再帰的にたどった資源集合（道具自身を含む）."""
    ct = (m.capture_rules or {}).get("capture_tool")
    if not ct:
        return set()
    seen: set[str] = set()
    stack = [it["resource"] for it in ct["items"]]
    while stack:
        rid = stack.pop()
        if rid in seen:
            continue
        seen.add(rid)
        for rec in m.recipes_for(rid):
            stack.extend(x["resource"] for x in rec["inputs"])
    return seen


def _check_capture_tool(m: Model, issues: list[Issue]) -> None:
    """RULE_CAPTURE_TOOL: 捕獲補助道具は RULE_CAPTURE_NO_PITY の明示的な例外（2026-11-11 ユーザー決定）。許す形だけを通す.

    - 道具はフィールドごとに 1 つ（全フィールド）、craft・stock・非売・untradable・account・origin craft
    - レシピは 1 つ以上・入力は狩り素材だけ
    - 等級倍率: ★1 は無し（置くなら 10000）、★2〜4 は 10000〜CAPTURE_TOOL_MULT_MAX_BPS、等級の重複なし。結果の上限 max_bps ≤ 10000
    - 1 試行あたり 1 個以上消費、適用は固有フィールド（home_field）、unlock_after_field は実在フィールド、直接捕獲の履歴が必須
    （fields[].capture での定義禁止は _pity_scan が報告する）
    """
    ct = (m.capture_rules or {}).get("capture_tool")
    if not ct:
        return
    p = "capture/capture_tool"
    res = m.resources
    seen_f: set[str] = set()
    for it in ct["items"]:
        fid, rid = it["field_id"], it["resource"]
        if fid not in m.fields:
            err(issues, "RULE_CAPTURE_TOOL", f"{p}/items", f"존재하지 않는 필드: {fid}")
        if fid in seen_f:
            err(issues, "RULE_CAPTURE_TOOL", f"{p}/items", f"필드 중복: {fid}")
        seen_f.add(fid)
        r = res.get(rid)
        if r is None:
            err(issues, "RULE_CAPTURE_TOOL", f"{p}/items", f"존재하지 않는 자원: {rid}")
            continue
        bad = [k for k, want in (("kind", "craft"), ("stack", "stock"), ("purchasable", False), ("trade_class", "untradable"),
                                 ("bind", "account"), ("origin", "craft")) if r.get(k) != want]
        if bad:
            err(issues, "RULE_CAPTURE_TOOL", f"resources/{rid}",
                f"포획 도구는 kind craft·stack stock·비매·untradable·account 귀속·origin craft여야 함(위반: {', '.join(bad)})")
        recs = m.recipes_for(rid)
        if not recs:
            err(issues, "RULE_CAPTURE_TOOL", f"resources/{rid}", "포획 도구 레시피가 없음(사냥 재료 레시피 필요)")
        for rec in recs:
            for x in rec["inputs"]:
                xr = res.get(x["resource"])
                if xr is None or xr["kind"] != "hunt":
                    err(issues, "RULE_CAPTURE_TOOL", f"crafting/{rec['id']}", f"포획 도구 레시피 입력은 사냥 재료(kind hunt)만: {x['resource']}")
    missing = [f for f in m.field_order if f not in seen_f]
    if missing:
        err(issues, "RULE_CAPTURE_TOOL", f"{p}/items", f"도구가 없는 필드: {missing}")
    grades = [g["grade"] for g in ct["mult_bps_by_grade"]]
    if len(grades) != len(set(grades)):
        err(issues, "RULE_CAPTURE_TOOL", f"{p}/mult_bps_by_grade", "등급 중복")
    for g in ct["mult_bps_by_grade"]:
        if g["grade"] == 1 and g["bps"] != 10000:
            err(issues, "RULE_CAPTURE_TOOL", f"{p}/mult_bps_by_grade", "★1은 도구 효과 없음(배율을 두려면 10000)")
        elif not 10000 <= g["bps"] <= CAPTURE_TOOL_MULT_MAX_BPS:
            err(issues, "RULE_CAPTURE_TOOL", f"{p}/mult_bps_by_grade",
                f"★{g['grade']} 배율 {g['bps']}는 10000~{CAPTURE_TOOL_MULT_MAX_BPS}이어야 함(상한 변경은 사용자 결정)")
    if not 1 <= ct["max_bps"] <= 10000:
        err(issues, "RULE_CAPTURE_TOOL", f"{p}/max_bps", "도구 적용 후 성공률 상한은 1~10000(100%)")
    if ct["per_attempt"] < 1:
        err(issues, "RULE_CAPTURE_TOOL", f"{p}/per_attempt", "시도당 도구 소비는 1 이상")
    if ct["applies_to"] != "home_field":
        err(issues, "RULE_CAPTURE_TOOL", f"{p}/applies_to", "적용 기준은 대상 정령의 고유 필드(home_field)만(2026-11-11 결정)")
    if ct["unlock_after_field"] not in m.fields:
        err(issues, "RULE_CAPTURE_TOOL", f"{p}/unlock_after_field", f"존재하지 않는 필드: {ct['unlock_after_field']}")
    if ct["requires_prior_direct_capture"] is not True:
        err(issues, "RULE_CAPTURE_TOOL", f"{p}/requires_prior_direct_capture", "직접 포획 이력 조건 필수(첫 포획 무효, 2026-11-11 결정)")


def capture_input_closure(m: Model) -> set[str]:
    """捕獲の試行コストを、それを産出する全レシピの入力まで再帰的にたどった資源集合（試行コスト自身を含む）."""
    if m.capture_rules is None:
        return set()
    seen: set[str] = set()
    stack = [c["resource"] for c in m.capture_rules["attempt_cost"]]
    while stack:
        rid = stack.pop()
        if rid in seen:
            continue
        seen.add(rid)
        for rec in m.recipes_for(rid):
            stack.extend(x["resource"] for x in rec["inputs"])
    return seen


def _strip_pity(v: Any, path: str, hits: list[str]) -> Any:
    if isinstance(v, dict):
        out = {}
        for k, x in v.items():
            if isinstance(k, str) and PITY_KEY.search(k):
                hits.append(f"{path}/{k}")
                continue
            out[k] = _strip_pity(x, f"{path}/{k}", hits)
        return out
    if isinstance(v, list):
        return [_strip_pity(x, f"{path}/{i}", hits) for i, x in enumerate(v)]
    return v


def _pity_scan(gd: GameData, issues: list[Issue]) -> dict[str, Any]:
    """RULE_CAPTURE_NO_PITY: capture.json 全体と fields[].capture の禁止キーを報告し、除いた文書（スキーマ検査用）を返す.

    フィールドの capture に成功率・確率系のキー（FIELD_PROB_KEY）があれば同じ規則で報告する（段階 2 で全体規則へ移行済み）。
    """
    out: dict[str, Any] = {}
    hits: list[str] = []
    tool_hits: list[str] = []
    cap = gd.docs.get("capture")
    if isinstance(cap, dict):
        out["capture"] = _strip_pity(cap, gd.label("capture") + ":", hits)
    fdoc = gd.docs.get("fields")
    if isinstance(fdoc, dict) and isinstance(fdoc.get("fields"), list):
        fdoc2 = copy.copy(fdoc)
        fdoc2["fields"] = []
        for i, f in enumerate(fdoc["fields"]):
            if isinstance(f, dict) and isinstance(f.get("capture"), dict):
                f = dict(f)
                fp = f"{gd.label('fields')}:/fields/{i}/capture"
                c2 = _strip_pity(f["capture"], fp, hits)
                # 捕獲補助道具をフィールド別に定義するのは禁止（全体規則 capture.json capture_tool だけ、RULE_CAPTURE_TOOL）
                for k in [k for k in c2 if isinstance(k, str) and FIELD_TOOL_KEY.search(k)]:
                    tool_hits.append(f"{fp}/{k}")
                    del c2[k]
                # 段階 2 以降、フィールド別の成功率・確率の上書き（success_bps_by_grade 等）は禁止（全体規則 capture.json のみ）
                for k in [k for k in c2 if isinstance(k, str) and FIELD_PROB_KEY.search(k)]:
                    hits.append(f"{fp}/{k}")
                    del c2[k]
                f["capture"] = c2
            fdoc2["fields"].append(f)
        out["fields"] = fdoc2
    for h in hits:
        err(issues, "RULE_CAPTURE_NO_PITY", h, "포획 천장·실패 보정·보장·필드별 성공률 덮어쓰기 금지(사용자 결정: 확률만으로 판정)")
    for h in tool_hits:
        err(issues, "RULE_CAPTURE_TOOL", h, "포획 보조 도구는 capture.json capture_tool에만 정의(필드별 정의 금지)")
    return out


def _check_night_clock(m: Model, issues: list[Issue]) -> None:
    """RULE_NIGHT_CLOCK（ゲーム内時計の夜区間）: 0 ≤ offset < cycle、0 ≤ night_minutes ≤ cycle、cycle は 1440 の約数.

    cycle が 1440 を割り切らないと、シミュの分（day0 00:00 UTC 起点）とゲームの UTC 通算分（os.time()//60）で
    昼夜の位相がずれる（2026-11-11 決定: 全世界同期のゲーム内時計）."""
    n = m.night
    cyc, off, mins = n["cycle_minutes"], n["night_start_offset_minutes"], n["night_minutes"]
    p = "rules/night"
    if formulas.MINUTES_PER_DAY % cyc != 0:
        err(issues, "RULE_NIGHT_CLOCK", f"{p}/cycle_minutes", f"cycle_minutes({cyc})는 1440의 약수여야 함(시뮬 분과 UTC 에폭 분의 위상 일치)")
    if not off < cyc:
        err(issues, "RULE_NIGHT_CLOCK", f"{p}/night_start_offset_minutes", f"0 ≤ night_start_offset_minutes < cycle_minutes({cyc}) 필요(현재 {off})")
    if not mins <= cyc:
        err(issues, "RULE_NIGHT_CLOCK", f"{p}/night_minutes", f"0 ≤ night_minutes ≤ cycle_minutes({cyc}) 필요(현재 {mins})")


def _check_capture_params(m: Model, issues: list[Issue]) -> None:
    """RULE_CAPTURE_PARAMS: 等級別成功率の網羅、光(H)区間倍率の単調性、簡易モード停止点、逃走確率の到達、時間値."""
    cap = m.capture_rules
    if cap is None:
        return
    p = "capture"
    grades = [g["grade"] for g in cap["base_success_bps_by_grade"]]
    if sorted(grades) != [1, 2, 3, 4]:
        err(issues, "RULE_CAPTURE_PARAMS", f"{p}/base_success_bps_by_grade", f"★1~4 성공률이 각각 1개씩 필요(현재 등급 {grades})")
    light = cap["light"]
    if light["max"] < 1:
        err(issues, "RULE_CAPTURE_PARAMS", f"{p}/light/max", "빛 최대값은 1 이상")
    atk = light["standard_attack"]
    if atk["damage"] < 1 or atk["seconds"] < 1:
        err(issues, "RULE_CAPTURE_PARAMS", f"{p}/light/standard_attack", "표준 공격의 damage·seconds는 1 이상 정수")
    bands = light["bands"]
    aboves = [b["above"] for b in bands]
    if aboves != sorted(set(aboves), reverse=True) or aboves[-1] < 0 or aboves[0] >= light["max"]:
        err(issues, "RULE_CAPTURE_PARAMS", f"{p}/light/bands", "구간 above는 빛 최대값 미만에서 내림차순·중복 없음·0 이상")
    mults = [b["mult_bps"] for b in bands]
    if any(x < formulas.BPS for x in mults) or any(b < a for a, b in zip(mults, mults[1:])):
        err(issues, "RULE_CAPTURE_PARAMS", f"{p}/light/bands", f"빛이 낮아질수록 배율이 줄면 안 되고 모두 10000 이상이어야 함(현재 {mults})")
    stop, scatter = cap["easy_mode"]["stop_at_light"], light["scatter_at_or_below"]
    if not scatter < stop <= light["max"]:
        err(issues, "RULE_CAPTURE_PARAMS", f"{p}/easy_mode", f"stop_at_light {stop}는 흩어짐 한계 {scatter}보다 크고 빛 최대값 이하여야 함")
    fl = cap["flee_after_failure"]
    if fl["first_bps"] < 0 or fl["step_bps"] < 0 or fl["max_bps"] != formulas.BPS or fl["first_bps"] > fl["max_bps"]:
        err(issues, "RULE_CAPTURE_PARAMS", f"{p}/flee_after_failure", "도망 확률은 0 이상·줄지 않음(step ≥ 0)·max_bps = 10000")
    else:
        k = 1
        while k <= CAPTURE_K_MAX_LIMIT and min(fl["max_bps"], fl["first_bps"] + fl["step_bps"] * (k - 1)) < formulas.BPS:
            k += 1
        if k > CAPTURE_K_MAX_LIMIT:
            err(issues, "RULE_CAPTURE_PARAMS", f"{p}/flee_after_failure", f"실패 {CAPTURE_K_MAX_LIMIT}회 안에 도망 확률이 100%에 도달하지 않음")
    for key, v in cap["time"].items():
        if key in ("encounter_base_seconds", "attempt_seconds") and v < 1:
            err(issues, "RULE_CAPTURE_PARAMS", f"{p}/time/{key}", "시간 값은 0보다 큰 정수")


def _check_weaken_vigor(m: Model, issues: list[Issue]) -> None:
    """RULE_WEAKEN_PARAMS（弱体化時間）・RULE_VIGOR_PARAMS（活力・餌の数値）・RULE_VIGOR_SCOPE（方置生産に適用しない）・
    RULE_FOOD_RECIPE_INPUT（餌レシピの入力は狩り素材だけ）."""
    cap = m.capture_rules
    if cap is None:
        return
    wk, vg = cap["weaken"], cap["vigor"]
    p = "capture/weaken"
    gaps = sorted((g["gap"], g["bps"]) for g in wk["grade_gap_mult_bps"])
    if [g for g, _ in gaps] != list(range(-3, 4)):
        err(issues, "RULE_WEAKEN_PARAMS", f"{p}/grade_gap_mult_bps", f"등급 차 −3~+3이 각각 1개씩 필요(현재 {[g for g, _ in gaps]})")
    elif any(b <= 0 for _, b in gaps) or any(b2 < b1 for (_, b1), (_, b2) in zip(gaps, gaps[1:])):
        err(issues, "RULE_WEAKEN_PARAMS", f"{p}/grade_gap_mult_bps", "배율은 양수이고 등급 차가 클수록 줄지 않아야 함")
    if wk["level_bps_per_level"] < 0 or wk["level_bps_cap"] < 0:
        err(issues, "RULE_WEAKEN_PARAMS", p, "레벨 배율은 0 이상")
    if not 1 <= wk["min_seconds"] <= wk["max_seconds"]:
        err(issues, "RULE_WEAKEN_PARAMS", p, "1 ≤ min_seconds ≤ max_seconds")
    if not wk["min_seconds"] <= wk["assist_seconds"] <= wk["max_seconds"]:
        err(issues, "RULE_WEAKEN_PARAMS", p, "보조 약화(assist_seconds)는 min~max 초 안(최종 상한 포함)")
    aa = wk["auto_attacker"]
    if not wk["min_seconds"] <= aa["max_seconds"] <= wk["max_seconds"] or not 0 <= aa["vigor_above"] < vg["max"]:
        err(issues, "RULE_WEAKEN_PARAMS", f"{p}/auto_attacker", "max_seconds는 min~max 초, vigor_above는 0 이상 활력 최대 미만")
    p = "capture/vigor"
    food = vg["food"]
    bad = []
    if vg["max"] < 1:
        bad.append("max ≥ 1")
    if vg["weaken_cost"]["base"] < 0 or vg["weaken_cost"]["per_gap"] < 0 or vg["hunt_cost_per_minute"] < 0:
        bad.append("소모량 ≥ 0")
    if vg["rest_recovery_per_hour"] < 1:
        bad.append("rest_recovery_per_hour ≥ 1(비활동 회복 필수)")
    if not 0 <= vg["low_at_or_below"] < vg["max"] or not 0 < vg["low_mult_bps"] <= formulas.BPS:
        bad.append("0 ≤ low_at_or_below < max, 0 < low_mult_bps ≤ 10000")
    if food["restore"] < 1 or food["window_minutes"] < 1 or food["max_per_window"] < 1 or not 0 <= food["auto_feed_at_or_below"] < vg["max"]:
        bad.append("food: restore·window_minutes·max_per_window ≥ 1, 0 ≤ auto_feed_at_or_below < max")
    fr = m.resources.get(food["resource"])
    if fr is None or fr["kind"] != "craft" or fr.get("stack") != "stock" or fr["purchasable"]:
        bad.append(f"food.resource {food['resource']}는 비매 craft(stock) 자원이어야 함")
    for b in bad:
        err(issues, "RULE_VIGOR_PARAMS", p, b)
    # シミュは applies_to を読まず常に弱体化・狩りの両方に適用するので、ちょうど VIGOR_SCOPES であることを強制する（レビュー Minor 4）
    extra = sorted(set(vg["applies_to"]) - VIGOR_SCOPES)
    missing = sorted(VIGOR_SCOPES - set(vg["applies_to"]))
    if extra:
        err(issues, "RULE_VIGOR_SCOPE", f"{p}/applies_to",
            f"활력은 동행 활동({sorted(VIGOR_SCOPES)})에만 적용(집 방치 생산·보유에는 유지비 없음): {extra}")
    if missing or len(vg["applies_to"]) != len(set(vg["applies_to"])):
        err(issues, "RULE_VIGOR_SCOPE", f"{p}/applies_to",
            f"applies_to는 정확히 {sorted(VIGOR_SCOPES)}(시뮬은 두 활동 모두에 적용, 누락·중복 불가): 누락 {missing}")
    if fr is not None:
        # 餌の投入物を末端まで展開し、購入可能資源・商品付与資源があれば禁止（餌 → 弱体化時間 → 捕獲の有料経路、レビュー Minor 5）
        granted = m.product_granted_resources()
        seen: set[str] = set()
        stack = [food["resource"]]
        while stack:
            rid = stack.pop()
            if rid in seen:
                continue
            seen.add(rid)
            for rec in m.recipes_for(rid):
                stack.extend(x["resource"] for x in rec["inputs"])
        for rid in sorted(seen - {food["resource"]}):
            r = m.resources.get(rid)
            if r is not None and (r["purchasable"] or rid in granted):
                err(issues, "RULE_PAID_CAPTURE", f"capture/vigor/food",
                    f"먹이 재료를 전개하면 구매 가능·상품 지급 자원 {rid}가 들어감(먹이→약화 시간→포획의 유료 경로)")
        recs = m.recipes_for(food["resource"])
        if not recs:
            err(issues, "RULE_FOOD_RECIPE_INPUT", f"resources/{food['resource']}", "먹이 레시피가 없음(사냥 재료 레시피 필요)")
        for rec in recs:
            for x in rec["inputs"]:
                r = m.resources.get(x["resource"])
                if r is None or r["kind"] != "hunt":
                    err(issues, "RULE_FOOD_RECIPE_INPUT", f"crafting/{rec['id']}",
                        f"먹이 레시피 입력은 사냥 재료(kind hunt)만: {x['resource']}")


def _check_crafting(m: Model, issues: list[Issue]) -> None:
    """RULE_CRAFT_GRAPH（参照・循環・atomic のレシピ数と付与禁止）と RULE_WICK_RECIPE_INPUT."""
    res = m.resources
    for rid, r in res.items():
        p = f"resources/{rid}"
        if r["kind"] == "craft" and "stack" not in r:
            err(issues, "RULE_CRAFT_GRAPH", p, "craft 자원에는 stack(stock|atomic)이 필요")
        if r.get("stack") == "atomic" and r["kind"] != "craft":
            err(issues, "RULE_CRAFT_GRAPH", p, "stack=atomic은 craft 자원만")
    bad_ref = False
    for rec_id in m.recipe_order:
        rec = m.recipes[rec_id]
        p = f"crafting/{rec_id}"
        out = rec["output"]["resource"]
        for rid in [out] + [x["resource"] for x in rec["inputs"]]:
            if rid not in res:
                err(issues, "RULE_CRAFT_GRAPH", p, f"존재하지 않는 자원 참조: {rid}")
                bad_ref = True
        if out not in res:
            continue
        if res[out]["kind"] != "craft":
            err(issues, "RULE_CRAFT_GRAPH", p, f"레시피 산출물은 craft 자원만: {out}")
        if rec["mode"] != res[out].get("stack"):
            err(issues, "RULE_CRAFT_GRAPH", p, f"mode {rec['mode']}가 산출물 {out}의 stack과 다름")
        if rec["mode"] == "atomic" and rec["output"]["amount"] != 1:
            err(issues, "RULE_CRAFT_GRAPH", p, "atomic 레시피의 산출량은 1")
    for rid, r in res.items():
        if r.get("stack") == "atomic":
            n = len(m.recipes_for(rid))
            if n != 1:
                err(issues, "RULE_CRAFT_GRAPH", f"resources/{rid}", f"atomic 품목의 레시피는 정확히 1개여야 함(현재 {n})")
    # 循環（産出物 → 入力の有向グラフ）
    color: dict[str, int] = {}

    def dfs(rid: str, trail: list[str]) -> list[str] | None:
        color[rid] = 1
        for rec in m.recipes_for(rid):
            for x in rec["inputs"]:
                nxt = x["resource"]
                if color.get(nxt) == 1:
                    return trail + [rid, nxt]
                if color.get(nxt, 0) == 0:
                    hit = dfs(nxt, trail + [rid])
                    if hit:
                        return hit
        color[rid] = 2
        return None

    for rid in sorted({m.recipes[r]["output"]["resource"] for r in m.recipe_order}):
        if color.get(rid, 0) == 0:
            cyc = dfs(rid, [])
            if cyc:
                err(issues, "RULE_CRAFT_GRAPH", "crafting/recipes", f"레시피 순환: {' → '.join(cyc)}")
                break
    # atomic 品目は使う時点で作る物なので、補給・報酬・商品で渡さない
    given: list[tuple[str, str]] = []
    if m.capture_rules is not None:
        given += [(c["resource"], "capture/supply/start") for c in m.capture_rules["supply"]["start"]]
        given += [(c["resource"], f"capture/supply/unlock_grants/{g['field_id']}")
                  for g in m.capture_rules["supply"]["unlock_grants"] for c in g["grants"]]
    given += [(r["resource"], f"daily_quests/{qid}") for qid, q in m.quests.items() for rbf in q["rewards_by_field"] for r in rbf["rewards"]]
    given += [(rid, f"products/{','.join(pids)}") for rid, pids in m.product_granted_resources().items()]
    for rid, path in given:
        if res.get(rid, {}).get("stack") == "atomic":
            err(issues, "RULE_CRAFT_GRAPH", path, f"atomic 품목 {rid}는 보급·보상으로 지급할 수 없음")
    if bad_ref or m.capture_rules is None:
        return
    # 芯（試行コストの資源）のレシピ入力は狩り素材だけ
    for c in m.capture_rules["attempt_cost"]:
        for rec in m.recipes_for(c["resource"]):
            for x in rec["inputs"]:
                if res[x["resource"]]["kind"] != "hunt":
                    err(issues, "RULE_WICK_RECIPE_INPUT", f"crafting/{rec['id']}",
                        f"심지 레시피 입력은 사냥 재료(kind hunt)만: {x['resource']}({res[x['resource']]['kind']})")


def _check_sinks(m: Model, issues: list[Issue]) -> None:
    """RULE_SINK_EFFECT（効果 0）と RULE_SINK_REPEAT（上限付き公式のみ・基本資源だけの反復先が 1 個以上）."""
    doc = m.sinks
    if doc is None:
        return
    ids = [it["id"] for it in doc["items"]] + [rs["id"] for rs in doc["repeat_sinks"]]
    for dup in sorted({i for i in ids if ids.count(i) > 1}):
        err(issues, "SCHEMA_DUP_ID", "sinks", f"items·repeat_sinks id 중복: {dup}")
    for it in doc["items"]:
        if it["effects"]:
            err(issues, "RULE_SINK_EFFECT", f"sinks/items/{it['id']}", "MVP 소비처 효과는 0(effects는 빈 배열)")
    for rs in doc["repeat_sinks"]:
        if rs["effects"]:
            err(issues, "RULE_SINK_EFFECT", f"sinks/repeat_sinks/{rs['id']}", "MVP 소비처 효과는 0(effects는 빈 배열)")
    for cid, c in m.sink_curves.items():
        p = f"curves/sink_curves/{cid}"
        if c["formula"] == "exp_ceil_capped":
            ok = "cap_level" in c and all("growth" in b for b in c["base"]) and "step" not in c and "cap_steps" not in c
        else:
            ok = "step" in c and "cap_steps" in c and "cap_level" not in c and not any("growth" in b for b in c["base"])
        if not ok:
            err(issues, "RULE_SINK_REPEAT", p, f"{c['formula']} 공식의 매개변수가 맞지 않음(exp_ceil_capped: cap_level·성분별 growth, "
                                                "linear_ceil_capped: step·cap_steps)")
            continue
        try:
            tables.build_sink_table(c)
        except formulas.FormulaError as exc:
            err(issues, "RULE_SAFE_INT", p, str(exc))
    basic_only = 0
    for rs in doc["repeat_sinks"]:
        c = m.sink_curves.get(rs["cost_curve"])
        if c is None or c["formula"] not in tables.SINK_FORMULAS:
            err(issues, "RULE_SINK_REPEAT", f"sinks/repeat_sinks/{rs['id']}",
                f"반복 소비처는 비용 상한 공식(sink_curves의 {'/'.join(tables.SINK_FORMULAS)})만 사용: {rs['cost_curve']}")
            continue
        if all(m.resources.get(b["resource"], {}).get("kind") == "basic" for b in c["base"]):
            basic_only += 1
    if basic_only == 0:
        err(issues, "RULE_SINK_REPEAT", "sinks/repeat_sinks", "기본 재료만 쓰는 반복 소비처가 1개 이상 필요(사용자 결정 I3)")


def _check_trade_reserved(m: Model, issues: list[Issue]) -> None:
    """RULE_TRADE_RESERVED: MVP は取引なし。trade_class は予約フィールドで untradable だけ."""
    rows = [(f"resources/{rid}", r.get("trade_class")) for rid, r in m.resources.items()]
    if m.sinks is not None:
        rows += [(f"sinks/items/{it['id']}", it.get("trade_class")) for it in m.sinks["items"]]
        rows += [(f"sinks/repeat_sinks/{rs['id']}", rs.get("trade_class")) for rs in m.sinks["repeat_sinks"]]
    for path, tc in rows:
        if tc is not None and tc != "untradable":
            err(issues, "RULE_TRADE_RESERVED", path, f"trade_class는 MVP에서 untradable만(거래 미구현, 필드 예약): {tc}")


def _check_hunt_rules(m: Model, issues: list[Issue]) -> None:
    c = m.constants
    if c["hunt_min_ratio_bps"] > c["hunt_max_ratio_bps"]:
        err(issues, "RULE_HUNT", "rules/constants", "hunt_min_ratio_bps > hunt_max_ratio_bps")
    quest_res = {r["resource"] for q in m.quests.values() for rbf in q["rewards_by_field"] for r in rbf["rewards"]}
    for fid, f in m.fields.items():
        for d in f["hunt"]["drops"]:
            if m.resources[d["resource"]]["kind"] != "hunt":
                err(issues, "RULE_HUNT", f"fields/{fid}/hunt", f"사냥 드롭은 hunt 자원이어야 함: {d['resource']}")
    for rid in m.hunt_resource_ids():
        if not any(d["resource"] == rid for f in m.fields.values() for d in f["hunt"]["drops"]):
            err(issues, "RULE_HUNT_SOURCE", f"resources/{rid}", "어느 필드에서도 드롭되지 않는 사냥 재료")
        if rid not in quest_res:
            warn(issues, "RULE_HUNT_IDLE_PATH", f"resources/{rid}", "일일 의뢰로 얻을 수 없음(방치 유저 경로 없음)")
    for fid, f in m.fields.items():
        for n in f["gather_nodes"]:
            if m.resources[n["resource"]]["kind"] != "basic":
                err(issues, "RULE_GATHER_NODE", f"fields/{fid}/gather_nodes/{n['id']}", "채집 노드는 기본 재료만")


def _check_hub_rules(m: Model, issues: list[Issue]) -> None:
    oc = m.hub["offline_cap"]
    if oc["max_hours"] > 24:
        err(issues, "RULE_OFFLINE_CAP", "hub/offline_cap", "오프라인 상한은 최대 24시간(사용자 확정 규칙 9)")
    hours = [oc["base_hours"]] + [u["hours"] for u in oc["upgrades"]]
    if hours != sorted(set(hours)):
        err(issues, "RULE_OFFLINE_CAP", "hub/offline_cap", "업그레이드 시간은 기본값보다 크고 오름차순이어야 함")
    if hours[-1] != oc["max_hours"]:
        err(issues, "RULE_OFFLINE_CAP", "hub/offline_cap", "마지막 업그레이드가 max_hours와 다름")
    # 사용자 규칙 F4: 기본 + 거점 등급 보너스 + 보관함 상품 최대치 ≤ max_capacity
    st_cfg = m.hub["storage"]
    paid = 0
    for pid, prod in m.products.items():
        for eff in prod["effects"]:
            if eff["type"] == "storage_capacity":
                if prod["purchase_limit_total"] == 0:
                    err(issues, "RULE_STORAGE_CAP", f"products/{pid}", "보관함 확장 상품은 총 구매 한도가 있어야 함(0=무제한 불가)")
                paid += eff.get("amount", 0) * prod["purchase_limit_total"]
    total = st_cfg["base_capacity"] + sum(r["storage_bonus"] for r in m.hub["ranks"]) + paid
    if total > st_cfg["max_capacity"]:
        err(issues, "RULE_STORAGE_CAP", "hub/storage", f"보유 상한 합계 {total} > max_capacity {st_cfg['max_capacity']}(과금 확장 상한 초과)")
    ranks = [r["rank"] for r in m.hub["ranks"]]
    if ranks != list(range(1, len(ranks) + 1)):
        err(issues, "RULE_HUB_RANKS", "hub/ranks", "rank는 1부터 연속이어야 함")


def _check_products(m: Model, issues: list[Issue]) -> None:
    for pid, prod in m.products.items():
        p = f"products/{pid}"
        kind = prod["kind"]
        if kind in FORBIDDEN_PRODUCT_KINDS:
            reason = FORBIDDEN_PRODUCT_KIND_REASONS.get(kind, "정령 판매·유료 랜덤·확률/행운·스탯 버프")
            err(issues, "RULE_FORBIDDEN_PRODUCT", p, f"금지된 상품 종류: {kind} ({reason})")
            continue
        if kind not in ALLOWED_PRODUCT_KINDS:
            err(issues, "RULE_UNKNOWN_PRODUCT", p, f"허용 목록에 없는 상품 종류: {kind}")
            continue
        allowed = ALLOWED_PRODUCT_KINDS[kind]
        for eff in prod["effects"]:
            et = eff["type"]
            if et in FORBIDDEN_EFFECT_TYPES:
                err(issues, "RULE_FORBIDDEN_PRODUCT", p, f"금지된 상품 효과: {et}")
            elif et in OFFLINE_CAP_EFFECT_TYPES:
                err(issues, "RULE_PAID_OFFLINE_CAP", p, f"오프라인 상한을 늘리는 상품 효과 금지(무료 강화만): {et}")
            elif kind == "subscription" and et not in allowed:
                err(issues, "RULE_SUBSCRIPTION_EFFECT", p, f"구독 혜택은 외형·이벤트 트랙만(진행 효과 금지): {et}")
            elif et not in allowed:
                err(issues, "RULE_PRODUCT_EFFECT", p, f"{kind} 상품에 허용되지 않는 효과: {et}")
            elif et == "storage_capacity":
                if eff.get("amount", 0) < 1:
                    err(issues, "RULE_PRODUCT_EFFECT", p, "storage_capacity.amount ≥ 1 필요")
            elif et == "research_time_minutes":
                if eff.get("minutes", 0) < 1 or set(eff) - {"type", "minutes", "placeholder", "notes"}:
                    err(issues, "RULE_PRODUCT_EFFECT", p, "research_time_minutes에는 minutes(≥1)만 둔다(비용·조건 면제 불가)")
        if kind in ("storage_expand", "research_time_skip") and not prod["effects"]:
            err(issues, "RULE_PRODUCT_EFFECT", p, f"{kind} 상품에 효과가 없음")


def _check_releases(m: Model, issues: list[Issue]) -> None:
    for rid, rel in m.releases.items():
        p = f"releases/{rid}"
        fset = set(rel["field_ids"])
        for fid in rel["field_ids"]:
            for req in m.fields[fid]["unlock"]["requires_fields"]:
                if req not in fset:
                    err(issues, "RULE_RELEASE_FIELDS", p, f"{fid}의 선행 필드 {req}가 릴리스에 없음")
        for sid in rel["spirit_ids"]:
            grade = m.spirits[sid]["grade"]
            ok_fields = []
            success = {g["grade"]: g["bps"] for g in (m.capture_rules or {}).get("base_success_bps_by_grade", [])}
            for fid in rel["field_ids"]:
                cap = m.fields[fid]["capture"]
                for e in cap["table"]:
                    if e["spirit_id"] == sid and e["weight"] > 0 and e["availability"] == "always" and success.get(grade, 0) > 0:
                        ok_fields.append(fid)
            if not ok_fields:
                err(issues, "RULE_RELEASE_ACCESS", p,
                    f"{sid}를 {rel['name']} 필드 합집합 {rel['field_ids']} 어디에서도 상시 획득할 수 없음")
        for fid in rel["field_ids"]:
            for e in m.fields[fid]["capture"]["table"]:
                if e["weight"] > 0 and e["spirit_id"] not in rel["spirit_ids"]:
                    warn(issues, "RULE_RELEASE_EXTRA", p, f"{fid}에서 목록 밖 정령 {e['spirit_id']}가 등장")


def _check_tables(m: Model, issues: list[Issue]) -> None:
    reasons = tables.staleness(m.gd.docs["curves"], m.gd.docs["upgrade_tables"])
    for r in reasons:
        err(issues, "STALE_TABLES", m.gd.label("upgrade_tables"), f"{r} — `python3 -m econ_sim gen-tables` 실행 필요")
    if "sink_tables" in m.gd.docs:
        for r in tables.sink_staleness(m.gd.docs["curves"], m.gd.docs["sink_tables"]):
            err(issues, "STALE_TABLES", m.gd.label("sink_tables"), f"{r} — `python3 -m econ_sim gen-tables` 실행 필요")
    elif m.sink_curves:
        err(issues, "STALE_TABLES", "manifest.json", "sink_curves가 있는데 sink_tables(generated/sink_tables.json)가 등록·생성되지 않음")


def _check_dominance(m: Model, issues: list[Issue]) -> None:
    # 2026-11-12 ユーザー決定: 上位互換禁止の原則を廃止。支配関係は参考情報（INFO）として報告だけ残す
    # （dominance.csv・レポートの支配表はそのまま出力する）
    for row in dominance_rows(m):
        if row["higher_grade_dominates"]:
            info(issues, "INFO_DOMINANCE", f"spirits/{row['spirit_a']}",
                 f"★{row['grade_a']} {row['spirit_a']}가 ★{row['grade_b']} {row['spirit_b']}를 모든 기여 차원에서 지배(고유 특성 보호 없음)")


# ---- 研究ツリー ------------------------------------------------------------------


def _research_topo(m: Model) -> list[str] | None:
    """先行条件のトポロジカル順（データ順を保つ Kahn 法）。循環があれば None."""
    nodes = m.research_nodes
    done: list[str] = []
    pending = list(m.research_order)
    progressed = True
    while pending and progressed:
        progressed = False
        for nid in list(pending):
            if all(p in done for p in nodes[nid]["prerequisites"]):
                done.append(nid)
                pending.remove(nid)
                progressed = True
    return None if pending else done


def research_r_neutral(m: Model, limit: int = RESEARCH_ENUM_LIMIT) -> tuple[str, list[str]]:
    """R 中立（資源別 累積直接 A ≤ 累積放置 I）を到達可能な全完了状態で検査する.

    到達可能な完了状態 = 先行条件について閉じた集合（各ノードの先行が全て含まれる）。フィールド・図鑑条件は
    いずれ満たせるので集合を制限しない。状態数が limit 以下なら全列挙（厳密）、超えたら先行グラフ基準の保守検査:
    直接ノードをトポロジカル順に、その祖先の放置ノードの残り容量から貪欲に割り当て、割り当てられれば
    「直接ノードを含む状態は必ずその祖先を含む」ので全状態で A ≤ I が保証される（失敗は偽陽性もありうる＝保守的）。
    戻り値: (方法 'enumeration'|'conservative', 違反メッセージ)。
    """
    order = _research_topo(m)
    if order is None:
        return "graph_error", []
    nodes = m.research_nodes
    idle = {n: m.research_effect_bps([n], "basic_idle_bps") for n in order}
    direct = {n: m.research_effect_bps([n], "basic_gather_bps") for n in order}
    basic = m.basic_ids
    violations: list[str] = []
    count = 0

    class _Overflow(Exception):
        pass

    def rec(i: int, chosen: list[str], a: dict[str, int], b: dict[str, int]) -> None:
        nonlocal count
        if i == len(order):
            count += 1
            if count > limit:
                raise _Overflow
            for r in basic:
                if a[r] > b[r] and len(violations) < 5:
                    violations.append(f"완료 상태 {sorted(chosen) or '[]'}에서 {r} 직접 {a[r]}bps > 방치 {b[r]}bps")
            return
        n = order[i]
        rec(i + 1, chosen, a, b)
        if all(p in chosen for p in nodes[n]["prerequisites"]):
            chosen.append(n)
            rec(i + 1, chosen, {r: a[r] + direct[n][r] for r in basic}, {r: b[r] + idle[n][r] for r in basic})
            chosen.pop()

    try:
        rec(0, [], dict.fromkeys(basic, 0), dict.fromkeys(basic, 0))
        return "enumeration", violations
    except _Overflow:
        violations.clear()
    # 保守検査（先行グラフの祖先集合への貪欲割り当て）
    anc: dict[str, set[str]] = {}
    for n in order:
        s_ = set()
        for p in nodes[n]["prerequisites"]:
            s_ |= {p} | anc[p]
        anc[n] = s_
    remain = {n: dict(idle[n]) for n in order}
    for n in order:
        for r in basic:
            need = direct[n][r]
            for src in sorted(anc[n], key=order.index, reverse=True):  # 近い祖先から使う
                take = min(need, remain[src][r])
                remain[src][r] -= take
                need -= take
            if need > 0:
                violations.append(f"보수 검사: {n}의 {r} 직접 효과 {direct[n][r]}bps를 선행 방치 연구로 덮지 못함(부족 {need}bps)")
    return "conservative", violations


def _check_research(m: Model, issues: list[Issue]) -> None:
    doc = m.research
    if not doc:
        return
    nodes = m.research_nodes
    rp = m.research_resource
    # 参照
    before = len(issues)
    for nid, n in nodes.items():
        p = f"research/{nid}"
        for c in n["costs"]:
            _ref(issues, f"{p}/costs", "자원", c["resource"], m.resources)
        for f in n["required_fields"]:
            _ref(issues, f"{p}/required_fields", "필드", f, m.fields)
        for q in n["prerequisites"]:
            _ref(issues, f"{p}/prerequisites", "연구 노드", q, nodes)
        _ref(issues, p, "릴리스", n["release_id"], m.releases)
        for eff in n["effects"]:
            for r in eff.get("resources", []):
                _ref(issues, f"{p}/effects", "자원", r, m.resources)
            if "field_id" in eff:
                _ref(issues, f"{p}/effects", "필드", eff["field_id"], m.fields)
    if any(i.level == "ERROR" for i in issues[before:]):
        return
    # 研究ポイントは購入不可・商品で付与しない
    if rp is None:
        err(issues, "RULE_RESEARCH_PAID", "resources", "kind=research 자원이 없음")
    else:
        if m.resources[rp]["purchasable"]:
            err(issues, "RULE_RESEARCH_PAID", f"resources/{rp}", "연구 포인트는 purchasable=false여야 함")
        for pid in m.product_granted_resources().get(rp, []):
            err(issues, "RULE_RESEARCH_PAID", f"products/{pid}", "상품·패스가 연구 포인트를 지급함")
    # 効果・トラック・短縮可否
    idle_sum = m.research_effect_bps([], "basic_idle_bps")
    gather_sum = dict(idle_sum)
    for nid, n in nodes.items():
        p = f"research/{nid}"
        for eff in n["effects"]:
            et = eff["type"]
            if et not in RESEARCH_EFFECT_TYPES:
                err(issues, "RULE_RESEARCH_EFFECT", f"{p}/effects",
                    f"허용되지 않는 연구 효과: {et}(허용: 기본 재료 방치·직접 채집 배율, 생태 정보)")
                continue
            if et in RESEARCH_PRODUCTION_EFFECTS:
                if eff.get("value_bps", 0) < 1:
                    err(issues, "RULE_RESEARCH_EFFECT", f"{p}/effects", f"{et}.value_bps ≥ 1 필요")
                for r in eff.get("resources", []):
                    if m.resources[r]["kind"] != "basic":
                        err(issues, "RULE_RESEARCH_EFFECT", f"{p}/effects", f"{et}는 기본 재료만 대상: {r}")
                if n["track"] != "production":
                    err(issues, "RULE_RESEARCH_TRACK", p, f"생산 효과({et})는 production 트랙만")
            elif eff.get("value_bps", 0) != 0 or eff.get("resources"):
                err(issues, "RULE_RESEARCH_EFFECT", f"{p}/effects", "habitat_info는 정보 효과(value_bps 0, resources 없음)")
            elif n["track"] != "ecology":
                err(issues, "RULE_RESEARCH_TRACK", p, "habitat_info는 ecology 트랙만")
        step = m.constants["activity_step_minutes"]
        if n["duration_minutes"] % step:
            # 完了が 5 分ステップの途中に落ちると、そのステップの直接採集全体に新しい A が掛かるため禁止
            err(issues, "RULE_RESEARCH_DURATION", p, f"duration_minutes는 활동 단계 {step}분의 배수여야 함")
        if n["speedup_allowed"] and n["track"] != "production":
            err(issues, "RULE_RESEARCH_SPEEDUP", p, "speedup_allowed=true는 production 노드만(생태 연구는 단축 불가)")
        if n["required_dex_count"] > len(m.spirits):
            err(issues, "RULE_RESEARCH_GRAPH", p, f"required_dex_count {n['required_dex_count']} > 정령 종 수 {len(m.spirits)}")
        rel = m.releases[n["release_id"]]
        for f in n["required_fields"]:
            if f not in rel["field_ids"]:
                err(issues, "RULE_RESEARCH_RELEASE", p, f"필요 필드 {f}가 릴리스 {n['release_id']} 필드에 없음")
        rel_order = list(m.releases)
        for q in n["prerequisites"]:
            if rel_order.index(nodes[q]["release_id"]) > rel_order.index(n["release_id"]):
                err(issues, "RULE_RESEARCH_RELEASE", p, f"선행 {q}가 더 늦은 릴리스에 있음")
        for r, v in m.research_effect_bps([nid], "basic_idle_bps").items():
            idle_sum[r] += v
        for r, v in m.research_effect_bps([nid], "basic_gather_bps").items():
            gather_sum[r] += v
    # 経路別合計予算（candidate_reserve_bps は未検証候補なので使えない）
    b = doc["budget"]
    for label, sums, cap in (("방치", idle_sum, b["idle_cap_bps"]), ("직접 채집", gather_sum, b["gather_cap_bps"])):
        for r, v in sums.items():
            if v > cap:
                err(issues, "RULE_RESEARCH_BUDGET", "research/budget",
                    f"{r} {label} 연구 합계 {v}bps > 상한 {cap}bps(candidate_reserve {b['candidate_reserve_bps']}bps는 사용 불가)")
    # 先行グラフ・R 中立
    if _research_topo(m) is None:
        err(issues, "RULE_RESEARCH_GRAPH", "research/nodes", "선행 조건 순환")
        return
    method, viol = research_r_neutral(m)
    for v in viol:
        err(issues, "RULE_RESEARCH_R_NEUTRAL", "research/nodes", f"{v} ({'전수 열거' if method == 'enumeration' else '선행 그래프 보수 검사'})")
