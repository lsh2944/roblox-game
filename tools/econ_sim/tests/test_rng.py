"""乱数派生: 決定性・ストリーム分離・比較群の共通乱数."""
import inspect
import unittest

from econ_sim import rng


class RngTest(unittest.TestCase):
    def test_golden_seed(self):
        # sha256('["econ_sim.rng/1",12345,"g1",0,"capture"]') の先頭 8 バイト（独立に計算した固定値）
        self.assertEqual(rng.derive_seed(12345, "g1", 0, "capture"), 0x9D106A3473C2A7B6)

    def test_same_key_same_draws(self):
        r1, r2 = rng.make_rng(7, "g", 3, "capture"), rng.make_rng(7, "g", 3, "capture")
        self.assertEqual([r1.random() for _ in range(100)], [r2.random() for _ in range(100)])

    def test_streams_and_keys_separate(self):
        base = rng.derive_seed(7, "g", 3, "capture")
        self.assertNotEqual(base, rng.derive_seed(7, "g", 3, "hunt_drop"))
        self.assertNotEqual(base, rng.derive_seed(7, "g", 4, "capture"))
        self.assertNotEqual(base, rng.derive_seed(8, "g", 3, "capture"))
        self.assertNotEqual(base, rng.derive_seed(7, "h", 3, "capture"))
        # 区切り文字の衝突が起きない
        self.assertNotEqual(rng.derive_seed(1, "a|b", 0, "c"), rng.derive_seed(1, "a", 0, "b|c"))

    def test_paired_groups_share_draws(self):
        # 無課金/課金の比較群は persona・購入有無をキーに含めないので、同じ潜在抽選値を得る
        params = inspect.signature(rng.derive_seed).parameters
        self.assertEqual(list(params), ["master_seed", "pairing_group_id", "replicate_id", "stream"])
        free = rng.make_rng(99, "balanced_pair", 5, "capture")
        paid = rng.make_rng(99, "balanced_pair", 5, "capture")
        self.assertEqual([free.random() for _ in range(50)], [paid.random() for _ in range(50)])

    def test_invalid_inputs(self):
        for bad in [("1", "g", 0, "s"), (1, "", 0, "s"), (1, "g", -1, "s"), (1, "g", 0, ""), (True, "g", 0, "s")]:
            with self.subTest(bad), self.assertRaises(TypeError):
                rng.derive_seed(*bad)


if __name__ == "__main__":
    unittest.main()
