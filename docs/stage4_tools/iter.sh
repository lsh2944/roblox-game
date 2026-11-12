#!/bin/bash
# 10 シード run → report → 主要判定の要約（スクラッチ専用）
set -e
OUT=/Users/leeseunghak/project/roblox-game/outputs/iter_$1
cd /Users/leeseunghak/project/roblox-game/tools/econ_sim
python3 -m econ_sim run --seeds ${2:-10} --workers 8 --out $OUT | tail -1
python3 -m econ_sim report --out $OUT | tail -1
python3 - "$OUT" <<'PY'
import csv, sys
d = sys.argv[1]
want = ("g2_r_over_max", "g2_r_undefined", "g2_r_field_band", "g2_r_actual_reference", "unlock_p50_target", "unlock_p90_max",
        "unlock_day", "heavy_user_lead", "paid_unlock_shortening", "star4_first_capture_p99", "hunt_material_idle_share")
for r in csv.DictReader(open(d + "/checks.csv")):
    if r["check_id"] in want and not (r["check_id"] == "unlock_day" and "forest" in r["cohort"]):
        print(r["check_id"][:22].ljust(22), r["cohort"][:30].ljust(30), r["estimate"][:22].ljust(22), r["draft_evaluation"][:5].ljust(5), r["reason"][:70])
PY
