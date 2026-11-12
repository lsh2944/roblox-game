"""段階 1（捕獲規則・制作・消費先のデータと検証器）: 展開コスト・反復コスト表・規則の境界・計画書の数値."""
import io
import shutil
import tempfile
import unittest
from pathlib import Path

from econ_sim import cli, jsonio, tables
from econ_sim.data_load import load_data, load_patch_file
from econ_sim.model import Model
from econ_sim.validate import has_errors, validate
from _support import DATA_DIR

VARIANT = DATA_DIR / "variants" / "wick_recipe_codex.json"


def error_codes(issues):
    return {i.code for i in issues if i.level == "ERROR"}


def amounts(costs):
    return {c["resource"]: c["amount"] for c in costs}


class ExpandCostsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.m = Model(load_data(DATA_DIR))

    # 段階 3 で道標に置き換える前の解禁コスト（狩り素材部分、基準本 baselines/20261110_pre_stage23/data/fields.json）
    BEFORE = {"forest": {"hunt_meadow": 15}, "cave": {"hunt_forest": 24, "hunt_meadow": 30},
              "ridge": {"hunt_cave": 20, "hunt_forest": 24, "hunt_meadow": 30}}

    def test_keys_expand_to_previous_unlock_hunt_costs(self):
        # 道標を展開すると段階 3 以前の解禁コスト（狩り素材部分）と完全に一致する（I6: 素材中立の置換）
        for key, field_id in (("key_meadow", "forest"), ("key_cave", "ridge"), ("key_forest", "cave")):
            with self.subTest(key=key):
                self.assertEqual(amounts(self.m.expand_costs([{"resource": key, "amount": 1}])), self.BEFORE[field_id])

    def test_mixed_costs_merge_and_keep_stock_items(self):
        got = self.m.expand_costs([{"resource": "dew", "amount": 5}, {"resource": "comp_cave", "amount": 2},
                                   {"resource": "hunt_cave", "amount": 1}, {"resource": "wick", "amount": 3}])
        # 初出順・同じ資源は合算、stock の芯は展開しない
        self.assertEqual(got, [{"resource": "dew", "amount": 5}, {"resource": "hunt_cave", "amount": 5}, {"resource": "wick", "amount": 3}])

    def test_unlock_requirements_are_expanded(self):
        # 段階 3: 解禁コストは道標（atomic）で書き、要求一覧（G3・検証用）は展開した素材で出す
        base = Model(load_data(DATA_DIR))
        reqs = [r for r in base.iter_requirements() if r.source_kind == "field_unlock"]
        raw = [(fid, c["resource"], c["amount"]) for fid in base.field_order for c in base.expand_costs(base.fields[fid]["unlock"]["costs"])]
        self.assertEqual([(r.source_id, r.resource, r.amount) for r in reqs], raw)
        self.assertTrue(any(base.resources[c["resource"]].get("stack") == "atomic"
                            for fid in base.field_order for c in base.fields[fid]["unlock"]["costs"]))
        self.assertFalse(any(base.resources[r.resource].get("stack") == "atomic" for r in reqs))
        self.assertFalse(any(r.source_kind == "sink" for r in base.iter_requirements()))
        sinks = [r for r in base.iter_requirements(include_sinks=True) if r.source_kind == "sink"]
        self.assertTrue(sinks)
        self.assertTrue(all(base.resources[r.resource].get("stack") != "atomic" for r in sinks))


class PlanNumbersTest(unittest.TestCase):
    """計画書 2.2 の placeholder 数値（有限消費先の合計）とデータの一致."""

    def test_finite_sink_totals(self):
        m = Model(load_data(DATA_DIR))
        tot: dict[str, int] = {}
        for it in m.sinks["items"]:
            for c in m.expand_costs(it["costs"]):
                tot[c["resource"]] = tot.get(c["resource"], 0) + c["amount"]
        for r in m.hub["ranks"]:  # 家 1~3 段階 = 既存拠点等級（質問 Q5）
            for c in r["costs"]:
                tot[c["resource"]] = tot.get(c["resource"], 0) + c["amount"]
        self.assertEqual(round(tot["dew"] / 1e6, 2), 7.27)
        self.assertEqual(round(tot["bloom"] / 1e6, 2), 7.27)
        self.assertEqual(round(tot["crystal"] / 1e6, 2), 4.23)
        self.assertEqual([tot[f"hunt_{f}"] for f in ("meadow", "forest", "cave", "ridge")], [63, 75, 120, 94])
        self.assertEqual(len([i for i in m.sinks["items"] if i["category"] == "furniture"]), 12)
        self.assertEqual(m.capture_rules["supply"]["start"], [{"resource": "wick", "amount": 21}])


class SinkTablesTest(unittest.TestCase):
    def test_repo_sink_tables_current_and_capped(self):
        gd = load_data(DATA_DIR)
        doc = gd.docs["sink_tables"]
        self.assertEqual(tables.sink_staleness(gd.docs["curves"], doc), [])
        # 制約: 上限以降は最終行（祭壇 L20 以降・モジュール 11 回目以降は一定）
        self.assertEqual(tables.sink_cost(doc, "sink_altar_meadow", 1)[0], {"resource": "dew", "amount": 2160})
        self.assertEqual(tables.sink_cost(doc, "sink_altar_meadow", 20), tables.sink_cost(doc, "sink_altar_meadow", 999))
        self.assertEqual(amounts(tables.sink_cost(doc, "sink_module_ridge", 50)), {"dew": 225000, "bloom": 270000, "crystal": 180000})
        self.assertEqual(amounts(tables.sink_cost(doc, "sink_module_ridge", 3)), {"dew": 165000, "bloom": 198000, "crystal": 132000})

    def test_tampered_sink_table_detected(self):
        gd = load_data(DATA_DIR, [{"op": "set", "file": "sink_tables", "path": "/sink_tables/id:sink_altar_meadow/rows/0/costs/0/amount",
                                   "value": 1}])
        self.assertEqual(error_codes(validate(gd)), {"STALE_TABLES"})

    def test_gen_tables_creates_missing_sink_tables(self):
        with tempfile.TemporaryDirectory() as tmp:
            data = Path(tmp) / "data"
            shutil.copytree(DATA_DIR, data)
            target = data / "generated" / "sink_tables.json"
            original = target.read_bytes()
            target.unlink()
            self.assertEqual(cli.main(["gen-tables", "--data", str(data), "--check"], out=io.StringIO()), 1)
            self.assertEqual(cli.main(["gen-tables", "--data", str(data)], out=io.StringIO()), 0)
            self.assertEqual(target.read_bytes(), original)
            self.assertEqual(cli.main(["gen-tables", "--data", str(data), "--check"], out=io.StringIO()), 0)


class RuleBoundaryTest(unittest.TestCase):
    """fixture 以外の境界（各規則の別の破り方）."""

    def codes(self, ops):
        return error_codes(validate(load_data(DATA_DIR, ops)))

    def test_variant_recipe_b_is_valid(self):
        issues = validate(load_data(DATA_DIR, load_patch_file(VARIANT)["ops"]))
        self.assertFalse(has_errors(issues), "\n".join(i.format() for i in issues if i.level == "ERROR"))

    def test_capture_params_cases(self):
        cases = [
            [{"op": "set", "file": "capture", "path": "/base_success_bps_by_grade", "value": [{"grade": 1, "bps": 10000}, {"grade": 2, "bps": 5000}, {"grade": 3, "bps": 2500}]}],
            [{"op": "set", "file": "capture", "path": "/easy_mode/stop_at_light", "value": 0}],
            [{"op": "set", "file": "capture", "path": "/flee_after_failure/step_bps", "value": 500}],  # 300+500×19 < 10000
            [{"op": "set", "file": "capture", "path": "/flee_after_failure/max_bps", "value": 9000}],
            [{"op": "set", "file": "capture", "path": "/time/attempt_seconds", "value": 0}],
            [{"op": "set", "file": "capture", "path": "/light/bands/1/mult_bps", "value": 9000}, {"op": "set", "file": "capture", "path": "/light/bands/2/mult_bps", "value": 9000}],
        ]
        for i, ops in enumerate(cases):
            with self.subTest(ops=ops):
                if i == 0:
                    # ★4 の成功率がなければ、出現表の ★4（shadow_lantern 等）も成功率なし（RULE_CAPTURE_TABLE）で、
                    # 4 週版の ★4 を常時獲得できない（RULE_RELEASE_ACCESS）
                    self.assertEqual(self.codes(ops), {"RULE_CAPTURE_PARAMS", "RULE_CAPTURE_TABLE", "RULE_RELEASE_ACCESS"})
                else:
                    self.assertEqual(self.codes(ops), {"RULE_CAPTURE_PARAMS"})
        # 境界: 逃走 300+step×(K−1) が K=20 で 10000 に届く最小の step は 511（510 は 9990 で不合格）
        self.assertEqual(self.codes([{"op": "set", "file": "capture", "path": "/flee_after_failure/step_bps", "value": 511}]), set())
        self.assertEqual(self.codes([{"op": "set", "file": "capture", "path": "/flee_after_failure/step_bps", "value": 510}]),
                         {"RULE_CAPTURE_PARAMS"})

    def test_field_override_is_pity(self):
        ops = [{"op": "set", "file": "fields", "path": "/fields/id:cave/capture/success_override_bps", "value": 9000}]
        self.assertEqual(self.codes(ops), {"RULE_CAPTURE_NO_PITY"})

    def test_craft_graph_cases(self):
        cases = [
            # atomic 品目のレシピが 2 個
            [{"op": "append", "file": "crafting", "path": "/recipes", "value": {"id": "key_meadow_alt", "output": {"resource": "key_meadow", "amount": 1}, "inputs": [{"resource": "hunt_forest", "amount": 1}], "mode": "atomic", "group": "key"}}],
            # atomic 品目を補給で配る
            [{"op": "set", "file": "capture", "path": "/supply/start", "value": [{"resource": "wick", "amount": 21}, {"resource": "key_meadow", "amount": 1}]}],
            # 存在しない資源の参照
            [{"op": "set", "file": "crafting", "path": "/recipes/id:comp_cave/inputs", "value": [{"resource": "hunt_moon", "amount": 2}]}],
            # mode と stack の不一致
            [{"op": "set", "file": "crafting", "path": "/recipes/id:comp_cave/mode", "value": "stock"}],
        ]
        for ops in cases:
            with self.subTest(ops=ops):
                self.assertEqual(self.codes(ops), {"RULE_CRAFT_GRAPH"})

    def test_product_granting_craft_item_is_paid_capture(self):
        # 2026-11-11 素材パック削除後は外形商品に付与効果を付けて検査する
        ops = [{"op": "append", "file": "products", "path": "/products/id:lantern_skin_glow/effects",
                "value": {"type": "basic_material_hours", "hours": 4, "resources": ["wick"], "rate_reference": "standard_free_idle_at_purchase"}}]
        codes = self.codes(ops)
        self.assertIn("RULE_PAID_CAPTURE", codes)
        self.assertIn("RULE_PRODUCT_EFFECT", codes)  # 外形商品に付与効果は不可（既存規則も同時に出る）

    def test_capture_supply_effect_forbidden(self):
        ops = [{"op": "append", "file": "products", "path": "/products/id:lantern_skin_glow/effects", "value": {"type": "capture_supply", "amount": 1}}]
        self.assertEqual(self.codes(ops), {"RULE_FORBIDDEN_PRODUCT"})

    def test_sink_repeat_cases(self):
        no_basic = [{"op": "set", "file": "sinks", "path": f"/repeat_sinks/id:module_{f}/cost_curve", "value": "sink_altar_meadow"}
                    for f in ("meadow", "forest", "cave", "ridge")]
        self.assertEqual(self.codes(no_basic), {"RULE_SINK_REPEAT"})
        bad_params = [{"op": "set", "file": "curves", "path": "/sink_curves/id:sink_module_meadow/cap_level", "value": 5}]
        self.assertEqual(self.codes(bad_params), {"RULE_SINK_REPEAT", "STALE_TABLES"})

    def test_sink_effect_on_repeat(self):
        ops = [{"op": "set", "file": "sinks", "path": "/repeat_sinks/id:altar_ridge/effects", "value": [{"type": "title"}]}]
        self.assertEqual(self.codes(ops), {"RULE_SINK_EFFECT"})

    def test_trade_reserved_on_item(self):
        ops = [{"op": "set", "file": "sinks", "path": "/items/id:outfit_ridge/trade_class", "value": "cosmetic_swap"}]
        self.assertEqual(self.codes(ops), {"RULE_TRADE_RESERVED"})


if __name__ == "__main__":
    unittest.main()
