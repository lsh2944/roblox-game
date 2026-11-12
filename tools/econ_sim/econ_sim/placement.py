"""施設への精霊配置.

- heuristic: 貪欲（限界増分が最大の (精霊, 施設) を順に埋める）+ 2-swap・移動の局所改善。シミュで使い、結果は「発見した配置」と表記する。
- exact: 施設ごとの部分集合値を使う部分集合 DP（施設間で値が独立なので厳密）。小さい代表状態の収束分析とテストで使う。
- best_single: 1 施設だけの厳密最適（種別 DP）。G2 判定分母（その資源の最善配置）と、放置・配置候補の保護に使う。
目的関数 = Σ 施設 weight[生産資源] × 施設生産（milli/時）。
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from .economy import Economy

EPS = 1e-9


@dataclass(frozen=True)
class Slot:
    fid: str
    level: int
    slots: int


@dataclass
class Placement:
    assign: dict[str, list[int]]  # 施設 → 精霊インデックス（入力 spirits の位置）
    value: float
    method: str
    proven_optimal: bool


class _Evaluator:
    def __init__(self, econ: Economy, facs: list[Slot], spirits: list[tuple[str, int]], weights: dict[str, float], night: bool):
        self.econ, self.facs, self.spirits, self.weights, self.night = econ, facs, spirits, weights, night
        self.cache: dict[tuple[int, tuple[int, ...]], float] = {}

    def value(self, k: int, idxs: tuple[int, ...]) -> float:
        key = (k, idxs)
        v = self.cache.get(key)
        if v is None:
            f = self.facs[k]
            w = self.weights.get(self.econ.m.facilities[f.fid]["produces"], 0.0)
            v = w * self.econ.facility_rate(f.fid, f.level, [self.spirits[i] for i in idxs], self.night) if (w and idxs) else 0.0
            self.cache[key] = v
        return v


def _key(idxs: list[int]) -> tuple[int, ...]:
    return tuple(sorted(idxs))


def heuristic(econ: Economy, facs: list[Slot], spirits: list[tuple[str, int]], weights: dict[str, float],
              night: bool = False, max_passes: int = 20) -> Placement:
    ev = _Evaluator(econ, facs, spirits, weights, night)
    groups: list[list[int]] = [[] for _ in facs]
    where: list[int] = [-1] * len(spirits)  # -1 = 控え
    # 貪欲
    while True:
        best = (EPS, -1, -1)
        for i in range(len(spirits)):
            if where[i] != -1:
                continue
            for k, f in enumerate(facs):
                if len(groups[k]) >= f.slots:
                    continue
                gain = ev.value(k, _key(groups[k] + [i])) - ev.value(k, _key(groups[k]))
                if gain > best[0]:
                    best = (gain, i, k)
        if best[1] < 0:
            break
        _, i, k = best
        groups[k].append(i)
        where[i] = k

    def group_val(k: int, members: list[int]) -> float:
        return ev.value(k, _key(members)) if k >= 0 else 0.0

    # 局所改善: 2 体の位置交換と、空き枠への移動
    for _ in range(max_passes):
        improved = False
        n = len(spirits)
        for i in range(n):
            for j in range(i + 1, n):
                a, b = where[i], where[j]
                if a == b or (a == -1 and b == -1):
                    continue
                ga = [x for x in groups[a] if x != i] + [j] if a >= 0 else []
                gb = [x for x in groups[b] if x != j] + [i] if b >= 0 else []
                before = (group_val(a, groups[a]) if a >= 0 else 0.0) + (group_val(b, groups[b]) if b >= 0 else 0.0)
                after = (group_val(a, ga) if a >= 0 else 0.0) + (group_val(b, gb) if b >= 0 else 0.0)
                if after > before + EPS:
                    if a >= 0:
                        groups[a] = ga
                    if b >= 0:
                        groups[b] = gb
                    where[i], where[j] = b, a
                    improved = True
        for i in range(n):
            a = where[i]
            for k, f in enumerate(facs):
                if k == a or len(groups[k]) >= f.slots:
                    continue
                ga = [x for x in groups[a] if x != i] if a >= 0 else []
                before = (group_val(a, groups[a]) if a >= 0 else 0.0) + group_val(k, groups[k])
                after = (group_val(a, ga) if a >= 0 else 0.0) + group_val(k, groups[k] + [i])
                if after > before + EPS:
                    if a >= 0:
                        groups[a] = ga
                    groups[k] = groups[k] + [i]
                    where[i] = k
                    a = k
                    improved = True
        # 連鎖移動: i を空き枠のある施設 k へ移し、空いた元の枠へ別の精霊 j を入れる（単独では悪化する 2 手の組）
        for i in range(n):
            a = where[i]
            if a < 0:
                continue
            for k, f in enumerate(facs):
                if k == a or len(groups[k]) >= f.slots:
                    continue
                for j in range(n):
                    b = where[j]
                    if j == i or b == a:
                        continue
                    new = {a: [x for x in groups[a] if x != i] + [j], k: groups[k] + [i]}
                    if b >= 0:
                        new[b] = [x for x in new.get(b, groups[b]) if x != j]
                    if any(len(g) > facs[g_k].slots for g_k, g in new.items()):
                        continue
                    before = sum(group_val(g_k, groups[g_k]) for g_k in new)
                    after = sum(group_val(g_k, g) for g_k, g in new.items())
                    if after > before + EPS:
                        for g_k, g in new.items():
                            groups[g_k] = g
                        where[i], where[j] = k, a
                        improved = True
                        break
                if where[i] != a:
                    break
        if not improved:
            break
    total = sum(group_val(k, g) for k, g in enumerate(groups))
    return Placement({f.fid: sorted(groups[k]) for k, f in enumerate(facs)}, total, "heuristic_greedy_2swap", False)


def exact(econ: Economy, facs: list[Slot], spirits: list[tuple[str, int]], weights: dict[str, float],
          night: bool = False, max_spirits: int = 14) -> Placement:
    n = len(spirits)
    if n > max_spirits:
        raise ValueError(f"정확 탐색은 정령 {max_spirits}마리 이하만 지원(현재 {n})")
    ev = _Evaluator(econ, facs, spirits, weights, night)
    full = (1 << n) - 1
    pop = [bin(x).count("1") for x in range(1 << n)]
    dp: dict[int, tuple[float, tuple[int, ...]]] = {0: (0.0, ())}
    for k, f in enumerate(facs):
        # 施設 k の部分集合値を先に全部求める（DP 内は表引きだけにする）
        vals = [ev.value(k, tuple(i for i in range(n) if sub >> i & 1)) if pop[sub] <= f.slots else -1.0
                for sub in range(1 << n)]
        new: dict[int, tuple[float, tuple[int, ...]]] = {}
        for mask, (v, choice) in dp.items():
            comp = full & ~mask
            sub = comp
            while True:
                if vals[sub] >= 0.0:
                    v2 = v + vals[sub]
                    m2 = mask | sub
                    cur = new.get(m2)
                    if cur is None or v2 > cur[0] + EPS:
                        new[m2] = (v2, choice + (sub,))
                if sub == 0:
                    break
                sub = (sub - 1) & comp
        dp = new
    best_mask = max(dp, key=lambda m: (dp[m][0], -m))
    value, choice = dp[best_mask]
    assign = {f.fid: [i for i in range(n) if choice[k] >> i & 1] for k, f in enumerate(facs)}
    return Placement(assign, value, "exact_subset_dp", True)


def best_single(econ: Economy, fac: Slot, spirits: list[tuple], night: bool = False) -> Placement:
    """1 施設だけの厳密最適配置（種別 DP、ロスターが大きくても多項式時間）.

    施設生産 = K × Σ枠寄与 × (1 + 混合ボーナス) で、寄与は非負・混合ボーナスは種の集合だけで決まり、種が増えても減らない。
    よって枠を埋める（k = min(枠, 精霊数)）配置の中に最適があり、同じ種なら寄与の高い個体から使えばよい。
    ボーナスの提供種 s（なし／混合特性を持つ各種）ごとに「s を 1 体以上含み、異なる種が min_distinct_species 以上」の条件下で
    Σ寄与を最大化する種別ナップサック DP を解き、各候補の実生産（facility_rate）の最大を採る。
    最適配置 O の提供種を s* とすると、s* の候補は Σ寄与 ≥ O かつボーナス ≥ O なので、切り捨て込みでも O 以上になる（厳密）。
    """
    from .economy import norm_member

    res = econ.m.facilities[fac.fid]["produces"]
    k = min(fac.slots, len(spirits))
    if k <= 0 or fac.level <= 0:
        return Placement({fac.fid: []}, 0.0, "exact_species_dp", True)
    norm = [norm_member(s) for s in spirits]
    power = [econ.slot_power(sp, lv, res, night, g) for sp, lv, g, _ in norm]
    by_sp: dict[str, list[int]] = {}
    for i, (sp, *_rest) in enumerate(norm):
        by_sp.setdefault(sp, []).append(i)
    order = sorted(by_sp)  # 種の処理順を固定（決定性）
    for sp in order:
        by_sp[sp].sort(key=lambda i: (-power[i], i))  # 同じ種は寄与の高い順（同値は入力順）
    mixed = econ.mixed_traits()
    classes: list[tuple[str | None, int]] = [(None, 1)] + [(sp, max(1, mixed[sp][1])) for sp in order if sp in mixed]
    best: tuple[float, list[int]] | None = None
    for req, need in classes:
        # dp[(使用数, min(異なる種数, need))] = (Σ寄与, 種ごとの使用数)
        dp: dict[tuple[int, int], tuple[int, tuple[int, ...]]] = {(0, 0): (0, ())}
        for sp in order:
            idxs = by_sp[sp]
            prefix = [0]
            for i in idxs[:k]:
                prefix.append(prefix[-1] + power[i])
            lo = 1 if sp == req else 0
            new: dict[tuple[int, int], tuple[int, tuple[int, ...]]] = {}
            for (used, d), (val, counts) in dp.items():
                for c in range(lo, min(k - used, len(idxs)) + 1):
                    key = (used + c, min(need, d + (1 if c else 0)))
                    v2 = val + prefix[c]
                    cur = new.get(key)
                    if cur is None or v2 > cur[0]:
                        new[key] = (v2, counts + (c,))
            dp = new
        hit = dp.get((k, need))
        if hit is None:
            continue  # 種数が足りずこの提供種の条件を満たせない
        chosen = [i for sp, c in zip(order, hit[1]) for i in by_sp[sp][:c]]
        value = float(econ.facility_rate(fac.fid, fac.level, [spirits[i] for i in chosen], night))
        if best is None or value > best[0] + EPS:
            best = (value, sorted(chosen))
    assert best is not None  # 提供種なしの候補は k ≤ 精霊数なので必ず成立する
    return Placement({fac.fid: best[1]}, best[0], "exact_species_dp", True)


def describe(assign: dict[str, list[int]], spirits: list[tuple[str, Any]]) -> dict[str, list[str]]:
    return {fid: sorted(spirits[i][0] for i in idxs) for fid, idxs in assign.items()}
