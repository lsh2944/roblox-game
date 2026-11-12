"""公式: test_vectors.json の黄金ベクトルと、境界・性質のテスト."""
import unittest
from fractions import Fraction

from econ_sim import formulas, jsonio
from _support import DATA_DIR

# 結果が分数ではなく文字列（資源 ID、"" = なし）の関数
STRING_RESULT_FNS = {"capture_tool_item"}


class GoldenVectorTest(unittest.TestCase):
    def test_all_vectors(self):
        doc = jsonio.load_strict(DATA_DIR / "test_vectors.json")
        self.assertGreaterEqual(len(doc["vectors"]), 40)
        for v in doc["vectors"]:
            with self.subTest(v["id"]):
                got = formulas.call_vector(v["fn"], v["args"])
                if isinstance(v["expected"], str) and v["fn"] not in STRING_RESULT_FNS:
                    self.assertEqual(Fraction(got), Fraction(v["expected"]))
                else:
                    self.assertEqual(got, v["expected"])

    def test_every_function_has_vector(self):
        doc = jsonio.load_strict(DATA_DIR / "test_vectors.json")
        covered = {v["fn"] for v in doc["vectors"]}
        self.assertEqual(covered, set(formulas.VECTOR_FUNCS))


class BoundaryTest(unittest.TestCase):
    def test_float_growth_is_exact(self):
        # JSON の 1.1 は float でも 10 進どおりに解釈し、100×1.1=110 を 111 にしない
        self.assertEqual(formulas.exp_ceil_cost(100, 1.1, 1), 110)
        self.assertEqual(formulas.exp_ceil_cost(100, 1.15, 0), 100)

    def test_safe_integer_guard(self):
        with self.assertRaises(formulas.FormulaError):
            formulas.exp_ceil_cost(10**15, "10", 3)
        with self.assertRaises(formulas.FormulaError):
            formulas.slot_power_bps(-1, 10000, 10000)

    def test_milestone_jump(self):
        m = [(10, 2), (25, 2)]
        self.assertEqual(formulas.linear_milestone_bps(1000, 9, m) * 2 + 2000, formulas.linear_milestone_bps(1000, 10, m))
        self.assertEqual(formulas.linear_milestone_bps(1000, 25, m), 136000)

    def test_offline_cap_boundary(self):
        cap = 12 * 60
        self.assertEqual(formulas.offline_credit_minutes(cap - 1, cap), (cap - 1, 0))
        self.assertEqual(formulas.offline_credit_minutes(cap, cap), (cap, 0))
        self.assertEqual(formulas.offline_credit_minutes(cap + 1, cap), (cap, 1))
        self.assertEqual(formulas.offline_credit_minutes(24 * 60, 24 * 60), (1440, 0))

    def test_accrue_split_equals_closed_form(self):
        # 区間を分割して積算しても、閉じた式で一度に積算した結果と一致する（端数繰越の正しさ）
        rate = 357_990
        total, carry = 0, 0
        for _ in range(137):
            got, carry = formulas.accrue_milli(rate, 1, carry)
            total += got
        once, carry_once = formulas.accrue_milli(rate, 137, 0)
        self.assertEqual((total, carry), (once, carry_once))
        self.assertEqual(once, rate * 137 // 60)

    def test_night_segments_cover_interval(self):
        # 2026-11-11 決定のゲーム内時計（60 分周期、毎時 30〜60 分が夜）
        clock = (60, 30, 30)
        segs = formulas.night_segments(100, 100 + 3 * 1440 + 7, *clock)
        self.assertEqual(segs[0][0], 100)
        self.assertEqual(segs[-1][1], 100 + 3 * 1440 + 7)
        for a, b in zip(segs, segs[1:]):
            self.assertEqual(a[1], b[0])
            self.assertNotEqual(a[2], b[2])
        for s, e, f in segs:
            # 各区間の全分が同じ昼夜で、夜は (分 mod 60) ≥ 30 と一致する（決定文の直接判定）
            self.assertTrue(all((m % 60 >= 30) == f for m in range(s, e)))
        night = sum(e - s for s, e, f in segs if f)
        # 3 日分（72 周期）でちょうど半分 + 端数 [4420, 4427)（mod 60 = 40..46、全部夜）7 分
        self.assertEqual(night, 3 * 1440 // 2 + 7)
        self.assertEqual(formulas.night_segments(50, 50, *clock), [])

    def test_night_segments_disabled_and_always(self):
        self.assertEqual(formulas.night_segments(100, 200, 60, 30, 0), [(100, 200, False)])
        self.assertEqual(formulas.night_segments(100, 200, 60, 30, 60), [(100, 200, True)])
        # 夜が周期をまたいで折り返す（offset 50、夜 20 分 → 毎時 50〜70(=10) 分が夜）
        self.assertEqual(formulas.night_segments(0, 60, 60, 50, 20), [(0, 10, True), (10, 50, False), (50, 60, True)])
        for bad in ((0, 0, 0), (60, 60, 30), (60, 30, 61), (60, -1, 30)):
            with self.assertRaises(formulas.FormulaError):
                formulas.night_segments(0, 10, *bad)

    def test_hunt_ratio_threshold(self):
        args = dict(drop_per_hour=30, recommended_power=20, bonus_bps=0, min_ratio_bps=5000, max_ratio_bps=15000)
        self.assertEqual(formulas.hunt_rate_milli_per_hour(party_power=99_999, **args), 0)
        self.assertEqual(formulas.hunt_rate_milli_per_hour(party_power=100_000, **args), 15000)

    def test_geometric_quantile_definition(self):
        # 定義: 1-(1-q)^n >= p を満たす最小の n
        for q in (Fraction(1, 7), Fraction(3, 1000), Fraction(5, 548)):
            for p in (Fraction(1, 2), Fraction(9, 10), Fraction(99, 100)):
                n = formulas.geometric_quantile(q, p)
                self.assertGreaterEqual(1 - (1 - q) ** n, p)
                if n > 1:
                    self.assertLess(1 - (1 - q) ** (n - 1), p)

    def test_g2_ratio_zero_idle(self):
        self.assertIsNone(formulas.g2_ratio(1000, 0))


if __name__ == "__main__":
    unittest.main()
