"""プレイヤー状態と日次集計（量は全て milli 整数、時間は通算分）."""
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class SpiritInst:
    uid: int
    species: str
    level: int
    gather_bps: int = 10_000  # 個体値（F2）: 採集・生産倍率 bps
    combat_bps: int = 10_000  # 個体値（F2）: 戦闘倍率 bps


@dataclass
class RStat:
    """採集ステップの R 集計（移行区間の内外を分ける）."""

    r_sum: float = 0.0  # Σ R × 分（R が定義できたステップのみ）
    r_minutes: int = 0
    over_outside: int = 0  # 移行区間外で R > 最大倍率の分
    over_transition: int = 0
    undefined_outside: int = 0  # 方置 0（R=∞）の分
    undefined_transition: int = 0
    max_outside: float = 0.0
    max_transition: float = 0.0

    def add(self, ratio: float | None, minutes: int, transition: bool, threshold: float) -> None:
        if ratio is None:
            if transition:
                self.undefined_transition += minutes
            else:
                self.undefined_outside += minutes
            return
        self.r_sum += ratio * minutes
        self.r_minutes += minutes
        if transition:
            self.max_transition = max(self.max_transition, ratio)
            if ratio > threshold:
                self.over_transition += minutes
        else:
            self.max_outside = max(self.max_outside, ratio)
            if ratio > threshold:
                self.over_outside += minutes


@dataclass
class DayAcc:
    """1 日分の集計（その日に属する区間だけを加算する）."""

    minutes: dict[str, int] = field(default_factory=dict)  # online/gather/hunt/capture/decor/manage/off_credited/off_lost
    earned: dict[tuple[str, str], int] = field(default_factory=dict)  # (source, resource) → milli
    spent: dict[str, int] = field(default_factory=dict)
    # G2: 判定は「現在の保有精霊で可能な最善配置」基準、実配置基準は参考（4 段階のメイン決定）
    r_best: RStat = field(default_factory=RStat)
    r_actual: RStat = field(default_factory=RStat)
    home_by_grade: dict[int, int] = field(default_factory=dict)  # F1 方置特殊財の等級別獲得（milli）
    fac_minutes: dict[str, int] = field(default_factory=dict)  # 種 → 生産に寄与した配置分
    party_minutes: dict[str, int] = field(default_factory=dict)
    released: dict[str, int] = field(default_factory=dict)
    # 捕獲の状態機械（段階 2）: 予算秒・使用秒、完了した遭遇のフィールド別件数・秒（完了日に計上）
    cap_budget_s: int = 0
    cap_used_s: int = 0
    enc_done: dict[str, int] = field(default_factory=dict)
    enc_seconds: dict[str, int] = field(default_factory=dict)
    # 弱体化（開始日に計上）: 弱体化した遭遇数・秒の合計・灯籠の補助弱体化の件数
    weaken_n: int = 0
    weaken_seconds: int = 0
    assist_weaken: int = 0
    # 活力: 給餌数、活力が low 以下の同行の狩り分（精霊×分）
    food_eaten: int = 0
    # 給餌の不足（活力 ≤ 給餌閾値の同行に与えられなかった回数）: 直近窓の上限 / 在庫・制作不可（段階 5 food_shortage）
    food_short_window: int = 0
    hunt_party_min: int = 0  # 狩りの同行精霊×分（vigor_low_share の分母）
    # 完了日に計上: (等級, 結果) → 件数、等級 → 試行数（capture_rule_conformance・capture_outcome_share）
    grade_results: dict[tuple[int, str], int] = field(default_factory=dict)
    grade_attempts: dict[int, int] = field(default_factory=dict)
    sink_spent: dict[str, int] = field(default_factory=dict)  # 有限の消費先（家・家具・衣装・図鑑記録）への支出（素材展開後、milli）
    sink_spent_repeat: dict[str, int] = field(default_factory=dict)  # 反復の消費先（モジュール・祭壇）への支出
    field_attempts: dict[str, int] = field(default_factory=dict)  # フィールド別の試行数（完了日）
    # 開始時に芯が K_max 回分以上あった遭遇だけの (等級, enc|success) 件数（capture_rule_conformance の偏り除去）
    grade_results_full: dict[tuple[int, str], int] = field(default_factory=dict)
    food_short_stock: int = 0
    vigor_low_hunt_min: int = 0
    wick_craft_hunt: int = 0  # 芯の制作に投入した狩り素材（milli、2026-11-11 狩り素材の用途内訳用）
    # 捕獲補助道具（2026-11-11）: 道具 → 制作した個数（milli）、制作に投入した狩り素材（milli）、フィールド → 消費した個数（開始日）
    lure_craft: dict[str, int] = field(default_factory=dict)
    lure_craft_hunt: int = 0
    lure_used: dict[str, int] = field(default_factory=dict)
    # 道具を 1 個以上使った遭遇（完了日）: (等級, enc|success|full_enc|full_success) → 件数、道具を使った試行数
    tool_grade: dict[tuple[int, str], int] = field(default_factory=dict)
    tool_attempts: int = 0
    # 回帰の番人（常に 0 のはず）: 道具を使った遭遇での初捕獲・unlock_after_field 解禁前の道具使用（開始日）
    tool_first_capture: int = 0
    tool_pre_unlock: int = 0

    def add_min(self, key: str, n: int) -> None:
        self.minutes[key] = self.minutes.get(key, 0) + n

    def add_earned(self, source: str, res: str, milli: int) -> None:
        if milli:
            self.earned[(source, res)] = self.earned.get((source, res), 0) + milli


@dataclass
class State:
    wallet: dict[str, int]
    unlocked: list[str]
    fac_level: dict[str, int]
    fac_slots: dict[str, int]
    tool_level: int
    roster: dict[int, SpiritInst]
    next_uid: int
    assignment: dict[str, list[int]]
    hub_rank: int
    offline_cap_hours: int
    storage_bonus: int = 0
    pass_owned: bool = False
    pass_claimed: set[str] = field(default_factory=set)
    purchase_total: dict[str, int] = field(default_factory=dict)
    purchase_day: dict[tuple[str, int], int] = field(default_factory=dict)
    robux: int = 0
    captures: int = 0
    encounters: int = 0
    releases: int = 0
    first_capture: dict[str, tuple[int, int]] = field(default_factory=dict)  # 種 → (時刻, その時点の累計遭遇数)
    field_unlock_time: dict[str, int] = field(default_factory=dict)
    storage_full_time: int | None = None
    exhausted_time: int | None = None
    quest_day: int = -1
    dex: set[str] = field(default_factory=set)  # 図鑑登録済みの種（F5）
    # 研究ツリー: 完了ノード・完了時刻（通算分）・進行中ノード → 完了予定時刻
    research_done: set[str] = field(default_factory=set)
    research_done_time: dict[str, int] = field(default_factory=dict)
    research_active: dict[str, int] = field(default_factory=dict)
    # 捕獲（段階 2）: 累計試行数・結果別の完了件数（success/flee/wick_out/scatter）
    attempts: int = 0
    result_counts: dict[str, int] = field(default_factory=dict)
    # 活力（tick、1 点 = 60）・最終更新時刻（この時刻までは回復済み、活動中は未来の時刻になる）・直近の給餌時刻
    vigor: dict[int, int] = field(default_factory=dict)
    vigor_t: dict[int, int] = field(default_factory=dict)
    feed_times: dict[int, list[int]] = field(default_factory=dict)
    # 消費先（段階 3）: 有限品目 → 購入時刻、反復消費先 → レベル、有限品目を全部買った時刻
    sinks_owned: dict[str, int] = field(default_factory=dict)
    repeat_levels: dict[str, int] = field(default_factory=dict)
    finite_completed_time: int | None = None
    dex_pages: dict[str, int] = field(default_factory=dict)  # 図鑑記録: 種 → 購入済みページ数
    version: int = 0
