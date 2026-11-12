"""e2e smoke: all --quick（短い日数）が全成果物を作り、HTML に外部 URL がない."""
import csv
import io
import json
import tempfile
import unittest
from pathlib import Path

from econ_sim import cli, metrics
from _support import CONFIG_DIR, DATA_DIR, FIXTURES_DIR
from econ_sim.data_load import load_data
from econ_sim.model import Model
from test_static import EXTERNAL


class AllQuickSmokeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory()
        cls.out = Path(cls._tmp.name) / "run"
        buf = io.StringIO()
        cls.code = cli.main(["all", "--quick", "--days", "2", "--data", str(DATA_DIR), "--config", str(CONFIG_DIR),
                             "--out", str(cls.out)], out=buf)
        cls.log = buf.getvalue()

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def test_exit_and_outputs(self):
        self.assertEqual(self.code, 0, self.log)
        for name in ("daily.csv", "events.csv", "spirit_daily.csv", "capture_stats.csv", "checks.csv", "allocation.csv",
                     "manifest.json", "report.html", "static/static.html"):
            self.assertTrue((self.out / name).is_file(), name)

    def test_report_offline(self):
        text = (self.out / "report.html").read_text(encoding="utf-8")
        self.assertIn("<svg", text)
        self.assertIsNone(EXTERNAL.search(text))
        self.assertLess(text.index("판정 요약"), text.index("필드 해금 곡선"))

    def test_manifest(self):
        m = json.loads((self.out / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual((m["replicates"], m["days"]), (20, 2))
        for key in ("run", "converge", "report", "all_total"):
            self.assertIn(key, m["timing_seconds"])
        self.assertTrue(m["assumptions"] and m["placeholders"])
        self.assertIn("persona_id", m["rng"]["excluded_from_key"])

    def test_checks_and_capture_stats(self):
        with open(self.out / "checks.csv", encoding="utf-8", newline="") as fh:
            rows = list(csv.DictReader(fh))
        self.assertEqual(list(rows[0]), metrics.CHECK_COLS)
        self.assertTrue(all(r["draft_evaluation"] in {"PASS", "WARN", "FAIL", "INCONCLUSIVE", "INFO"} for r in rows))
        self.assertTrue(all(r["approval_state"] in {"approved", "draft"} for r in rows))
        rule = next(r for r in rows if r["check_id"] == "rule_validation")
        self.assertEqual(rule["draft_evaluation"], "PASS")
        with open(self.out / "capture_stats.csv", encoding="utf-8", newline="") as fh:
            self.assertEqual(sum(1 for _ in csv.DictReader(fh)), 6 * 10)  # 6 ペルソナ（研究比較群 2 を追加）× 10 種

    def test_capture_state_columns(self):
        # 段階 2: 捕獲の状態機械・活力の列があり、1 日の使用秒は予算秒以下（時間の保存）
        with open(self.out / "daily.csv", encoding="utf-8", newline="") as fh:
            rows = list(csv.DictReader(fh))
        for col in ("attempts_cum", "capture_seconds", "capture_budget_seconds", "capture_carry_seconds", "weaken_seconds",
                    "food_eaten", "enc_done_meadow", "enc_seconds_meadow", "earned_grant_wick", "earned_craft_wick"):
            self.assertIn(col, rows[0])
        self.assertTrue(all(int(r["capture_seconds"]) <= int(r["capture_budget_seconds"]) for r in rows))
        self.assertTrue(any(int(r["enc_done_meadow"]) > 0 for r in rows))

    def test_stage5_checks_present(self):
        # 段階 5・12 節の新指標（全て draft/INFO）が出て、既存の approved 行の check_id は残る
        with open(self.out / "checks.csv", encoding="utf-8", newline="") as fh:
            rows = list(csv.DictReader(fh))
        ids = {r["check_id"] for r in rows}
        for cid in ("capture_rule_conformance", "capture_time_conservation", "encounter_seconds_mean", "capture_outcome_share",
                    "wick_shortage_share", "wick_procure_minutes", "wick_paid_free_gap", "star4_exposure", "finite_cosmetic_completed_day",
                    "finite_cosmetic_progress", "sink_absorption", "repeat_sink_available_rate", "capture_pending_at_horizon",
                    "weaken_seconds_mean", "vigor_low_share", "food_per_day", "food_shortage", "assist_weaken_share", "vigor_paid_free_gap"):
            self.assertIn(cid, ids)
        new = [r for r in rows if r["check_id"] in ids - {"g2_r_over_max"} and r["check_id"].startswith(("capture_", "wick_", "finite_", "sink_",
                                                                                                          "repeat_", "weaken_", "vigor_", "food_"))]
        self.assertTrue(all(r["approval_state"] == "draft" for r in new))
        cons = next(r for r in rows if r["check_id"] == "capture_time_conservation")
        self.assertEqual(cons["draft_evaluation"], "PASS")
        for cid in ("g2_r_over_max", "unlock_p50_target", "paid_unlock_shortening", "star4_first_capture_p99", "research_natural_gain"):
            self.assertIn(cid, ids)
        with open(self.out / "daily.csv", encoding="utf-8", newline="") as fh:
            head = next(csv.reader(fh))
        for col in ("wick_blocked_min", "wick_procure_min", "sink_spent_basic", "finite_sink_done", "repeat_sink_levels", "g4_enc"):
            self.assertIn(col, head)
        self.assertTrue((self.out / "static" / "sink_catalog.csv").is_file())

    def test_finite_event_and_approved_unchanged(self):
        with open(self.out / "events.csv", encoding="utf-8", newline="") as fh:
            ev = [r for r in csv.DictReader(fh) if r["event_type"] == "finite_cosmetic_completed"]
        self.assertEqual(len(ev), 120)  # 6 ペルソナ × 20 反復、未到達も observed=false で 1 行
        ref = json.loads((FIXTURES_DIR / "approved_thresholds_ref.json").read_text(encoding="utf-8"))
        ref_rows = {(a, b): c for a, b, c in ref["rows"]}
        with open(self.out / "checks.csv", encoding="utf-8", newline="") as fh:
            rows = list(csv.DictReader(fh))
        seen = 0
        for r in rows:
            k = (r["check_id"], r["cohort"])
            if k in ref_rows:
                seen += 1
                self.assertEqual((r["approval_state"], r["threshold"]), ("approved", ref_rows[k]), k)
        self.assertGreaterEqual(seen, 25)
        approved_ids = {a for a, _, _ in ref["rows"]}
        self.assertFalse({r["check_id"] for r in rows if r["approval_state"] == "approved"} - approved_ids)  # 新しい approved 指標はない

    def test_censoring_recorded(self):
        with open(self.out / "events.csv", encoding="utf-8", newline="") as fh:
            ev = [r for r in csv.DictReader(fh) if r["event_type"] == "field_unlock" and r["target_id"] == "ridge"]
        self.assertEqual(len(ev), 120)  # 6 ペルソナ × 20 反復、未到達も行を残す
        self.assertTrue(all(r["censor_time_minutes"] == str(2 * 1440) for r in ev))
        self.assertTrue(any(r["observed"] == "false" and r["event_time_minutes"] == "" for r in ev))


class PatchRunTest(unittest.TestCase):
    def test_run_with_patch_records_manifest(self):
        before = {k: v for k, v in sorted(load_data(DATA_DIR).file_sha256.items())}
        before = {load_data(DATA_DIR).label(k): v for k, v in before.items()}
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "run"
            patch = DATA_DIR / "variants" / "wick_recipe_codex.json"
            code = cli.main(["run", "--seeds", "1", "--days", "1", "--data", str(DATA_DIR), "--config", str(CONFIG_DIR),
                             "--patch", str(patch), "--out", str(out)], out=io.StringIO())
            self.assertEqual(code, 0)
            m = json.loads((out / "manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(m["patch"]["path"], str(patch))
            self.assertEqual(m["data_file_sha256"], before)  # 元ファイルは変えない
            # パッチが実際に適用された（単一プロセス実行のワーカー文脈のモデル）
            from econ_sim import runner
            from econ_sim.data_load import load_patch_file
            ops = load_patch_file(patch)["ops"]
            recipes = runner._CTX["model"].recipes
            self.assertNotEqual(recipes, Model(load_data(DATA_DIR)).recipes)
            self.assertEqual(recipes, Model(load_data(DATA_DIR, ops)).recipes)


class QuantileTest(unittest.TestCase):
    def test_censored_quantile(self):
        self.assertEqual(metrics.quantile_censored([1, 2, 3, None], 0.5), 2)
        self.assertIsNone(metrics.quantile_censored([1, None, None, None], 0.5))
        self.assertEqual(metrics.quantile_censored([5, 1, 3], 0.9), 5)
        lo, hi = metrics.wilson(9, 10)
        self.assertLess(lo, 0.9)
        self.assertGreater(hi, 0.9)


if __name__ == "__main__":
    unittest.main()
