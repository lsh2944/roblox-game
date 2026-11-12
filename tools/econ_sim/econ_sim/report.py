"""run 結果の単一 HTML（判定要約を先頭、外部 URL なし、インライン SVG）."""
from __future__ import annotations

from typing import Any

from . import report_html as H
from .metrics import CHECK_COLS, RunData, f

_ORDER = {"FAIL": 0, "WARN": 1, "INCONCLUSIVE": 2, "PASS": 3, "INFO": 4}


def build(rd: RunData, result: dict[str, Any], ser: dict[str, Any], manifest: dict[str, Any]) -> str:
    m = rd.model
    checks = sorted(result["checks"], key=lambda r: (_ORDER.get(r[9], 9), r[0], r[1]))
    counts = {k: sum(1 for r in checks if r[9] == k) for k in _ORDER}
    body = [
        "<h1>경제 시뮬레이터 결과</h1>",
        f'<p class="note">run_id={H.esc(manifest.get("run_id", ""))} / 반복 {H.esc(manifest.get("replicates", ""))}회 × '
        f'{H.esc(len(rd.personas))}개 페르소나 / {rd.days}일 / master_seed={H.esc(manifest.get("master_seed", ""))}. '
        "approval_state=draft 판정은 초안 기준이며 공식 합격이 아니다. 배치는 휴리스틱으로 '발견한 배치'다.</p>",
        *([f'<p class="FAIL">경고: {H.esc(w)}</p>' for w in manifest.get("report_warnings", [])]),
        "<h2>판정 요약</h2>",
        "<p>" + ", ".join(f"{k} {v}" for k, v in counts.items() if v) + "</p>",
        H.table(CHECK_COLS, checks, left_cols=4, class_col="draft_evaluation"),
    ]
    body.append("<h2>필드 해금 곡선(기간 내 도달 비율)</h2>")
    for fid, per in ser["unlock"].items():
        body.append(H.line_chart(per, f"{m.fields[fid]['name']}({fid}) 해금 도달률", "일", "도달 비율", 0.0, 1.0))
    rows = []
    for (pid, fid), s in sorted(result["unlock"].items(), key=lambda kv: (rd.personas.index(kv[0][0]), m.field_rank(kv[0][1]))):
        rows.append([pid, fid, f(s["p10"], 0), f(s["p50"], 0), f(s["p90"], 0), f(s["dfirst"]), f(s["dh"])])
    body.append(H.table(["persona", "field", "p10 일", "p50 일", "p90 일", f"D{rd.extract_days[0]} 도달률", "기간 내 도달률"],
                        rows, left_cols=2))
    body.append('<p class="note">분위수는 미도달을 +∞로 포함해 계산한다. 공란 = 해당 분위가 기간 안에 도달하지 못함.</p>')
    body.append("<h2>직접 채집 / 방치 비중</h2>")
    body.append(H.line_chart(ser["share"], "하루 기본 재료 중 직접 채집 비중 S(중앙값)", "일", "S"))
    body.append("<h2>정령 사용 분포(시설 배치 분, 발견한 배치)</h2>")
    urows = []
    for (pid, d), (gs, ss) in result["usage"].items():
        if not gs:
            continue
        top = sorted(ss.items(), key=lambda kv: -kv[1])[:4]
        urows.append([pid, f"D{d}", *[f(gs.get(g, 0.0)) for g in (1, 2, 3, 4)], ", ".join(f"{sp} {v:.2f}" for sp, v in top)])
    body.append(H.table(["persona", "day", "★1", "★2", "★3", "★4", "상위 종 비중"], urows, left_cols=2))
    if ser.get("capture_cdf"):
        body.append(f"<h2>포획 첫 획득 누적 비율({H.esc(ser['capture_persona'])})</h2>")
        body.append(H.line_chart(ser["capture_cdf"], "종별 첫 획득 누적 비율", "일", "획득 비율", 0.0, 1.0))
    body.append("<h2>보관함 사용률</h2>")
    body.append(H.line_chart(ser["storage"], "보유 정령 / 보관함 상한(중앙값)", "일", "사용률", 0.0, 1.0, [(1.0, "상한")]))
    if result["paid"]:
        body.append("<h2>과금 vs 무과금(같은 비교군 난수 짝)</h2>")
        prow = [[r["field"], f(r["free_p50"], 0), f(r["paid_p50"], 0), f(r["shortening"]), str(r["both"]),
                 str(r["free_censored"]), f"{r['free_reach']}/{r['n']}", f"{r['paid_reach']}/{r['n']}"] for r in result["paid"]]
        body.append(H.table(["field", "무과금 p50 일", "과금 p50 일", "단축률 중앙값(분 기준)", "양쪽 도달 짝", "무과금 미도달 짝(하한)",
                             "무과금 도달", "과금 도달"], prow))
    cs = result.get("capture_sink") or {}
    if cs:
        cap_ids = ("capture_rule_conformance", "capture_time_conservation", "encounter_seconds_mean", "capture_outcome_share",
                   "wick_shortage_share", "wick_procure_minutes", "wick_paid_free_gap", "wick_vs_unlimited", "star4_exposure",
                   "capture_pending_at_horizon", "weaken_seconds_mean", "vigor_low_share", "food_per_day", "food_shortage",
                   "assist_weaken_share", "vigor_paid_free_gap", "ablation_effect")
        body.append("<h2>포획·심지·활력</h2>")
        g = [r for r in cs["capture"] if r[0] == "grade"]
        body.append(H.table(["", "등급", "성공", "도망", "심지 소진", "평균 시도", "해석 Q/E[A]"], g, left_cols=2))
        fr = [r[:5] for r in cs["capture"] if r[0] == "field"]
        body.append(H.table(["", "필드", "조우 평균 초", "해석 초", "완료 조우"], fr, left_cols=2))
        pr = [r for r in cs["capture"] if r[0] == "persona"]
        body.append(H.table(["", "persona", "심지 부족 D1-14", "약화 평균 초", "급식/일", "저활력 사냥 비율", "등롱 보조 비율"], pr, left_cols=2))
        body.append(H.table(CHECK_COLS, [r for r in checks if r[0] in cap_ids], left_cols=4, class_col="draft_evaluation"))
        body.append('<p class="note">확률 함수(시도 성공률·빛 구간·도망)에는 성장·활력·상품 입력이 없다. 성장·활력·먹이는 약화 시간에만 영향을 주며, '
                    '고정 시간 안의 시도 기회는 늘 수 있다. 확률표는 게임에서 상시 공개하고 플랫폼 분류는 출시 전 공식 확인 대상이다.</p>')
        if cs.get("tool"):
            body.append("<h2>포획 보조 도구</h2>")
            fields = rd.model.field_order
            body.append(H.table(["persona", "도구 소비/일", "도구 시도/일", "도구 조우 성공률", "★4 획득/일",
                                 *[f"{fl} 제작/소비/일" for fl in fields]], cs["tool"], left_cols=1))
            tool_ids = ("capture_tool_first_capture_zero", "capture_tool_conformance", "capture_tool_usage", "capture_tool_field",
                        "star4_success_per_day_after_unlock")
            body.append(H.table(CHECK_COLS, [r for r in checks if r[0] in tool_ids], left_cols=4, class_col="draft_evaluation"))
            body.append('<p class="note">/일 값은 전역 해금(capture_tool.unlock_after_field) 후 일수 기준. 도구는 대상 정령의 고유 필드 재료로 만들며 '
                        '첫 포획·해금 전에는 효과가 없다. 도구 사용 조우는 위 확률 적합도(capture_rule_conformance)에서 빠지고 '
                        'capture_tool_conformance로 따로 본다. 도구는 비매·상품 지급 금지라 유료 랜덤 경로가 아니다.</p>')
        body.append("<h2>소비처</h2>")
        body.append(H.table(["persona", *[f"유한 진척 D{d}" for d in rd.cs.progress_days], "유한 완료 p50 일", "흡수율(합계)", "흡수율(반복)", "반복 개방 일 비율"],
                            cs["sink"], left_cols=1))
        sink_ids = ("finite_cosmetic_completed_day", "finite_cosmetic_progress", "sink_absorption", "repeat_sink_available_rate")
        body.append(H.table(CHECK_COLS, [r for r in checks if r[0] in sink_ids], left_cols=4, class_col="draft_evaluation"))
    conv = result["convergence"]
    if conv["cases"]:
        body.append("<h2>수렴 분석(대표 상태 정확 탐색, 종 복제 무제한 재고)</h2>")
        crow = [[sp, str(i["used_cases"]), f"{i['max_loss']:.2f}", str(i["cases"])] for sp, i in conv["species"].items()]
        body.append(H.table(["species", "최적 배치 사용 사례 수", "제외 시 최대 손실 %", "평가 사례 수"], crow))
        skipped = conv.get("gap_skipped", 0)
        skip_note = f" gap 미측정 {skipped}건(정령 수가 정확 탐색 상한 초과)." if skipped else ""
        # 実測 0 件なら gap は「未測定」と書き、0.0000（差なし）と区別する
        gap_txt = f"{conv['max_gap']:.4f}" if conv.get("gap_measured", 0) else "미측정"
        body.append(f'<p class="note">대표 상태 {conv["cases"]}개, 휴리스틱 최대 gap {gap_txt}.{skip_note} 동행(파티)은 대상 외.</p>')
    body.append("<h2>가정</h2><ul>" + "".join(f"<li>{H.esc(a)}</li>" for a in manifest.get("assumptions", [])) + "</ul>")
    body.append(f"<h2>placeholder</h2><p>{len(manifest.get('placeholders', []))}건(manifest.json 참조)</p>")
    return H.page("econ_sim report", body)
