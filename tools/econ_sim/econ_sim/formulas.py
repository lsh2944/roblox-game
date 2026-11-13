"""経済ルールの純粋な計算式（後で Luau の Formulas モジュールへ 1:1 で移植する対象）.

単位と丸めの約束:
- 倍率は bps（10000 = 1.0 倍）、生産量は milli（1000 = 1 個）の整数で扱う。
- 丸めは各段の整数除算（切り捨て）で、段の順序は関数ごとに固定する。
- 中間値が 2^53-1 を超えたら FormulaError（Luau の number で同じ結果を出すため）。
- 曲線のコスト計算だけは有理数（Fraction）で厳密に ceil する（浮動小数の 100*1.1=110.00000000000001 対策）。
"""
from __future__ import annotations

import math
from fractions import Fraction
from typing import Any, Callable, Iterable

BPS = 10_000
MILLI = 1_000
MINUTES_PER_HOUR = 60
MINUTES_PER_DAY = 1_440
MAX_SAFE_INT = 2**53 - 1


class FormulaError(ValueError):
    """入力範囲外・安全整数超過."""


def _safe(*values: int) -> None:
    for v in values:
        if isinstance(v, bool) or not isinstance(v, int):
            raise FormulaError(f"정수가 아님: {v!r}")
        if abs(v) > MAX_SAFE_INT:
            raise FormulaError(f"2^53-1 초과: {v}")


def _nonneg(**values: int) -> None:
    for name, v in values.items():
        _safe(v)
        if v < 0:
            raise FormulaError(f"{name}는 0 이상이어야 함: {v}")


def to_fraction(x: Any) -> Fraction:
    """JSON 由来の数値を 10 進表記どおりの有理数に変換する（float は最短表現 repr を使う）."""
    if isinstance(x, Fraction):
        return x
    if isinstance(x, bool):
        raise FormulaError(f"수치가 아님: {x!r}")
    if isinstance(x, int):
        return Fraction(x)
    if isinstance(x, float):
        if not math.isfinite(x):
            raise FormulaError(f"비유한 수: {x}")
        return Fraction(repr(x))
    if isinstance(x, str):
        return Fraction(x)
    raise FormulaError(f"수치가 아님: {x!r}")


def ceil_fraction(v: Fraction) -> int:
    return -((-v.numerator) // v.denominator)


# ---- 強化曲線 ---------------------------------------------------------------


def exp_ceil_cost(base_amount: int, growth: Any, exponent: int) -> int:
    """cost = ceil(base × growth^exponent)。施設は exponent=L-1、精霊は exponent=L."""
    _nonneg(base_amount=base_amount, exponent=exponent)
    g = to_fraction(growth)
    if g <= 0:
        raise FormulaError(f"growth는 양수여야 함: {growth}")
    result = ceil_fraction(base_amount * g**exponent)
    _safe(result)
    return result


def exp_ceil_capped_cost(base_amount: int, growth: Any, level: int, cap_level: int) -> int:
    """消費先の反復コスト（上限付き指数）: レベル L(≥1) の購入コスト = ceil(base × growth^min(L, cap_level))."""
    _nonneg(cap_level=cap_level)
    _safe(level)
    if level < 1:
        raise FormulaError(f"level은 1 이상: {level}")
    return exp_ceil_cost(base_amount, growth, min(level, cap_level))


def linear_ceil_capped_cost(base_amount: int, step: Any, n: int, cap_steps: int) -> int:
    """消費先の反復コスト（上限付き線形）: n 回目(≥1)の購入コスト = ceil(base × (1 + step × min(n−1, cap_steps)))."""
    _nonneg(base_amount=base_amount, cap_steps=cap_steps)
    _safe(n)
    if n < 1:
        raise FormulaError(f"n은 1 이상: {n}")
    st = to_fraction(step)
    if st < 0:
        raise FormulaError(f"step은 0 이상: {step}")
    result = ceil_fraction(base_amount * (1 + st * min(n - 1, cap_steps)))
    _safe(result)
    return result


def linear_milestone_bps(per_level_bps: int, level: int, milestones: Iterable[tuple[int, int]]) -> int:
    """倍率 = (1 + per_level×(L-1)) × Π{到達済みマイルストーンの倍率}（線形解釈）."""
    _nonneg(per_level_bps=per_level_bps)
    _safe(level)
    if level < 1:
        raise FormulaError(f"level은 1 이상: {level}")
    value = BPS + per_level_bps * (level - 1)
    for m_level, mult in milestones:
        _nonneg(m_level=m_level, mult=mult)
        if level >= m_level:
            value *= mult
    _safe(value)
    return value


# ---- 生産・採集・狩り ----------------------------------------------------------


def slot_power_bps(gather: int, ability_bps: int, aptitude_bps: int, trait_bps: int = 0) -> int:
    """配置 1 枠の寄与（採集力×能力倍率×適性×(1+特性)）。単位は「採集力×bps」."""
    _nonneg(gather=gather, ability_bps=ability_bps, aptitude_bps=aptitude_bps)
    _safe(trait_bps)
    raw = gather * ability_bps * aptitude_bps
    _safe(raw)
    power = raw // BPS
    factor = max(0, BPS + trait_bps)  # 特性合計が -100% 未満なら 0 に止める
    _safe(power * factor)
    return power * factor // BPS


def idle_rate_milli_per_hour(
    base_per_hour: int, facility_mult_bps: int, slot_powers_bps: Iterable[int], gather_ref: int
) -> int:
    """施設 1 つの放置生産（milli/時）= 基本率×施設倍率×Σ(枠寄与)/G_REF."""
    _nonneg(base_per_hour=base_per_hour, facility_mult_bps=facility_mult_bps)
    if gather_ref < 1:
        raise FormulaError("gather_ref는 1 이상")
    staff = 0
    for p in slot_powers_bps:
        _nonneg(slot_power=p)
        staff += p
    _safe(staff)
    scaled = base_per_hour * MILLI * facility_mult_bps
    _safe(scaled)
    scaled //= BPS
    _safe(scaled * staff)
    return scaled * staff // (gather_ref * BPS)


def companion_bonus_bps(companion_powers_bps: Iterable[int], k_bps: int, gather_ref: int) -> int:
    """同行精霊による直接採集ボーナス（bps）= k × Σ(枠寄与)/G_REF."""
    _nonneg(k_bps=k_bps)
    if gather_ref < 1:
        raise FormulaError("gather_ref는 1 이상")
    total = 0
    for p in companion_powers_bps:
        _nonneg(companion_power=p)
        total += p
    _safe(k_bps * total)
    return k_bps * total // (gather_ref * BPS)


def direct_rate_milli_per_hour(node_per_hour: int, tool_mult_bps: int, companion_bonus: int) -> int:
    """直接採集（milli/活動時間）= ノード基本率×道具倍率×(1+同行ボーナス)."""
    _nonneg(node_per_hour=node_per_hour, tool_mult_bps=tool_mult_bps, companion_bonus=companion_bonus)
    scaled = node_per_hour * MILLI * tool_mult_bps
    _safe(scaled)
    scaled //= BPS
    _safe(scaled * (BPS + companion_bonus))
    return scaled * (BPS + companion_bonus) // BPS


def research_scaled_milli(amount_milli: int, research_bps: int) -> int:
    """研究効果（決定 C2）: 既存の計算結果（図鑑ボーナス込み）に経路別に 1 回だけ掛ける。切り捨て.

    方置 = 既存方置量 × (10000 + I) / 10000、直接 = 既存直接量 × (10000 + A) / 10000（加算ではなく乗算）。
    """
    _nonneg(amount_milli=amount_milli, research_bps=research_bps)
    _safe(amount_milli * (BPS + research_bps))
    return amount_milli * (BPS + research_bps) // BPS


def idle_dex_research_milli(raw_milli: int, dex_bps: int, research_bps: int) -> int:
    """適用順: 図鑑ボーナス（その資源の bps）→ 切り捨て → 研究 → 切り捨て（乗算順序の黄金ベクトル用）.

    施設方置（資源別合計）と直接採集（2026-11-12 から図鑑も掛かる）が同じ順序を使う。
    """
    _nonneg(raw_milli=raw_milli, dex_bps=dex_bps)
    return research_scaled_milli(raw_milli * (BPS + dex_bps) // BPS, research_bps)


# ---- 図鑑ボーナス（2026-11-12 ユーザー決定、docs/spirit_roster_expansion_20261112.md 図鑑ボーナス改編） ----------
# 種ごとに dex_bonus を 1 つ持ち、数値は rules.dex_bonus（等級・種類別）だけで決める。全経路がこの関数の結果を使う。

DEX_RESOURCE = "resource_output"
DEX_SPECIAL_TYPES = ("upgrade_cost_down", "craft_cost_down", "capture_attempt_up")
DEX_COST_TYPES = ("upgrade_cost_down", "craft_cost_down")  # 費用減少として使える種類（それ以外を費用に掛けるのは誤り）


def dex_bonus_map(registered: Iterable[str], spirits: dict[str, Any], rule: dict[str, Any]) -> dict[str, Any]:
    """図鑑登録種の集合 → {"resource_output": {資源: bps}, "upgrade_cost_down": bps, "craft_cost_down": bps, "capture_attempt_up": bps}.

    spirits は 種 → {"grade", "dex_bonus": {"type", "resource"?}}（spirits.json の項目でよい）。data に無い種は無視する
    （保存データに残った削除済みの種で精算が止まらないように）。重複は 1 回だけ数える。合計してから種類別の上限 cap_bps で切る
    （resource_output は資源別）。値が 0 の資源は含めない。
    """
    res: dict[str, int] = {}
    out: dict[str, Any] = {DEX_RESOURCE: res, **{t: 0 for t in DEX_SPECIAL_TYPES}}
    for sid in sorted(set(registered)):
        s = spirits.get(sid)
        if s is None:
            continue
        b = s["dex_bonus"]
        t = b["type"]
        if t == DEX_RESOURCE:
            v = rule["grade_bps"].get(str(s["grade"]))
            if v is None:
                raise FormulaError(f"등급 {s['grade']}의 도감 보너스 수치가 없음: {sid}")
            res[b["resource"]] = res.get(b["resource"], 0) + v
        elif t in DEX_SPECIAL_TYPES:
            out[t] += rule["special_bps"][t]
        else:
            raise FormulaError(f"알 수 없는 도감 보너스 종류: {t}")
    cap = rule["cap_bps"]
    for r in list(res):
        res[r] = min(cap[DEX_RESOURCE], res[r])
        if res[r] <= 0:
            del res[r]
    for t in DEX_SPECIAL_TYPES:
        out[t] = min(cap[t], out[t])
    return out


def dex_scaled_milli(amount_milli: int, dex_bps: int) -> int:
    """生産量に図鑑ボーナスを掛ける: amount × (10000 + dex) // 10000（切り捨て）."""
    _nonneg(amount_milli=amount_milli, dex_bps=dex_bps)
    _safe(amount_milli * (BPS + dex_bps))
    return amount_milli * (BPS + dex_bps) // BPS


def discounted_cost(amount: int, discount_bps: int) -> int:
    """費用の割引: amount − amount × r // 10000（割引額を切り捨て = 費用は切り上げ）。r < 10000 なら amount ≥ 1 → 結果 ≥ 1."""
    _nonneg(amount=amount, discount_bps=discount_bps)
    if discount_bps > BPS:
        raise FormulaError(f"discount_bps는 0..{BPS}: {discount_bps}")
    _safe(amount * discount_bps)
    return amount - amount * discount_bps // BPS


def discounted_costs(costs: list[dict[str, Any]], discount_bps: int) -> list[dict[str, Any]]:
    """費用の各項目に discounted_cost を掛けた新しいリスト（割引 0 なら写しだけ）."""
    return [{**c, "amount": discounted_cost(c["amount"], discount_bps)} for c in costs]


def capture_bonus_attempt_bps(p_bps: int, bonus_bps: int) -> int:
    """図鑑の捕獲確率ボーナス: 道具適用後の成功率 p に加算する。p > 0 のときだけ min(10000, p + bonus)、p ≤ 0（散り）は 0 のまま."""
    _safe(p_bps)
    _nonneg(bonus_bps=bonus_bps)
    if p_bps <= 0:
        return p_bps
    return min(BPS, p_bps + bonus_bps)


def party_power_bps(members: Iterable[tuple[int, int]]) -> int:
    """パーティ戦闘力 = Σ(戦闘力×能力倍率bps)。単位は「戦闘力×bps」."""
    total = 0
    for combat, ability_bps in members:
        _nonneg(combat=combat, ability_bps=ability_bps)
        total += combat * ability_bps
    _safe(total)
    return total


def hunt_rate_milli_per_hour(
    drop_per_hour: int,
    party_power: int,
    recommended_power: int,
    bonus_bps: int,
    min_ratio_bps: int,
    max_ratio_bps: int,
) -> int:
    """狩りドロップ（milli/活動時間）。戦力比が下限未満なら 0、上限で頭打ち."""
    _nonneg(drop_per_hour=drop_per_hour, party_power=party_power, bonus_bps=bonus_bps)
    _nonneg(min_ratio_bps=min_ratio_bps, max_ratio_bps=max_ratio_bps)
    if recommended_power < 1:
        raise FormulaError("recommended_power는 1 이상")
    ratio = party_power // recommended_power
    if ratio < min_ratio_bps:
        return 0
    eff = min(ratio, max_ratio_bps)
    scaled = drop_per_hour * MILLI * eff
    _safe(scaled)
    scaled //= BPS
    _safe(scaled * (BPS + bonus_bps))
    return scaled * (BPS + bonus_bps) // BPS


# ---- 捕獲（固定確率の解析式） -------------------------------------------------------


def capture_success_per_encounter(weight: int, total_weight: int, success_bps: int) -> Fraction:
    """遭遇 1 回あたりその種を捕まえる確率 q = (w/W) × p_grade."""
    _nonneg(weight=weight, success_bps=success_bps)
    if total_weight < 1 or weight > total_weight or success_bps > BPS:
        raise FormulaError("가중치/확률 범위 오류")
    return Fraction(weight, total_weight) * Fraction(success_bps, BPS)


_EXACT_LIMIT = 200_000


def geometric_quantile(q: Any, p: Any) -> int:
    """1-(1-q)^n >= p を満たす最小の n（天井なしの固定確率でのみ有効）."""
    q = to_fraction(q)
    p = to_fraction(p)
    if not (0 < q <= 1) or not (0 < p < 1):
        raise FormulaError(f"범위 오류 q={q}, p={p}")
    if q == 1:
        return 1
    estimate = math.log(1 - float(p)) / math.log1p(-float(q))
    n = max(1, math.ceil(estimate))
    if n > _EXACT_LIMIT:
        return n  # 巨大な n は浮動小数の推定値をそのまま使う（境界一致は保証しない）
    miss = 1 - q
    limit = 1 - p

    def reached(k: int) -> bool:
        return miss**k <= limit

    while n > 1 and reached(n - 1):
        n -= 1
    while not reached(n):
        n += 1
    return n


# ---- 時間（オフライン上限・夜間境界・端数繰越） ------------------------------------


def offline_credit_minutes(gap_minutes: int, cap_minutes: int) -> tuple[int, int]:
    """(認定分, 失効分)。上限を超えた分は生産しない."""
    _nonneg(gap_minutes=gap_minutes, cap_minutes=cap_minutes)
    credited = min(gap_minutes, cap_minutes)
    return credited, gap_minutes - credited


def accrue_milli(rate_milli_per_hour: int, minutes: int, carry: int) -> tuple[int, int]:
    """一定生産率の区間を閉じた式で積算する。carry は (milli×分) の端数で 0..59."""
    _nonneg(rate_milli_per_hour=rate_milli_per_hour, minutes=minutes, carry=carry)
    if carry >= MINUTES_PER_HOUR:
        raise FormulaError("carry는 0..59")
    total = rate_milli_per_hour * minutes + carry
    _safe(total)
    return total // MINUTES_PER_HOUR, total % MINUTES_PER_HOUR


def _night_phase(minute: int, cycle_minutes: int, night_start_offset_minutes: int) -> int:
    """夜の開始からの経過分（0..cycle-1）。phase < night_minutes なら夜."""
    return (minute - night_start_offset_minutes) % cycle_minutes


def night_segments(start_minute: int, end_minute: int, cycle_minutes: int, night_start_offset_minutes: int,
                   night_minutes: int) -> list[tuple[int, int, bool]]:
    """[start, end) をゲーム内時計の夜/昼境界で分割する（隣接する同種区間は結合）。

    分は UTC 通算分（ゲームは os.time()//60、シミュは day0 00:00 起点で同じ軸）。
    ゲーム内の 1 日 = cycle_minutes 分。(分 mod cycle) が [offset, offset+night_minutes) に入る区間（周期で折り返す）が夜。
    2026-11-11 ユーザー決定: cycle 60・offset 30・夜 30 分（毎時 00〜30 分が昼、30〜60 分が夜、全世界同期）.
    """
    _nonneg(start_minute=start_minute, end_minute=end_minute)
    if end_minute < start_minute:
        raise FormulaError("end < start")
    if cycle_minutes < 1 or not 0 <= night_start_offset_minutes < cycle_minutes or not 0 <= night_minutes <= cycle_minutes:
        raise FormulaError("cycle ≥ 1, 0 ≤ offset < cycle, 0 ≤ night_minutes ≤ cycle")
    if start_minute == end_minute:
        return []
    if night_minutes in (0, cycle_minutes):
        return [(start_minute, end_minute, night_minutes == cycle_minutes)]
    segs: list[tuple[int, int, bool]] = []
    t = start_minute
    while t < end_minute:
        phase = _night_phase(t, cycle_minutes, night_start_offset_minutes)
        flag = phase < night_minutes
        seg_end = min(end_minute, t + ((night_minutes - phase) if flag else (cycle_minutes - phase)))
        segs.append((t, seg_end, flag))
        t = seg_end
    return segs


# ---- G2 指標 ------------------------------------------------------------------


def g2_ratio(direct_milli_per_hour: int, idle_milli_per_hour: int) -> Fraction | None:
    """R = 直接採集の追加獲得量 / 同じ状態の放置量（時間当たり）。分母 0 は None."""
    _nonneg(direct=direct_milli_per_hour, idle=idle_milli_per_hour)
    if idle_milli_per_hour == 0:
        return None
    return Fraction(direct_milli_per_hour, idle_milli_per_hour)


def direct_share(direct_hours: Any, ratio: Any, idle_hours: Any) -> Fraction:
    """1 日の直接比重 S = hR/(hR+H)（報告専用・合否基準ではない）."""
    h, r, big_h = to_fraction(direct_hours), to_fraction(ratio), to_fraction(idle_hours)
    denom = h * r + big_h
    if denom <= 0:
        raise FormulaError("분모가 0 이하")
    return h * r / denom


# ---- 捕獲の状態機械（2026-11-10 決定。capture.json の規則で計算する純粋関数） -------------------------
# 確率関数（試行成功率・光区間・逃走）は成長・活力・商品・研究を入力に持たない。成長・活力は弱体化の秒数だけに効く。
# rule は capture.json の文書（必要なキーだけの部分集合でもよい）。

ENCOUNTER_RESULTS = ("success", "flee", "wick_out", "scatter")


def _grade_bps(rule: dict[str, Any], grade: int) -> int:
    for g in rule["base_success_bps_by_grade"]:
        if g["grade"] == grade:
            return g["bps"]
    raise FormulaError(f"등급 {grade}의 성공률이 없음")


def capture_attempt_bps(grade: int, light: int, rule: dict[str, Any]) -> int:
    """1 回の試行の成功率（bps）= 等級の基本成功率 × 光(H)区間の倍率（切り捨て、上限 10000）。光が散り限界以下なら 0."""
    _safe(grade, light)
    lt = rule["light"]
    if light <= lt["scatter_at_or_below"]:
        return 0
    mult = BPS
    for b in lt["bands"]:  # above の降順。最初に light > above となる区間
        if light > b["above"]:
            mult = b["mult_bps"]
            break
    return min(BPS, _grade_bps(rule, grade) * mult // BPS)


def flee_bps(failures: int, rule: dict[str, Any]) -> int:
    """失敗 failures 回目の直後に逃げる確率（bps）= min(max, first + step×(failures−1))。failures ≥ 1."""
    _safe(failures)
    if failures < 1:
        raise FormulaError("failures는 1 이상")
    fl = rule["flee_after_failure"]
    return min(fl["max_bps"], fl["first_bps"] + fl["step_bps"] * (failures - 1))


def capture_k_max(rule: dict[str, Any], limit: int = 20) -> int:
    """1 遭遇の最大試行数 = 逃走確率が 100% に達する失敗回数（以降は試行できない）。limit 以内に達しなければ FormulaError."""
    for k in range(1, limit + 1):
        if flee_bps(k, rule) >= BPS:
            return k
    raise FormulaError(f"실패 {limit}회 안에 도망 확률이 100%에 도달하지 않음")


def weaken_needed(grade: int, rule: dict[str, Any]) -> bool:
    """簡易モードで弱体化するか。弱体化しても成功率が上がらない（★1 など既に 100%）なら飛ばす（skip_when_no_gain）."""
    lt = rule["light"]
    stop = rule["easy_mode"]["stop_at_light"]
    if not rule.get("weaken", {}).get("skip_when_no_gain", True):
        return True
    return capture_attempt_bps(grade, stop, rule) > capture_attempt_bps(grade, lt["max"], rule)


def easy_attempt_light(grade: int, rule: dict[str, Any]) -> int:
    """簡易モードで試行するときの光: 弱体化するなら停止点（stop_at_light、散らない）、しないなら最大値."""
    return rule["easy_mode"]["stop_at_light"] if weaken_needed(grade, rule) else rule["light"]["max"]


def _gap_mult_bps(rule: dict[str, Any], gap: int) -> int:
    for g in rule["weaken"]["grade_gap_mult_bps"]:
        if g["gap"] == gap:
            return g["bps"]
    raise FormulaError(f"등급 차 {gap}의 배율이 없음")


def weaken_seconds(attacker_grade: int, attacker_level: int, target_grade: int, vigor: Any, rule: dict[str, Any]) -> int:
    """同行精霊 1 体が簡易モードの弱体化（光 max → stop_at_light）にかける秒数（活力の効率込みの最終値）。活力 0 以下は −1（行動不可）.

    D = damage × 等級差倍率 M[clamp(攻撃−対象, −3, 3)] × レベル倍率 B(1 + min(per_level×(L−1), cap)) × 活力倍率 V（≤low なら low_mult）
    打数 n = ceil((max − stop) / D)、秒 = clamp(標準攻撃秒 × n, min_seconds, max_seconds)。整数で厳密に計算する。
    """
    _safe(attacker_grade, attacker_level, target_grade)
    if attacker_level < 1:
        raise FormulaError("attacker_level은 1 이상")
    v = to_fraction(vigor)
    if v <= 0:
        return -1
    wk, vg, lt = rule["weaken"], rule["vigor"], rule["light"]
    gap = max(-3, min(3, attacker_grade - target_grade))
    m = _gap_mult_bps(rule, gap)
    b = BPS + min(wk["level_bps_per_level"] * (attacker_level - 1), wk["level_bps_cap"])
    vm = vg["low_mult_bps"] if v <= vg["low_at_or_below"] else BPS
    need = lt["max"] - rule["easy_mode"]["stop_at_light"]
    num = need * BPS * BPS * BPS
    den = lt["standard_attack"]["damage"] * m * b * vm
    _safe(num, den)
    if den <= 0:
        raise FormulaError("약화 피해가 0")
    n = -(-num // den)
    return max(wk["min_seconds"], min(wk["max_seconds"], lt["standard_attack"]["seconds"] * n))


def weaken_vigor_cost(attacker_grade: int, target_grade: int, rule: dict[str, Any]) -> int:
    """弱体化 1 回（1 遭遇）の活力消費 = base + per_gap × max(攻撃−対象, 0)（等級差は ±3 で頭打ち）."""
    _safe(attacker_grade, target_grade)
    c = rule["vigor"]["weaken_cost"]
    return c["base"] + c["per_gap"] * max(0, min(3, attacker_grade - target_grade))


def resolve_encounter(grade: int, rule: dict[str, Any], uniforms: list[float], wicks_available: int,
                      weaken_s: int) -> list[Any]:
    """簡易モード 1 遭遇の結果 [result, attempts, wicks_used, seconds]（捕獲補助道具なし）.

    uniforms は [試行成功 K_max 個, 逃走 K_max 個]（一様 [0,1)）。i 回目の試行は uniforms[i−1]、i 回目の失敗後の逃走は
    uniforms[K_max+i−1] を使う（試行数に依らず位置が固定）。wicks_available < 0 は芯無制限（wicks_used は 0 を返す）。
    result/attempts/wicks_used は grade・rule・uniforms・wicks_available だけで決まり、weaken_s は seconds にだけ足す。
    道具版 resolve_encounter_tool の tools_available=0 と同じ結果（実装は 1 つ）。
    """
    return resolve_encounter_tool(grade, rule, uniforms, wicks_available, weaken_s, 0)[:4]


# ---- 捕獲補助道具（2026-11-11 ユーザー決定。「成功率は等級別固定」の明示的な例外、検証器 RULE_CAPTURE_TOOL） ----
# rule["capture_tool"] が無いデータでは道具は常に無効（倍率 = BPS）。確率は試行ごとの成功率だけを変え、逃走・弱体化・出現・
# 個体値・乱数の消費順は変えない。


def capture_tool_mult_bps(grade: int, rule: dict[str, Any]) -> int:
    """等級の道具倍率（bps）。capture_tool が無い・その等級の倍率が無い（★1）なら BPS（効果なし）."""
    _safe(grade)
    ct = rule.get("capture_tool")
    if not ct:
        return BPS
    for g in ct["mult_bps_by_grade"]:
        if g["grade"] == grade:
            return g["bps"]
    return BPS


def capture_tool_attempt_bps(grade: int, light: int, rule: dict[str, Any]) -> int:
    """道具を使った 1 回の試行の成功率（bps）= min(max_bps, 基本成功率 × 等級倍率)（切り捨て）。基本より下がることはない.

    基本成功率 = capture_attempt_bps（等級 bps × 光(H)区間倍率）。散り限界以下（0）は道具でも 0。
    """
    base = capture_attempt_bps(grade, light, rule)
    mult = capture_tool_mult_bps(grade, rule)
    if base <= 0 or mult <= BPS:
        return base
    cap = rule["capture_tool"]["max_bps"]
    return max(base, min(cap, base * mult // BPS))


def capture_tool_item(home_field: str, grade: int, unlocked_fields: list[str], directly_captured: bool,
                      rule: dict[str, Any]) -> str | None:
    """この遭遇に効く道具の資源 ID（効かなければ None）.

    条件（全部必要）: capture_tool がある、等級に倍率がある（★1 は無し）、unlock_after_field が解禁済み（全体）、
    対象種を直接捕獲したことがある（初捕獲は無効、開始精霊は直接捕獲ではない）、対象種の固有フィールド（home_field）の道具。
    遭遇したフィールドではなく home_field で決まる。
    """
    ct = rule.get("capture_tool")
    if not ct or capture_tool_mult_bps(grade, rule) <= BPS:
        return None
    if ct["unlock_after_field"] not in unlocked_fields or not directly_captured:
        return None
    for it in ct["items"]:
        if it["field_id"] == home_field:
            return it["resource"]
    return None


def resolve_encounter_tool(grade: int, rule: dict[str, Any], uniforms: list[float], wicks_available: int,
                           weaken_s: int, tools_available: int, capture_bonus_bps: int = 0) -> list[Any]:
    """簡易モード 1 遭遇の結果 [result, attempts, wicks_used, seconds, tools_used]（捕獲補助道具あり）.

    capture_bonus_bps は図鑑の捕獲確率ボーナス（dex_bonus_map の capture_attempt_up）。道具の有無を決めた後の各試行の成功率に
    capture_bonus_attempt_bps で加える（逃走・乱数の位置・道具の消費は変えない）。

    tools_available は使える道具の在庫（個、0 なら道具なし）。各試行の直前に在庫が per_attempt 個以上残っていればその試行で
    消費し、成功率を capture_tool_attempt_bps にする。残っていなければその試行は道具なしで進める（芯は別に 1 回分消費）。
    等級に倍率がなければ（★1）道具は消費しない。乱数の位置・逃走判定は resolve_encounter と同じ。
    """
    _safe(grade, weaken_s, wicks_available, tools_available)
    unlimited = wicks_available < 0
    k = capture_k_max(rule)
    if len(uniforms) < 2 * k:
        raise FormulaError(f"uniforms는 {2 * k}개 필요")
    light = easy_attempt_light(grade, rule)
    p = capture_bonus_attempt_bps(capture_attempt_bps(grade, light, rule), capture_bonus_bps)
    pt = capture_bonus_attempt_bps(capture_tool_attempt_bps(grade, light, rule), capture_bonus_bps)
    tool_per = rule["capture_tool"]["per_attempt"] if tools_available > 0 and capture_tool_mult_bps(grade, rule) > BPS else 0
    per = sum(c["amount"] for c in rule["attempt_cost"])
    attempts = used = tools_used = 0
    result = "flee"
    for i in range(1, k + 1):
        if not unlimited and wicks_available - used < per:
            result = "wick_out"
            break
        attempts += 1
        used += per
        pi = p
        if tool_per > 0 and tools_available - tools_used >= tool_per:
            tools_used += tool_per
            pi = pt
        if uniforms[i - 1] * BPS < pi:
            result = "success"
            break
        if uniforms[k + i - 1] * BPS < flee_bps(i, rule):
            result = "flee"
            break
    t = rule["time"]
    return [result, attempts, 0 if unlimited else used,
            t["encounter_base_seconds"] + weaken_s + t["attempt_seconds"] * attempts, tools_used]


def encounter_expectation(grade: int, rule: dict[str, Any], with_tool: bool = False,
                          capture_bonus_bps: int = 0) -> tuple[Fraction, Fraction]:
    """簡易モード・芯無制限での (遭遇あたり捕獲確率 Q, 期待試行数 E[A])（有理数で厳密）.

    with_tool=True は全試行で道具を使う（在庫無制限）ときの値（成功率 = capture_tool_attempt_bps、逃走は同じ）。
    capture_bonus_bps は図鑑の捕獲確率ボーナス（道具の後に capture_bonus_attempt_bps で加える）。
    """
    light = easy_attempt_light(grade, rule)
    base = capture_tool_attempt_bps(grade, light, rule) if with_tool else capture_attempt_bps(grade, light, rule)
    p = Fraction(capture_bonus_attempt_bps(base, capture_bonus_bps), BPS)
    k = capture_k_max(rule)
    q = ea = Fraction(0)
    alive = Fraction(1)
    for i in range(1, k + 1):
        ea += alive
        q += alive * p
        alive *= (1 - p) * (1 - Fraction(flee_bps(i, rule), BPS))
    return q, ea


def vigor_hunt_scaled_milli(rate_milli: int, powers: Iterable[int], mults_bps: Iterable[int]) -> int:
    """狩りの産出を活力で縮める: rate × Σ(戦闘力_i × 倍率_i) / (Σ戦闘力_i × BPS)（切り捨て）。戦闘力ではなく産出に掛ける."""
    ps, ms = list(powers), list(mults_bps)
    _nonneg(rate_milli=rate_milli)
    if len(ps) != len(ms):
        raise FormulaError("powers와 mults_bps의 길이가 다름")
    total = sum(ps)
    if total <= 0:
        return 0
    num = sum(p * m for p, m in zip(ps, ms))
    _safe(total, num, rate_milli * num)
    return rate_milli * num // (total * BPS)


# ---- test_vectors.json 実行用ディスパッチ ------------------------------------------------


def _jsonable(v: Any) -> Any:
    if isinstance(v, Fraction):
        return str(v)
    if isinstance(v, tuple):
        return [_jsonable(x) for x in v]
    if isinstance(v, list):
        return [_jsonable(x) for x in v]
    return v


VECTOR_FUNCS: dict[str, Callable[..., Any]] = {
    "exp_ceil_cost": exp_ceil_cost,
    "exp_ceil_capped_cost": exp_ceil_capped_cost,
    "linear_ceil_capped_cost": linear_ceil_capped_cost,
    "linear_milestone_bps": lambda per_level_bps, level, milestones: linear_milestone_bps(
        per_level_bps, level, [tuple(m) for m in milestones]
    ),
    "slot_power_bps": slot_power_bps,
    "idle_rate_milli_per_hour": idle_rate_milli_per_hour,
    "companion_bonus_bps": companion_bonus_bps,
    "direct_rate_milli_per_hour": direct_rate_milli_per_hour,
    "research_scaled_milli": research_scaled_milli,
    "idle_dex_research_milli": idle_dex_research_milli,
    "dex_bonus_map": dex_bonus_map,
    "dex_scaled_milli": dex_scaled_milli,
    "discounted_cost": discounted_cost,
    "capture_bonus_attempt_bps": capture_bonus_attempt_bps,
    "party_power_bps": lambda members: party_power_bps([tuple(m) for m in members]),
    "hunt_rate_milli_per_hour": hunt_rate_milli_per_hour,
    "capture_success_per_encounter": capture_success_per_encounter,
    "geometric_quantile": geometric_quantile,
    "offline_credit_minutes": offline_credit_minutes,
    "accrue_milli": accrue_milli,
    "night_segments": night_segments,
    "g2_ratio": g2_ratio,
    "direct_share": direct_share,
    "capture_attempt_bps": capture_attempt_bps,
    "flee_bps": flee_bps,
    "capture_k_max": capture_k_max,
    "weaken_needed": weaken_needed,
    "easy_attempt_light": easy_attempt_light,
    "weaken_seconds": weaken_seconds,
    "weaken_vigor_cost": weaken_vigor_cost,
    "resolve_encounter": resolve_encounter,
    "encounter_expectation": encounter_expectation,
    "capture_tool_mult_bps": capture_tool_mult_bps,
    "capture_tool_attempt_bps": capture_tool_attempt_bps,
    # JSON に null を置かないため「効く道具なし」は空文字列で比較する
    "capture_tool_item": lambda **a: capture_tool_item(**a) or "",
    "resolve_encounter_tool": resolve_encounter_tool,
    "vigor_hunt_scaled_milli": vigor_hunt_scaled_milli,
}


def call_vector(fn: str, args: dict[str, Any]) -> Any:
    """test_vectors.json の 1 件を実行し、JSON で比較できる形で返す（Fraction は "分子/分母" 文字列）."""
    if fn not in VECTOR_FUNCS:
        raise FormulaError(f"알 수 없는 함수: {fn}")
    return _jsonable(VECTOR_FUNCS[fn](**args))
