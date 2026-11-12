"""static 出力: 生成物・バイト決定性・外部 URL なし・要件どおりの値."""
import csv
import io
import re
import tempfile
import unittest
from fractions import Fraction
from pathlib import Path

from econ_sim import cli, static_analysis
from _support import CONFIG_DIR, DATA_DIR

EXTERNAL = re.compile(r"(?i)(https?:|ftp:|wss?:|//[a-z0-9]|url\s*\(|@import|<script|<link|<iframe|<img|\bsrc\s*=)")


def read_csv(path):
    with open(path, encoding="utf-8", newline="") as fh:
        return list(csv.DictReader(fh))


class StaticOutputTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory()
        base = Path(cls._tmp.name)
        cls.out1, cls.out2 = base / "run1", base / "run2"
        for out in (cls.out1, cls.out2):
            buf = io.StringIO()
            code = cli.main(["static", "--data", str(DATA_DIR), "--config", str(CONFIG_DIR), "--out", str(out)], out=buf)
            assert code == 0, buf.getvalue()

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def test_files_exist(self):
        for name in static_analysis.CSV_FILES + ("static.html", "static_meta.json"):
            self.assertTrue((self.out1 / name).is_file(), name)

    def test_csv_bytes_identical(self):
        for name in static_analysis.CSV_FILES:
            with self.subTest(name):
                self.assertEqual((self.out1 / name).read_bytes(), (self.out2 / name).read_bytes())

    def test_html_has_no_external_url(self):
        text = (self.out1 / "static.html").read_text(encoding="utf-8")
        self.assertTrue(text.startswith("<!DOCTYPE html>"))
        self.assertIn("<svg", text)
        self.assertIsNone(EXTERNAL.search(text), EXTERNAL.search(text) and EXTERNAL.search(text).group(0))

    def test_payback_drops_at_milestones(self):
        rows = [r for r in read_csv(self.out1 / "facility_payback.csv") if r["facility_id"] == "dew_spring"]
        by_to = {int(r["to_level"]): r for r in rows}
        for m in (10, 25):
            # マイルストーン到達の強化は直前・直後の強化より回収が早い（不連続）
            self.assertEqual(by_to[m]["milestone"], "true")
            self.assertLess(Fraction(by_to[m]["payback_hours_normalized"]), Fraction(by_to[m - 1]["payback_hours_normalized"]))
            self.assertLess(Fraction(by_to[m]["payback_hours_normalized"]), Fraction(by_to[m + 1]["payback_hours_normalized"]))
        # Lv1→2: 費用 40+20=60、生産増 = 20/h × 0.1 × 基準 3 枠 = 6/h → 10 時間
        self.assertEqual(by_to[2]["payback_hours_normalized"], "10.00")

    def test_capture_quantiles_ordered_and_week2_covered(self):
        rows = read_csv(self.out1 / "capture_quantiles.csv")
        for r in rows:
            if r["method"] == "unavailable":
                continue
            self.assertLessEqual(int(r["encounters_p50"]), int(r["encounters_p90"]))
            self.assertLessEqual(int(r["encounters_p90"]), int(r["encounters_p99"]))
        week2 = [r for r in rows if r["scope"] == "release:week2"]
        self.assertEqual(len(week2), 6)
        self.assertTrue(all(r["method"] != "unavailable" for r in week2))
        self.assertTrue(all(r["field_id"] in ("meadow", "forest") for r in week2))

    def test_g3_minutes_match_spec(self):
        rows = {r["requirement_id"]: r for r in read_csv(self.out1 / "g3_hunt_minutes.csv")}
        r = rows["field_unlock:forest:unlock"]
        # 15 個 ÷ 30 個/時（推奨戦闘力） = 30 分、日次依頼 3 個/日 → 5 日
        self.assertEqual((r["minutes_ref"], r["idle_wait_days"], r["draft_evaluation"]), ("30.0", "5", "PASS"))

    def test_g2_rule_over_3x_is_fail(self):
        # 3 倍超は FAIL。ただし解禁直後の入口状態（transition_exempt）はシミュと同じ移行区間免除で INFO
        for r in read_csv(self.out1 / "g2_ratio.csv"):
            if r["r_ratio"] and Fraction(r["r_ratio"]) > 3:
                expected = "INFO" if "transition_exempt" in r["note"] else "FAIL"
                self.assertEqual((r["draft_evaluation"], r["approval_state"]), (expected, "approved"))
            if "transition_exempt" in r["note"]:
                self.assertTrue(r["state_id"].endswith("_entry") and r["field_id"] != "meadow")

    def test_meta_lists_placeholders(self):
        meta = (self.out1 / "static_meta.json").read_text(encoding="utf-8")
        self.assertIn('"placeholders"', meta)
        self.assertIn("fields.json", meta)


if __name__ == "__main__":
    unittest.main()
