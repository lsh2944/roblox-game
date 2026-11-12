"""収束分析: 精霊数が部分集合 DP の上限を超える代表状態は、1 体ずつモードの厳密解を省きヒューリスティック行だけを出す.

2026-11-12 の 20 種拡張で cave・ridge の代表状態が 14 体を超えたための扱い。
- 1 体ずつ（one_of_each_available）: heuristic_greedy_2swap 行だけ、upper_bound・gap は空欄、proven_optimal=false
- 無制限在庫（unlimited_copies）: 従来どおり exact_enumeration と exact_excluding が出る
- 集計: gap は実測できたケースだけで取り、省いた件数は gap_skipped、実測 0 件なら推定値は空欄
"""
import unittest
from types import SimpleNamespace

from econ_sim import converge, metrics, placement
from econ_sim.data_load import load_data
from econ_sim.economy import Economy
from econ_sim.model import Model
from _support import DATA_DIR


def _state(sid, field_id):
    # 枠 2 の小さい状態（無制限在庫の重複組合せ列挙を軽くする）
    return {"id": sid, "field_id": field_id, "facility_level": 5, "staff": {"slots": 2, "spirit_level": 5}}


class ConvergeSkipTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.model = Model(load_data(DATA_DIR))
        cls.econ = Economy(cls.model)
        cls.ref = {"g2_states": [_state("small", "meadow"), _state("big", "ridge")]}
        cls.start = ["sparkle", "dewdrop", "flower_lamp"]
        cls.cases = {c["case_id"]: c for c in converge.representative_cases(cls.model, cls.ref, cls.start)}
        raw = converge.analyze(cls.econ, cls.ref, cls.start)
        cls.rows = [dict(zip(converge.COLUMNS, r)) for r in raw]

    def rows_of(self, state_id, mode):
        return [r for r in self.rows if r["state_id"] == state_id and r["inventory_mode"] == mode]

    def test_fixture_spans_the_limit(self):
        # 前提: big は上限超え、small は上限以内（テストの意味を保つための確認）
        big = {len(c["species"]) for c in self.cases.values() if c["state_id"] == "big"}
        small = {len(c["species"]) for c in self.cases.values() if c["state_id"] == "small"}
        self.assertTrue(all(n > placement.EXACT_MAX_SPIRITS for n in big), big)
        self.assertTrue(all(n <= placement.EXACT_MAX_SPIRITS for n in small), small)

    def test_over_limit_one_of_each_has_only_heuristic_rows(self):
        rows = self.rows_of("big", "one_of_each_available")
        self.assertEqual(len(rows), len(converge.MODES))  # ボトルネック重みごとに 1 行
        for r in rows:
            self.assertEqual(r["method"], "heuristic_greedy_2swap")
            self.assertEqual(r["upper_bound"], "")
            self.assertEqual(r["gap"], "")
            self.assertEqual(r["proven_optimal"], "false")
            self.assertGreater(float(r["objective_value"]), 0.0)
            self.assertTrue(r["species_used"])

    def test_over_limit_unlimited_rows_unchanged(self):
        rows = self.rows_of("big", "unlimited_copies")
        n_species = len(next(c for c in self.cases.values() if c["state_id"] == "big")["species"])
        enum = [r for r in rows if r["method"] == "exact_enumeration"]
        excl = [r for r in rows if r["method"] == "exact_excluding"]
        self.assertEqual(len(enum), len(converge.MODES))
        self.assertEqual(len(excl), len(converge.MODES) * n_species)
        self.assertTrue(all(r["proven_optimal"] == "true" and r["gap"] == "0.0000" for r in enum))

    def test_within_limit_keeps_exact_and_gap(self):
        rows = self.rows_of("small", "one_of_each_available")
        methods = {r["method"] for r in rows}
        self.assertEqual(methods, {"exact_subset_dp", "heuristic_greedy_2swap", "exact_excluding"})
        for r in rows:
            if r["method"] == "heuristic_greedy_2swap":
                self.assertNotEqual(r["gap"], "")
                self.assertNotEqual(r["upper_bound"], "")

    def test_summary_counts_skipped_and_measured(self):
        rd = SimpleNamespace(allocation=self.rows, model=self.model)
        conv = metrics.convergence_summary(rd)
        self.assertEqual(conv["gap_skipped"], len(converge.MODES))   # big の 4 ケース
        self.assertEqual(conv["gap_measured"], len(converge.MODES))  # small の 4 ケース
        self.assertEqual(conv["cases"], 2 * len(converge.MODES))     # 無制限在庫の厳密ケース（判定用）は両状態とも残る
        est, n, note = metrics.heuristic_gap_summary(conv)
        self.assertEqual(n, len(converge.MODES))
        self.assertNotEqual(est, "")
        self.assertIn("미측정 4건", note)


class HeuristicGapSummaryTest(unittest.TestCase):
    def test_no_measurement_is_blank_not_zero(self):
        est, n, note = metrics.heuristic_gap_summary({"max_gap": 0.0, "cases": 8, "gap_measured": 0, "gap_skipped": 8})
        self.assertEqual((est, n), ("", 0))
        self.assertIn("미측정 8건", note)

    def test_all_measured_has_no_skip_note(self):
        est, n, note = metrics.heuristic_gap_summary({"max_gap": 0.0123, "cases": 8, "gap_measured": 8, "gap_skipped": 0})
        self.assertEqual((est, n), ("0.0123", 8))
        self.assertNotIn("미측정", note)


if __name__ == "__main__":
    unittest.main()
