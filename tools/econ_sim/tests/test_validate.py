"""検証器: 実データは合格、broken fixture はそれぞれ意図した ERROR で不合格."""
import io
import shutil
import tempfile
import unittest
from pathlib import Path

from econ_sim import cli
from econ_sim.data_load import load_data, load_patch_file
from econ_sim.validate import has_errors, validate
from _support import DATA_DIR, FIXTURES_DIR


def error_codes(issues):
    return {i.code for i in issues if i.level == "ERROR"}


class RealDataTest(unittest.TestCase):
    def test_repo_data_passes(self):
        issues = validate(load_data(DATA_DIR))
        self.assertFalse(has_errors(issues), "\n".join(i.format() for i in issues if i.level == "ERROR"))

    def test_dominance_is_warning_only(self):
        issues = validate(load_data(DATA_DIR))
        self.assertTrue(all(i.level == "WARN" for i in issues if i.code == "WARN_DOMINANCE"))


class BrokenFixtureTest(unittest.TestCase):
    def test_required_categories_exist(self):
        names = {p.name for p in FIXTURES_DIR.glob("broken_*.json")}
        for required in ("broken_paid_capture.json", "broken_forbidden_product_effect.json",
                         "broken_week2_access.json", "broken_reference.json"):
            self.assertIn(required, names)

    def test_each_fixture_fails_with_intended_code(self):
        fixtures = sorted(FIXTURES_DIR.glob("broken_*.json"))
        self.assertGreaterEqual(len(fixtures), 4)
        for path in fixtures:
            with self.subTest(path.name):
                fx = load_patch_file(path)
                issues = validate(load_data(DATA_DIR, fx["ops"]))
                self.assertEqual(error_codes(issues), set(fx["expect_codes"]),
                                 "\n".join(i.format() for i in issues if i.level == "ERROR"))

    def test_cli_exit_codes(self):
        out = io.StringIO()
        self.assertEqual(cli.main(["validate"], out=out), 0)
        out = io.StringIO()
        self.assertEqual(cli.main(["validate", "--patch", str(FIXTURES_DIR / "broken_paid_capture.json")], out=out), 1)
        self.assertIn("RULE_PAID_CAPTURE", out.getvalue())


class ExtraRuleTest(unittest.TestCase):
    """fixture 以外の規則（ユーザー確定規則の逸脱）."""

    def check(self, ops, code):
        issues = validate(load_data(DATA_DIR, ops))
        self.assertIn(code, error_codes(issues), "\n".join(i.format() for i in issues))

    def test_purchasable_hunt_material(self):
        self.check([{"op": "set", "file": "resources", "path": "/resources/id:hunt_meadow/purchasable", "value": True}],
                   "RULE_PURCHASABLE_KIND")

    def test_upkeep_forbidden(self):
        self.check([{"op": "set", "file": "spirits", "path": "/spirits/id:aurora_deer/upkeep",
                     "value": [{"resource": "crystal", "amount": 5}]}], "RULE_UPKEEP")

    def test_night_clock_rules(self):
        # 2026-11-11 決定のゲーム内時計: 周期は 1440 の約数、夜の長さは周期以内、旧キー（UTC 時刻）はスキーマ違反
        self.check([{"op": "set", "file": "rules", "path": "/night/cycle_minutes", "value": 7},
                    {"op": "set", "file": "rules", "path": "/night/night_start_offset_minutes", "value": 3},
                    {"op": "set", "file": "rules", "path": "/night/night_minutes", "value": 3}], "RULE_NIGHT_CLOCK")
        self.check([{"op": "set", "file": "rules", "path": "/night/night_minutes", "value": 61}], "RULE_NIGHT_CLOCK")
        self.check([{"op": "set", "file": "rules", "path": "/night/start_hour", "value": 20}], "SCHEMA_UNKNOWN_KEY")

    def test_trait_hour_keys_removed(self):
        # 2026-11-12 決定: 夜は rules.night だけ。特性 params の start_hour / end_hour は削除済みキー（スキーマ違反）
        for key in ("start_hour", "end_hour"):
            self.check([{"op": "set", "file": "spirits", "path": "/spirits/id:moon_fox/traits/0/params",
                         "value": {key: 22}}], "SCHEMA_UNKNOWN_KEY")

    def test_offline_cap_over_24h(self):
        self.check([{"op": "append", "file": "hub", "path": "/offline_cap/upgrades", "value": {"hours": 30, "costs": []}},
                    {"op": "set", "file": "hub", "path": "/offline_cap/max_hours", "value": 30}], "RULE_OFFLINE_CAP")

    def test_removed_material_kinds_are_forbidden(self):
        # 2026-11-11 ユーザー決定: 基本素材箱・初心者パスは商品候補から削除。未知 kind ではなく禁止 kind として拒否する
        for kind in ("basic_material_pack", "beginner_pass"):
            with self.subTest(kind):
                issues = validate(load_data(DATA_DIR, [{"op": "append", "file": "products", "path": "/products", "value": {
                    "id": "readd", "name": "재추가", "kind": kind, "price_robux": 1,
                    "purchase_limit_total": 0, "purchase_limit_per_day": 0, "effects": []}}]))
                self.assertIn("RULE_FORBIDDEN_PRODUCT", error_codes(issues))
                self.assertNotIn("RULE_UNKNOWN_PRODUCT", error_codes(issues))

    def test_cosmetic_product_cannot_grant_resources(self):
        # 残る商品（外形）に基本素材の付与効果を付けても許可されない（進行効果なし）
        self.check([{"op": "append", "file": "products", "path": "/products/id:lantern_skin_glow/effects",
                     "value": {"type": "basic_material_hours", "hours": 4, "resources": ["dew"],
                               "rate_reference": "standard_free_idle_at_purchase"}}], "RULE_PRODUCT_EFFECT")

    def test_unlock_cycle(self):
        self.check([{"op": "set", "file": "fields", "path": "/fields/id:meadow/unlock/requires_fields", "value": ["ridge"]}],
                   "RULE_UNLOCK_GRAPH")

    def test_null_rejected(self):
        self.check([{"op": "set", "file": "spirits", "path": "/spirits/id:sparkle/combat", "value": None}], "NULL_VALUE")


class StrictJsonTest(unittest.TestCase):
    def _with_text(self, name, transform):
        with tempfile.TemporaryDirectory() as tmp:
            dst = Path(tmp) / "data"
            shutil.copytree(DATA_DIR, dst)
            p = dst / name
            p.write_text(transform(p.read_text(encoding="utf-8")), encoding="utf-8")
            return error_codes(validate(load_data(dst)))

    def test_duplicate_key(self):
        codes = self._with_text("hub.json", lambda s: s.replace('"storage": {"base_capacity": 100,',
                                                                 '"storage": {"base_capacity": 100, "base_capacity": 40,'))
        self.assertEqual(codes, {"LOAD_JSON"})

    def test_nan(self):
        codes = self._with_text("hub.json", lambda s: s.replace('"base_capacity": 100', '"base_capacity": NaN'))
        self.assertEqual(codes, {"LOAD_JSON"})

    def test_manifest_path_escape(self):
        codes = self._with_text("manifest.json", lambda s: s.replace('"path": "hub.json"', '"path": "../hub.json"'))
        self.assertIn("LOAD_PATH", codes)


if __name__ == "__main__":
    unittest.main()
