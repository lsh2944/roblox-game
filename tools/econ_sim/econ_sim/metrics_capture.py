"""段階 5: 捕獲の状態機械・芯・活力/餌・消費先の指標（全て draft または INFO。既存 approved 判定には触れない）.

daily.csv の行を RunData の読み込みと同じ 1 回の走査で集計し（CaptureSinkData.add）、Checks に行を足す（add_checks）。
新しい列がない古い run では何も出さない。
"""
from __future__ import annotations

from typing import Any

from . import formulas
from .model import field_encounter_expectation

RESULTS = ("success", "flee", "wick_out", "scatter")
# daily 行から反復ごとに合計する値（期間別: e = 1〜early_days 日、l = それ以降）
_PER_RUN = ("wick_blocked_min", "wick_procure_min", "capture_min", "weaken_count", "weaken_seconds",
            "weaken_assist", "food_eaten", "food_short_window", "food_short_stock", "vigor_low_hunt_min", "hunt_party_min")
# 獲得の出典（runner.SOURCES と同じ。metrics は runner を import しない）
SOURCES_ALL = ("idle", "direct", "hunt", "quest", "paid", "release", "craft", "grant", "sink")


def encode_dex_full(d: dict[tuple[int, int], list[int]]) -> str:
    """図鑑ボーナス付き遭遇の (等級, bps) → [件数, 成功] を daily.csv の 1 列にする（"等級:bps:件数:成功" を ; で連結、空なら ""）."""
    return ";".join(f"{g}:{b}:{v[0]}:{v[1]}" for (g, b), v in sorted(d.items()))


def parse_dex_full(s: str) -> dict[tuple[int, int], list[int]]:
    """encode_dex_full の逆."""
    out: dict[tuple[int, int], list[int]] = {}
    for part in (s or "").split(";"):
        if part:
            g, b, n, k = (int(x) for x in part.split(":"))
            out[(g, b)] = [n, k]
    return out


def dex_conformance(dex_full: dict[str, dict[tuple[int, int], list[int]]], personas: list[str], rule: dict[str, Any],
                    min_enc: int, wilson: Any) -> list[dict[str, Any]]:
    """図鑑の捕獲確率ボーナス付き遭遇の適合度（等級 × bps 別）。Q = encounter_expectation(等級, rule, capture_bonus_bps=bps)."""
    tot: dict[tuple[int, int], list[int]] = {}
    for p in personas:
        for key, (n, k) in dex_full.get(p, {}).items():
            v = tot.setdefault(key, [0, 0])
            v[0] += n
            v[1] += k
    rows = []
    for (gr, bps), (n, k) in sorted(tot.items()):
        q, _ = formulas.encounter_expectation(gr, rule, capture_bonus_bps=bps)
        lo, hi = wilson(k, n) if n else (None, None)
        if n < min_enc or lo is None:
            ev = "INCONCLUSIVE"
        else:
            ev = "PASS" if lo - 1e-9 <= float(q) <= hi + 1e-9 else "WARN"
        rows.append({"grade": gr, "bps": bps, "n": n, "k": k, "q": q, "lo": lo, "hi": hi, "evaluation": ev})
    return rows


def _num(r: dict[str, str], k: str) -> float:
    v = r.get(k, "")
    return float(v) if v else 0.0


class CaptureSinkData:
    """daily.csv から段階 5 の指標に要る量を集める（ペルソナ別の合計、反復別の期間合計、反復別の日次スナップショット）."""

    def __init__(self, model: Any, early_days: int = 14, absorption_from_day: int = 21, progress_days: tuple[int, ...] = (30, 60),
                 balance_days: tuple[int, ...] = (14, 30, 60)):
        self.m = model
        self.early = early_days
        self.absorb_from = absorption_from_day
        self.progress_days = progress_days
        self.active = False
        self.grade: dict[str, dict[tuple[int, str], int]] = {}  # persona → (等級, 結果|enc|attempts) → 件数
        self.dex_full: dict[str, dict[tuple[int, int], list[int]]] = {}  # persona → (等級, 図鑑ボーナス bps) → [件数, 成功]
        self.field: dict[str, dict[str, list[int]]] = {}  # persona → field → [件数, 秒]
        self.violations: dict[str, int] = {}
        self.run: dict[tuple[str, int], dict[str, float]] = {}  # (persona, rep) → "<key>_<e|l>" → 合計
        self.days: dict[tuple[str, int], dict[str, int]] = {}  # (persona, rep) → 日数（e/l）
        self.finite: dict[tuple[str, int], dict[int, int]] = {}  # (persona, rep) → 日 → 有限品目の購入数
        self.carry: dict[tuple[str, int], int] = {}  # 最終日の持ち越し秒
        self.repeat_open_days: dict[str, list[int]] = {}  # persona → [反復消費先が開いている日数, 全日数]
        self.absorb: dict[str, list[float]] = {}  # persona → [消費先の基本資源支出, 基本資源の獲得]（absorption_from_day 以降）
        self.star4_fields = [f for f in model.field_order
                             if any(e["weight"] > 0 and model.spirits[e["spirit_id"]]["grade"] == 4 for e in model.fields[f]["capture"]["table"])]
        self.finite_total = 0
        self.group: dict[str, str] = {}  # persona → 比較群（同じ群は同じ乱数ブロックを使うので独立でない）
        # 捕獲補助道具（2026-11-11）: persona → 合計（unlock_after_field 解禁後の日だけ数える量は "@u" 付き）、
        # (persona, rep) → 日 → 狩り素材のフィールド別残高（balance_days の日だけ）
        ct = (model.capture_rules or {}).get("capture_tool")
        self.tool_unlock_rank = model.field_rank(ct["unlock_after_field"]) if ct else None
        self.balance_days = balance_days
        self.tool: dict[str, dict[str, float]] = {}
        self.hunt_bal: dict[tuple[str, int], dict[int, dict[str, float]]] = {}
        self.tool_active = False
        self.tool_personas: set[str] = set()  # capture_tool != off のペルソナ（RunData が manifest から設定する）

    def add(self, r: dict[str, str], sources: tuple[str, ...] = SOURCES_ALL) -> None:
        if "g1_enc" not in r:
            return
        self.active = True
        m = self.m
        pid, rep, day = r["persona_id"], int(r["replicate_id"]), int(r["day"])
        self.group.setdefault(pid, r["pairing_group_id"])
        g = self.grade.setdefault(pid, {})
        for gr in (1, 2, 3, 4):
            for k in ("enc", "attempts", *RESULTS, "full_enc", "full_success", "dex_enc"):
                g[(gr, k)] = g.get((gr, k), 0) + int(r.get(f"g{gr}_{k}", 0) or 0)
        dfull = self.dex_full.setdefault(pid, {})
        for key, (n, k) in parse_dex_full(r.get("dex_capture_full", "")).items():
            v = dfull.setdefault(key, [0, 0])
            v[0] += n
            v[1] += k
        fd = self.field.setdefault(pid, {})
        for f in m.field_order:
            v = fd.setdefault(f, [0, 0])
            v[0] += int(r[f"enc_done_{f}"])
            v[1] += int(r[f"enc_seconds_{f}"])
        if int(r["capture_seconds"]) > int(r["capture_budget_seconds"]):
            self.violations[pid] = self.violations.get(pid, 0) + 1
        else:
            self.violations.setdefault(pid, 0)
        per = "e" if day <= self.early else "l"
        acc = self.run.setdefault((pid, rep), {})
        vals = {k: _num(r, k) for k in _PER_RUN}
        vals["attempts"] = sum(_num(r, f"g{gr}_attempts") for gr in (1, 2, 3, 4))  # 完了日に計上した試行数
        for fid in m.field_order:
            vals[f"attempts@{fid}"] = _num(r, f"attempts_{fid}")
        vals["star4_enc"] = _num(r, "g4_enc")
        vals["star4_field_seconds"] = sum(_num(r, f"enc_seconds_{f}") for f in self.star4_fields)
        vals["captures"] = _num(r, "capture_success_cum")
        for k, v in vals.items():
            if k == "captures":
                acc["captures"] = v  # 累計列なので最後の値
            else:
                acc[f"{k}_{per}"] = acc.get(f"{k}_{per}", 0.0) + v
        dd = self.days.setdefault((pid, rep), {"e": 0, "l": 0})
        dd[per] += 1
        self.finite.setdefault((pid, rep), {})[day] = int(r["finite_sink_done"])
        self.carry[(pid, rep)] = int(r["capture_carry_seconds"])
        ro = self.repeat_open_days.setdefault(pid, [0, 0])
        ro[0] += int(int(r["repeat_sink_open"]) > 0)
        ro[1] += 1
        if "tool_attempts" in r:
            self._add_tool(r, pid, rep, day)
        if day >= self.absorb_from:
            ab = self.absorb.setdefault(pid, [0.0, 0.0, 0.0])  # [有限への基本資源支出, 反復への支出, 基本資源の獲得]
            ab[0] += _num(r, "sink_spent_basic")
            ab[1] += _num(r, "sink_spent_basic_repeat")
            ab[2] += sum(_num(r, f"earned_{s}_{b}") for s in sources for b in m.basic_ids if f"earned_{s}_{b}" in r)


    def _add_tool(self, r: dict[str, str], pid: str, rep: int, day: int) -> None:
        """捕獲補助道具の列（runner.TOOL_COLS ほか）を集める。解禁後 = 最高フィールドが unlock_after_field 以上の日."""
        self.tool_active = True
        m = self.m
        t = self.tool.setdefault(pid, {})

        def add(k: str, v: float) -> None:
            t[k] = t.get(k, 0.0) + v

        for k in ("tool_attempts", "tool_enc", "tool_success", "tool_first_capture", "tool_pre_unlock", "craft_hunt_lure"):
            add(k, _num(r, k))
        for gr in (1, 2, 3, 4):
            for k in ("enc", "success", "full_enc", "full_success", "dex_excl"):
                add(f"g{gr}_tool_{k}", _num(r, f"g{gr}_tool_{k}"))
        unlocked = self.tool_unlock_rank is not None and m.field_rank(r["highest_field"]) >= self.tool_unlock_rank
        if unlocked:
            add("days@u", 1)
            add("g4_success@u", _num(r, "g4_success"))
            add("g4_enc@u", _num(r, "g4_enc"))
            add("tool_attempts@u", _num(r, "tool_attempts"))
            add("craft_hunt_lure@u", _num(r, "craft_hunt_lure"))
        for f in m.field_order:
            add(f"lure_craft_{f}", _num(r, f"lure_craft_{f}"))
            add(f"lure_used_{f}", _num(r, f"lure_used_{f}"))
            if unlocked:
                add(f"lure_used_{f}@u", _num(r, f"lure_used_{f}"))
                add(f"lure_craft_{f}@u", _num(r, f"lure_craft_{f}"))
        for h in m.hunt_resource_ids():
            if unlocked:
                add(f"earned_{h}@u", sum(_num(r, f"earned_{s}_{h}") for s in SOURCES_ALL))
        if day in self.balance_days:
            self.hunt_bal.setdefault((pid, rep), {})[day] = {h: _num(r, f"wallet_{h}") for h in m.hunt_resource_ids()}


def _pairs(rd: Any, base: str, test: str) -> list[int]:
    return sorted(set(rd.reps.get(base, [])) & set(rd.reps.get(test, [])))


def _star4_delays(rd: Any, pid: str) -> dict[str, list[float | None]]:
    """★4 の種別「その種が出るフィールドの初進入日からの初獲得日数」（未獲得 None、未進入の反復は除く）."""
    m = rd.model
    out: dict[str, list[float | None]] = {}
    for sp in m.spirit_order:
        if m.spirits[sp]["grade"] != 4:
            continue
        entry_field = next((f for f in m.field_order if any(e["spirit_id"] == sp and e["weight"] > 0 for e in m.fields[f]["capture"]["table"])), None)
        if entry_field is None:
            continue
        vals: list[float | None] = []
        for rep in rd.reps.get(pid, []):
            entry = 1 if not m.fields[entry_field]["unlock"]["requires_fields"] else \
                rd.events.get((pid, "field_unlock", entry_field), {}).get(rep, (None,))[0]
            if entry is None:
                continue
            got = rd.events.get((pid, "first_capture", sp), {}).get(rep, (None,))[0]
            vals.append(None if got is None else float(got - entry))
        out[sp] = vals
    return out


def add_checks(rd: Any, sc: dict[str, Any], ck: Any) -> dict[str, Any]:
    """段階 5・12 節の新指標を ck に足し、report 用の要約を返す."""
    from .metrics import f, median, quantile_censored, wilson  # 循環 import 回避
    cs: CaptureSinkData | None = getattr(rd, "cs", None)  # 手組みの RunData（テスト）や古い run では無い
    if cs is None or not cs.active:
        return {}
    cfg = sc.get("capture_sinks", {})
    appr = cfg.get("approval", "draft")
    m = rd.model
    rule = m.capture_rules
    personas = rd.personas
    out: dict[str, Any] = {"capture": [], "sink": []}

    def ev(n: int | str) -> str:
        return f"simulated_n={n}"

    # 1·4. 等級別の結果と解析値（Q, E[A]）の一致。同じ比較群のペルソナは同じ乱数ブロックを使い独立でないので、
    # 比較群ごとに最初のペルソナだけを合算する
    min_enc = int(cfg.get("conformance_min_encounters", 30))
    indep: list[str] = []
    seen_groups: set[str] = set()
    for p in personas:
        if cs.group.get(p) not in seen_groups:
            seen_groups.add(cs.group.get(p, p))
            indep.append(p)
    for gr in (1, 2, 3, 4):
        tot = {k: sum(cs.grade.get(p, {}).get((gr, k), 0) for p in indep)
               for k in ("enc", "attempts", *RESULTS, "full_enc", "full_success", "dex_enc")}
        q, ea = formulas.encounter_expectation(gr, rule)
        # 開始時に芯が K_max 回分以上（または無制限）あった遭遇だけを数える。芯切れの遭遇を単に除くと、失敗が続いた遭遇ほど
        # 除かれて成功率が上に偏るため（2 次レビュー Minor 4）
        n = tot["full_enc"]
        k = tot["full_success"]
        lo, hi = wilson(k, n) if n else (None, None)
        if n < min_enc or lo is None:
            evaluation = "INCONCLUSIVE"
        else:
            evaluation = "PASS" if lo - 1e-9 <= float(q) <= hi + 1e-9 else "WARN"  # k=n で Wilson 上端が浮動小数で 1 をわずかに下回る
        att = (tot["attempts"] / tot["enc"]) if tot["enc"] else None
        ck.add("capture_rule_conformance", f"grade{gr}", "success_per_encounter", "observed(start_wick>=K_max)", f(k / n if n else None, 4), n,
               f(lo, 4), f(hi, 4), f"Q={float(q):.4f} ∈ Wilson CI", evaluation, appr, ev(n),
               f"평균 시도 {f(att, 3)}(해석 E[A] {float(ea):.3f}, 심지 소진 포함) — 비교군별 첫 페르소나 합산({','.join(indep)})"
               f", 도감 포획 보정 조우 {tot['dex_enc']}건은 적합도에서 제외")
        shares = {k2: (tot[k2] / tot["enc"] if tot["enc"] else None) for k2 in RESULTS}
        ck.add("capture_outcome_share", f"grade{gr}", "encounter_outcome", "success/flee/wick_out/scatter",
               "/".join(f(shares[k2], 3) for k2 in RESULTS), tot["enc"], "", "", "", "INFO", appr, ev(tot["enc"]), "완료일 기준, 비교군별 첫 페르소나 합산")
        out["capture"].append(["grade", f"★{gr}", f(shares["success"], 3), f(shares["flee"], 3), f(shares["wick_out"], 3), f(att, 2), f"{float(q):.3f}/{float(ea):.2f}"])
    # 1b. 図鑑の捕獲確率ボーナス付き遭遇の適合度（2026-11-13 リビュー Minor 1）: 基本規則の行から外した遭遇を等級 × bps 別に検査する
    for d in dex_conformance(cs.dex_full, indep, rule, min_enc, wilson):
        ck.add("capture_dex_conformance", f"grade{d['grade']}:bps{d['bps']}", "success_per_encounter",
               "observed(start_wick>=K_max,no_tool,dex_bonus)", f(d["k"] / d["n"] if d["n"] else None, 4), d["n"],
               f(d["lo"], 4), f(d["hi"], 4), f"Q_dex={float(d['q']):.4f} ∈ Wilson CI", d["evaluation"], appr, ev(d["n"]),
               f"도감 포획 확률 보너스 +{d['bps']}bps가 걸린 도구 없는 조우만(Q = encounter_expectation(capture_bonus_bps)), "
               f"비교군별 첫 페르소나 합산({','.join(indep)})")
    # 2. 時間の保存
    viol = sum(cs.violations.values())
    ck.add("capture_time_conservation", "all", "capture_seconds_le_budget", "violation_days", str(viol), sum(len(rd.reps[p]) for p in personas) * rd.days,
           "", "", "0", "PASS" if viol == 0 else "FAIL", appr, "simulated", "하루 사용 초 ≤ 그날 포획 예산 초(미완료는 다음 단계로 이월)")
    # 3. フィールド別の遭遇平均秒
    for fid in m.field_order:
        n = sum(cs.field.get(p, {}).get(fid, [0, 0])[0] for p in indep)  # 比較群ごとに 1 ペルソナ（同じ乱数ブロックの重複を避ける）
        s = sum(cs.field.get(p, {}).get(fid, [0, 0])[1] for p in indep)
        _, an = field_encounter_expectation(m, fid, rule)
        ck.add("encounter_seconds_mean", fid, "encounter_seconds", "mean", f(s / n if n else None, 1), n, "", "", f"해석 {float(an):.1f}",
               "INFO", appr, ev(n), "해석값은 동등급 Lv1·활력 최대 약화 기준(실측은 동행 레벨·활력 반영), 비교군별 첫 페르소나 합산")
        out["capture"].append(["field", fid, f(s / n if n else None, 1), f"{float(an):.1f}", str(n), "", ""])

    shortage_max = float(cfg.get("wick_shortage_max", 0.01))
    judged = set(cfg.get("wick_shortage_personas", []))
    for pid in personas:
        reps = rd.reps[pid]
        runs = [cs.run.get((pid, r), {}) for r in reps]
        days = [cs.days.get((pid, r), {"e": 0, "l": 0}) for r in reps]
        de, dl = sum(d["e"] for d in days), sum(d["l"] for d in days)

        def tot(key: str, per: str | None = None) -> float:
            if per:
                return sum(x.get(f"{key}_{per}", 0.0) for x in runs)
            return tot(key, "e") + tot(key, "l")

        # 5. 芯不足で捕獲に使えなかった捕獲予算の比率（期間別）
        for per, label in (("e", f"D1-{cs.early}"), ("l", f"D{cs.early + 1}+")):
            blocked, used = tot("wick_blocked_min", per), tot("capture_min", per)
            budget = blocked + used
            share = blocked / budget if budget else None
            if pid in judged and share is not None:
                evaluation = "PASS" if share <= shortage_max else "WARN"
            else:
                evaluation = "INFO"
            ck.add("wick_shortage_share", f"{pid}:{label}", "wick_blocked_minutes", "blocked/capture_budget", f(share, 3), len(reps), "", "",
                   f"≤{shortage_max}" if pid in judged else "", evaluation, appr, ev(len(reps)),
                   "심지가 없어 포획에 쓰지 못한 포획 예산 분(조달 사냥으로 돌린 분 포함)")
        # 6. 調達狩り分
        ck.add("wick_procure_minutes", pid, "wick_procure_min", "per_day(D1-14/D15+)",
               f"{f(tot('wick_procure_min', 'e') / de if de else None, 1)}/{f(tot('wick_procure_min', 'l') / dl if dl else None, 1)}",
               len(reps), "", "", "", "INFO", appr, ev(len(reps)), "심지 재료 조달 사냥(포획 예산·flex 합계)")
        # 9. ★4 への露出
        s4 = tot("star4_enc")
        mins = tot("star4_field_seconds") / 60
        g4 = cs.grade.get(pid, {})
        g4n = g4.get((4, "enc"), 0)
        reasons = "/".join(f(g4.get((4, k), 0) / g4n if g4n else None, 3) for k in RESULTS)
        ck.add("star4_exposure", pid, "star4", "field_minutes_per_run/encounters_per_run/outcome(s/f/w/x)",
               f"{f(mins / len(reps) if reps else None, 0)}/{f(s4 / len(reps) if reps else None, 1)}/{reasons}", len(reps), "", "", "",
               "INFO", appr, ev(len(reps)), f"★4 출현 필드({','.join(cs.star4_fields)})의 완료 조우 분, ★4 조우 수, ★4 조우 종료 사유")
        # 14. 期間末の未完了遭遇
        pend = [cs.carry.get((pid, r), 0) for r in reps]
        ck.add("capture_pending_at_horizon", pid, "pending_encounter", "share_runs/mean_seconds",
               f"{f(sum(1 for x in pend if x > 0) / len(pend) if pend else None, 3)}/{f(sum(pend) / len(pend) if pend else None, 1)}",
               len(reps), "", "", "", "INFO", appr, ev(len(reps)), "기간 끝 미완료 조우(결과 미적용)")
        # 12 節: 弱体化・活力・餌
        wn, ws = tot("weaken_count"), tot("weaken_seconds")
        ck.add("weaken_seconds_mean", pid, "weaken_seconds", "mean", f(ws / wn if wn else None, 2), int(wn), "", "", "2~12", "INFO", appr,
               ev(len(reps)), "약화한 조우만(★1 생략 제외), 등롱 보조 포함")
        ck.add("assist_weaken_share", pid, "assist_weaken", "share", f(tot("weaken_assist") / wn if wn else None, 3), int(wn), "", "", "",
               "INFO", appr, ev(len(reps)), "동행이 모두 활동 불가이거나 등롱보다 느려 등롱(12초)으로 약화한 비율")
        hp = tot("hunt_party_min")
        ck.add("vigor_low_share", pid, "vigor_low_hunt", "low_party_minutes/hunt_party_minutes", f(tot("vigor_low_hunt_min") / hp if hp else None, 3),
               len(reps), "", "", "", "INFO", appr, ev(len(reps)), "사냥 동행 분 중 활력 ≤50(산출 75%)인 비율")
        dall = de + dl
        ck.add("food_per_day", pid, "food_eaten", "per_day", f(tot("food_eaten") / dall if dall else None, 2), len(reps), "", "", "", "INFO",
               appr, ev(len(reps)), "자동 급식 수(개체당 60분 2개 상한)")
        ck.add("food_shortage", pid, "food_short", "per_day(window/stock)",
               f"{f(tot('food_short_window') / dall if dall else None, 2)}/{f(tot('food_short_stock') / dall if dall else None, 2)}",
               len(reps), "", "", "", "INFO", appr, ev(len(reps)), "활력 ≤50 동행에게 급식하지 못한 기회: 60분 상한 / 재고·제작 불가")
        bud_e = tot("wick_blocked_min", "e") + tot("capture_min", "e")
        out["capture"].append(["persona", pid, f(tot("wick_blocked_min", "e") / bud_e if bud_e else None, 3),
                               f(ws / wn if wn else None, 2), f(tot("food_eaten") / dall if dall else None, 2),
                               f(tot("vigor_low_hunt_min") / hp if hp else None, 3), f(tot("weaken_assist") / wn if wn else None, 3)])
        # 10·11·12·13. 消費先
        n_fin = cs.finite_total
        prog = []
        for d in cs.progress_days:
            vals = [cs.finite.get((pid, r), {}).get(d) for r in reps]
            vals2 = [v for v in vals if v is not None]
            prog.append(f(sum(vals2) / len(vals2) / n_fin if vals2 and n_fin else None, 3))
        ck.add("finite_cosmetic_progress", pid, "finite_sink_done", "share_" + "/".join(f"D{d}" for d in cs.progress_days), "/".join(prog),
               len(reps), "", "", "", "INFO", appr, ev(len(reps)), f"유한 외형 품목 {n_fin}개(집 2~9단계·가구·의상) 중 구매 비율 평균")
        cd = rd.event_days(pid, "finite_cosmetic_completed", "all")
        p50 = quantile_censored(cd, 0.5)
        lo_d, hi_d = cfg.get("finite_complete_day_min", 45), cfg.get("finite_complete_day_max", 60)
        if pid == cfg.get("finite_complete_persona"):
            evaluation = "PASS" if (p50 is not None and lo_d <= p50 <= hi_d) else "WARN"
        else:
            evaluation = "INFO"
        ck.add("finite_cosmetic_completed_day", pid, "finite_cosmetic_completed", "p50_day(blank=not_reached)", f(p50, 0), len(cd), "", "",
               f"D{lo_d}~D{hi_d}" if evaluation != "INFO" else "", evaluation, appr, ev(len(cd)),
               f"기간 내 완료율 {f(sum(v is not None for v in cd) / len(cd) if cd else None, 3)}")
        ab = cs.absorb.get(pid, [0.0, 0.0, 0.0])
        ck.add("sink_absorption", pid, "sink_spent_basic/earned_basic", f"D{cs.absorb_from}+ total/finite/repeat",
               "/".join(f(x / ab[2] if ab[2] else None, 3) for x in (ab[0] + ab[1], ab[0], ab[1])),
               len(reps), "", "", "", "INFO", appr, ev(len(reps)), "소비처에 쓴 기본 재료 ÷ 획득한 기본 재료(합계/유한/반복)")
        ro = cs.repeat_open_days.get(pid, [0, 0])
        ck.add("repeat_sink_available_rate", pid, "repeat_sink_open", "share_days", f(ro[0] / ro[1] if ro[1] else None, 3), len(reps),
               "", "", "", "INFO", appr, ev(len(reps)), "반복 소비처가 1개 이상 열린 날 비율")
        out["sink"].append([pid, *prog, f(p50, 0), f((ab[0] + ab[1]) / ab[2] if ab[2] else None, 3), f(ab[1] / ab[2] if ab[2] else None, 3),
                            f(ro[0] / ro[1] if ro[1] else None, 3)])

    out["tool"] = _tool_checks(rd, cs, ck, appr, indep, ev, min_enc)

    # 7·20. 課金・無課金の対（同じ反復）
    pair = sc.get("paid_pair", {})
    free, paid = pair.get("free"), pair.get("paid")
    if free in rd.reps and paid in rd.reps:
        reps = _pairs(rd, free, paid)

        def diff(key: str, per: str) -> float | None:
            vals = [cs.run.get((paid, r), {}).get(f"{key}_{per}", 0.0) - cs.run.get((free, r), {}).get(f"{key}_{per}", 0.0) for r in reps]
            return median(vals)

        for key, label in (("wick_blocked_min", "심지 부족 분"), ("wick_procure_min", "조달 사냥 분"), ("attempts", "시도 수"),
                           *[(f"attempts@{fid}", f"{fid} 시도 수") for fid in m.field_order]):
            ck.add("wick_paid_free_gap", f"{paid}-{free}:{key}", key, "paired_median_diff(D1-14/D15+)",
                   f"{f(diff(key, 'e'), 1)}/{f(diff(key, 'l'), 1)}", len(reps), "", "", "", "INFO", appr, ev(len(reps)),
                   f"{label}(과금 − 무과금, 같은 반복 짝의 중앙값). 사용자 판단 자료")
        d4f, d4p = _star4_delays(rd, free), _star4_delays(rd, paid)
        for sp in d4f:
            ck.add("wick_paid_free_gap", f"{paid}-{free}:{sp}", "star4_first_capture_days_after_entry", "p50 free/paid",
                   f"{f(quantile_censored(d4f[sp], 0.5), 0)}/{f(quantile_censored(d4p[sp], 0.5), 0)}", len(d4f[sp]), "", "", "", "INFO", appr,
                   ev(len(d4f[sp])), "★4 첫 획득(필드 진입 후 일수) 중앙값: 무과금/과금")
        for key, label in (("weaken_seconds", "약화 초 합"), ("food_eaten", "급식 수"), ("vigor_low_hunt_min", "저활력 사냥 분"),
                           ("weaken_assist", "등롱 보조 수")):
            ck.add("vigor_paid_free_gap", f"{paid}-{free}:{key}", key, "paired_median_diff(D1-14/D15+)",
                   f"{f(diff(key, 'e'), 1)}/{f(diff(key, 'l'), 1)}", len(reps), "", "", "", "INFO", appr, ev(len(reps)),
                   f"{label}(과금 − 무과금). 레벨·먹이 경로가 약화 시간에 주는 차이")

    # 8·21. 芯無制限・機能停止との比較（指定されたペルソナが run にあるときだけ）
    for kind, pairs in (("wick_vs_unlimited", cfg.get("wick_unlimited_pairs", [])), ("ablation_effect", cfg.get("ablation_pairs", []))):
        for pr in pairs:
            base, test = pr["base"], pr["test"]
            if base not in rd.reps or test not in rd.reps:
                continue
            reps = _pairs(rd, base, test)
            db, dt = _star4_delays(rd, base), _star4_delays(rd, test)
            for sp in db:
                ck.add(kind, f"{test}-{base}:{sp}", "star4_first_capture_days_after_entry", "p98.5 base/test",
                       f"{f(quantile_censored(db[sp], 0.985), 0)}/{f(quantile_censored(dt[sp], 0.985), 0)}", len(reps), "", "", "", "INFO", appr,
                       ev(len(reps)), "★4 첫 획득 꼬리(필드 진입 후 일수)")
            ridge = m.field_order[-1]
            ck.add(kind, f"{test}-{base}:{ridge}", "field_unlock_day", "p50 base/test",
                   f"{f(quantile_censored(rd.event_days(base, 'field_unlock', ridge), 0.5), 0)}/"
                   f"{f(quantile_censored(rd.event_days(test, 'field_unlock', ridge), 0.5), 0)}", len(reps), "", "", "", "INFO", appr, ev(len(reps)), "")
            for key in ("weaken_seconds", "captures"):
                bv = [cs.run.get((base, r), {}) for r in reps]
                tv = [cs.run.get((test, r), {}) for r in reps]
                if key == "captures":
                    b, t = median([x.get("captures", 0.0) for x in bv]), median([x.get("captures", 0.0) for x in tv])
                else:
                    b = sum(x.get("weaken_seconds_e", 0) + x.get("weaken_seconds_l", 0) for x in bv) / max(1, sum(x.get("weaken_count_e", 0) + x.get("weaken_count_l", 0) for x in bv))
                    t = sum(x.get("weaken_seconds_e", 0) + x.get("weaken_seconds_l", 0) for x in tv) / max(1, sum(x.get("weaken_count_e", 0) + x.get("weaken_count_l", 0) for x in tv))
                ck.add(kind, f"{test}-{base}:{key}", key, "base/test", f"{f(b, 2)}/{f(t, 2)}", len(reps), "", "", "", "INFO", appr, ev(len(reps)),
                       "포획 성공 누적 중앙값" if key == "captures" else "약화 평균 초")
    return out


def _tool_checks(rd: Any, cs: CaptureSinkData, ck: Any, appr: str, indep: list[str], ev: Any, min_enc: int) -> list[list[str]]:
    """捕獲補助道具（2026-11-11）の指標。番人（初捕獲・解禁前に道具 0）だけ draft PASS/FAIL、適合度は draft、他は INFO."""
    from .metrics import f, wilson
    if not cs.tool_active or not cs.tool_personas:
        return []  # 道具 off だけの run では道具の check・report 節を出さない（2026-11-11 レビュー m1）
    m = rd.model
    rule = m.capture_rules
    rows: list[list[str]] = []
    hunt = m.hunt_resource_ids()
    # 番人: 道具を使った遭遇での初捕獲・unlock_after_field 解禁前の道具使用
    bad = sum(cs.tool.get(p, {}).get("tool_first_capture", 0) + cs.tool.get(p, {}).get("tool_pre_unlock", 0) for p in rd.personas)
    ck.add("capture_tool_first_capture_zero", "all", "tool_on_first_capture+tool_before_unlock", "count", str(int(bad)),
           sum(len(rd.reps[p]) for p in rd.personas), "", "", "0", "PASS" if bad == 0 else "FAIL", appr, "simulated",
           "첫 포획(직접 포획 이력 없음)·전역 해금 전에는 도구 효과 0(2026-11-11 결정)")
    # 道具付き遭遇の適合度（開始時に芯・道具とも K_max 回分以上の遭遇だけ、比較群ごとに最初のペルソナ）
    for gr in (2, 3, 4):
        n = int(sum(cs.tool.get(p, {}).get(f"g{gr}_tool_full_enc", 0) for p in indep))
        k = int(sum(cs.tool.get(p, {}).get(f"g{gr}_tool_full_success", 0) for p in indep))
        if n == 0:
            continue
        q, _ = formulas.encounter_expectation(gr, rule, with_tool=True)
        lo, hi = wilson(k, n)
        evaluation = "INCONCLUSIVE" if n < min_enc or lo is None else ("PASS" if lo - 1e-9 <= float(q) <= hi + 1e-9 else "WARN")
        ck.add("capture_tool_conformance", f"grade{gr}", "success_per_encounter", "observed(start_wick,tool>=K_max)", f(k / n, 4), n,
               f(lo, 4), f(hi, 4), f"Q_tool={float(q):.4f} ∈ Wilson CI", evaluation, appr, ev(n),
               f"도구 사용 조우만, 비교군별 첫 페르소나 합산({','.join(indep)}), 도감 포획 보정 조우 "
               f"{int(sum(cs.tool.get(p, {}).get(f'g{gr}_tool_dex_excl', 0) for p in indep))}건은 제외")
    for pid in [p for p in rd.personas if p in cs.tool_personas]:
        t = cs.tool.get(pid, {})
        reps = rd.reps[pid]
        du = t.get("days@u", 0.0)
        used = sum(t.get(f"lure_used_{fl}@u", 0.0) for fl in m.field_order)
        att = t.get("tool_attempts@u", 0.0)
        enc, suc = t.get("tool_enc", 0.0), t.get("tool_success", 0.0)
        s4 = t.get("g4_success@u", 0.0)
        ck.add("capture_tool_usage", pid, "lure", "per_day_after_unlock(used/tool_attempts/craft_hunt)|tool_enc_success",
               f"{f(used / du if du else None, 2)}/{f(att / du if du else None, 2)}/{f(t.get('craft_hunt_lure@u', 0.0) / du if du else None, 2)}"
               f"|{f(suc / enc if enc else None, 3)}", len(reps), "", "", "", "INFO", appr, ev(len(reps)),
               "전역 해금 후 하루 평균 도구 소비(조우 시작일)·도구 시도(조우 완료일)·도구 제작에 쓴 사냥 재료, 도구 사용 조우의 성공률. "
               "집계 시점이 달라 날짜 경계에서 소비≠시도일 수 있음, '전역 해금 후'는 그날 최고 해금 필드 기준 근사")
        ck.add("star4_success_per_day_after_unlock", pid, "g4_success", "per_day_after_unlock(success/enc)",
               f"{f(s4 / du if du else None, 3)}/{f(t.get('g4_enc@u', 0.0) / du if du else None, 2)}", len(reps), "", "", "", "INFO", appr,
               ev(len(reps)), "전역 해금 후 ★4 획득·조우/일(중복 포획 포함)")
        bal_cells = []
        for fl in m.field_order:
            h = next((x for x in hunt if any(d["resource"] == x for d in m.fields[fl]["hunt"]["drops"])), None)
            cu = t.get(f"lure_craft_{fl}@u", 0.0)
            uu = t.get(f"lure_used_{fl}@u", 0.0)
            earned = t.get(f"earned_{h}@u", 0.0) if h else 0.0
            # 道具の制作に使った狩り素材 = 制作数 × 入力/産出（レシピは 1 つ・入力 1 種の前提で近似、無ければ空）
            recs = [rc for rc in m.recipes_for(next((it["resource"] for it in rule["capture_tool"]["items"] if it["field_id"] == fl), ""))
                    if len(rc["inputs"]) == 1] if rule.get("capture_tool") else []
            hunt_used = cu * recs[0]["inputs"][0]["amount"] / recs[0]["output"]["amount"] if recs else None
            bals = []
            for d in cs.balance_days:
                vals = [cs.hunt_bal.get((pid, r_), {}).get(d, {}).get(h) for r_ in reps] if h else []
                vals = [v for v in vals if v is not None]
                bals.append(f(sum(vals) / len(vals) if vals else None, 1))
            ck.add("capture_tool_field", f"{pid}:{fl}", "lure", "per_day_after_unlock(craft/used)|hunt_share|wallet_" + "/".join(f"D{d}" for d in cs.balance_days),
                   f"{f(cu / du if du else None, 2)}/{f(uu / du if du else None, 2)}|{f(hunt_used / earned if earned and hunt_used is not None else None, 3)}|{'/'.join(bals)}",
                   len(reps), "", "", "", "INFO", appr, ev(len(reps)),
                   f"전역 해금 후 도구 제작·소비/일(제작은 그날, 소비는 조우 시작일), 도구 제작에 투입한 {h} ÷ 같은 기간 {h} 획득(투입 비율, "
                   f"레시피 입력 1종 가정), 기간 끝이 아닌 지정 일의 {h} 잔고 평균. '전역 해금 후'는 그날 최고 해금 필드 기준 근사")
            bal_cells.append(f"{f(cu / du if du else None, 2)}/{f(uu / du if du else None, 2)}")
        rows.append([pid, f(used / du if du else None, 2), f(att / du if du else None, 2), f(suc / enc if enc else None, 3),
                     f(s4 / du if du else None, 3), *bal_cells])
    return rows
