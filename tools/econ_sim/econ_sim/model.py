"""検証済みデータへの参照用インデックス（validate・static・2 段階の sim が共用）."""
from __future__ import annotations

from dataclasses import dataclass
from fractions import Fraction
from typing import Any, Iterator

from . import formulas
from .data_load import GameData
from .tables import Tables


@dataclass(frozen=True)
class Requirement:
    """コスト 1 件（G3 の狩り分換算・有料経路検査で使う）."""

    source_kind: str  # field_unlock / facility_level / facility_slot / hub_rank / offline_cap / capture / cost_table / sink
    source_id: str
    detail: str
    path: str
    resource: str
    amount: int

    @property
    def requirement_id(self) -> str:
        return f"{self.source_kind}:{self.source_id}:{self.detail}"


def by_id(items: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    return {item["id"]: item for item in items}


class Model:
    def __init__(self, gd: GameData):
        d = gd.docs
        self.gd = gd
        self.resources = by_id(d["resources"]["resources"])
        self.resource_order = [r["id"] for r in d["resources"]["resources"]]
        self.basic_ids = [r["id"] for r in d["resources"]["resources"] if r["kind"] == "basic"]
        self.apt_bps = {a["id"]: a["bps"] for a in d["rules"]["aptitude_bps"]}
        self.constants = d["rules"]["constants"]
        self.night = d["rules"]["night"]
        self.spirits = by_id(d["spirits"]["spirits"])
        self.spirit_order = [s["id"] for s in d["spirits"]["spirits"]]
        self.cost_curves = by_id(d["curves"]["cost_curves"])
        self.bonus_curves = by_id(d["curves"]["bonus_curves"])
        self.facilities = by_id(d["facilities"]["facilities"])
        self.facility_order = [f["id"] for f in d["facilities"]["facilities"]]
        self.tools = by_id(d["tools"]["tools"])
        self.fields = by_id(d["fields"]["fields"])
        self.field_order = [f["id"] for f in sorted(d["fields"]["fields"], key=lambda f: (f["order"], f["id"]))]
        self.nodes = {n["id"]: (f["id"], n) for f in d["fields"]["fields"] for n in f["gather_nodes"]}
        self.hub = d["hub"]
        self.quests = by_id(d["daily_quests"]["quests"])
        self.products = by_id(d["products"]["products"])
        self.releases = by_id(d["releases"]["releases"])
        # 研究ツリー（research.json、任意ファイル。無ければ研究なし）
        rdoc = d.get("research")
        self.research: dict[str, Any] | None = rdoc
        self.research_nodes = by_id(rdoc["nodes"]) if rdoc else {}
        self.research_order = [n["id"] for n in rdoc["nodes"]] if rdoc else []
        self.research_resource = next((r for r in self.resource_order if self.resources[r]["kind"] == "research"), None)
        # 捕獲規則（2026-11-10 段階 2 から必須、シミュの捕獲状態機械が使う）・制作・消費先（任意ファイル）
        self.capture_rules: dict[str, Any] | None = d.get("capture")
        self.sink_tables_doc: dict[str, Any] | None = d.get("sink_tables")
        cdoc = d.get("crafting")
        self.recipes = by_id(cdoc["recipes"]) if cdoc else {}
        self.recipe_order = [r["id"] for r in cdoc["recipes"]] if cdoc else []
        self.sinks: dict[str, Any] | None = d.get("sinks")
        self.sink_curves = by_id(d["curves"].get("sink_curves", []))
        self._tables: Tables | None = None

    @property
    def tables(self) -> Tables:
        if self._tables is None:
            self._tables = Tables(self.gd.docs["upgrade_tables"])
        return self._tables

    def field_rank(self, field_id: str) -> int:
        return self.field_order.index(field_id)

    def hunt_resource_ids(self) -> list[str]:
        return [rid for rid in self.resource_order if self.resources[rid]["kind"] == "hunt"]

    def facility_for_resource(self, resource_id: str) -> dict[str, Any] | None:
        for fid in self.facility_order:
            if self.facilities[fid]["produces"] == resource_id:
                return self.facilities[fid]
        return None

    def level_cap_at_field(self, entity: dict[str, Any], field_id: str) -> int:
        """そのフィールドまで解禁済みのときの最大レベル（未定義なら 0 = 不可）."""
        rank = self.field_rank(field_id)
        best = 0
        for cap in entity["level_cap_by_field"]:
            if cap["field_id"] in self.fields and self.field_rank(cap["field_id"]) <= rank:
                best = max(best, cap["max_level"])
        return min(best, entity["max_level"])

    def first_field_allowing(self, entity: dict[str, Any], level: int) -> str:
        for field_id in self.field_order:
            if self.level_cap_at_field(entity, field_id) >= level:
                return field_id
        return ""

    def recipes_for(self, resource_id: str) -> list[dict[str, Any]]:
        """その資源を産出するレシピ（データ順）."""
        return [self.recipes[r] for r in self.recipe_order if self.recipes[r]["output"]["resource"] == resource_id]

    def expand_costs(self, costs: list[dict[str, Any]]) -> list[dict[str, Any]]:
        """atomic 品目（stack=atomic）を唯一のレシピで再帰的に素材へ展開したコスト（同じ資源は合算、初出順）.

        stock 品目（例: 芯）・未知の資源・レシピが 1 個でない atomic・循環は展開せずそのまま残す（検証器が別途 ERROR にする）。
        atomic レシピの産出量は 1（RULE_CRAFT_GRAPH）だが、念のため必要数を産出量で切り上げる。
        """
        out: dict[str, int] = {}

        def add(res: str, amount: int, path: frozenset[str]) -> None:
            r = self.resources.get(res)
            if r is not None and r.get("stack") == "atomic" and res not in path:
                recs = self.recipes_for(res)
                if len(recs) == 1:
                    rec = recs[0]
                    per = rec["output"]["amount"]
                    times = -(-amount // per) if per > 0 else 0
                    if times > 0:
                        for x in rec["inputs"]:
                            add(x["resource"], x["amount"] * times, path | {res})
                        return
            out[res] = out.get(res, 0) + amount

        for c in costs:
            add(c["resource"], c["amount"], frozenset())
        return [{"resource": r, "amount": a} for r, a in out.items()]

    def iter_requirements(self, include_tables: bool = True, include_sinks: bool = False) -> Iterator[Requirement]:
        """データ中の全コストを出典付きで列挙する.

        フィールド解禁は atomic 品目（道標）を展開した素材コストで出す（I6、段階 1 時点では解禁コストに atomic 品目はなく恒等）。
        include_sinks=True なら消費先の有限品目（展開済み）を source_kind="sink" で加える（G3 approved の対象外、INFO 用）。
        """
        for fid in self.field_order:
            f = self.fields[fid]
            for i, c in enumerate(self.expand_costs(f["unlock"]["costs"])):
                yield Requirement("field_unlock", fid, "unlock", f"fields/{fid}/unlock/costs/{i}", c["resource"], c["amount"])
        if self.capture_rules is not None:  # 捕獲の試行コスト（全フィールド共通、段階 2 で fields[].capture.costs から移した）
            for i, c in enumerate(self.capture_rules["attempt_cost"]):
                yield Requirement("capture", "all_fields", "attempt", f"capture/attempt_cost/{i}", c["resource"], c["amount"])
        for fac_id in self.facility_order:
            fac = self.facilities[fac_id]
            for gate in fac["hunt_gates"]:
                for i, c in enumerate(gate["costs"]):
                    yield Requirement("facility_level", fac_id, f"to_lv{gate['to_level']}",
                                      f"facilities/{fac_id}/hunt_gates/to_lv{gate['to_level']}/{i}", c["resource"], c["amount"])
            for slot in fac["slots"]["unlock"]:
                for i, c in enumerate(slot["costs"]):
                    yield Requirement("facility_slot", fac_id, f"slot{slot['slot']}",
                                      f"facilities/{fac_id}/slots/unlock/slot{slot['slot']}/{i}", c["resource"], c["amount"])
        for rank in self.hub["ranks"]:
            for i, c in enumerate(rank["costs"]):
                yield Requirement("hub_rank", f"rank{rank['rank']}", "upgrade", f"hub/ranks/{rank['rank']}/{i}", c["resource"], c["amount"])
        for up in self.hub["offline_cap"]["upgrades"]:
            for i, c in enumerate(up["costs"]):
                yield Requirement("offline_cap", f"{up['hours']}h", "upgrade", f"hub/offline_cap/{up['hours']}h/{i}", c["resource"], c["amount"])
        if include_tables:
            for tid, levels in self.tables.cost.items():
                for lv in sorted(levels):
                    for c in levels[lv]:
                        yield Requirement("cost_table", tid, f"lv{lv}", f"upgrade_tables/{tid}/lv{lv}", c["resource"], c["amount"])
        if include_sinks and self.sinks:
            for it in self.sinks["items"]:
                for i, c in enumerate(self.expand_costs(it["costs"])):
                    yield Requirement("sink", it["id"], it["category"], f"sinks/items/{it['id']}/{i}", c["resource"], c["amount"])

    def product_granted_resources(self) -> dict[str, list[str]]:
        """商品が付与しうる資源 → 商品 ID 一覧."""
        granted: dict[str, list[str]] = {}
        for pid, p in self.products.items():
            for eff in p["effects"]:
                rids: list[str] = list(eff.get("resources", []))
                for m in eff.get("missions", []):
                    rids.extend(r["resource"] for r in m["rewards"])
                for rid in rids:
                    granted.setdefault(rid, [])
                    if pid not in granted[rid]:
                        granted[rid].append(pid)
        return granted

    def research_effect_bps(self, node_ids: Iterator[str] | list[str] | set[str], effect_type: str) -> dict[str, int]:
        """完了ノード集合の効果合計（基本資源別 bps）。effect.resources が無ければ基本資源 3 種すべてに掛かる.

        基本資源以外の resources 指定は無視する（検証器が RULE_RESEARCH_EFFECT で報告し、合計で KeyError にしない）。
        """
        out = {r: 0 for r in self.basic_ids}
        for nid in node_ids:
            for eff in self.research_nodes[nid]["effects"]:
                if eff["type"] != effect_type:
                    continue
                for r in eff.get("resources", self.basic_ids):
                    if r in out:
                        out[r] += eff.get("value_bps", 0)
        return out

    def trait_value(self, spirit_id: str, trait_type: str) -> int:
        return sum(t["value_bps"] for t in self.spirits[spirit_id]["traits"] if t["type"] == trait_type)


def sim_unsupported(model: Model) -> list[tuple[str, str]]:
    """スキーマ上は許すがシミュが扱えないデータ（(パス, 理由)）。run は開始時に中断し、validate は WARN を出す."""
    out: list[tuple[str, str]] = []
    for fid in model.field_order:
        for e in model.fields[fid]["capture"]["table"]:
            if e["availability"] == "event" and e["weight"] > 0:
                out.append((f"fields/{fid}/capture/table/{e['spirit_id']}", "availability=event(기간 한정)은 시뮬 미구현"))
    if model.capture_rules is not None and len(model.capture_rules["attempt_cost"]) != 1:
        out.append(("capture/attempt_cost", "시도 비용이 자원 1종이 아님(시뮬은 심지 1종만 지원)"))
    for sid in model.spirit_order:
        s = model.spirits[sid]
        if s["placement_cost"] != 1:
            out.append((f"spirits/{sid}/placement_cost", "placement_cost≠1(배치 비용 포인트)은 시뮬 미구현"))
    return out


def field_encounter_expectation(m: "Model", field_id: str, rule: dict[str, Any], night: bool = False) -> tuple[Fraction, Fraction]:
    """フィールドの遭遇 1 回あたり (期待試行数, 期待秒)（有理数。静的見込み: 攻撃者 = 対象と同等級 Lv1・活力満タン、★1 は弱体化なし）."""
    table = [e for e in m.fields[field_id]["capture"]["table"]
             if e["weight"] > 0 and (e["availability"] == "always" or (night and e["availability"] == "night_only"))]
    total = sum(e["weight"] for e in table)
    if total <= 0:
        return Fraction(0), Fraction(0)
    t = rule["time"]
    ea = secs = Fraction(0)
    for e in table:
        g = m.spirits[e["spirit_id"]]["grade"]
        a = formulas.encounter_expectation(g, rule)[1]
        w = formulas.weaken_seconds(g, 1, g, rule["vigor"]["max"], rule) if formulas.weaken_needed(g, rule) else 0
        ea += Fraction(e["weight"], total) * a
        secs += Fraction(e["weight"], total) * (t["encounter_base_seconds"] + max(w, 0) + t["attempt_seconds"] * a)
    return ea, secs
