"""外部 URL を一切含まない単一 HTML の生成（インライン CSS・インライン SVG のみ）.

2 段階の report.html もここの部品（table・line_chart・page）を再利用する想定。
"""
from __future__ import annotations

import html
import math
from collections import Counter
from typing import Any, Iterable

PALETTE = ["#2f6db5", "#d0662b", "#3a9a5b", "#9b59b6", "#c0392b", "#7f8c8d"]
CSS = """
body{font-family:-apple-system,'Apple SD Gothic Neo','Malgun Gothic',sans-serif;margin:24px;color:#222;max-width:1200px}
h1{font-size:22px}h2{font-size:18px;margin-top:32px;border-bottom:1px solid #ccc;padding-bottom:4px}
table{border-collapse:collapse;font-size:12px;margin:8px 0}th,td{border:1px solid #ccc;padding:3px 6px;text-align:right}
th{background:#f3f3f3;position:sticky;top:0}td.l,th.l{text-align:left}
.PASS{background:#e3f4e6}.WARN{background:#fff4d6}.FAIL{background:#fbe0de}.NA{background:#eee}
.note{color:#555;font-size:13px}.dom{background:#fbe0de}.prot{background:#fff4d6}
details{margin:8px 0}summary{cursor:pointer}
"""


def esc(v: Any) -> str:
    return html.escape(str(v), quote=True)


def table(headers: list[str], rows: Iterable[list[str]], left_cols: int = 1, class_col: str | None = None) -> str:
    idx = headers.index(class_col) if class_col in headers else -1
    out = ["<table><thead><tr>"]
    out += [f'<th class="{"l" if i < left_cols else ""}">{esc(h)}</th>' for i, h in enumerate(headers)]
    out.append("</tr></thead><tbody>")
    for row in rows:
        cls = ""
        if idx >= 0:
            cls = row[idx].replace("/", "") if row[idx] in ("PASS", "WARN", "FAIL") else ("NA" if row[idx] == "N/A" else "")
        out.append(f'<tr class="{cls}">' + "".join(
            f'<td class="{"l" if i < left_cols else ""}">{esc(v)}</td>' for i, v in enumerate(row)) + "</tr>")
    out.append("</tbody></table>")
    return "".join(out)


def line_chart_log(series: dict[str, list[tuple[float, float]]], vlines: list[float], title: str,
                   x_label: str, y_label: str, width: int = 760, height: int = 340) -> str:
    """対数 y 軸の折れ線グラフ（インライン SVG、xmlns 属性なし）."""
    pts = [p for s in series.values() for p in s if p[1] > 0]
    if not pts:
        return "<p>데이터 없음</p>"
    ml, mr, mt, mb = 60, 150, 30, 40
    xs = [p[0] for p in pts]
    x0, x1 = min(xs), max(xs)
    y0 = 10 ** math.floor(math.log10(min(p[1] for p in pts)))
    y1 = 10 ** math.ceil(math.log10(max(p[1] for p in pts)))
    pw, ph = width - ml - mr, height - mt - mb

    def sx(x: float) -> float:
        return ml + (x - x0) / (x1 - x0 or 1) * pw

    def sy(y: float) -> float:
        return mt + ph - (math.log10(y) - math.log10(y0)) / (math.log10(y1) - math.log10(y0) or 1) * ph

    out = [f'<svg viewBox="0 0 {width} {height}" width="{width}" height="{height}" role="img" aria-label="{esc(title)}">',
           f'<text x="{ml}" y="18" font-size="13">{esc(title)}</text>']
    e = round(math.log10(y0))
    while 10**e <= y1 * 1.0001:
        y = sy(10**e)
        out.append(f'<line x1="{ml}" x2="{ml + pw}" y1="{y:.1f}" y2="{y:.1f}" stroke="#ddd"/>'
                   f'<text x="{ml - 6}" y="{y + 4:.1f}" font-size="10" text-anchor="end">{10**e:g}</text>')
        e += 1
    for v in vlines:
        x = sx(v)
        out.append(f'<line x1="{x:.1f}" x2="{x:.1f}" y1="{mt}" y2="{mt + ph}" stroke="#c0392b" stroke-dasharray="4 3"/>'
                   f'<text x="{x + 3:.1f}" y="{mt + 10}" font-size="10" fill="#c0392b">Lv{v:g}</text>')
    step = max(1, round((x1 - x0) / 10))
    xv = x0
    while xv <= x1:
        out.append(f'<text x="{sx(xv):.1f}" y="{mt + ph + 14}" font-size="10" text-anchor="middle">{xv:g}</text>')
        xv += step
    out.append(f'<text x="{ml + pw / 2:.1f}" y="{height - 6}" font-size="11" text-anchor="middle">{esc(x_label)}</text>')
    out.append(f'<text x="12" y="{mt + ph / 2:.1f}" font-size="11" transform="rotate(-90 12 {mt + ph / 2:.1f})" '
               f'text-anchor="middle">{esc(y_label)}</text>')
    for i, (name, s) in enumerate(series.items()):
        color = PALETTE[i % len(PALETTE)]
        path = " ".join(f"{sx(x):.1f},{sy(y):.1f}" for x, y in s if y > 0)
        out.append(f'<polyline fill="none" stroke="{color}" stroke-width="2" points="{path}"/>')
        ly = mt + 14 + i * 16
        out.append(f'<line x1="{ml + pw + 10}" x2="{ml + pw + 30}" y1="{ly}" y2="{ly}" stroke="{color}" stroke-width="2"/>'
                   f'<text x="{ml + pw + 34}" y="{ly + 4}" font-size="11">{esc(name)}</text>')
    out.append("</svg>")
    return "".join(out)


def page(title: str, body: list[str]) -> str:
    return ("<!DOCTYPE html>\n<html lang=\"ko\"><head><meta charset=\"utf-8\">"
            f"<title>{esc(title)}</title><style>{CSS}</style></head><body>"
            + "\n".join(body) + "</body></html>\n")


def _counts(rows: list[list[str]], col: int) -> str:
    c = Counter(r[col] for r in rows)
    return ", ".join(f"{k} {c[k]}" for k in ("PASS", "WARN", "FAIL", "N/A") if c.get(k))


def static_page(model: Any, tables_out: dict[str, tuple[list[str], list[list[str]]]], meta: dict[str, Any]) -> str:
    g2h, g2r = tables_out["g2_ratio.csv"]  # draft_evaluation=最大倍率規則, band_evaluation=目標帯
    g3h, g3r = tables_out["g3_hunt_minutes.csv"]
    caph, capr = tables_out["capture_quantiles.csv"]
    domh, domr = tables_out["dominance.csv"]
    payh, payr = tables_out["facility_payback.csv"]
    ev2, ev3 = g2h.index("draft_evaluation"), g3h.index("draft_evaluation")
    dom_hits = [r for r in domr if r[domh.index("higher_grade_dominates")] == "true"]
    body = [f"<h1>경제 시뮬레이터 static 결과</h1>",
            '<p class="note">모든 값은 기준 상태(config/static_reference.json)에 대한 <b>정규화 추정</b>이다. '
            "approval_state=draft 판정은 초안 기준이며 공식 합격이 아니다. 실제 정체·해금 시점은 2단계 시뮬레이션에서 판정한다.</p>",
            "<h2>요약</h2><ul>",
            f"<li>G2 직접/방치 비율 R: {esc(_counts(g2r, ev2))} (최대 3배 초과는 FAIL)</li>",
            f"<li>G3 사냥 분 환산(목표 10~30분): {esc(_counts(g3r, ev3))}</li>",
            f"<li>고등급이 저등급을 특성 보호 없이 지배하는 쌍: {len(dom_hits)}건</li>",
            f"<li>placeholder 항목: {len(meta['placeholders'])}건, 검증 경고: {len(meta['validation_warnings'])}건</li>",
            "</ul>"]
    body.append("<h2>G2 직접 채집 / 방치 비율</h2>")
    body.append('<p class="note">R = 직접 채집 시간당 획득 / 같은 상태 방치 시간당 생산. S = hR/(hR+H) (h=하루 직접 채집 시간, H=하루 방치 시간; 보고용).</p>')
    body.append(table(g2h, g2r, left_cols=5, class_col="draft_evaluation"))
    body.append("<h2>G3 사냥 재료 요구량의 사냥 분 환산</h2>")
    body.append(table(g3h, g3r, left_cols=5, class_col="draft_evaluation"))
    body.append("<h2>시설 강화 회수기간(정규화)</h2>")
    series: dict[str, list[tuple[float, float]]] = {}
    pi, ti, fi = payh.index("payback_hours_normalized"), payh.index("to_level"), payh.index("facility_id")
    for r in payr:
        if r[pi]:
            series.setdefault(r[fi], []).append((float(r[ti]), float(r[pi])))
    vlines = sorted({float(r[ti]) for r in payr if r[payh.index("milestone")] == "true"})
    body.append(line_chart_log(series, vlines, "강화 1회 회수기간(시간, 로그 축)", "도달 레벨", "시간"))
    body.append('<p class="note">기본 자원 1단위=1로 합산한 비용 / 기준 배치의 생산 증가량. 마일스톤 레벨(점선)에서 회수기간이 불연속으로 떨어진다.</p>')
    body.append(f"<details><summary>회수기간 표 ({len(payr)}행)</summary>{table(payh, payr, left_cols=2)}</details>")
    body.append("<h2>정령 지배표</h2>")
    body.append('<p class="note">행 A가 열 B를 지배: D = 모든 기여 차원(시설 3·동행 3·전투) 이상, 고유 특성 보호 없음 / '
                "T = 수치상 지배지만 B의 고유 특성으로 보호 / 공란 = 지배 아님.</p>")
    ids = list(model.spirit_order)
    rel = {(r[0], r[2]): r[4] for r in domr}
    mat = ["<table><thead><tr><th class=\"l\">A \\ B</th>"] + [f"<th>{esc(model.spirits[b]['name'])}<br>★{model.spirits[b]['grade']}</th>" for b in ids] + ["</tr></thead><tbody>"]
    for a in ids:
        mat.append(f"<tr><td class=\"l\">{esc(model.spirits[a]['name'])} ★{model.spirits[a]['grade']}</td>")
        for b in ids:
            v = rel.get((a, b), "")
            cell = {"dominates": ('dom', 'D'), "trait_protected": ('prot', 'T')}.get(v, ("", ""))
            mat.append(f'<td class="{cell[0]}">{cell[1]}</td>')
        mat.append("</tr>")
    mat.append("</tbody></table>")
    body.append("".join(mat))
    body.append("<h2>포획 첫 획득 분위수(고정 확률 해석식)</h2>")
    body.append('<p class="note">천장 없는 고정 확률의 기하분포. minutes = 조우 수 / 시간당 조우. release 행은 해당 릴리스 필드 중 p99가 가장 짧은 단일 필드.</p>')
    body.append(table(caph, capr, left_cols=5))
    body.append("<h2>placeholder 목록</h2>")
    body.append(table(["file", "path", "id", "notes"], [[p["file"], p["path"], p["id"], p["notes"]] for p in meta["placeholders"]], left_cols=4))
    if meta["validation_warnings"]:
        body.append("<h2>검증 경고</h2><ul>" + "".join(f"<li>{esc(w)}</li>" for w in meta["validation_warnings"]) + "</ul>")
    body.append(f'<p class="note">tables_sha256={esc(meta["tables_sha256"])} / curves_sha256={esc(meta["curves_sha256"])}</p>')
    return page("econ_sim static", body)


def line_chart(series: dict[str, list[tuple[float, float]]], title: str, x_label: str, y_label: str,
               y_min: float = 0.0, y_max: float | None = None, hlines: list[tuple[float, str]] | None = None,
               width: int = 760, height: int = 300) -> str:
    """線形軸の折れ線グラフ（インライン SVG、xmlns 属性なし）."""
    pts = [p for s in series.values() for p in s]
    if not pts:
        return "<p>데이터 없음</p>"
    ml, mr, mt, mb = 56, 170, 28, 40
    x0, x1 = min(p[0] for p in pts), max(p[0] for p in pts)
    top = y_max if y_max is not None else max(max(p[1] for p in pts), *(h[0] for h in (hlines or [])), y_min + 1e-9)
    pw, ph = width - ml - mr, height - mt - mb

    def sx(x: float) -> float:
        return ml + (x - x0) / (x1 - x0 or 1) * pw

    def sy(y: float) -> float:
        return mt + ph - (y - y_min) / (top - y_min or 1) * ph

    out = [f'<svg viewBox="0 0 {width} {height}" width="{width}" height="{height}" role="img" aria-label="{esc(title)}">',
           f'<text x="{ml}" y="16" font-size="13">{esc(title)}</text>']
    for i in range(5):
        y = y_min + (top - y_min) * i / 4
        out.append(f'<line x1="{ml}" x2="{ml + pw}" y1="{sy(y):.1f}" y2="{sy(y):.1f}" stroke="#e3e3e3"/>'
                   f'<text x="{ml - 6}" y="{sy(y) + 4:.1f}" font-size="10" text-anchor="end">{y:.3g}</text>')
    for y, label in hlines or []:
        out.append(f'<line x1="{ml}" x2="{ml + pw}" y1="{sy(y):.1f}" y2="{sy(y):.1f}" stroke="#c0392b" stroke-dasharray="4 3"/>'
                   f'<text x="{ml + pw - 4}" y="{sy(y) - 3:.1f}" font-size="10" fill="#c0392b" text-anchor="end">{esc(label)}</text>')
    step = max(1, round((x1 - x0) / 10))
    xv = x0
    while xv <= x1:
        out.append(f'<text x="{sx(xv):.1f}" y="{mt + ph + 14}" font-size="10" text-anchor="middle">{xv:g}</text>')
        xv += step
    out.append(f'<text x="{ml + pw / 2:.1f}" y="{height - 6}" font-size="11" text-anchor="middle">{esc(x_label)}</text>')
    out.append(f'<text x="12" y="{mt + ph / 2:.1f}" font-size="11" transform="rotate(-90 12 {mt + ph / 2:.1f})" '
               f'text-anchor="middle">{esc(y_label)}</text>')
    colors = PALETTE + ["#16a085", "#f39c12", "#2c3e50", "#e84393"]
    for i, (name, s) in enumerate(series.items()):
        color = colors[i % len(colors)]
        out.append(f'<polyline fill="none" stroke="{color}" stroke-width="2" points="'
                   + " ".join(f"{sx(x):.1f},{sy(y):.1f}" for x, y in s) + '"/>')
        ly = mt + 10 + i * 15
        out.append(f'<line x1="{ml + pw + 10}" x2="{ml + pw + 28}" y1="{ly}" y2="{ly}" stroke="{color}" stroke-width="2"/>'
                   f'<text x="{ml + pw + 32}" y="{ly + 4}" font-size="11">{esc(name)}</text>')
    out.append("</svg>")
    return "".join(out)
