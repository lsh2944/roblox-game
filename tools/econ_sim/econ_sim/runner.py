"""ペルソナ × 反復のシミュ実行と CSV 出力（daily / events / spirit_daily）.

並列（--workers）でも結果の順序は (ペルソナ設定順, replicate 昇順) に固定し、CSV バイトは並列数に依存しない。
"""
from __future__ import annotations

import csv
import os
import tempfile
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
from typing import Any, Iterable

from . import jsonio
from .data_load import load_data
from .economy import Economy
from .metrics_capture import encode_dex_full
from .model import Model
from .sim import DAY, Simulator
from .sim_config import load_personas

# craft=制作の産出、grant=芯などの支給（開始・解禁）、sink=消費先の報酬（MVP は効果 0 で常に 0）
SOURCES = ("idle", "direct", "hunt", "quest", "paid", "release", "craft", "grant", "sink")
R_KEYS = ("r_mean", "r_minutes", "over_max_minutes", "over_max_transition_minutes", "undefined_minutes",
          "undefined_transition_minutes", "r_max_outside", "r_max_transition")


DAILY_BASE = [
    "persona_id", "pairing_group_id", "replicate_id", "day", "fields_unlocked", "highest_field",
    "online_min", "gather_min", "hunt_min", "capture_min", "decor_min", "manage_min",
    "offline_credited_min", "offline_lost_min", "spirit_count", "capacity", "encounters_cum", "captures_cum",
    "releases_cum", "robux_cum", "pass_claims_cum", "content_exhausted", "facility_level_sum",
    "tool_level", "offline_cap_h", "hub_rank", "best_party_combat", "dex_registered", "research_done", "direct_share_basic",
    *[f"g2_{b}_{k}" for b in ("best", "actual") for k in R_KEYS],
    "home_g1", "home_g2", "home_g3", "home_g4",
]
EVENT_COLS = ["persona_id", "pairing_group_id", "replicate_id", "event_type", "target_id", "observed",
              "event_time_minutes", "event_day", "attempt_count", "value", "censor_time_minutes"]
SPIRIT_COLS = ["persona_id", "day", "species_id", "grade", "runs", "owned_mean", "mean_level",
               "facility_slot_minutes_mean", "party_slot_minutes_mean", "released_mean"]


def milli_str(v: int) -> str:
    sign = "-" if v < 0 else ""
    v = abs(v)
    return f"{sign}{v // 1000}.{v % 1000:03d}"


def _rstat_cells(rs: Any) -> list[str]:
    return [_fmt_float(rs.r_sum / rs.r_minutes, 4) if rs.r_minutes else "", str(rs.r_minutes), str(rs.over_outside),
            str(rs.over_transition), str(rs.undefined_outside), str(rs.undefined_transition),
            _fmt_float(rs.max_outside, 4) if rs.r_minutes else "", _fmt_float(rs.max_transition, 4) if rs.r_minutes else ""]


# 捕獲の状態機械・活力（段階 2）。累計（_cum）以外はその日の値。遭遇の件数・秒は完了日に計上する
CAPTURE_COLS = ["attempts_cum", "capture_success_cum", "capture_flee_cum", "capture_wick_out_cum", "capture_scatter_cum",
                "capture_budget_seconds", "capture_seconds", "capture_carry_seconds", "weaken_count", "weaken_seconds",
                "weaken_assist", "food_eaten", "vigor_low_hunt_min",
                # 段階 5: 芯の不足・調達、餌の不足、狩りの同行分、消費先
                "wick_blocked_min", "wick_procure_min", "food_short_window", "food_short_stock", "hunt_party_min",
                "sink_spent_basic", "sink_spent_hunt", "sink_spent_basic_repeat", "sink_spent_hunt_repeat", "finite_sink_done", "repeat_sink_levels", "repeat_sink_open", "dex_pages",
                # 2026-11-11: 芯の制作に投入した狩り素材（その日、用途内訳用）
                "craft_hunt_wick"]
# 等級別の完了遭遇（完了日）: 件数・結果・試行数。dex_enc = 図鑑の捕獲確率ボーナスが掛かった遭遇（2026-11-12、full_* の適合度から外す）
GRADE_COLS = [f"g{g}_{k}" for g in (1, 2, 3, 4)
              for k in ("enc", "success", "flee", "wick_out", "scatter", "attempts", "full_enc", "full_success", "dex_enc")]
# 捕獲補助道具（2026-11-11）: 道具を使った試行数・遭遇数・成功数（完了日）、番人 2 種（常に 0）、道具の制作に投入した狩り素材、
# 等級別の道具遭遇（完了日。full = 開始時に芯・道具とも K_max 回分以上）、フィールド別の道具の制作数・消費数（消費は開始日）。
# 道具を使った遭遇は g*_full_enc/full_success（道具なしの適合度）から外す。dex_excl = 図鑑の捕獲確率ボーナスが掛かったため
# 道具の適合度（g*_tool_full_*）から外した full 遭遇の件数（2026-11-13 リビュー Minor 1）
TOOL_GRADE_KEYS = ("enc", "success", "full_enc", "full_success", "dex_excl")
TOOL_COLS = ["tool_attempts", "tool_enc", "tool_success", "tool_first_capture", "tool_pre_unlock", "craft_hunt_lure",
             *[f"g{g}_tool_{k}" for g in (1, 2, 3, 4) for k in TOOL_GRADE_KEYS]]
# 図鑑の捕獲確率ボーナス付き・道具なし・開始時に芯 K_max 回分以上の遭遇（完了日）: "等級:bps:件数:成功;..."（bps 別の適合度用）
DEX_COLS = ["dex_capture_full"]


def daily_columns(model: Model) -> list[str]:
    cols = list(DAILY_BASE) + CAPTURE_COLS + GRADE_COLS + [f"{k}_{f}" for f in model.field_order for k in ("enc_done", "enc_seconds", "attempts")]
    cols += TOOL_COLS + [f"{k}_{f}" for f in model.field_order for k in ("lure_craft", "lure_used")] + DEX_COLS
    for r in model.resource_order:
        cols += [f"wallet_{r}"] + [f"earned_{s}_{r}" for s in SOURCES] + [f"spent_{r}"]
    return cols


# ---- ワーカー（プロセスごとに 1 回だけデータを読む） ----
_CTX: dict[str, Any] = {}


def _init(data_dir: str, personas_path: str, reference_path: str, days: int, master_seed: int | None = None,
          r_threshold: float = 3.0, transition_minutes: int = 1440, patch_ops: list[dict[str, Any]] | None = None) -> None:
    gd = load_data(data_dir, patch_ops)
    model = Model(gd)
    cfg, _ = load_personas(Path(personas_path), model)
    if master_seed is not None:
        cfg["master_seed"] = master_seed
    cfg["r_threshold"] = r_threshold
    cfg["transition_minutes"] = transition_minutes
    _CTX.update(model=model, econ=Economy(model), cfg=cfg, ref=jsonio.load_strict(Path(reference_path)), days=days)


def _run(job: tuple[int, int]) -> dict[str, Any]:
    pi, rep = job
    model, econ, cfg, days = _CTX["model"], _CTX["econ"], _CTX["cfg"], _CTX["days"]
    persona = cfg["personas"][pi]
    sim = Simulator(econ, cfg, persona, rep, days, _CTX["ref"])
    sim.run()
    return {"daily": _daily_rows(sim, model), "events": _event_rows(sim, model), "spirit": _spirit_stats(sim)}


def _fmt_float(x: float, places: int) -> str:
    return format(x, f".{places}f")


def _daily_rows(sim: Simulator, model: Model) -> list[list[str]]:
    rows = []
    p = sim.persona
    for snap in sim.day_snapshots:
        d = snap["day"]
        acc = sim.day_acc(d)
        mins = acc.minutes
        direct = sum(acc.earned.get(("direct", r), 0) for r in model.basic_ids)
        idle = sum(acc.earned.get(("idle", r), 0) for r in model.basic_ids)
        share = _fmt_float(direct / (direct + idle), 4) if direct + idle else ""
        row = [p["id"], p["pairing_group"], str(sim.replicate_id), str(d + 1), str(snap["fields_unlocked"]), snap["highest_field"],
               *[str(mins.get(k, 0)) for k in ("online", "gather", "hunt", "capture", "decor", "manage", "off_credited", "off_lost")],
               str(snap["spirit_count"]), str(snap["capacity"]), str(snap["encounters"]), str(snap["captures"]),
               str(snap["releases"]), str(snap["robux"]), str(snap["pass_claims"]),
               "true" if snap["exhausted"] else "false", str(snap["facility_level_sum"]), str(snap["tool_level"]),
               str(snap["offline_cap_h"]), str(snap["hub_rank"]), str(snap["best_party_combat"]), str(snap["dex"]), str(snap["research_done"]), share,
               *_rstat_cells(acc.r_best), *_rstat_cells(acc.r_actual),
               *[milli_str(acc.home_by_grade.get(g, 0)) for g in (1, 2, 3, 4)]]
        res = snap["results"]
        row += [str(snap["attempts"]), *[str(res.get(k, 0)) for k in ("success", "flee", "wick_out", "scatter")],
                str(acc.cap_budget_s), str(acc.cap_used_s), str(snap["pending_seconds"]), str(acc.weaken_n), str(acc.weaken_seconds),
                str(acc.assist_weaken), str(acc.food_eaten), str(acc.vigor_low_hunt_min),
                str(mins.get("wick_blocked", 0)), str(mins.get("wick_procure", 0)), str(acc.food_short_window), str(acc.food_short_stock),
                str(acc.hunt_party_min),
                milli_str(sum(acc.sink_spent.get(r, 0) for r in model.basic_ids)),
                milli_str(sum(v for r, v in acc.sink_spent.items() if model.resources[r]["kind"] == "hunt")),
                milli_str(sum(acc.sink_spent_repeat.get(r, 0) for r in model.basic_ids)),
                milli_str(sum(v for r, v in acc.sink_spent_repeat.items() if model.resources[r]["kind"] == "hunt")),
                str(snap["finite_done"]), str(snap["repeat_levels"]), str(snap["repeat_open"]), str(snap["dex_pages"]), milli_str(acc.wick_craft_hunt)]
        for g in (1, 2, 3, 4):
            n = sum(v for (gg, _), v in acc.grade_results.items() if gg == g)
            row += [str(n), *[str(acc.grade_results.get((g, k), 0)) for k in ("success", "flee", "wick_out", "scatter")],
                    str(acc.grade_attempts.get(g, 0)), str(acc.grade_results_full.get((g, "enc"), 0)),
                    str(acc.grade_results_full.get((g, "success"), 0)), str(acc.dex_capture_enc.get(g, 0))]
        for f in model.field_order:
            row += [str(acc.enc_done.get(f, 0)), str(acc.enc_seconds.get(f, 0)), str(acc.field_attempts.get(f, 0))]
        tg = acc.tool_grade
        row += [str(acc.tool_attempts), str(sum(v for (_, k), v in tg.items() if k == "enc")),
                str(sum(v for (_, k), v in tg.items() if k == "success")), str(acc.tool_first_capture), str(acc.tool_pre_unlock),
                milli_str(acc.lure_craft_hunt)]
        row += [str(tg.get((g, k), 0)) for g in (1, 2, 3, 4) for k in TOOL_GRADE_KEYS]
        for f in model.field_order:
            row += [milli_str(acc.lure_craft.get(f, 0)), str(acc.lure_used.get(f, 0))]
        row.append(encode_dex_full(acc.dex_capture_full))
        for r in model.resource_order:
            row.append(milli_str(snap["wallet"][r]))
            row += [milli_str(acc.earned.get((s, r), 0)) for s in SOURCES]
            row.append(milli_str(acc.spent.get(r, 0)))
        rows.append(row)
    return rows


def _event_rows(sim: Simulator, model: Model) -> list[list[str]]:
    st, p = sim.state, sim.persona
    censor = str(sim.days * DAY)
    base = [p["id"], p["pairing_group"], str(sim.replicate_id)]
    rows: list[list[str]] = []

    def add(event_type: str, target: str, t: int | None, attempts: str = "", value: str = "") -> None:
        obs = t is not None
        rows.append(base + [event_type, target, "true" if obs else "false", str(t) if obs else "",
                            str(t // DAY + 1) if obs else "", attempts, value, censor])

    add("game_start", "first_session", sim.game_start)
    for fid in model.field_order:
        if model.fields[fid]["unlock"]["requires_fields"]:
            add("field_unlock", fid, st.field_unlock_time.get(fid))
    for sid in model.spirit_order:
        fc = st.first_capture.get(sid)
        add("first_capture", sid, fc[0] if fc else None, str(fc[1]) if fc else str(st.encounters))
    add("storage_full", "storage", st.storage_full_time)
    add("content_exhausted", "all", st.exhausted_time)
    add("finite_cosmetic_completed", "all", st.finite_completed_time)  # 有限の外形品目（家 1〜9・家具・衣装）を全部買った時刻
    for nid in model.research_order:  # 研究完了（未完了・研究なしも observed=false で 1 行）
        add("research_complete", nid, st.research_done_time.get(nid))
    for e in sim.extra_events:
        add(e["event_type"], e["target_id"], e["time"], "", str(e["value"]))
    return rows


def _spirit_stats(sim: Simulator) -> dict[tuple[int, str], list[int]]:
    out: dict[tuple[int, str], list[int]] = {}
    for snap in sim.day_snapshots:
        d = snap["day"]
        acc = sim.day_acc(d)
        for sp in set(snap["species"]) | set(acc.fac_minutes) | set(acc.party_minutes) | set(acc.released):
            cnt, lvl = snap["species"].get(sp, [0, 0])
            out[(d, sp)] = [cnt, lvl, acc.fac_minutes.get(sp, 0), acc.party_minutes.get(sp, 0), acc.released.get(sp, 0)]
    return out


class _CsvOut:
    """一時ファイルに書いて最後に置き換える CSV 出力."""

    def __init__(self, path: Path, header: list[str]):
        self.path = Path(path)
        if self.path.is_symlink():
            raise OSError(f"심볼릭 링크에는 쓰지 않음: {self.path}")
        fd, self.tmp = tempfile.mkstemp(prefix=f".{self.path.name}.", suffix=".tmp", dir=self.path.parent)
        self.fh = os.fdopen(fd, "w", encoding="utf-8", newline="")
        self.w = csv.writer(self.fh, lineterminator="\n")
        self.w.writerow(header)

    def rows(self, rows: Iterable[list[str]]) -> None:
        self.w.writerows(rows)

    def close(self, ok: bool) -> None:
        self.fh.close()
        if ok:
            os.replace(self.tmp, self.path)
        elif os.path.exists(self.tmp):
            os.unlink(self.tmp)


def run_all(data_dir: Path, personas_path: Path, reference_path: Path, out_dir: Path, replicates: int, days: int,
            workers: int = 1, persona_ids: list[str] | None = None, master_seed: int | None = None,
            r_threshold: float = 3.0, transition_minutes: int = 1440,
            patch_ops: list[dict[str, Any]] | None = None) -> dict[str, Any]:
    gd = load_data(data_dir, patch_ops)
    model = Model(gd)
    cfg, _ = load_personas(personas_path, model)
    if master_seed is not None:
        cfg["master_seed"] = master_seed
    personas = [(i, p) for i, p in enumerate(cfg["personas"]) if persona_ids is None or p["id"] in persona_ids]
    jobs = [(i, rep) for i, _ in personas for rep in range(replicates)]
    out_dir.mkdir(parents=True, exist_ok=True)
    outs = [_CsvOut(out_dir / "daily.csv", daily_columns(model)), _CsvOut(out_dir / "events.csv", EVENT_COLS)]
    spirit_sum: dict[tuple[str, int, str], list[int]] = {}
    runs_per_persona: dict[str, int] = {}
    ok = False
    try:
        init_args = (str(data_dir), str(personas_path), str(reference_path), days, master_seed, r_threshold, transition_minutes, patch_ops)
        if workers > 1:
            with ProcessPoolExecutor(max_workers=workers, initializer=_init, initargs=init_args) as ex:
                results = ex.map(_run, jobs, chunksize=max(1, len(jobs) // (workers * 8)))
                _consume(results, jobs, cfg, outs, spirit_sum, runs_per_persona)
        else:
            _init(*init_args)
            _consume((_run(j) for j in jobs), jobs, cfg, outs, spirit_sum, runs_per_persona)
        ok = True
    finally:
        for o in outs:
            o.close(ok)
    spirit_out = _CsvOut(out_dir / "spirit_daily.csv", SPIRIT_COLS)
    try:
        rows = []
        for (pid, d, sp) in sorted(spirit_sum, key=lambda k: ([p["id"] for _, p in personas].index(k[0]), k[1], model.spirit_order.index(k[2]))):
            cnt, lvl, fac, party, rel = spirit_sum[(pid, d, sp)]
            n = runs_per_persona[pid]
            rows.append([pid, str(d + 1), sp, str(model.spirits[sp]["grade"]), str(n), _fmt_float(cnt / n, 3),
                         _fmt_float(lvl / cnt, 3) if cnt else "", _fmt_float(fac / n, 1), _fmt_float(party / n, 1), _fmt_float(rel / n, 3)])
        spirit_out.rows(rows)
        spirit_out.close(True)
    except BaseException:
        spirit_out.close(False)
        raise
    return {"runs": len(jobs), "personas": [p["id"] for _, p in personas], "replicates": replicates, "days": days,
            "master_seed": cfg["master_seed"], "cfg": cfg}


def _consume(results: Iterable[dict[str, Any]], jobs: list[tuple[int, int]], cfg: dict[str, Any], outs: list[_CsvOut],
             spirit_sum: dict[tuple[str, int, str], list[int]], runs_per_persona: dict[str, int]) -> None:
    for (pi, _), res in zip(jobs, results):
        pid = cfg["personas"][pi]["id"]
        runs_per_persona[pid] = runs_per_persona.get(pid, 0) + 1
        outs[0].rows(res["daily"])
        outs[1].rows(res["events"])
        for (d, sp), vals in res["spirit"].items():
            acc = spirit_sum.setdefault((pid, d, sp), [0, 0, 0, 0, 0])
            for i, v in enumerate(vals):
                acc[i] += v
