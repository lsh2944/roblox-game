--!strict
-- PlotSpec: 部地の割り当て（接続順・満員・再入室・返却後の再利用）とワールド座標表（Config.WORLD）の整合
-- 配置: ServerStorage.Tests.PlotSpec（Rojo: game/tests/PlotSpec.luau）
-- 依存: deps.PlotService・deps.MeadowBuilder（純粋関数 checkConfig・plotFrame だけ）・deps.Config・deps.gd・deps.TestKit
-- 期待値の出典: world_hud_design W1 決定（サーバー 8 人 = 部地 8 個）・W4（接続時は自分の部地）・1 節（部地 ≈64×64、
--   広場の周りに半円、ノード ID = fields.json gather_nodes[].id、判定半径 GATHER_RADIUS、野生の出現区域はフィールド中央）

return {
	name = "Plot",
	run = function(t: any, deps: any)
		local PS = deps.PlotService
		local MB = deps.MeadowBuilder
		local W = deps.Config.WORLD

		t:test("부지 8개, 접속 순서대로 1..8, 9번째는 nil", function()
			t:eq(#W.plots, 8)
			local ps = PS.new(#W.plots)
			for u = 1, 8 do
				t:eq(ps:assign(100 + u), u)
			end
			t:eq(ps:assign(200), nil, "가득 참")
			t:eq(ps:plotOf(200), nil)
			t:eq(ps:ownerOf(3), 103)
		end)

		t:test("같은 플레이어 재배정은 같은 번호(중복 점유 없음)", function()
			local ps = PS.new(8)
			t:eq(ps:assign(1), 1)
			t:eq(ps:assign(1), 1)
			t:eq(ps:assign(2), 2)
		end)

		t:test("반납한 번호는 다음 접속자가 재사용, 재입장은 빈 번호 중 가장 작은 것", function()
			local ps = PS.new(8)
			for u = 1, 8 do
				ps:assign(u)
			end
			t:eq(ps:release(3), 3)
			t:eq(ps:ownerOf(3), nil)
			t:eq(ps:release(3), nil, "두 번 반납")
			t:eq(ps:assign(9), 3)
			t:eq(ps:release(5), 5)
			t:eq(ps:release(2), 2)
			t:eq(ps:assign(5), 2, "재입장(이전 5번) → 가장 작은 빈 번호")
			t:eq(ps:assign(10), 5)
			t:eq(ps:assign(11), nil)
		end)

		t:test("노드 좌표 = data 의 meadow gather_nodes, 시설 id 확인, 어긋나면 오류", function()
			MB.checkConfig(W, deps.gd)
			local w1 = deps.TestKit.deepCopy(W)
			w1.nodes.meadow_bloom = nil
			t:throws(function()
				MB.checkConfig(w1, deps.gd)
			end, "meadow_bloom")
			local w2 = deps.TestKit.deepCopy(W)
			w2.nodes.forest_dew = { x = 0, z = 0, radius = 5 }
			t:throws(function()
				MB.checkConfig(w2, deps.gd)
			end, "forest_dew")
			local w3 = deps.TestKit.deepCopy(W)
			w3.plotLayout.pedestals.no_such = { x = 0, z = 0 }
			t:throws(function()
				MB.checkConfig(w3, deps.gd)
			end, "no_such")
		end)

		-- 2D の向き付き正方形（中心・前方向・半辺）の頂点
		local function corners(cx: number, cz: number, fx: number, fz: number, h: number): { { number } }
			local rx, rz = -fz, fx
			local out = {}
			for _, a in { 1, -1 } do
				for _, b in { 1, -1 } do
					table.insert(out, { cx + fx * h * a + rx * h * b, cz + fz * h * a + rz * h * b })
				end
			end
			return out
		end
		local function separated(pa: { { number } }, pb: { { number } }, axes: { { number } }): boolean
			for _, ax in axes do
				local amin, amax, bmin, bmax = math.huge, -math.huge, math.huge, -math.huge
				for _, p in pa do
					local d = p[1] * ax[1] + p[2] * ax[2]
					amin, amax = math.min(amin, d), math.max(amax, d)
				end
				for _, p in pb do
					local d = p[1] * ax[1] + p[2] * ax[2]
					bmin, bmax = math.min(bmin, d), math.max(bmax, d)
				end
				if amax <= bmin or bmax <= amin then
					return true
				end
			end
			return false
		end
		local h = W.plotSize / 2

		t:test("부지끼리·광장·필드와 겹치지 않음, 앞 방향은 광장", function()
			local quads = {}
			local frames = {}
			for i = 1, #W.plots do
				local x, z, fx, fz = MB.plotFrame(W, i)
				t:ok(math.abs(fx * fx + fz * fz - 1) < 1e-9, "단위 벡터")
				-- 前方向に進むと広場に近づく
				t:ok(math.abs((x + fx) - W.plaza.x) + math.abs((z + fz) - W.plaza.z) < math.abs(x - W.plaza.x) + math.abs(z - W.plaza.z), `부지 {i} 앞 방향`)
				quads[i] = corners(x, z, fx, fz, h)
				frames[i] = { fx, fz }
			end
			for i = 1, #quads do
				for j = i + 1, #quads do
					local axes = {
						frames[i],
						{ -frames[i][2], frames[i][1] },
						frames[j],
						{ -frames[j][2], frames[j][1] },
					}
					t:ok(separated(quads[i], quads[j], axes), `부지 {i}·{j} 겹침`)
				end
				-- 広場（円）: 部地のローカル座標で最近点までの距離 > 半径
				local x, z, fx, fz = MB.plotFrame(W, i)
				local dx, dz = W.plaza.x - x, W.plaza.z - z
				local u = dx * fx + dz * fz
				local v = dx * -fz + dz * fx
				local cu, cv = math.clamp(u, -h, h), math.clamp(v, -h, h)
				t:ok(math.sqrt((u - cu) ^ 2 + (v - cv) ^ 2) > W.plaza.radius, `부지 {i} 광장과 겹침`)
				-- フィールド（軸に沿った長方形）
				local f = W.field
				local fq = {
					{ f.x - f.sizeX / 2, f.z - f.sizeZ / 2 },
					{ f.x + f.sizeX / 2, f.z - f.sizeZ / 2 },
					{ f.x - f.sizeX / 2, f.z + f.sizeZ / 2 },
					{ f.x + f.sizeX / 2, f.z + f.sizeZ / 2 },
				}
				t:ok(separated(quads[i], fq, { { 1, 0 }, { 0, 1 }, frames[i], { -frames[i][2], frames[i][1] } }), `부지 {i} 필드와 겹침`)
			end
		end)

		local function inField(x: number, z: number, margin: number): boolean
			local f = W.field
			return math.abs(x - f.x) + margin <= f.sizeX / 2 and math.abs(z - f.z) + margin <= f.sizeZ / 2
		end

		t:test("노드·판정 반경·야생 구역·출현 지점은 필드 안, 노드 판정 반경은 야생 구역과 떨어짐", function()
			local R = deps.Config.GATHER_RADIUS
			local wz = W.wildZone
			t:ok(inField(wz.x, wz.z, wz.radius), "야생 구역")
			for id, n in W.nodes do
				t:ok(inField(n.x, n.z, R), `노드 {id} 판정 반경`)
				t:ok(n.radius < R, `노드 {id} 보이는 반경 < 판정 반경`)
				local d = math.sqrt((n.x - wz.x) ^ 2 + (n.z - wz.z) ^ 2)
				t:ok(d > R + wz.radius, `노드 {id} 와 야생 구역`)
			end
			t:ok(#W.wildPoints >= 1, "출현 지점")
			for i, p in W.wildPoints do
				t:ok(math.sqrt((p.x - wz.x) ^ 2 + (p.z - wz.z) ^ 2) <= wz.radius, `출현 지점 {i}`)
			end
			t:ok(W.gate.z < W.field.z - W.field.sizeZ / 2, "숲 관문은 필드 북쪽 너머")
		end)

		t:test("부지 안 배치: 스폰·받침대·예약·전시대·이름표가 부지 안", function()
			local L = W.plotLayout
			local function inside(p: any, margin: number)
				return math.abs(p.x) + margin <= h and math.abs(p.z) + margin <= h
			end
			t:ok(inside(L.spawn, 2), "스폰")
			t:ok(inside(L.house, 9), "집")
			t:ok(inside(L.reserved, 5), "예약")
			t:ok(inside(L.sign, 1), "이름표")
			for fid, p in L.pedestals do
				t:ok(inside(p, 5), fid)
			end
			t:eq(#L.showcase, 3)
			for i, p in L.showcase do
				t:ok(inside(p, 4), `전시대 {i}`)
			end
		end)
	end,
}
