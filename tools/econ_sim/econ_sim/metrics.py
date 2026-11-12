"""run 出力（daily / events / spirit_daily / allocation）からの集計と判定.

- 分位数は打ち切り（未到達）を +∞ として全実行で数える（完了者だけの分位数を公式値にしない）。
  分位点が未到達側に落ちたら値は空欄（=期間内に未到達）。
- 割合は Wilson 95% 区間を付け、区間が閾値をまたぐ場合は INCONCLUSIVE。
- check 行は閾値ごとに分ける。approval_state は閾値の承認状態で決まり、結果によって変わらない。
- 日次の抽出日・対象ペルソナ・閾値は criteria.json / manifest.json（personas.json 由来）から読む。
"""
from __future__ import annotations

import csv
import math
from fractions import Fraction
from pathlib import Path
from typing import Any, Iterable

from . import formulas, metrics_capture, static_analysis
from .model import Model
from .schema import ID, AnyValue, Arr, Bool, Int, Issue, Num, Obj, Str

CHECK_COLS = ["check_id", "cohort", "metric", "statistic", "estimate", "n", "uncertainty_low", "uncertainty_high",
              "threshold", "draft_evaluation", "approval_state", "evidence_status", "reason"]
SOURCES = ("idle", "direct", "hunt", "quest", "paid", "release")
G2_SUM_KEYS = ("r_sum", "r_minutes", "over_max_minutes", "over_max_transition_minutes", "undefined_minutes",
               "undefined_transition_minutes", "gather_min")
_APPROVAL = Str(enum=["approved", "draft"])

SIM_CRITERIA_SCHEMA = Obj(req={
    "approval": _APPROVAL,
    "unlock_targets": Arr(Obj(req={"persona_id": ID, "field_id": ID, "p50_day": Num(min=0), "p50_tolerance": Num(min=0),
                                   "p90_max_day": Num(min=0), "approval": _APPROVAL})),
    "min_samples_tail": Int(min=1), "usage_low_grade_max_grade": Int(min=1), "usage_low_grade_min_share": Num(min=0, max=1),
    "usage_single_species_max_share": Num(min=0, max=1), "capture_release_id": ID, "capture_by_day": Int(min=1),
    "capture_min_rate": Num(min=0, max=1), "report_capture_persona": ID,
    "storage_full_min_day": Arr(Obj(req={"persona_id": ID, "day": Num(min=0)})),
    "paid_pair": Obj(req={"free": ID, "paid": ID}), "paid_max_shortening": Num(min=0, max=1), "paid_approval": _APPROVAL,
    "exhaustion_max_rate": Arr(Obj(req={"persona_id": ID, "day": Int(min=1), "rate": Num(min=0, max=1)})),
    "convergence_min_exclusion_loss_pct": Num(min=0), "g2_personas": Arr(ID),
}, opt={"notes": AnyValue(), "hunt_idle_early_days": Int(min=1), "g2_approved_personas": Arr(ID),
        "exhaustion_info_only": Bool(),
        "lead": Obj(req={"fast": ID, "base": ID, "field_id": ID, "min_days": Num(min=0), "approval": _APPROVAL}),
        "star4_first_capture": Obj(req={"max_days_after_entry": Num(min=0), "approved_personas": Arr(ID), "approval": _APPROVAL},
                                   opt={"quantile": Num(min=0.5, max=1), "notes": AnyValue()}),
        "research": Obj(req={
            "none": ID, "cap": ID, "natural": ID, "final_field": ID, "ci_level": Num(min=0.5, max=0.999),
            "min_pairs": Int(min=1), "cap_max_shortening": Num(min=0, max=1), "cap_approval": _APPROVAL,
            "cap_cumulative_info_band": Arr(Num(min=0, max=1), min_items=2), "natural_min_gain": Num(min=0, max=1),
            "natural_approval": _APPROVAL, "noresearch_p50_max_day": Num(min=0), "noresearch_p90_max_day": Num(min=0),
            "noresearch_approval": _APPROVAL, "noresearch_reach_min_rate": Num(min=0, max=1), "noresearch_reach_approval": _APPROVAL,
            "rp_period_days": Arr(Int(min=1), min_items=1)}, opt={"skip": ID}),
        # 段階 5（2026-11-10）: 捕獲・芯・活力・消費先の新指標（全て draft/INFO）
        "capture_sinks": Obj(req={
            "approval": _APPROVAL, "early_days": Int(min=1), "wick_shortage_max": Num(min=0, max=1), "wick_shortage_personas": Arr(ID),
            "finite_complete_persona": ID, "finite_complete_day_min": Num(min=0), "finite_complete_day_max": Num(min=0),
            "finite_progress_days": Arr(Int(min=1), min_items=1), "sink_absorption_from_day": Int(min=1),
            "conformance_min_encounters": Int(min=1),
            "wick_unlimited_pairs": Arr(Obj(req={"base": ID, "test": ID})), "ablation_pairs": Arr(Obj(req={"base": ID, "test": ID})),
        }, opt={"notes": AnyValue(),
                # 捕獲補助道具（2026-11-11）: 狩り素材の残高を見る日（INFO）
                "tool_balance_days": Arr(Int(min=1), min_items=1)})})


# ---- 統計 ----


def quantile_censored(values: list[float | None], p: float) -> float | None:
    """最近順位法の分位数。None（未到達）は +∞ として並べ、分位点が ∞ なら None を返す."""
    if not values:
        return None
    vals = sorted(math.inf if v is None else v for v in values)
    v = vals[max(0, math.ceil(p * len(vals)) - 1)]
    return None if math.isinf(v) else v


def wilson(k: int, n: int, z: float = 1.959964) -> tuple[float | None, float | None]:
    if n == 0:
        return None, None
    p = k / n
    denom = 1 + z * z / n
    center = (p + z * z / (2 * n)) / denom
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denom
    return max(0.0, center - half), min(1.0, center + half)


def median_ci(values: list[float], level: float = 0.95) -> tuple[float | None, float | None, float | None]:
    """中央値と分布によらない順位信頼区間（二項分布 B(n, 1/2) の正確計算、標準ライブラリ・決定的）.

    j = P(B ≤ j) ≤ (1−level)/2 を満たす最大の j とし、区間 = [x_(j+1), x_(n−j)]（1 始まりの順位統計量）。
    被覆確率は 1 − 2·P(B ≤ j) ≥ level。n が小さく j が無ければ区間は None。中央値は他の判定と同じ最近順位法。
    """
    v = sorted(values)
    n = len(v)
    if n == 0:
        return None, None, None
    med = quantile_censored(v, 0.5)
    alpha2 = (1 - Fraction(str(level))) / 2
    total = 2 ** n
    cum, j = 0, -1
    for i in range(n + 1):
        cum += math.comb(n, i)
        if Fraction(cum, total) <= alpha2:
            j = i
        else:
            break
    if j < 0:
        return med, None, None
    return med, v[j], v[n - 1 - j]


def f(x: float | None, places: int = 3) -> str:
    return "" if x is None else format(x, f".{places}f")


def median(values: list[float]) -> float | None:
    return quantile_censored(list(values), 0.5) if values else None


# ---- 読み込み ----


def _rows(path: Path) -> Iterable[dict[str, str]]:
    with open(path, encoding="utf-8", newline="") as fh:
        yield from csv.DictReader(fh)


class RunData:
    def __init__(self, out_dir: Path, model: Model, manifest: dict[str, Any] | None = None):
        manifest = manifest or {}
        self.model = model
        self.personas: list[str] = []
        self.reps: dict[str, list[int]] = {}
        self.days = 0
        self.share: dict[tuple[str, int], list[float]] = {}
        self.storage: dict[tuple[str, int], list[float]] = {}
        self.g2: dict[str, dict[str, dict[str, float]]] = {}  # basis(best/actual) → persona → 集計
        self.g2_field: dict[tuple[str, str], list[float]] = {}  # (persona, 最高フィールド) → [Σ R×分, 分]（最善配置基準）
        self.hunt_daily: dict[tuple[str, int], list[tuple[int, dict[str, float], dict[str, float], list[float]]]] = {}
        self.hunt_wallet: dict[tuple[str, int], dict[str, float]] = {}
        self.basic_cum: dict[tuple[str, int], dict[int, float]] = {}
        self.lost: dict[str, list[int]] = {}
        self.capture_minutes: dict[str, int] = {}
        hunt_ids = model.hunt_resource_ids()
        basic = model.basic_ids
        cum: dict[tuple[str, int], float] = {}
        # 研究ポイント（kind=research）: (persona, rep) → [(日, 獲得, 支出, 残高)]
        self.rp_id = model.research_resource
        self.rp_daily: dict[tuple[str, int], list[tuple[int, float, float, float]]] = {}
        # 段階 5 の捕獲・芯・活力・消費先の集計（同じ走査で集める）
        cs_cfg = manifest.get("capture_sinks_cfg", {})
        self.cs = metrics_capture.CaptureSinkData(model, int(cs_cfg.get("early_days", 14)), int(cs_cfg.get("sink_absorption_from_day", 21)),
                                                  tuple(cs_cfg.get("finite_progress_days", [30, 60])),
                                                  tuple(cs_cfg.get("tool_balance_days", [14, 30, 60])))
        self.cs.finite_total = sum(1 for r in model.hub["ranks"] if r["rank"] > 1) + len((model.sinks or {}).get("items", []))
        # 捕獲補助道具の指標は capture_tool != off のペルソナがあるときだけ出す（manifest の personas 記録、無い古い run は off 扱い）
        self.cs.tool_personas = {p["id"] for p in manifest.get("personas", []) or []
                                 if isinstance(p, dict) and p.get("capture_tool", "off") != "off"}
        for r in _rows(out_dir / "daily.csv"):
            pid, rep, day = r["persona_id"], int(r["replicate_id"]), int(r["day"])
            if pid not in self.reps:
                self.personas.append(pid)
                self.reps[pid] = []
            if day == 1:
                self.reps[pid].append(rep)
            self.days = max(self.days, day)
            if r["direct_share_basic"]:
                self.share.setdefault((pid, day), []).append(float(r["direct_share_basic"]))
            self.storage.setdefault((pid, day), []).append(int(r["spirit_count"]) / int(r["capacity"]))
            for basis in ("best", "actual"):
                g = self.g2.setdefault(basis, {}).setdefault(pid, dict.fromkeys(G2_SUM_KEYS, 0.0) | {"max_outside": 0.0, "max_transition": 0.0})
                mins = int(r[f"g2_{basis}_r_minutes"])
                if mins:
                    g["r_sum"] += float(r[f"g2_{basis}_r_mean"]) * mins
                    g["max_outside"] = max(g["max_outside"], float(r[f"g2_{basis}_r_max_outside"]))
                    g["max_transition"] = max(g["max_transition"], float(r[f"g2_{basis}_r_max_transition"]))
                    if basis == "best":
                        fb = self.g2_field.setdefault((pid, r["highest_field"]), [0.0, 0])
                        fb[0] += float(r["g2_best_r_mean"]) * mins
                        fb[1] += mins
                g["r_minutes"] += mins
                for k in ("over_max_minutes", "over_max_transition_minutes", "undefined_minutes", "undefined_transition_minutes"):
                    g[k] += int(r[f"g2_{basis}_{k}"])
                g["gather_min"] += int(r["gather_min"])
            # 狩り素材: 日別の方置（F1）・全経路の獲得、等級別方置、期末残高（期間別比重・積み上がりの報告用）
            idle_h = {h: float(r[f"earned_idle_{h}"]) for h in hunt_ids}
            all_h = {h: sum(float(r[f"earned_{s_}_{h}"]) for s_ in SOURCES) for h in hunt_ids}
            grades = [float(r[f"home_g{g_}"]) for g_ in (1, 2, 3, 4)]
            self.hunt_daily.setdefault((pid, rep), []).append((day, idle_h, all_h, grades))
            self.hunt_wallet[(pid, rep)] = {h: float(r[f"wallet_{h}"]) for h in hunt_ids}
            key = (pid, rep)
            cum[key] = cum.get(key, 0.0) + sum(float(r[f"earned_{s}_{res}"]) for s in SOURCES for res in basic)
            self.basic_cum.setdefault(key, {})[day] = cum[key]
            if self.rp_id and f"wallet_{self.rp_id}" in r:
                rp = self.rp_id
                self.rp_daily.setdefault((pid, rep), []).append(
                    (day, sum(float(r[f"earned_{s_}_{rp}"]) for s_ in SOURCES), float(r[f"spent_{rp}"]), float(r[f"wallet_{rp}"])))
            lst = self.lost.setdefault(pid, [0, 0])
            lst[0] += int(r["offline_lost_min"])
            lst[1] += 1
            self.capture_minutes[pid] = self.capture_minutes.get(pid, 0) + int(r["capture_min"])
            self.cs.add(r)
        # (persona, type, target) → rep → (日, 分, 試行数)
        self.events: dict[tuple[str, str, str], dict[int, tuple[int | None, int | None, int | None]]] = {}
        self.purchases: dict[tuple[str, str], int] = {}  # (persona, 商品) → 全反復の購入回数
        self.censor_minutes = 0
        for r in _rows(out_dir / "events.csv"):
            if r["event_type"] in ("purchase", "pass_claim", "research_start"):
                if r["event_type"] == "purchase":
                    k = (r["persona_id"], r["target_id"])
                    self.purchases[k] = self.purchases.get(k, 0) + 1
                continue
            obs = r["observed"] == "true"
            key = (r["persona_id"], r["event_type"], r["target_id"])
            self.events.setdefault(key, {})[int(r["replicate_id"])] = (
                int(r["event_day"]) if obs else None, int(r["event_time_minutes"]) if obs else None,
                int(r["attempt_count"]) if (obs and r["attempt_count"]) else None)
            self.censor_minutes = int(r["censor_time_minutes"])
        self.spirit: dict[tuple[str, int, str], dict[str, str]] = {}
        for r in _rows(out_dir / "spirit_daily.csv"):
            self.spirit[(r["persona_id"], int(r["day"]), r["species_id"])] = r
        self.allocation = list(_rows(out_dir / "allocation.csv")) if (out_dir / "allocation.csv").is_file() else []
        self.extract_days = [d for d in manifest.get("extract_days", [30, 60]) if d <= self.days] or [self.days]
        self.start_species = set(manifest.get("start_spirits", []))
        self.r_threshold = manifest.get("g2_r_threshold")
        self.transition_minutes = manifest.get("g2_transition_minutes")

    def event_days(self, pid: str, etype: str, target: str) -> list[int | None]:
        d = self.events.get((pid, etype, target), {})
        return [d.get(rep, (None, None, None))[0] for rep in self.reps.get(pid, [])]

    def reached_by(self, pid: str, etype: str, target: str, day: int) -> tuple[int, int]:
        vals = self.event_days(pid, etype, target)
        return sum(1 for v in vals if v is not None and v <= day), len(vals)

    def game_start(self, pid: str, rep: int) -> int:
        e = self.events.get((pid, "game_start", "first_session"), {}).get(rep)
        return e[1] if e and e[1] is not None else 0


# ---- 集計 ----


class Checks:
    def __init__(self) -> None:
        self.rows: list[list[str]] = []

    def add(self, check_id: str, cohort: str, metric: str, statistic: str, estimate: str, n: int | str, lo: str, hi: str,
            threshold: str, evaluation: str, approval: str, evidence: str, reason: str = "") -> None:
        self.rows.append([check_id, cohort, metric, statistic, estimate, str(n), lo, hi, threshold, evaluation, approval, evidence, reason])


def _rate_eval(k: int, n: int, threshold: float, higher_is_good: bool, fail_word: str = "WARN") -> tuple[str, str, str]:
    lo, hi = wilson(k, n)
    if lo is None:
        return "INCONCLUSIVE", "", ""
    if higher_is_good:
        ev = "PASS" if lo >= threshold else (fail_word if hi < threshold else "INCONCLUSIVE")
    else:
        ev = "PASS" if hi <= threshold else (fail_word if lo > threshold else "INCONCLUSIVE")
    return ev, f(lo, 3), f(hi, 3)


def grade_shares(rd: RunData, pid: str, day: int) -> tuple[dict[int, float], dict[str, float]]:
    by_species = {}
    for sp in rd.model.spirit_order:
        r = rd.spirit.get((pid, day, sp))
        by_species[sp] = float(r["facility_slot_minutes_mean"]) if r else 0.0
    total = sum(by_species.values())
    if total <= 0:
        return {}, {}
    sp_share = {sp: v / total for sp, v in by_species.items()}
    g_share: dict[int, float] = {}
    for sp, v in sp_share.items():
        g = rd.model.spirits[sp]["grade"]
        g_share[g] = g_share.get(g, 0.0) + v
    return g_share, sp_share


def paired_shortening(rd: RunData, free: str, paid: str, fid: str) -> dict[str, Any]:
    """課金短縮率 1 − T_paid/T_free（分単位、ゲーム開始から）。無課金未到達は T_free ≥ 打ち切り時刻の下限として含める."""
    reps = sorted(set(rd.reps.get(free, [])) & set(rd.reps.get(paid, [])))
    fd = rd.events.get((free, "field_unlock", fid), {})
    pd = rd.events.get((paid, "field_unlock", fid), {})
    vals: list[float] = []
    both = free_censored = paid_censored = neither = 0
    for r in reps:
        tf, tp = fd.get(r, (None, None, None))[1], pd.get(r, (None, None, None))[1]
        sf, sp_ = rd.game_start(free, r), rd.game_start(paid, r)
        if tf is not None and tp is not None:
            both += 1
            vals.append(1 - (tp - sp_) / max(1, tf - sf))
        elif tf is None and tp is not None:
            free_censored += 1  # T_free ≥ censor → 短縮率の下限
            vals.append(1 - (tp - sp_) / max(1, rd.censor_minutes - sf))
        elif tf is not None:
            paid_censored += 1  # 課金側が遅い（短縮なし）
            vals.append(1 - (rd.censor_minutes - sp_) / max(1, tf - sf))
        else:
            neither += 1
    fv = [fd.get(r, (None,))[0] for r in reps]
    pv = [pd.get(r, (None,))[0] for r in reps]
    return {"field": fid, "n": len(reps), "both": both, "free_censored": free_censored, "paid_censored": paid_censored,
            "neither": neither, "shortening": median(vals), "free_p50": quantile_censored(fv, 0.5),
            "paid_p50": quantile_censored(pv, 0.5), "free_reach": sum(v is not None for v in fv),
            "paid_reach": sum(v is not None for v in pv)}


def compute(rd: RunData, crit: dict[str, Any], ref: dict[str, Any], validation_errors: int) -> dict[str, Any]:
    m = rd.model
    sc = crit["sim"]
    issues: list[Issue] = []
    SIM_CRITERIA_SCHEMA.check(sc, "criteria.json:/sim", issues)
    if issues:
        raise ValueError("\n".join(i.format() for i in issues))
    appr = sc["approval"]
    ck = Checks()
    horizon = rd.days
    d_first = rd.extract_days[0]

    def sim_ev(n: int) -> str:
        return f"simulated_n={n}"

    ck.add("rule_validation", "data", "validator_errors", "count", str(validation_errors), "", "", "", "0",
           "PASS" if validation_errors == 0 else "FAIL", "approved", "validator", "유료 랜덤 경로·금지 상품·2주판 접근성 등 규칙 검사")

    # G2（閾値ごとに行を分ける）
    g = crit["g2"]
    max_r = g["max_ratio"]
    trans = int(g.get("transition_minutes", 0))
    threshold_ok = (rd.r_threshold is None or abs(float(rd.r_threshold) - float(max_r)) < 1e-12) and \
        (rd.transition_minutes is None or int(rd.transition_minutes) == trans)
    mismatch = f"run 시 R 임계값/전환 구간({rd.r_threshold}/{rd.transition_minutes}) ≠ criteria({max_r}/{trans}): run 재실행 필요"
    g2_approved = sc.get("g2_approved_personas", sc["g2_personas"])
    for pid in sc["g2_personas"]:
        if pid not in rd.g2.get("best", {}):
            continue
        # 承認対象外のペルソナ（例: light_1h）は参考値(INFO)として報告する（ユーザー決定 2026-11-09）
        ref_only = pid not in g2_approved
        ref_note = "참고 페르소나(판정 대상 외). " if ref_only else ""
        b, a = rd.g2["best"][pid], rd.g2["actual"][pid]
        n = len(rd.reps[pid])
        share = b["over_max_minutes"] / b["r_minutes"] if b["r_minutes"] else None
        if not threshold_ok:
            ev, reason = "INCONCLUSIVE", mismatch
        else:
            ev = "INCONCLUSIVE" if share is None else ("FAIL" if b["over_max_minutes"] > 0 else "PASS")
            if ref_only and ev != "INCONCLUSIVE":
                ev = "INFO"
            reason = (f"{ref_note}판정=현재 보유 정령의 최선 배치 기준 R. 전환 구간({trans}분) 밖 R>{max_r} 비중, "
                      f"구간 밖 최대 R={b['max_outside']:.3f}(구간 안 최대 {b['max_transition']:.3f})")
        ck.add("g2_r_over_max", pid, "g2_r_best", f"share_of_gather_minutes_R>{max_r}_outside_transition", f(share, 4), n, "", "", "0",
               ev, g["max_ratio_approval"], sim_ev(n), reason)
        ushare = b["undefined_minutes"] / b["gather_min"] if b["gather_min"] else None
        ck.add("g2_r_undefined", pid, "g2_r_best", "share_of_gather_minutes_idle0_outside_transition", f(ushare, 4), n, "", "", "0",
               "INCONCLUSIVE" if (ushare is None or not threshold_ok) else ("INFO" if ref_only else ("FAIL" if b["undefined_minutes"] > 0 else "PASS")),
               g["max_ratio_approval"], sim_ev(n),
               f"전환 구간 밖에서 최선 배치로도 방치 0인 자원을 직접 채집한 분 {int(b['undefined_minutes'])}(R=∞로 보고 FAIL)")
        ck.add("g2_r_transition", pid, "g2_r_best", "transition_minutes_over_max/undefined",
               f"{int(b['over_max_transition_minutes'])}/{int(b['undefined_transition_minutes'])}", n, "", "",
               f"허용(해금 후 {trans}분)", "INFO", g.get("transition_approval", appr), sim_ev(n),
               f"전환 구간 안의 R>{max_r} 분·R 미정의 분(전체 채집 분 {int(b['gather_min'])}, 반복 합계)")
        a_share = a["over_max_minutes"] / a["r_minutes"] if a["r_minutes"] else None
        ck.add("g2_r_actual_reference", pid, "g2_r_actual", "share_R>max_outside/max_outside/undefined_outside",
               f"{f(a_share, 4)}/{a['max_outside']:.3f}/{int(a['undefined_minutes'])}", n, "", "", "참고", "INFO", appr, sim_ev(n),
               f"실제 배치(시뮬 정책이 고른 배치) 기준 R. 구간 안 최대 {a['max_transition']:.3f}")
        mean = b["r_sum"] / b["r_minutes"] if b["r_minutes"] else None
        ck.add("g2_r_mean_max", pid, "g2_r_best", "gather_minute_weighted_mean", f(mean, 3), n, "", "", f"≤{max_r}",
               "INCONCLUSIVE" if mean is None else ("FAIL" if mean > max_r else "PASS"), g["max_ratio_approval"], sim_ev(n), "")
        lo_b, hi_b = g.get("field_band_min", g["warn_below_ratio"]), g.get("field_band_max", max_r)
        for fid in rd.model.field_order:
            fb = rd.g2_field.get((pid, fid))
            if not fb or not fb[1]:
                continue
            fm = fb[0] / fb[1]
            ck.add("g2_r_field_band", f"{pid}:{fid}", "g2_r_best", "gather_minute_weighted_mean_by_highest_field", f(fm, 3), n, "", "",
                   f"{lo_b}~{hi_b}", "PASS" if lo_b <= fm <= hi_b else "WARN", g.get("field_band_approval", "draft"), sim_ev(n),
                   f"그 필드가 최고 해금 필드인 동안의 채집 가중 R(채집 {int(fb[1])}분)")
    for pid in rd.personas:
        early = [v for d in (1, 2, 3) for v in rd.share.get((pid, d), [])]
        n = len(rd.reps[pid])
        for label, vals in (("day1_3_mean", early), (f"day{d_first}_median", rd.share.get((pid, d_first), []))):
            est = (sum(vals) / len(vals)) if (vals and "mean" in label) else median(vals)
            ck.add("g2_direct_share_S", pid, "direct_share_basic", label, f(est, 4), n, "", "", "보고용", "INFO", appr, sim_ev(n),
                   "하루 기본 재료 중 직접 채집 비중(합격 기준 아님)")

    # G3（静的換算: 承認範囲 / 依頼待ち: 草案）
    hdr, g3rows = static_analysis.g3_hunt_minutes(m, ref, crit)
    mi = hdr.index("minutes_ref")
    wi = hdr.index("idle_wait_evaluation")
    g3 = crit["g3"]
    lo_m, hi_m = g3["pass_min_minutes"], g3["pass_max_minutes"]
    mins_list = [float(r[mi]) for r in g3rows if r[mi]]
    inside = sum(1 for v in mins_list if lo_m <= v <= hi_m)
    ck.add("g3_hunt_minutes", "data", "g3_minutes", "requirements_in_range", f"{inside}/{len(g3rows)}", len(g3rows), "", "",
           f"{lo_m}~{hi_m}분", "PASS" if inside == len(g3rows) else "FAIL", g3["pass_approval"], "static_reference",
           f"범위 {min(mins_list, default=0):.1f}~{max(mins_list, default=0):.1f}분(추천 전투력 기준)")
    # 사용자 결정: 필드 해금 비용은 '일일 의뢰 3일분' 규칙 대상이 아니다（INFO で別掲）
    ki = hdr.index("source_kind")
    waits = [r[wi] for r in g3rows if r[ki] != "field_unlock"]
    unlock_waits = [f"{r[hdr.index('source_id')]}:" + (f"{r[hdr.index('idle_wait_days')]}일" if r[hdr.index('idle_wait_days')] else "불가")
                    for r in g3rows if r[ki] == "field_unlock"]
    ck.add("g3_idle_wait", "data", "g3_idle_wait_days", "requirements_within_limit(excl_field_unlock)",
           f"{waits.count('PASS')}/{len(waits)}", len(waits), "", "", f"≤{g3['idle_wait_days_max']}일",
           "PASS" if waits.count("PASS") == len(waits) else "WARN", g3["idle_wait_approval"], "static_reference",
           "일일 의뢰(해금 최고 필드 재료)만으로 요구 1건을 모으는 일수(필드 해금 비용 제외)")
    ck.add("g3_idle_wait_field_unlock", "data", "g3_idle_wait_days", "field_unlock_days", ", ".join(unlock_waits), len(unlock_waits),
           "", "", "대상 외", "INFO", g3["idle_wait_approval"], "static_reference", "필드 해금 비용은 3일 규칙 대상 외(사용자 결정)")

    # 解禁
    unlock_summary: dict[tuple[str, str], dict[str, Any]] = {}
    targets = {(t["persona_id"], t["field_id"]): t for t in sc["unlock_targets"]}
    for pid in rd.personas:
        n = len(rd.reps[pid])
        for fid in m.field_order:
            if not m.fields[fid]["unlock"]["requires_fields"]:
                continue
            vals = rd.event_days(pid, "field_unlock", fid)
            kd, _ = rd.reached_by(pid, "field_unlock", fid, d_first)
            kh, _ = rd.reached_by(pid, "field_unlock", fid, horizon)
            p10, p50, p90 = (quantile_censored(vals, p) for p in (0.1, 0.5, 0.9))
            unlock_summary[(pid, fid)] = {"p10": p10, "p50": p50, "p90": p90, "dfirst": kd / n if n else None, "dh": kh / n if n else None}
            lo, hi = wilson(kh, n)
            tgt = targets.get((pid, fid))
            reach = f"D{d_first} 도달률 {f(kd / n if n else None, 3)}, 기간 내 도달률 {f(kh / n if n else None, 3)}"
            if tgt is None:
                ck.add("unlock_day", f"{pid}:{fid}", "field_unlock_day", "p50/p90(blank=not_reached)", f"{f(p50, 0)}/{f(p90, 0)}", n,
                       f(lo, 3), f(hi, 3), "", "INFO", appr, sim_ev(n), "목표 해금일 없음; " + reach)
                continue
            lo_d, hi_d = tgt["p50_day"] * (1 - tgt["p50_tolerance"]), tgt["p50_day"] * (1 + tgt["p50_tolerance"])
            ck.add("unlock_p50_target", f"{pid}:{fid}", "field_unlock_day", "p50", f(p50, 0), n, "", "",
                   f"{lo_d:g}~{hi_d:g}일", "PASS" if (p50 is not None and lo_d <= p50 <= hi_d) else "FAIL", tgt["approval"],
                   sim_ev(n), reach)
            ck.add("unlock_p90_max", f"{pid}:{fid}", "field_unlock_day", "p90", f(p90, 0), n, "", "",
                   f"≤{tgt['p90_max_day']:g}일", "PASS" if (p90 is not None and p90 <= tgt["p90_max_day"]) else "FAIL",
                   tgt["approval"], sim_ev(n), reach)

    # 使用分布
    usage: dict[tuple[str, int], tuple[dict[int, float], dict[str, float]]] = {}
    for pid in rd.personas:
        for d in rd.extract_days:
            gs, ss = grade_shares(rd, pid, d)
            usage[(pid, d)] = (gs, ss)
            if not gs:
                continue
            n = len(rd.reps[pid])
            low = sum(v for gr, v in gs.items() if gr <= sc["usage_low_grade_max_grade"])
            ck.add("usage_low_grade_share", f"{pid}:D{d}", "facility_slot_minutes", f"grade<={sc['usage_low_grade_max_grade']}_share",
                   f(low, 3), n, "", "", f"≥{sc['usage_low_grade_min_share']}",
                   "PASS" if low >= sc["usage_low_grade_min_share"] else "WARN", appr, sim_ev(n) + ";found_placement",
                   "시뮬 배치는 휴리스틱으로 발견한 배치")
            top_sp = max(ss, key=lambda s: (ss[s], s))
            ck.add("usage_single_species_share", f"{pid}:D{d}", "facility_slot_minutes", "max_species_share",
                   f(ss[top_sp], 3), n, "", "", f"≤{sc['usage_single_species_max_share']}",
                   "PASS" if ss[top_sp] <= sc["usage_single_species_max_share"] else "WARN", appr, sim_ev(n) + ";found_placement",
                   f"최다 종 {top_sp}")

    # 捕獲（開始精霊は保有済みとして扱う）
    rel = m.releases.get(sc["capture_release_id"])
    if rel:
        by = sc["capture_by_day"]
        for pid in rd.personas:
            n = len(rd.reps[pid])
            if rd.capture_minutes.get(pid, 0) == 0:
                ck.add("capture_release_species", pid, "first_capture", "capture_minutes", "0", n, "", "", "", "INFO", appr,
                       sim_ev(n), "포획 활동 시간이 없는 페르소나(시작 정령만 보유)")
                continue
            for sp in rel["spirit_ids"]:
                start_owned = sp in rd.start_species
                k = n if start_owned else rd.reached_by(pid, "first_capture", sp, by)[0]
                ev, lo, hi = _rate_eval(k, n, sc["capture_min_rate"], True)
                ck.add("capture_release_species", f"{pid}:{sp}", "first_capture", f"acquired_by_D{by}",
                       f(k / n if n else None, 3), n, lo, hi, f"≥{sc['capture_min_rate']}", ev, appr, sim_ev(n),
                       f"{rel['name']} 정령 획득률(천장 없음)" + ("; 시작 정령으로 보유" if start_owned else ""))

    # 保管箱
    for item in sc["storage_full_min_day"]:
        pid = item["persona_id"]
        if pid not in rd.reps:
            continue
        vals = rd.event_days(pid, "storage_full", "storage")
        n = len(vals)
        p50 = quantile_censored(vals, 0.5)
        ck.add("storage_full_day", pid, "storage_full", "first_day_p50(blank=not_reached)", f(p50, 0), n, "", "", f"≥{item['day']}",
               "PASS" if (p50 is None or p50 >= item["day"]) else "WARN", appr, sim_ev(n),
               f"기간 내 도달률 {f(sum(v is not None for v in vals) / n if n else None, 3)}")

    # 課金比較（同じ replicate の対、分単位、打ち切り込み）
    pair = sc["paid_pair"]
    paid_rows: list[dict[str, Any]] = []
    if pair["free"] in rd.reps and pair["paid"] in rd.reps:
        for fid in m.field_order:
            if not m.fields[fid]["unlock"]["requires_fields"]:
                continue
            ps = paired_shortening(rd, pair["free"], pair["paid"], fid)
            paid_rows.append(ps)
            short = ps["shortening"]
            censored = ps["free_censored"] + ps["paid_censored"]
            if short is None:
                ev = "INCONCLUSIVE"
            elif short > sc["paid_max_shortening"]:
                ev = "FAIL"  # 打ち切り込みの値は真の短縮率の下限側なので、超過は確定
            elif ps["free_censored"]:
                ev = "INCONCLUSIVE"  # 下限が閾値以下でも真値は超えうる
            else:
                ev = "PASS"
            ck.add("paid_unlock_shortening", f"{pair['paid']}_vs_{pair['free']}:{fid}", "field_unlock_minutes",
                   "paired_median_1-Tpaid/Tfree", f(short, 3), ps["n"], "", "", f"≤{sc['paid_max_shortening']}", ev,
                   sc["paid_approval"], sim_ev(ps["n"]),
                   f"분 단위·게임 시작 기준; 양쪽 도달 {ps['both']}, 무과금 미도달(하한 포함) {ps['free_censored']}, "
                   f"과금 미도달 {ps['paid_censored']}, 둘 다 미도달(제외) {ps['neither']}" + ("; 검열 포함" if censored else ""))
        reps = sorted(set(rd.reps[pair["free"]]) & set(rd.reps[pair["paid"]]))
        for d in rd.extract_days:
            ratios = [rd.basic_cum[(pair["paid"], r)].get(d, 0) / rd.basic_cum[(pair["free"], r)].get(d, 1) - 1 for r in reps
                      if rd.basic_cum.get((pair["free"], r), {}).get(d)]
            ck.add("paid_basic_income_gap", f"{pair['paid']}_vs_{pair['free']}:D{d}", "cum_basic_earned", "paired_median_ratio-1",
                   f(median(ratios), 3), len(reps), "", "", "", "INFO", appr, sim_ev(len(reps)), "누적 기본 재료 획득량 차이(보고용)")

    # コンテンツ消化
    for item in sc["exhaustion_max_rate"]:
        pid = item["persona_id"]
        if pid not in rd.reps or item["day"] > horizon:
            continue
        k, n = rd.reached_by(pid, "content_exhausted", "all", item["day"])
        ev, lo, hi = _rate_eval(k, n, item["rate"], False)
        if sc.get("exhaustion_info_only"):
            ev = "INFO"  # MVP（4 フィールド）は D30 消化を許容し、新フィールド更新で対応（ユーザー決定 2026-11-09）
        ck.add("content_exhausted_rate", f"{pid}:D{item['day']}", "content_exhausted", "rate", f(k / n if n else None, 3), n, lo, hi,
               f"≤{item['rate']}", ev, appr, sim_ev(n), "소진=모든 필드+시설·슬롯·도구·거점·오프라인 최대(정령 레벨 제외)")

    # F1: 狩り素材のうち方置（固有フィールド精霊）比重を期間・フィールド・等級別に（ユーザー意図: 序盤はプレイ中心、後半 50〜60% も可）
    last_field = rd.model.field_order[-1]
    early_end = sc.get("hunt_idle_early_days", 14)
    for pid in rd.personas:
        n = len(rd.reps[pid])
        periods = {"until_last_field": [0.0, 0.0], f"D1-{early_end}": [0.0, 0.0], f"D{early_end + 1}+": [0.0, 0.0]}
        by_field: dict[str, list[float]] = {}
        by_grade = [0.0, 0.0, 0.0, 0.0]
        for rep in rd.reps[pid]:
            last_day = rd.events.get((pid, "field_unlock", last_field), {}).get(rep, (None,))[0]
            for day, idle_h, all_h, grades in rd.hunt_daily.get((pid, rep), []):
                i, t = sum(idle_h.values()), sum(all_h.values())
                if last_day is None or day <= last_day:
                    periods["until_last_field"][0] += i
                    periods["until_last_field"][1] += t
                key = f"D1-{early_end}" if day <= early_end else f"D{early_end + 1}+"
                periods[key][0] += i
                periods[key][1] += t
                for h in idle_h:
                    fb = by_field.setdefault(h, [0.0, 0.0])
                    fb[0] += idle_h[h]
                    fb[1] += all_h[h]
                for k in range(4):
                    by_grade[k] += grades[k]
        for label, (i, t) in periods.items():
            ck.add("hunt_material_idle_share", f"{pid}:{label}", "hunt_material_earned", "idle(F1)/all_sources", f(i / t if t else None, 3),
                   n, "", "", "보고용", "INFO", appr, sim_ev(n), "사냥 재료 획득 중 고유 필드 정령 방치 생산 비중(기간별)")
        ck.add("hunt_material_idle_share_by_field", pid, "hunt_material_earned", "idle/all_by_resource",
               ", ".join(f"{h} {v[0] / v[1]:.2f}" for h, v in by_field.items() if v[1]), n, "", "", "보고용", "INFO", appr, sim_ev(n),
               "자원(필드)별 방치 비중")
        tg = sum(by_grade)
        ck.add("hunt_material_idle_by_grade", pid, "home_material_by_grade", "share_of_idle_hunt_material",
               ", ".join(f"★{k + 1} {v / tg:.2f}" for k, v in enumerate(by_grade)) if tg else "", n, "", "", "보고용", "INFO", appr,
               sim_ev(n), "방치 생산 사냥 재료의 등급별 구성")
        ends = [rd.hunt_wallet[(pid, rep)] for rep in rd.reps[pid] if (pid, rep) in rd.hunt_wallet]
        if ends:
            ck.add("hunt_material_stock_end", pid, "wallet_hunt_material", f"median_at_D{horizon}",
                   ", ".join(f"{h} {median([e[h] for e in ends]):.0f}" for h in ends[0]), n, "", "", "허용(적체)", "INFO", appr, sim_ev(n),
                   "기간 끝의 사냥 재료 보유량(모든 필드 해금 후 적체는 허용, 사용자 결정)")

    # 헤비 유저 선행(초안): 최종 필드 해금 p50 이 기준 페르소나보다 min_days 이상 빠른가
    lead = sc.get("lead")
    if lead and lead["fast"] in rd.reps and lead["base"] in rd.reps:
        fp = quantile_censored(rd.event_days(lead["fast"], "field_unlock", lead["field_id"]), 0.5)
        bp = quantile_censored(rd.event_days(lead["base"], "field_unlock", lead["field_id"]), 0.5)
        diff = None if (fp is None or bp is None) else bp - fp
        ck.add("heavy_user_lead", f"{lead['fast']}_vs_{lead['base']}:{lead['field_id']}", "field_unlock_day", "p50_base-p50_fast",
               f(diff, 0), len(rd.reps[lead["fast"]]), "", "", f"≥{lead['min_days']}일",
               "INCONCLUSIVE" if diff is None else ("PASS" if diff >= lead["min_days"] else "WARN"), lead["approval"],
               sim_ev(len(rd.reps[lead["fast"]])), f"{lead['fast']} p50 {f(fp, 0)}일, {lead['base']} p50 {f(bp, 0)}일")

    # ★4 첫 획득: 그 종이 나오는 필드 첫 진입일부터의 일수の上側分位（既定 p99、criteria の quantile で変更。balanced のみ承認対象、他は INFO）
    s4 = sc.get("star4_first_capture")
    if s4:
        s4_q = s4.get("quantile", 0.99)
        s4_label = f"p{s4_q * 100:g}"
        for pid in rd.personas:
            n = len(rd.reps[pid])
            for sp in rd.model.spirit_order:
                if rd.model.spirits[sp]["grade"] != 4 or sp in rd.start_species:
                    continue
                entry_field = next((fid for fid in rd.model.field_order
                                    if any(e["spirit_id"] == sp and e["weight"] > 0 for e in rd.model.fields[fid]["capture"]["table"])), None)
                delays: list[float | None] = []
                for rep in rd.reps[pid]:
                    if rd.model.fields[entry_field]["unlock"]["requires_fields"]:
                        entry = rd.events.get((pid, "field_unlock", entry_field), {}).get(rep, (None,))[0]
                    else:
                        entry = 1
                    if entry is None:
                        continue  # 필드 미진입 반복은 대상 외
                    cap = rd.events.get((pid, "first_capture", sp), {}).get(rep, (None,))[0]
                    delays.append(None if cap is None else cap - entry)
                p99 = quantile_censored(delays, s4_q)
                approved = pid in s4["approved_personas"]
                ev = "INFO" if not approved else ("PASS" if (p99 is not None and p99 <= s4["max_days_after_entry"]) else "FAIL")
                ck.add("star4_first_capture_p99", f"{pid}:{sp}", "first_capture_days_after_field_entry", f"{s4_label}(blank=not_reached)",
                       f(p99, 0), len(delays), "", "", f"≤{s4['max_days_after_entry']}일", ev, s4["approval"] if approved else appr,
                       sim_ev(len(delays)) + ("" if len(delays) >= sc["min_samples_tail"] else ";insufficient_samples"),
                       f"진입 필드 {entry_field}; 미획득 {sum(1 for d in delays if d is None)}회")

    for pid in rd.personas:
        lost, days = rd.lost[pid]
        ck.add("offline_lost_minutes", pid, "offline_lost_min", "mean_per_day", f(lost / days if days else None, 1), len(rd.reps[pid]),
               "", "", "", "INFO", appr, sim_ev(len(rd.reps[pid])), "오프라인 상한 초과로 생산하지 못한 분")

    research_rows = research_checks(rd, sc, ck) if sc.get("research") else {}
    capture_sink = metrics_capture.add_checks(rd, sc, ck)

    conv = convergence_summary(rd)
    for sp, info in conv["species"].items():
        ok = info["used_cases"] > 0 or info["max_loss"] >= sc["convergence_min_exclusion_loss_pct"]
        ck.add("convergence_species_role", sp, "exact_placement", "used_cases/max_exclusion_loss_pct",
               f"{info['used_cases']}/{info['max_loss']:.2f}", info["cases"], "", "",
               f"사용≥1 또는 손실≥{sc['convergence_min_exclusion_loss_pct']}%", "PASS" if ok else "WARN", appr,
               "exact_representative_states(proven)", "복제 무제한 재고 대표 상태의 시설 배치만(동행 제외), 해당 종이 등장하는 상태만")
    if conv["cases"]:
        est, n, note = heuristic_gap_summary(conv)
        ck.add("convergence_heuristic_gap", "representative_states", "placement_gap", "max_gap", est, n,
               "", "", "", "INFO", appr, "exact_representative_states(proven)", note)

    return {"checks": ck.rows, "unlock": unlock_summary, "usage": usage, "paid": paid_rows, "convergence": conv,
            "capture_sink": capture_sink,
            "research": research_rows}


# ---- 研究（R2: 上限試験・自然研究・無研究保証・短縮購入） ----


def _unlock_minute(rd: RunData, pid: str, fid: str, rep: int) -> int | None:
    """フィールド進入分（開始フィールドはゲーム開始）。未到達は None."""
    if not rd.model.fields[fid]["unlock"]["requires_fields"]:
        return rd.game_start(pid, rep)
    return rd.events.get((pid, "field_unlock", fid), {}).get(rep, (None, None, None))[1]


def segment_pairs(rd: RunData, test: str, base: str, a: str, b: str) -> dict[str, Any]:
    """同じ replicate 対の短縮率 1 − Δtest/Δbase（Δ = b 解禁分 − a 進入分、分単位）.

    打ち切りは paired_shortening と同じ慣例: base だけ b 未到達なら Δbase ≥ 打ち切り − ba として値を入れる（真の短縮率の
    下限）、test だけ未到達なら Δtest ≥ 打ち切り − ta（真の短縮率の上限）。両方未到達、またはどちらかが区間 a に
    未進入の対だけを除外し、件数を別に返す。
    """
    out: dict[str, Any] = {"vals": [], "both": 0, "base_censored": 0, "test_censored": 0, "neither": 0, "unentered": 0}
    censor = rd.censor_minutes
    for rep in sorted(set(rd.reps.get(test, [])) & set(rd.reps.get(base, []))):
        ta, tb = _unlock_minute(rd, test, a, rep), _unlock_minute(rd, test, b, rep)
        ba, bb = _unlock_minute(rd, base, a, rep), _unlock_minute(rd, base, b, rep)
        if tb is None and bb is None:
            out["neither"] += 1
            continue
        if ta is None or ba is None:
            out["unentered"] += 1
            continue
        if tb is not None and bb is not None:
            out["both"] += 1
        elif bb is None:
            out["base_censored"] += 1
            bb = censor
        else:
            out["test_censored"] += 1
            tb = censor
        out["vals"].append(1 - (tb - ta) / max(1, bb - ba))
    return out


def _censor_txt(sp: dict[str, Any]) -> str:
    return (f"양쪽 도달 {sp['both']}, 기준 미도달(하한값 포함) {sp['base_censored']}, 시험 미도달(상한값 포함) {sp['test_censored']}, "
            f"미도달 제외 {sp['neither'] + sp['unentered']}(둘 다 미도달 {sp['neither']}·구간 미진입 {sp['unentered']})")


def research_checks(rd: RunData, sc: dict[str, Any], ck: Checks) -> dict[str, Any]:
    rc = sc["research"]
    m = rd.model
    none, cap, nat, skip = rc["none"], rc["cap"], rc["natural"], rc.get("skip")
    level, min_pairs = rc["ci_level"], rc["min_pairs"]
    order = m.field_order
    final = rc["final_field"]
    segs = list(zip(order, order[1:]))
    out: dict[str, Any] = {"segments": [], "cumulative": {}}

    def sim_ev(n: int) -> str:
        return f"simulated_n={n}"

    def ci_txt(lo: float | None, hi: float | None) -> str:
        return f"{int(level * 100)}% 순위 CI [{f(lo)}, {f(hi)}]"

    # 上限試験: 区間ごとの中央値と CI 上端 ≤ 上限（CI が閾値をまたげば INCONCLUSIVE）。
    # base 未到達の値は真の短縮率の下限なので PASS を確定できない → INCONCLUSIVE。test 未到達の値は上限なので FAIL を確定できない
    thr = rc["cap_max_shortening"]
    if cap in rd.reps and none in rd.reps:
        for a, b in segs:
            sp = segment_pairs(rd, cap, none, a, b)
            vals = sp["vals"]
            med, lo, hi = median_ci(vals, level)
            if len(vals) < min_pairs or hi is None:
                ev = "INCONCLUSIVE"
            elif hi <= thr:
                ev = "INCONCLUSIVE" if sp["base_censored"] else "PASS"
            elif lo > thr:
                ev = "INCONCLUSIVE" if sp["test_censored"] else "FAIL"
            else:
                ev = "INCONCLUSIVE"
            out["segments"].append({"segment": f"{a}->{b}", "median": med, "lo": lo, "hi": hi, "n": len(vals)})
            ck.add("research_cap_shortening", f"{cap}_vs_{none}:{a}->{b}", "field_segment_minutes",
                   "paired_median_1-dcap/dnone", f(med), len(vals), f(lo), f(hi), f"중앙값·CI 상단 ≤{thr}", ev, rc["cap_approval"],
                   sim_ev(len(vals)), f"Δ=다음 필드 해금 분−현재 필드 진입 분(같은 replicate 짝). {ci_txt(lo, hi)}; {_censor_txt(sp)}")
        sp = segment_pairs(rd, cap, none, order[0], final)
        med, lo, hi = median_ci(sp["vals"], level)
        band = rc["cap_cumulative_info_band"]
        out["cumulative"]["cap"] = (med, lo, hi, len(sp["vals"]))
        ck.add("research_cap_cumulative", f"{cap}_vs_{none}:{order[0]}->{final}", "field_unlock_minutes",
               "paired_median_1-Tcap/Tnone", f(med), len(sp["vals"]), f(lo), f(hi), f"참고 {band[0]}~{band[1]}", "INFO", rc["cap_approval"],
               sim_ev(len(sp["vals"])), f"게임 시작→{final} 누적 단축(목표 참고값). {ci_txt(lo, hi)}; {_censor_txt(sp)}")
    # 自然研究の利得: 能線累積短縮の中央値 ≥ 下限（test 未到達=上限値があれば PASS、base 未到達=下限値があれば FAIL を確定しない）
    if nat in rd.reps and none in rd.reps:
        sp = segment_pairs(rd, nat, none, order[0], final)
        vals = sp["vals"]
        med, lo, hi = median_ci(vals, level)
        out["cumulative"]["natural"] = (med, lo, hi, len(vals))
        gmin = rc["natural_min_gain"]
        if med is None or len(vals) < min_pairs:
            ev = "INCONCLUSIVE"
        elif med >= gmin:
            ev = "INCONCLUSIVE" if sp["test_censored"] else "PASS"
        else:
            ev = "INCONCLUSIVE" if sp["base_censored"] else "FAIL"
        ck.add("research_natural_gain", f"{nat}_vs_{none}:{order[0]}->{final}", "field_unlock_minutes", "paired_median_1-Tnat/Tnone",
               f(med), len(vals), f(lo), f(hi), f"중앙값 ≥{gmin}", ev, rc["natural_approval"], sim_ev(len(vals)),
               f"자연 연구 순단축(사용자 결정 3%). {ci_txt(lo, hi)}(판정은 중앙값); {_censor_txt(sp)}")
        for a, b in segs:
            sp = segment_pairs(rd, nat, none, a, b)
            med, lo, hi = median_ci(sp["vals"], level)
            ck.add("research_natural_segment", f"{nat}_vs_{none}:{a}->{b}", "field_segment_minutes", "paired_median_1-dnat/dnone",
                   f(med), len(sp["vals"]), f(lo), f(hi), "참고", "INFO", rc["natural_approval"], sim_ev(len(sp["vals"])),
                   f"{ci_txt(lo, hi)}; {_censor_txt(sp)}")
    # 無研究経路の保証: 到達率・p50・p90
    if none in rd.reps:
        n = len(rd.reps[none])
        vals = rd.event_days(none, "field_unlock", final)
        p50, p90 = quantile_censored(vals, 0.5), quantile_censored(vals, 0.9)
        k = sum(1 for v in vals if v is not None)
        ev_r, lo_r, hi_r = _rate_eval(k, n, rc["noresearch_reach_min_rate"], True, "FAIL")
        ck.add("noresearch_unlock", f"{none}:{final}:reach", "field_unlock", f"reached_by_D{rd.days}", f(k / n if n else None), n,
               lo_r, hi_r, f"≥{rc['noresearch_reach_min_rate']}", ev_r, rc["noresearch_reach_approval"], sim_ev(n),
               "기간 내 도달률(Wilson 95%). 임계값 0.9는 p90 기준에서 정한 구현 판단(draft)")
        ck.add("noresearch_unlock", f"{none}:{final}:p50", "field_unlock_day", "p50", f(p50, 0), n, "", "",
               f"≤{rc['noresearch_p50_max_day']}일", "PASS" if (p50 is not None and p50 <= rc["noresearch_p50_max_day"]) else "FAIL",
               rc["noresearch_approval"], sim_ev(n), "연구 없이도 능선 목표 범위 안")
        ck.add("noresearch_unlock", f"{none}:{final}:p90", "field_unlock_day", "p90", f(p90, 0), n, "", "",
               f"≤{rc['noresearch_p90_max_day']}일", "PASS" if (p90 is not None and p90 <= rc["noresearch_p90_max_day"]) else "FAIL",
               rc["noresearch_approval"], sim_ev(n), "")
    # 研究短縮購入（決定 C3）: 無研究を共通分母にした %p 差と自然研究比の相対短縮を別々に、対ごとの差の中央値
    # MVP では研究短縮商品を除外（ユーザー決定 2026-11-09、測定利得 0）。criteria に skip ペルソナがあるときだけ出力する
    if skip and all(p in rd.reps for p in (none, nat, skip)):
        pp, rel, excluded = [], [], 0
        for rep in sorted(set(rd.reps[none]) & set(rd.reps[nat]) & set(rd.reps[skip])):
            t = {p: (_unlock_minute(rd, p, final, rep), _unlock_minute(rd, p, order[0], rep)) for p in (none, nat, skip)}
            if any(v[0] is None for v in t.values()):
                excluded += 1
                continue
            tn, tt, ts = (t[p][0] - t[p][1] for p in (none, nat, skip))
            pp.append((tt - ts) / tn)
            rel.append(1 - ts / tt)
        n_buy = getattr(rd, "purchases", {}).get((skip, next((pid for pid, p in m.products.items() if p["kind"] == "research_time_skip"), "")), 0)
        reps_n = len(rd.reps[skip]) or 1
        med_pp, lo_pp, hi_pp = median_ci(pp, level)
        med_rel, lo_rel, hi_rel = median_ci(rel, level)
        cap_c = out["cumulative"].get("cap")
        nat_c = out["cumulative"].get("natural")
        bound = "" if not (cap_c and nat_c and cap_c[0] is not None and nat_c[0] is not None) else \
            f"; 참고 상한 s_cap−s_nat(중앙값끼리) {cap_c[0] - nat_c[0]:.3f}"
        ck.add("research_skip_gain", f"{skip}_vs_{nat}:{order[0]}->{final}", "field_unlock_minutes",
               "paired_median_(Tnat-Tskip)/Tnone", f(med_pp), len(pp), f(lo_pp), f(hi_pp), "보고용", "INFO", sc.get("approval", "draft"),
               sim_ev(len(pp)), f"무연구 시간을 공통 분모로 한 %p 차이(단축 상품만 사는 비교군, 다른 상품 효과 분리){bound}; "
               f"반복당 단축 구매 {n_buy / reps_n:.1f}회; 미도달 제외 {excluded}")
        ck.add("research_skip_gain", f"{skip}_vs_{nat}:{order[0]}->{final}:relative", "field_unlock_minutes",
               "paired_median_1-Tskip/Tnat", f(med_rel), len(rel), f(lo_rel), f(hi_rel), "보고용", "INFO", sc.get("approval", "draft"),
               sim_ev(len(rel)), f"자연 연구 대비 상대 단축(결정 C3); 미도달 제외 {excluded}")
    # INFO: 研究ポイントの収入・累積・残高、ノード完了日、完了後の積み上がり（RunData を直接組むテストでは属性なし）
    if getattr(rd, "rp_id", None) and hasattr(rd, "rp_daily"):
        periods = rc["rp_period_days"]
        for pid in rd.personas:
            n = len(rd.reps[pid])
            cells, starts = [], [1] + [d + 1 for d in periods[:-1]]
            for s0, e0 in zip(starts, periods):
                if s0 > rd.days:
                    break
                per = [sum(x[1] for x in rd.rp_daily.get((pid, rep), []) if s0 <= x[0] <= min(e0, rd.days)) / (min(e0, rd.days) - s0 + 1)
                       for rep in rd.reps[pid]]
                cum = [sum(x[1] for x in rd.rp_daily.get((pid, rep), []) if x[0] <= min(e0, rd.days)) for rep in rd.reps[pid]]
                bal = [next((x[3] for x in rd.rp_daily.get((pid, rep), []) if x[0] == min(e0, rd.days)), 0.0) for rep in rd.reps[pid]]
                cells.append(f"D{s0}-{min(e0, rd.days)} 일평균 {median(per) or 0:.1f}/누적 {median(cum) or 0:.0f}/잔고 {median(bal) or 0:.0f}")
            ck.add("research_points", pid, "research_points", "median_daily_income/cum/balance", "; ".join(cells), n, "", "", "보고용",
                   "INFO", sc.get("approval", "draft"), sim_ev(n), "연구 포인트(놓아주기 보상)의 기간별 하루 수입·누적·기간 끝 잔고 중앙값")
            done_days = []
            for nid in m.research_order:
                vals = rd.event_days(pid, "research_complete", nid)
                k = sum(1 for v in vals if v is not None)
                if k:
                    done_days.append(f"{nid} {f(quantile_censored(vals, 0.5), 0) or '-'}({k / n:.2f})")
            if not done_days:
                continue
            ck.add("research_node_complete_day", pid, "research_complete_day", "p50(complete_rate)", ", ".join(done_days), n, "", "",
                   "보고용", "INFO", sc.get("approval", "draft"), sim_ev(n), "노드별 완료일 p50(빈칸=과반 미완료)과 기간 내 완료율")
            # 全ノード完了後の研究ポイント積み上がり（完了日以降の獲得・期末残高）
            after, end_bal = [], []
            for rep in rd.reps[pid]:
                days_ = [rd.events.get((pid, "research_complete", nid), {}).get(rep, (None,))[0] for nid in m.research_order]
                rows = rd.rp_daily.get((pid, rep), [])
                end_bal.append(rows[-1][3] if rows else 0.0)
                if all(d is not None for d in days_):
                    last = max(days_)
                    after.append(sum(x[1] for x in rows if x[0] > last))
            ck.add("research_points_backlog", pid, "research_points", f"after_all_done_earned/end_balance_D{rd.days}",
                   f"{f(median(after), 0) if after else '-'}/{f(median(end_bal), 0)}", n, "", "", "허용(적체)", "INFO",
                   sc.get("approval", "draft"), sim_ev(n),
                   f"모든 노드 완료 {len(after)}/{n}회. 완료 후 획득 중앙값/기간 끝 잔고 중앙값(MVP 적체 허용, 결정 I5)")
        for nid in m.research_order:
            vals = rd.event_days(nat, "research_complete", nid)
            if not vals or not any(v is not None for v in vals):
                continue
            n = len(vals)
            ck.add("research_node_complete_dist", f"{nat}:{nid}", "research_complete_day", "p10/p50/p90(blank=not_done)",
                   "/".join(f(quantile_censored(vals, p), 0) for p in (0.1, 0.5, 0.9)), n, "", "", "보고용", "INFO",
                   sc.get("approval", "draft"), sim_ev(n), f"기간 내 완료율 {sum(1 for v in vals if v is not None) / n:.3f}")
    return out


def convergence_summary(rd: RunData) -> dict[str, Any]:
    species: dict[str, dict[str, Any]] = {}
    max_gap = 0.0
    cases = 0
    gap_measured = 0  # 厳密解と比べて gap を測れた代表ケース数
    gap_skipped = 0  # 厳密解を省いた（精霊数が部分集合 DP の上限超え）ため gap を測れなかった代表ケース数
    for r in rd.allocation:
        if r["inventory_mode"] != "unlimited_copies":
            if r["method"] == "heuristic_greedy_2swap":
                if r["gap"]:
                    max_gap = max(max_gap, float(r["gap"]))
                    gap_measured += 1
                else:
                    gap_skipped += 1
            continue
        if r["method"] == "exact_enumeration":
            cases += 1
            for sp in filter(None, r["species_used"].split(";")):
                species.setdefault(sp, {"used_cases": 0, "max_loss": 0.0, "cases": 0})["used_cases"] += 1
        elif r["method"] == "exact_excluding":
            info = species.setdefault(r["excluded_species_id"], {"used_cases": 0, "max_loss": 0.0, "cases": 0})
            info["cases"] += 1
            info["max_loss"] = max(info["max_loss"], float(r["exclusion_loss_pct"]))
    order = rd.model.spirit_order
    return {"species": {sp: species[sp] for sp in order if sp in species}, "max_gap": max_gap, "cases": cases,
            "gap_measured": gap_measured, "gap_skipped": gap_skipped}


def heuristic_gap_summary(conv: dict[str, Any]) -> tuple[str, int, str]:
    """convergence_heuristic_gap 行の (推定値, n, 理由)。n は gap を実測したケース数で、0 件なら推定値は空欄（0 と区別）."""
    measured = conv.get("gap_measured", 0)
    est = format(conv["max_gap"], ".4f") if measured else ""
    note = "휴리스틱 대비 정확 해 차이(시뮬 배치의 오차 참고)"
    if conv.get("gap_skipped"):
        note += f"; 정령 수가 정확 탐색 상한을 넘어 gap 미측정 {conv['gap_skipped']}건 제외"
    return est, measured, note


def capture_columns(rd: RunData, sc: dict[str, Any]) -> list[str]:
    days = sorted({sc["capture_by_day"], *rd.extract_days})
    return (["persona_id", "species_id", "grade", "start_owned", "runs"] + [f"acquired_by_d{d}_rate" for d in days]
            + ["acquired_by_horizon_rate", "not_acquired_rate", "acquired_ci_low", "acquired_ci_high",
               "first_day_p10", "first_day_p50", "first_day_p90", "first_day_p99", "p99_note",
               "encounters_p50_completers", "encounters_p90_completers", "encounters_p99_completers",
               "analytic_best_field", "analytic_encounters_p90", "analytic_encounters_p99"])


def capture_stats(rd: RunData, sc: dict[str, Any]) -> list[list[str]]:
    """捕獲による初獲得の統計（開始精霊は start_owned=true、捕獲統計は捕獲のみ）."""
    m = rd.model
    days_cols = sorted({sc["capture_by_day"], *rd.extract_days})
    analytic: dict[str, tuple[str, int, int]] = {}
    qg = {g["grade"]: formulas.encounter_expectation(g["grade"], m.capture_rules)[0] for g in m.capture_rules["base_success_bps_by_grade"]}
    for sp in m.spirit_order:
        best = None
        for fid in m.field_order:
            cap = m.fields[fid]["capture"]
            total = sum(e["weight"] for e in cap["table"])
            for e in cap["table"]:
                # 段階 2: 遭遇あたり q = (w/W)·Q_等級（簡易モード、capture.json）
                qq = qg.get(m.spirits[sp]["grade"], 0)
                if e["spirit_id"] == sp and e["weight"] > 0 and e["availability"] == "always" and qq > 0:
                    q = Fraction(e["weight"], total) * qq
                    if best is None or q > best[0]:
                        best = (q, fid)
        if best:
            analytic[sp] = (best[1], formulas.geometric_quantile(best[0], "9/10"), formulas.geometric_quantile(best[0], "99/100"))
    rows = []
    for pid in rd.personas:
        n = len(rd.reps[pid])
        for sp in m.spirit_order:
            ev = rd.events.get((pid, "first_capture", sp), {})
            days = [ev.get(r, (None, None, None))[0] for r in rd.reps[pid]]
            atts = [ev[r][2] for r in rd.reps[pid] if r in ev and ev[r][0] is not None and ev[r][2] is not None]
            got = sum(1 for d in days if d is not None)
            lo, hi = wilson(got, n)
            an = analytic.get(sp, ("", 0, 0))
            rows.append([pid, sp, str(m.spirits[sp]["grade"]), "true" if sp in rd.start_species else "false", str(n),
                         *[f(sum(1 for d in days if d is not None and d <= dd) / n if n else None) for dd in days_cols],
                         f(got / n if n else None), f(1 - got / n if n else None), f(lo), f(hi),
                         *[f(quantile_censored(days, p), 0) for p in (0.1, 0.5, 0.9, 0.99)],
                         "" if n >= sc["min_samples_tail"] else f"n={n}<{sc['min_samples_tail']}",
                         *[f(quantile_censored([float(a) for a in atts], p), 0) for p in (0.5, 0.9, 0.99)],
                         an[0], str(an[1]) if an[0] else "", str(an[2]) if an[0] else ""])
    return rows


def series(rd: RunData, sc: dict[str, Any]) -> dict[str, Any]:
    """report.html のグラフ用系列（日別）."""
    m = rd.model
    days = list(range(1, rd.days + 1))
    out: dict[str, Any] = {"days": days, "unlock": {}, "share": {}, "storage": {}, "capture_cdf": {}}
    for fid in m.field_order:
        if not m.fields[fid]["unlock"]["requires_fields"]:
            continue
        out["unlock"][fid] = {}
        for pid in rd.personas:
            vals = rd.event_days(pid, "field_unlock", fid)
            n = len(vals) or 1
            out["unlock"][fid][pid] = [(d, sum(1 for v in vals if v is not None and v <= d) / n) for d in days]
    for pid in rd.personas:
        out["share"][pid] = [(d, median(rd.share.get((pid, d), [])) or 0.0) for d in days]
        out["storage"][pid] = [(d, median(rd.storage.get((pid, d), [])) or 0.0) for d in days]
    cap_pid = sc["report_capture_persona"] if sc["report_capture_persona"] in rd.personas else (rd.personas[0] if rd.personas else "")
    if cap_pid:
        for sp in m.spirit_order:
            if sp in rd.start_species:
                continue
            vals = rd.event_days(cap_pid, "first_capture", sp)
            n = len(vals) or 1
            out["capture_cdf"][sp] = [(d, sum(1 for v in vals if v is not None and v <= d) / n) for d in days]
        out["capture_persona"] = cap_pid
    return out
