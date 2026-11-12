"""シミュ: オフライン境界・課金ペルソナの購入（外形・便利のみ）・比較群共通乱数・CSV 決定性."""
import copy
import tempfile
import unittest
from pathlib import Path

from econ_sim import jsonio, runner
from econ_sim.data_load import load_data
from econ_sim.economy import Economy
from econ_sim.model import Model
from econ_sim.sim import Simulator
from econ_sim.sim_config import load_personas
from _support import CONFIG_DIR, DATA_DIR


class SimBase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        model = Model(load_data(DATA_DIR))
        cls.econ = Economy(model)
        cls.cfg, _ = load_personas(CONFIG_DIR / "personas.json", model)
        cls.ref = jsonio.load_strict(CONFIG_DIR / "static_reference.json")

    def make(self, persona_id, persona_patch=None, days=2):
        persona = copy.deepcopy(next(p for p in self.cfg["personas"] if p["id"] == persona_id))
        persona.update(persona_patch or {})
        return Simulator(self.econ, self.cfg, persona, 0, days, self.ref)


class OfflineTest(SimBase):
    def test_first_session_is_game_start(self):
        # M1: 最初のセッション開始（light_1h は 08:00=480 分）より前は生産も失効もない
        sim = self.make("light_1h", days=1)
        self.assertEqual((sim.t, sim.logout_time, sim.game_start), (480, 480, 480))
        sim.advance(480)
        # 開始時の支給（芯 21 個、capture.supply.start）以外は何もない
        start = {c["resource"]: c["amount"] * 1000 for c in sim.m.capture_rules["supply"]["start"]}
        self.assertEqual({r: v for r, v in sim.state.wallet.items() if v}, start)
        sim.run()
        acc = sim.day_acc(0)
        produced = acc.minutes.get("online", 0) + acc.minutes.get("off_credited", 0) + acc.minutes.get("off_lost", 0)
        self.assertEqual(produced, 1440 - 480)
        self.assertEqual(acc.minutes.get("off_lost", 0), 0)

    def test_cap_boundary_credit_and_loss(self):
        for extra in (0, 1, 100):
            with self.subTest(extra=extra):
                sim = self.make("light_1h")
                rate = sim.idle_rates(frozenset(), False)["dew"]
                cap = sim.state.offline_cap_hours * 60  # 720
                sim.advance(480 + cap + extra)  # ゲーム開始（=ログアウト扱い）480 から
                acc = sim.day_acc(0)
                self.assertEqual(acc.minutes.get("off_credited", 0), cap)
                self.assertEqual(acc.minutes.get("off_lost", 0), extra)
                self.assertEqual(sim.state.wallet["dew"], rate * cap // 60)

    def test_offline_split_across_days(self):
        sim = self.make("light_1h")
        sim.advance(1200)  # 480..1200 認定
        sim.logout_time = 1200  # 20:00 にログアウトしたとみなす
        sim.advance(1200 + 800)  # 夜境界・日境界で分割
        self.assertEqual(sim.day_acc(0).minutes["off_credited"], 720 + 240)
        self.assertEqual(sim.day_acc(1).minutes["off_credited"], 480)
        self.assertEqual(sim.day_acc(1).minutes["off_lost"], 80)


class PurchaseTest(SimBase):
    """2026-11-11 ユーザー決定: 課金は外形・便利のみ（進行効果なし）。balanced_paid は外形・便利の購入者."""

    CONVENIENCE_KINDS = {"cosmetic", "placement_preset", "storage_expand"}

    def test_paid_persona_buys_only_cosmetic_convenience(self):
        sim = self.make("balanced_paid")
        kinds = {sim.m.products[pu["product_id"]]["kind"] for pu in sim.persona["purchases"]}
        self.assertTrue(kinds)
        self.assertLessEqual(kinds, self.CONVENIENCE_KINDS)

    def test_cosmetic_and_preset_change_nothing_but_robux(self):
        sim = self.make("balanced_paid")
        st = sim.state
        wallet, cap = dict(st.wallet), sim.capacity()
        self.assertTrue(sim.buy_product("lantern_skin_glow", 0))
        self.assertTrue(sim.buy_product("placement_preset_3", 0))
        self.assertEqual(st.wallet, wallet)  # 資源の付与なし
        self.assertEqual(sim.capacity(), cap)
        self.assertEqual(st.robux, 49 + 79)
        self.assertFalse(sim.buy_product("lantern_skin_glow", 1))  # 総購入上限 1
        self.assertEqual(st.pass_claimed, set())

    def test_storage_purchase_grants_no_resources(self):
        sim = self.make("balanced_paid")
        st = sim.state
        wallet = dict(st.wallet)
        self.assertTrue(sim.buy_product("storage_plus_10", 0))
        self.assertEqual(sim.capacity(), 110)
        self.assertEqual(st.wallet, wallet)


class CommonRandomNumbersTest(SimBase):
    def test_paired_personas_share_capture_draws(self):
        free, paid = self.make("balanced"), self.make("balanced_paid")
        for day in (0, 7, 59):
            a = [free.capture_rng(day).random() for _ in range(20)]
            b = [paid.capture_rng(day).random() for _ in range(20)]
            self.assertEqual(a, b)
        other = self.make("balanced", {"id": "renamed_persona"})
        self.assertEqual(other.capture_rng(3).random(), self.make("balanced").capture_rng(3).random())
        hard = self.make("hardcore")
        self.assertNotEqual(hard.capture_rng(3).random(), self.make("balanced").capture_rng(3).random())


class DeterminismTest(unittest.TestCase):
    def test_same_input_same_csv_bytes_any_workers(self):
        names = ("daily.csv", "events.csv", "spirit_daily.csv")
        outs = []
        with tempfile.TemporaryDirectory() as tmp:
            for i, workers in enumerate((1, 1, 2)):
                out = Path(tmp) / f"r{i}"
                runner.run_all(DATA_DIR, CONFIG_DIR / "personas.json", CONFIG_DIR / "static_reference.json", out,
                               replicates=2, days=3, workers=workers, persona_ids=["light_1h", "balanced", "balanced_paid"])
                outs.append({n: (out / n).read_bytes() for n in names})
        for n in names:
            with self.subTest(n):
                self.assertEqual(outs[0][n], outs[1][n])
                self.assertEqual(outs[0][n], outs[2][n])
        self.assertGreater(outs[0]["daily.csv"].count(b"\n"), 18)


if __name__ == "__main__":
    unittest.main()
