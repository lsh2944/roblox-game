# 解禁直前の状態観測（balanced、replicate 0..N-1）。結果は static_reference の *_entry 定義に使う
import json, statistics, sys
from econ_sim.data_load import load_data
from econ_sim.model import Model
from econ_sim.economy import Economy
from econ_sim.sim_config import load_personas
from econ_sim.sim import Simulator
from econ_sim import jsonio
from econ_sim.paths import DEFAULT_DATA_DIR, DEFAULT_CONFIG_DIR
gd = load_data(DEFAULT_DATA_DIR); m = Model(gd); econ = Economy(m)
cfg, _ = load_personas(DEFAULT_CONFIG_DIR / 'personas.json', m)
ref = jsonio.load_strict(DEFAULT_CONFIG_DIR / 'static_reference.json')
obs = {}
orig = Simulator.unlock_field
def patched(self, fid):
    st = self.state
    snap = {"day": self.t // 1440 + 1, "tool": st.tool_level, "fac": dict(st.fac_level),
            "staff": {self.m.facilities[f]["produces"]: [(st.roster[u].species, st.roster[u].level) for u in us] for f, us in st.assignment.items()}}
    comp = {}
    for node in self.m.fields[fid]["gather_nodes"]:
        if node.get("requires_node_trait"):
            continue
        party = self.policy.gather_party(node, node["resource"])
        comp[node["resource"]] = [(st.roster[u].species, st.roster[u].level) for u in party]
    snap["companions"] = comp
    before = set(st.fac_level)
    result = orig(self, fid)
    # 解禁で新しく開いた施設は、開いた直後の配置（空き施設補充後）を記録する
    for f in set(st.fac_level) - before:
        snap["staff"][self.m.facilities[f]["produces"]] = [(st.roster[u].species, st.roster[u].level) for u in st.assignment[f]]
        snap["fac"][f] = st.fac_level[f]
    obs.setdefault(fid, []).append(snap)
    return result
Simulator.unlock_field = patched
p = next(x for x in cfg['personas'] if x['id'] == 'balanced')
for rep in range(int(sys.argv[1])):
    Simulator(econ, cfg, p, rep, 25, ref).run()
out = {}
for fid, snaps in obs.items():
    lv = statistics.median([sum(s["fac"].values()) for s in snaps])
    pick = min(snaps, key=lambda s: (abs(sum(s["fac"].values()) - lv), s["day"]))  # 施設 Lv 合計が中央値に最も近い実行
    out[fid] = {"n": len(snaps), "day_median": statistics.median([s["day"] for s in snaps]),
                "tool_median": statistics.median([s["tool"] for s in snaps]), "picked": pick}
print(json.dumps(out, ensure_ascii=False))
