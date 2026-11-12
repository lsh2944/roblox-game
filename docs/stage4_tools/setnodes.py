# fields.json の採集ノード量・解禁コストを id 指定で書き換える（書式は保つ）。データ再調整の作業用
import json, re, sys, pathlib
p = pathlib.Path(__file__).resolve().parents[2] / 'data' / 'fields.json'
s = p.read_text(encoding='utf-8')
args = json.loads(sys.argv[1])
for node, rate in args.get('nodes', {}).items():
    pat = re.compile(r'(\{"id": "' + node + r'", "resource": "\w+", "base_per_hour": )(\d+)')
    s, n = pat.subn(lambda m: m.group(1) + str(rate), s)
    assert n == 1, node
for fid, costs in args.get('unlock', {}).items():
    pat = re.compile(r'("id": "' + fid + r'".*?"unlock": \{"requires_fields": \[[^\]]*\], "costs": )(\[.*?\])(\})', re.S)
    s, n = pat.subn(lambda m: m.group(1) + json.dumps(costs, ensure_ascii=False) + m.group(3), s)
    assert n == 1, fid
json.loads(s)
p.write_text(s, encoding='utf-8')
print('ok')
