"""コマンドライン入口: validate / gen-tables / static / run / converge / report / all.

終了コード: 0 = 成功, 1 = 検証エラー・表が古い, 2 = 引数・入出力・設定エラー。
"""
from __future__ import annotations

import argparse
import platform
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, TextIO

from . import __version__, converge, jsonio, metrics, report, rng, runner, static_analysis, tables
from .assumptions import ASSUMPTIONS
from .data_load import PatchError, collect_placeholders, load_data, load_patch_file
from .economy import Economy
from .model import Model
from .sim_config import SimConfigError, load_personas
from .paths import DEFAULT_CONFIG_DIR, DEFAULT_DATA_DIR, DEFAULT_OUTPUT_DIR
from .schema import Issue
from .validate import has_errors, validate


def _print_issues(issues: list[Issue], out: TextIO) -> None:
    rank = {"ERROR": 0, "WARN": 1}
    for i in sorted(issues, key=lambda x: (rank.get(x.level, 2), x.code, x.path)):
        print(i.format(), file=out)
    n_err = sum(1 for i in issues if i.level == "ERROR")
    n_warn = sum(1 for i in issues if i.level == "WARN")
    n_info = sum(1 for i in issues if i.level == "INFO")
    # INFO は参考情報で合否・WARN 件数に含めない
    print(f"검증 결과: ERROR {n_err}건, WARN {n_warn}건, INFO {n_info}건 → {'FAIL' if n_err else 'OK'}", file=out)


def _load(args: argparse.Namespace):
    ops = None
    if getattr(args, "patch", None):
        ops = load_patch_file(args.patch)["ops"]
    return load_data(args.data, ops)


def cmd_validate(args: argparse.Namespace, out: TextIO) -> int:
    gd = _load(args)
    issues = validate(gd)
    _print_issues(issues, out)
    return 1 if has_errors(issues) else 0


def cmd_gen_tables(args: argparse.Namespace, out: TextIO) -> int:
    gd = load_data(args.data)
    # 生成表そのものの欠落・古さはここでは問題にしない（これから作るため）。他の検証は通常どおり行う
    generated = [n for n in ("upgrade_tables", "sink_tables") if n in gd.rel_paths]
    gd.issues = [i for i in gd.issues if not (i.code == "LOAD_MISSING" and i.path in {gd.label(n) for n in generated})]
    issues = validate(gd, check_tables=False)
    if has_errors(issues):
        _print_issues(issues, out)
        print("데이터 오류 때문에 표를 생성하지 않음", file=out)
        return 1
    # (manifest id, 生成関数, 本文抽出, 鮮度検査)。sink_tables は manifest に登録されているときだけ扱う
    jobs = [("upgrade_tables", tables.generate, tables.table_body, tables.staleness)]
    if "sink_tables" in gd.rel_paths:
        jobs.append(("sink_tables", tables.generate_sinks, tables.sink_body, tables.sink_staleness))
    stale_any = False
    for name, gen, body, staleness in jobs:
        new_doc = gen(gd.docs["curves"])
        target = Path(args.data) / gd.rel_paths[name]
        current = gd.docs.get(name)
        if args.check:
            stale = staleness(gd.docs["curves"], current) if current is not None else ["파일 없음"]
            for r in stale:
                print(f"STALE({gd.rel_paths[name]}): {r}", file=out)
            stale_any = stale_any or bool(stale)
            continue
        if current is not None and body(current) == body(new_doc) and current.get("curves_sha256") == new_doc["curves_sha256"]:
            print(f"변경 없음: {target}", file=out)
        else:
            jsonio.write_text_atomic(target, jsonio.dump_pretty(new_doc))
            print(f"생성: {target}", file=out)
        print(f"{name}: curves_sha256={new_doc['curves_sha256']}\n{name}: tables_sha256={new_doc['tables_sha256']}", file=out)
    if args.check:
        print("최신" if not stale_any else "갱신 필요: python3 -m econ_sim gen-tables", file=out)
        return 1 if stale_any else 0
    return 0


def cmd_static(args: argparse.Namespace, out: TextIO) -> int:
    gd = _load(args)
    issues = validate(gd)
    if has_errors(issues):
        _print_issues(issues, out)
        print("검증 오류가 있어 static을 실행하지 않음", file=out)
        return 1
    warnings = [i for i in issues if i.level == "WARN"]
    out_dir = Path(args.out) if args.out else DEFAULT_OUTPUT_DIR / "static"
    try:
        written = static_analysis.run_static(gd, Path(args.config), out_dir, warnings)
    except static_analysis.StaticConfigError as exc:
        print(f"설정 오류:\n{exc}", file=out)
        return 2
    for name, path in written.items():
        print(f"출력: {path}", file=out)
    print(f"검증 경고 {len(warnings)}건(static_meta.json에 기록)", file=out)
    return 0


# ---- シミュ系サブコマンド ----

MANIFEST = "manifest.json"


def _read_manifest(out_dir: Path) -> dict[str, Any]:
    path = out_dir / MANIFEST
    return jsonio.load_strict(path) if path.is_file() else {}


def _write_manifest(out_dir: Path, manifest: dict[str, Any]) -> None:
    jsonio.write_text_atomic(out_dir / MANIFEST, jsonio.dump_pretty(manifest))


def _out_dir(args: argparse.Namespace, label: str) -> Path:
    if args.out:
        return Path(args.out)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return DEFAULT_OUTPUT_DIR / f"{stamp}_{label}"


def _validated(args: argparse.Namespace, out: TextIO):
    gd = _load(args)  # --patch があれば適用したデータ（元ファイルは変えない、段階 7 の比較実行用）
    issues = validate(gd)
    if has_errors(issues):
        _print_issues(issues, out)
        print("검증 오류가 있어 실행하지 않음", file=out)
        return None, issues
    return gd, issues


def _config_paths(args: argparse.Namespace) -> dict[str, Path]:
    cfg = Path(args.config)
    return {"personas": Path(args.personas) if getattr(args, "personas", None) else cfg / "personas.json",
            "static_reference": cfg / "static_reference.json", "criteria": cfg / "criteria.json"}


def do_run(args: argparse.Namespace, out: TextIO, out_dir: Path) -> int:
    gd, issues = _validated(args, out)
    if gd is None:
        return 1
    model = Model(gd)
    paths = _config_paths(args)
    cfg, cfg_hash = load_personas(paths["personas"], model)
    replicates = args.seeds or (cfg["replicates_quick"] if args.quick else cfg["replicates_default"])
    days = args.days or cfg["horizon_days"]
    if args.seed is not None:
        cfg["master_seed"] = args.seed
    crit = jsonio.load_strict(paths["criteria"])
    r_threshold = float(crit["g2"]["max_ratio"])
    transition = int(crit["g2"].get("transition_minutes", 1440))
    out_dir.mkdir(parents=True, exist_ok=True)
    t0 = time.perf_counter()
    patch_ops = load_patch_file(args.patch)["ops"] if getattr(args, "patch", None) else None
    info = runner.run_all(Path(args.data), paths["personas"], paths["static_reference"], out_dir, replicates, days,
                          workers=args.workers, master_seed=cfg["master_seed"], r_threshold=r_threshold,
                          transition_minutes=transition, patch_ops=patch_ops)
    elapsed = time.perf_counter() - t0
    manifest = {
        "run_id": out_dir.name, "generator": f"econ_sim {__version__}", "python": platform.python_version(),
        "platform": platform.platform(), "command": "econ_sim " + " ".join(sys.argv[1:]) if sys.argv else "",
        "master_seed": cfg["master_seed"], "replicates": replicates, "days": days, "extract_days": [d for d in cfg["extract_days"] if d <= days],
        "personas": [{"id": p["id"], "pairing_group": p["pairing_group"], "research": p.get("research", "natural"),
                      "wick_mode": p.get("wick_mode", "required"), "sink_preference": p.get("sink_preference", "normal"),
                      "ablation": p.get("ablation", []), "capture_tool": p.get("capture_tool", "off")} for p in cfg["personas"]],
        "start_spirits": [s["species"] for s in cfg["start"]["spirits"]], "g2_r_threshold": r_threshold, "g2_transition_minutes": transition,
        "rng": {"version": rng.RNG_VERSION, "key": "sha256(master_seed, pairing_group_id, replicate_id, stream)",
                "streams": ["capture:day<N>", "individual:day<N>", "individual:start"], "excluded_from_key": ["persona_id", "purchases", "research_mode"]},
        "workers": args.workers,
        "patch": ({"path": str(args.patch), "sha256": jsonio.sha256_hex(Path(args.patch).read_bytes())}
                  if getattr(args, "patch", None) else None),
        "data_file_sha256": {gd.label(k): v for k, v in sorted(gd.file_sha256.items())},
        "curves_sha256": gd.docs["upgrade_tables"]["curves_sha256"], "tables_sha256": gd.docs["upgrade_tables"]["tables_sha256"],
        "config_sha256": {"personas.json": cfg_hash, **{f"{k}.json": jsonio.sha256_hex(v.read_bytes()) for k, v in paths.items() if k != "personas"}},
        "timing_seconds": {"run": round(elapsed, 2)},
        "runs": info["runs"], "assumptions": ASSUMPTIONS, "placeholders": collect_placeholders(gd),
        "validation_warnings": [i.format() for i in issues if i.level == "WARN"],
        "outputs": ["daily.csv", "events.csv", "spirit_daily.csv"],
    }
    _write_manifest(out_dir, manifest)
    print(f"run: {info['runs']}회 실행, {elapsed:.1f}초 → {out_dir}", file=out)
    return 0


def do_converge(args: argparse.Namespace, out: TextIO, out_dir: Path) -> int:
    gd, _ = _validated(args, out)
    if gd is None:
        return 1
    model = Model(gd)
    paths = _config_paths(args)
    cfg, _ = load_personas(paths["personas"], model)
    ref = jsonio.load_strict(paths["static_reference"])
    t0 = time.perf_counter()
    rows = converge.analyze(Economy(model), ref, [s["species"] for s in cfg["start"]["spirits"]])
    out_dir.mkdir(parents=True, exist_ok=True)
    jsonio.write_text_atomic(out_dir / "allocation.csv", static_analysis.to_csv(converge.COLUMNS, rows))
    elapsed = time.perf_counter() - t0
    manifest = _read_manifest(out_dir)
    manifest.setdefault("timing_seconds", {})["converge"] = round(elapsed, 2)
    manifest.setdefault("outputs", [])
    if "allocation.csv" not in manifest["outputs"]:
        manifest["outputs"].append("allocation.csv")
    _write_manifest(out_dir, manifest)
    n_cases = sum(1 for r in rows if r[4] == "one_of_each_available" and r[5] == "heuristic_greedy_2swap")
    n_exact = sum(1 for r in rows if r[5] == "exact_subset_dp")
    print(f"converge: {n_cases}개 대표 상태(1마리씩 정확 해 {n_exact}개), {elapsed:.1f}초 → {out_dir / 'allocation.csv'}", file=out)
    return 0


def do_report(args: argparse.Namespace, out: TextIO, out_dir: Path) -> int:
    # run が --patch 付きなら、report 単独実行でも同じパッチを自動適用する（無ければ・内容が違えば警告）（2 次レビュー Minor 6）
    rec = _read_manifest(out_dir).get("patch") if (out_dir / "manifest.json").is_file() else None
    if rec and not getattr(args, "patch", None):
        pp = Path(rec["path"])
        if pp.is_file() and jsonio.sha256_hex(pp.read_bytes()) == rec["sha256"]:
            args.patch = str(pp)
            print(f"run의 패치를 적용: {pp}", file=out)
        else:
            print(f"경고: run의 패치 {pp}를 찾을 수 없거나 내용이 다름 — 패치 없이 판정", file=out)
    gd, issues = _validated(args, out)
    if gd is None:
        return 1
    if not (out_dir / "daily.csv").is_file():
        print(f"run 결과가 없음: {out_dir}", file=out)
        return 2
    model = Model(gd)
    paths = _config_paths(args)
    crit = jsonio.load_strict(paths["criteria"])
    ref = jsonio.load_strict(paths["static_reference"])
    t0 = time.perf_counter()
    manifest = _read_manifest(out_dir)
    # run 時と現在のデータが違えば、判定が別データの結果を読んでいることになるので警告を残す
    now = {gd.label(k): v for k, v in sorted(gd.file_sha256.items())}
    diff = sorted(k for k in set(now) | set(manifest.get("data_file_sha256", {})) if now.get(k) != manifest.get("data_file_sha256", {}).get(k))
    manifest["report_warnings"] = ([f"run 이후 데이터가 바뀜: {', '.join(diff)} (CSV는 run 시점 데이터 기준)"] if diff else [])
    for w in manifest["report_warnings"]:
        print(f"경고: {w}", file=out)
    rd = metrics.RunData(out_dir, model, {**manifest, "capture_sinks_cfg": crit["sim"].get("capture_sinks", {})})
    result = metrics.compute(rd, crit, ref, sum(1 for i in issues if i.level == "ERROR"))
    jsonio.write_text_atomic(out_dir / "checks.csv", static_analysis.to_csv(metrics.CHECK_COLS, result["checks"]))
    jsonio.write_text_atomic(out_dir / "capture_stats.csv",
                             static_analysis.to_csv(metrics.capture_columns(rd, crit["sim"]), metrics.capture_stats(rd, crit["sim"])))
    manifest.setdefault("assumptions", ASSUMPTIONS)
    manifest.setdefault("placeholders", collect_placeholders(gd))
    manifest["criteria_sha256"] = jsonio.sha256_hex(paths["criteria"].read_bytes())
    manifest["check_counts"] = {k: sum(1 for r in result["checks"] if r[9] == k) for k in ("PASS", "WARN", "FAIL", "INCONCLUSIVE", "INFO")}
    html = report.build(rd, result, metrics.series(rd, crit["sim"]), manifest)
    jsonio.write_text_atomic(out_dir / "report.html", html)
    manifest.setdefault("timing_seconds", {})["report"] = round(time.perf_counter() - t0, 2)
    for name in ("capture_stats.csv", "checks.csv", "report.html"):
        if name not in manifest.setdefault("outputs", []):
            manifest["outputs"].append(name)
    _write_manifest(out_dir, manifest)
    print(f"report: 판정 {manifest['check_counts']} → {out_dir / 'report.html'}", file=out)
    return 0


def _need_out(args: argparse.Namespace, out: TextIO) -> Path | None:
    if not args.out:
        print("--out <run 디렉터리>가 필요", file=out)
        return None
    return Path(args.out)


def cmd_run(args: argparse.Namespace, out: TextIO) -> int:
    return do_run(args, out, _out_dir(args, "quick" if args.quick else "full"))


def cmd_converge(args: argparse.Namespace, out: TextIO) -> int:
    d = _need_out(args, out)
    return 2 if d is None else do_converge(args, out, d)


def cmd_report(args: argparse.Namespace, out: TextIO) -> int:
    d = _need_out(args, out)
    return 2 if d is None else do_report(args, out, d)


def cmd_all(args: argparse.Namespace, out: TextIO) -> int:
    out_dir = _out_dir(args, "quick" if args.quick else "full")
    t0 = time.perf_counter()
    gd, issues = _validated(args, out)
    if gd is None:
        return 1
    stale = tables.staleness(gd.docs["curves"], gd.docs["upgrade_tables"])
    if stale:
        print("강화표가 오래됨: python3 -m econ_sim gen-tables", file=out)
        return 1
    try:
        static_analysis.run_static(gd, Path(args.config), out_dir / "static", [i for i in issues if i.level == "WARN"])
    except static_analysis.StaticConfigError as exc:
        print(f"설정 오류:\n{exc}", file=out)
        return 2
    for step in (do_run, do_converge, do_report):
        code = step(args, out, out_dir)
        if code:
            return code
    manifest = _read_manifest(out_dir)
    manifest["timing_seconds"]["all_total"] = round(time.perf_counter() - t0, 2)
    manifest["outputs"].append("static/")
    _write_manifest(out_dir, manifest)
    print(f"all 완료: {manifest['timing_seconds']['all_total']}초 → {out_dir}", file=out)
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="python3 -m econ_sim", description="Roblox 방치·수집 게임 경제 시뮬레이터")
    sub = p.add_subparsers(dest="command", required=True)

    def common(sp: argparse.ArgumentParser, patch: bool = True) -> None:
        sp.add_argument("--data", default=str(DEFAULT_DATA_DIR), help="data 디렉터리(기본: roblox-game/data)")
        if patch:
            sp.add_argument("--patch", help="데이터 패치 JSON(ops). 원본 파일은 바꾸지 않음")

    v = sub.add_parser("validate", help="data/ 스키마·참조·규칙 검증")
    common(v)
    v.set_defaults(func=cmd_validate)
    g = sub.add_parser("gen-tables", help="curves.json → generated/upgrade_tables.json·sink_tables.json")
    common(g, patch=False)
    g.add_argument("--check", action="store_true", help="쓰지 않고 최신 여부만 확인(오래되면 종료 코드 1)")
    g.set_defaults(func=cmd_gen_tables)
    s = sub.add_parser("static", help="정적 분석 CSV·HTML 생성")
    common(s)
    s.add_argument("--config", default=str(DEFAULT_CONFIG_DIR), help="static_reference.json·criteria.json 위치")
    s.add_argument("--out", help="출력 디렉터리(기본: roblox-game/outputs/static)")
    s.set_defaults(func=cmd_static)

    def sim_opts(sp: argparse.ArgumentParser, run_opts: bool) -> None:
        common(sp, patch=True)
        sp.add_argument("--config", default=str(DEFAULT_CONFIG_DIR), help="personas·static_reference·criteria 위치")
        sp.add_argument("--personas", help="personas.json 경로(기본: --config/personas.json)")
        sp.add_argument("--out", help="run 디렉터리(기본: roblox-game/outputs/<UTC시각>_<quick|full>)")
        if run_opts:
            sp.add_argument("--quick", action="store_true", help="반복 수를 replicates_quick(20)으로")
            sp.add_argument("--seeds", type=int, help="반복 수 직접 지정(기본 200)")
            sp.add_argument("--days", type=int, help="시뮬 일수(기본 60)")
            sp.add_argument("--seed", type=int, help="master_seed 덮어쓰기")
            sp.add_argument("--workers", type=int, default=1, help="병렬 프로세스 수(결과 바이트는 동일)")

    for name, func, helptext, run_opts in (
        ("run", cmd_run, "페르소나 시뮬레이션(daily/events/spirit_daily.csv)", True),
        ("converge", cmd_converge, "대표 상태 정확 배치·종 제외 손실(allocation.csv)", False),
        ("report", cmd_report, "지표·판정·report.html(checks/capture_stats.csv)", False),
        ("all", cmd_all, "validate→static→run→converge→report", True),
    ):
        sp = sub.add_parser(name, help=helptext)
        sim_opts(sp, run_opts)
        sp.set_defaults(func=func)
    return p


def main(argv: list[str] | None = None, out: TextIO | None = None) -> int:
    out = out or sys.stdout
    args = build_parser().parse_args(argv)
    try:
        return args.func(args, out)
    except (OSError, ValueError, PatchError, SimConfigError) as exc:
        print(f"오류: {exc}", file=out)
        return 2
