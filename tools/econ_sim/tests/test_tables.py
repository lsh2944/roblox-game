"""曲線 → 整数強化表の生成・ハッシュ・鮮度."""
import copy
import io
import shutil
import tempfile
import unittest
from pathlib import Path

from econ_sim import cli, jsonio, tables
from econ_sim.data_load import load_data
from econ_sim.validate import validate
from _support import DATA_DIR

SAMPLE = {
    "schema_version": 1,
    "cost_curves": [
        {"id": "fac", "formula": "exp_ceil", "base": [{"resource": "dew", "amount": 100}], "growth": 1.15, "exponent_offset": -1, "max_level": 6},
        {"id": "spirit", "formula": "exp_ceil", "base": [{"resource": "dew", "amount": 10}], "growth": 1.12, "exponent_offset": 0, "max_level": 3},
    ],
    "bonus_curves": [
        {"id": "out", "formula": "linear_milestone", "per_level": 0.10, "milestones": [{"level": 3, "mult": 2}], "max_level": 4},
    ],
}


class TablesTest(unittest.TestCase):
    def test_spec_values(self):
        doc = tables.generate(SAMPLE)
        fac = [row["costs"][0]["amount"] for row in doc["cost_tables"][0]["levels"]]
        # ceil(100×1.15^(L-1)), L=1..5: 100, 115, 132.25, 152.0875, 174.900625
        self.assertEqual(fac, [100, 115, 133, 153, 175])
        spirit = [row["costs"][0]["amount"] for row in doc["cost_tables"][1]["levels"]]
        # ceil(10×1.12^L), L=1..2: 11.2, 12.544
        self.assertEqual(spirit, [12, 13])
        out = [row["mult_bps"] for row in doc["bonus_tables"][0]["levels"]]
        # (1+0.1(L-1)) × (L>=3 で ×2): 1.0, 1.1, 2.4, 2.6
        self.assertEqual(out, [10000, 11000, 24000, 26000])

    def test_deterministic_and_hashed(self):
        a, b = tables.generate(SAMPLE), tables.generate(copy.deepcopy(SAMPLE))
        self.assertEqual(jsonio.dump_pretty(a), jsonio.dump_pretty(b))
        self.assertEqual(a["curves_sha256"], jsonio.canonical_sha256(SAMPLE))
        self.assertEqual(a["tables_sha256"], jsonio.canonical_sha256(tables.table_body(a)))
        self.assertEqual(tables.staleness(SAMPLE, a), [])

    def test_repo_tables_are_current(self):
        gd = load_data(DATA_DIR)
        self.assertEqual(tables.staleness(gd.docs["curves"], gd.docs["upgrade_tables"]), [])

    def test_stale_after_curve_change(self):
        gd = load_data(DATA_DIR, [{"op": "set", "file": "curves", "path": "/cost_curves/id:fac_cost_dew_spring/growth", "value": 1.2}])
        codes = {i.code for i in validate(gd) if i.level == "ERROR"}
        self.assertEqual(codes, {"STALE_TABLES"})

    def test_tampered_table_detected(self):
        gd = load_data(DATA_DIR, [{"op": "set", "file": "upgrade_tables",
                                   "path": "/bonus_tables/id:facility_output/levels/9/mult_bps", "value": 99999}])
        codes = {i.code for i in validate(gd) if i.level == "ERROR"}
        self.assertEqual(codes, {"STALE_TABLES"})

    def test_gen_tables_cli_creates_missing_and_refuses_broken(self):
        with tempfile.TemporaryDirectory() as tmp:
            data = Path(tmp) / "data"
            shutil.copytree(DATA_DIR, data)
            target = data / "generated" / "upgrade_tables.json"
            original = target.read_bytes()
            target.unlink()
            self.assertEqual(cli.main(["gen-tables", "--data", str(data), "--check"], out=io.StringIO()), 1)
            self.assertEqual(cli.main(["gen-tables", "--data", str(data)], out=io.StringIO()), 0)
            self.assertEqual(target.read_bytes(), original)
            self.assertEqual(cli.main(["gen-tables", "--data", str(data), "--check"], out=io.StringIO()), 0)
            # 曲線以外のデータが壊れていれば表を書かない
            target.unlink()
            spirits = data / "spirits.json"
            spirits.write_text(spirits.read_text(encoding="utf-8").replace('"combat": 3,', '"combat": "x",', 1), encoding="utf-8")
            self.assertEqual(cli.main(["gen-tables", "--data", str(data)], out=io.StringIO()), 1)
            self.assertFalse(target.exists())


if __name__ == "__main__":
    unittest.main()
