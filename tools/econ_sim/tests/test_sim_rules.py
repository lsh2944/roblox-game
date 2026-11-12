"""3 段階: M2 R 未定義の判定、M3 未実装データの fail-fast と捕獲コスト・夜限定、M4 分単位・検閲込みの課金短縮率."""
import copy
import json
import tempfile
import unittest
from pathlib import Path

from econ_sim import jsonio, metrics
from econ_sim.data_load import load_data
from econ_sim.economy import Economy
from econ_sim.model import Model
from econ_sim.sim import Simulator
from econ_sim.sim_config import SimConfigError, load_personas
from econ_sim.validate import validate
from _support import CONFIG_DIR, DATA_DIR

CRIT = jsonio.load_strict(CONFIG_DIR / "criteria.json")
REF = jsonio.load_strict(CONFIG_DIR / "static_reference.json")


def sim_with(ops, persona_id="balanced"):
    model = Model(load_data(DATA_DIR, ops))
    cfg, _ = load_personas(CONFIG_DIR / "personas.json", model)
    persona = copy.deepcopy(next(p for p in cfg["personas"] if p["id"] == persona_id))
    return Simulator(Economy(model), cfg, persona, 0, 2, REF)


class FailFastTest(unittest.TestCase):
    def check(self, ops, text):
        model = Model(load_data(DATA_DIR, ops))
        with self.assertRaises(SimConfigError) as cm:
            load_personas(CONFIG_DIR / "personas.json", model)
        self.assertIn(text, str(cm.exception))
        codes = {i.code for i in validate(load_data(DATA_DIR, ops))}
        self.assertIn("RULE_SIM_UNSUPPORTED", codes)

    def test_event_availability(self):
        self.check([{"op": "set", "file": "fields", "path": "/fields/id:meadow/capture/table/spirit_id=sparkle/availability",
                     "value": "event"}], "availability=event")

    def test_placement_cost(self):
        self.check([{"op": "set", "file": "spirits", "path": "/spirits/id:sparkle/placement_cost", "value": 2}], "placement_cost")

    def test_step_mismatch(self):
        model = Model(load_data(DATA_DIR))
        doc = jsonio.load_strict(CONFIG_DIR / "personas.json")
        doc["policy"]["step_minutes"] = 10
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "personas.json"
            p.write_text(json.dumps(doc, ensure_ascii=False), encoding="utf-8")
            with self.assertRaises(SimConfigError):
                load_personas(p, model)


class CaptureRuleTest(unittest.TestCase):
    def test_capture_cost_spent_and_stops(self):
        # 試行ごとに芯 1 個（capture.json）。芯が尽きたら新しい遭遇を始めず、捕獲先も選ばない（狩り素材がなく芯も作れない）
        sim = sim_with([])
        sim.state.wallet["wick"] = 2000  # 2 試行分
        sim._capture("meadow", 0, False)
        self.assertEqual(sim.state.wallet["wick"], 0)
        self.assertEqual(sim.state.attempts, 2)
        self.assertGreaterEqual(sim.state.encounters, 1)
        self.assertIsNone(sim.policy.capture_field())

    def test_night_only_entries(self):
        ops = [{"op": "set", "file": "fields", "path": f"/fields/id:meadow/capture/table/spirit_id={sp}/availability", "value": "night_only"}
               for sp in ("sparkle", "dewdrop", "flower_lamp", "sunset_bird", "shard_light")]
        sim = sim_with(ops)
        sim._capture("meadow", 0, False)
        self.assertEqual(sim.state.encounters, 0)  # 昼は出現なし
        sim._capture("meadow", 0, True)
        self.assertGreater(sim.state.encounters, 0)


class MetricsRuleTest(unittest.TestCase):
    @staticmethod
    def rundata(events, reps=(0, 1), censor=2880):
        rd = object.__new__(metrics.RunData)
        rd.reps = {"free": list(reps), "paid": list(reps)}
        rd.events = events
        rd.censor_minutes = censor
        return rd

    def test_paid_shortening_minutes_and_censoring(self):
        start = {("free", "game_start", "first_session"): {0: (1, 420, None), 1: (1, 420, None)},
                 ("paid", "game_start", "first_session"): {0: (1, 420, None), 1: (1, 420, None)}}
        ev = dict(start)
        ev[("free", "field_unlock", "forest")] = {0: (1, 1000, None)}  # rep1 は未到達（検閲）
        ev[("paid", "field_unlock", "forest")] = {0: (1, 720, None), 1: (1, 800, None)}
        ps = metrics.paired_shortening(self.rundata(ev), "free", "paid", "forest")
        # rep0: 1 − (720−420)/(1000−420) = 0.4828（同じ日でも分単位で差が出る）
        # rep1: T_free ≥ 2880 → 1 − (800−420)/(2880−420) = 0.8455（下限）。最近順位の中央値は小さい方
        self.assertAlmostEqual(ps["shortening"], 1 - 300 / 580, places=9)
        self.assertEqual((ps["both"], ps["free_censored"], ps["paid_censored"], ps["neither"]), (1, 1, 0, 0))

    def test_paid_shortening_both_censored_excluded(self):
        ev = {("free", "field_unlock", "ridge"): {}, ("paid", "field_unlock", "ridge"): {}}
        ps = metrics.paired_shortening(self.rundata(ev), "free", "paid", "ridge")
        self.assertIsNone(ps["shortening"])
        self.assertEqual(ps["neither"], 2)

    def test_r_undefined_is_separate_fail(self):
        rd = object.__new__(metrics.RunData)
        model = Model(load_data(DATA_DIR))
        rd.model = model
        rd.personas = ["balanced"]
        rd.reps = {"balanced": [0]}
        rd.days = 2
        rd.extract_days = [2]
        rd.share, rd.storage, rd.basic_cum, rd.spirit, rd.allocation, rd.events = {}, {}, {}, {}, [], {}
        rd.lost = {"balanced": [0, 2]}
        rd.capture_minutes = {"balanced": 0}
        rd.hunt_earned = {}
        rd.start_species = set()
        rd.censor_minutes = 2880
        rd.r_threshold = CRIT["g2"]["max_ratio"]
        rd.transition_minutes = CRIT["g2"]["transition_minutes"]
        rd.g2_field, rd.hunt_daily, rd.hunt_wallet = {}, {}, {}
        for undef, want in ((0, "PASS"), (5, "FAIL")):
            # 最善配置基準（判定）: 区間外未定義 undef 分、移行区間内の超過・未定義（各 30 分）は FAIL にしない
            best = {"r_sum": 100.0, "r_minutes": 50, "over_max_minutes": 0, "over_max_transition_minutes": 30,
                    "undefined_minutes": undef, "undefined_transition_minutes": 30, "gather_min": 50 + undef,
                    "max_outside": 2.0, "max_transition": 9.0}
            # 実配置基準は参考行のみ（判定に使わない）
            actual = dict(best, over_max_minutes=20, max_outside=7.0)
            rd.g2 = {"best": {"balanced": best}, "actual": {"balanced": actual}}
            rows = metrics.compute(rd, CRIT, REF, 0)["checks"]
            row = next(r for r in rows if r[0] == "g2_r_undefined" and r[1] == "balanced")
            over = next(r for r in rows if r[0] == "g2_r_over_max" and r[1] == "balanced")
            ref_row = next(r for r in rows if r[0] == "g2_r_actual_reference" and r[1] == "balanced")
            self.assertEqual((row[9], row[10]), (want, "approved"))
            self.assertEqual(ref_row[9], "INFO")
            self.assertIn("구간 밖 최대 R=2.000", over[12])
            self.assertEqual(over[9], "PASS")  # 超過判定とは分離


if __name__ == "__main__":
    unittest.main()
