--!strict
-- GatherLoopSpec: 直接採集の結線（S6）。サーバーが測る距離（水平・キャラクター無し = 無限大）、GatherStart の受け付け、
--   連打・ノードの付け替えで産出が時間分だけ、範囲外の区間は認定しない、1 秒ループの通知、保存前の精算順、退出・終了の後始末順
-- 配置: ServerStorage.Tests.GatherLoopSpec（Rojo: game/tests/GatherLoopSpec.luau）
-- 依存: deps.GatherLoop・GatherService・GatherCalc・Activity・Ledger・SessionCleanup・SaveSchema・Config・Formulas・CaptureLogic・
--   Net・econ・gd
-- 期待値の出典: 計画書 4.3「채집 세션」（1 秒ごとの再確認、範囲外・遭遇で自動終了、産出はサーバー時間に縛る）、
--   2026-11-24 S6 承認範囲（キャラクター無し・死亡 = 距離無限大で開始拒否・範囲外、退出は releaseAsync の前に SessionCleanup、
--   保存前は採集精算 → 放置精算）。採集率は GatherSpec と同じ（meadow_dew 同行なし 160800 milli/時）。
--   秒の積算の期待値は「経過秒 × 率 // 3600」を手で数える（連打しても経過秒は増えない）

local T = 1762819200 -- 秒（60 の倍数）

return {
	name = "GatherLoop",
	run = function(t: any, deps: any)
		local GL = deps.GatherLoop
		local GC = deps.GatherCalc
		local E = deps.Net.ErrorCode
		local R = deps.Config.GATHER_RADIUS
		local NODES = deps.Config.WORLD.nodes
		local DEW = NODES.meadow_dew
		local BLOOM = NODES.meadow_bloom

		local function newWorld(): (any, any, any)
			local save = deps.SaveSchema.newSave({
				gd = deps.gd,
				startSpirits = deps.Config.START_SPIRITS,
				milli = deps.Formulas.MILLI,
				vigorTick = deps.CaptureLogic.VIGOR_TICK,
			}, T)
			local act = deps.Activity.new()
			local svc = deps.GatherService.new({
				GatherCalc = GC,
				econ = deps.econ,
				ledger = deps.Ledger.new(deps.gd),
				activity = act,
				radius = R,
				maxGapSeconds = deps.Config.GATHER_MAX_CREDIT_SECONDS,
			})
			return save, svc, act
		end

		-- 位置（Vector3 互換）。ノードから水平に dx・dz ずらし、Y は腰の高さ
		local function near(n: any, dx: number, dz: number): any
			return { X = n.x + dx, Y = 3.5, Z = n.z + dz }
		end

		local function startDeps(svc: any, pos: { [number]: any }): any
			return {
				gather = svc,
				nodes = NODES,
				rootPosition = function(userId: number)
					return pos[userId]
				end,
			}
		end

		t:test("거리: 수평(XZ) 거리, 높이는 무시, 위치 없음·모르는 노드는 무한대", function()
			t:eq(GL.distance(NODES, "meadow_dew", { X = DEW.x + 3, Y = 100, Z = DEW.z + 4 }), 5)
			t:eq(GL.distance(NODES, "meadow_dew", nil), math.huge, "캐릭터 없음")
			t:eq(GL.distance(NODES, "no_node", near(DEW, 0, 0)), math.huge)
			t:eq(GL.distance(NODES, 7, near(DEW, 0, 0)), math.huge)
			t:eq(GL.distance(NODES, "meadow_dew", { X = 0 / 0, Y = 0, Z = 0 }), math.huge, "NaN 위치")
		end)

		t:test("GatherStart: 범위 안(경계 포함)은 시작, 밖은 TOO_FAR, 캐릭터 없음·사망은 거부", function()
			local save, svc, act = newWorld()
			local pos: { [number]: any } = { [1] = near(DEW, R, 0) }
			local d = startDeps(svc, pos)
			local r = GL.start(d, 1, save, "meadow_dew", T)
			t:eq(r.ok, true, "수평 거리 = R(허리 높이 3.5와 무관)")
			t:eq(svc:session(1).nodeId, "meadow_dew")
			svc:stop(1, save, T)

			pos[1] = near(DEW, 0, R + 0.5)
			r = GL.start(d, 1, save, "meadow_dew", T)
			t:eq({ r.ok, r.code }, { false, E.TOO_FAR })
			t:eq(svc:session(1), nil)

			pos[1] = nil -- キャラクター無し・死亡（Main の rootPosition が nil）
			r = GL.start(d, 1, save, "meadow_dew", T)
			t:eq(r.ok, false, "캐릭터 없음 = 거리 무한대로 거부")
			t:eq(r.code, E.BAD_ARG, "GatherCalc.checkStart 는 무한대 거리를 BAD_ARG 로 거부")
			t:eq(svc:session(1), nil)
			t:eq(act:get(1), nil)

			-- 別のノードの近くにいても、要求したノードからの距離で判定する
			pos[1] = near(BLOOM, 0, 0)
			t:eq(GL.start(d, 1, save, "meadow_dew", T).code, E.TOO_FAR)
		end)

		t:test("연타: 같은 노드 GatherStart 를 매초 여러 번 보내도 산출은 경과 시간만큼", function()
			local save, svc = newWorld()
			local pos = { [1] = near(DEW, 1, 1) }
			local d = startDeps(svc, pos)
			local tick = {
				gather = svc,
				nodes = NODES,
				radius = R,
				getSave = function()
					return save
				end,
				rootPosition = d.rootPosition,
				onEnded = function() end,
				onGained = function() end,
				log = function() end,
			}
			t:eq(GL.start(d, 1, save, "meadow_dew", T).ok, true)
			for s = 1, 60 do
				for _ = 1, 5 do
					GL.start(d, 1, save, "meadow_dew", T + s)
				end
				GL.tickAll(tick, T + s)
			end
			t:eq(save.wallet.dew, (160800 * 60) // 3600, "60초분 = 2680")
		end)

		t:test("연타: 다른 노드로 번갈아 바꿔도 각 자원은 그 노드에 있던 시간만큼", function()
			local save, svc = newWorld()
			local pos: { [number]: any } = { [1] = near(DEW, 0, 0) }
			local d = startDeps(svc, pos)
			local tick = {
				gather = svc,
				nodes = NODES,
				radius = R,
				getSave = function()
					return save
				end,
				rootPosition = d.rootPosition,
				onEnded = function() end,
				onGained = function() end,
				log = function() end,
			}
			local rateDew = GC.rate(deps.econ, save, deps.gd.nodes.meadow_dew.node)
			local rateBloom = GC.rate(deps.econ, save, deps.gd.nodes.meadow_bloom.node)
			t:ok(rateBloom > 0)
			-- 0〜10 秒 dew、10〜20 秒 bloom、20〜30 秒 dew。切り替えの秒に両方へ連打（同じ秒の GatherStart は増やさない）
			GL.start(d, 1, save, "meadow_dew", T)
			for s = 1, 30 do
				local onDew = s <= 10 or s > 20
				pos[1] = near(if onDew then DEW else BLOOM, 0, 0)
				if s == 11 or s == 21 then
					local id = if onDew then "meadow_dew" else "meadow_bloom"
					for _ = 1, 4 do
						-- 切り替え: 前のノードは s−1 まで tick 済み。新しいノードを s−1 から始め（4 回連打）、s−1 → s の 1 秒は新しいノード側
						GL.start(d, 1, save, id, T + s - 1)
					end
				end
				GL.tickAll(tick, T + s)
			end
			local dewG = GC.accrueSeconds(rateDew, 20, 0)
			local bloomG = GC.accrueSeconds(rateBloom, 10, 0)
			t:eq(save.wallet.dew, dewG, "dew 20초")
			t:eq(save.wallet.bloom, bloomG, "bloom 10초")
		end)

		t:test("1초 루프: 범위 밖으로 나간 구간은 인정하지 않고 종료·알림 1회, 캐릭터 없음도 범위 밖", function()
			local save, svc, act = newWorld()
			local pos: { [number]: any } = { [1] = near(DEW, 0, 0) }
			local ended, gained = {}, 0
			local tick = {
				gather = svc,
				nodes = NODES,
				radius = R,
				getSave = function()
					return save
				end,
				rootPosition = function(userId: number)
					return pos[userId]
				end,
				onEnded = function(userId: number, nodeId: string)
					table.insert(ended, { userId, nodeId })
				end,
				onGained = function()
					gained += 1
				end,
				log = function() end,
			}
			GL.start(startDeps(svc, pos), 1, save, "meadow_dew", T)
			for s = 1, 10 do
				t:eq(GL.tickAll(tick, T + s), 1)
			end
			t:eq(gained, 10, "매초 지갑 증가 → StateChanged 표시")
			local before = save.wallet.dew
			t:eq(before, (160800 * 10) // 3600)
			pos[1] = near(DEW, R + 1, 0)
			GL.tickAll(tick, T + 11)
			t:eq(save.wallet.dew, before, "범위 밖 구간(10→11초) 미인정")
			t:eq(ended, { { 1, "meadow_dew" } })
			t:eq(svc:session(1), nil)
			t:eq(act:get(1), nil)
			t:eq(GL.tickAll(tick, T + 12), 0, "세션이 없으면 확인하지 않음")
			t:eq(#ended, 1)

			-- キャラクター無し（死亡）も範囲外
			pos[1] = near(DEW, 0, 0)
			GL.start(startDeps(svc, pos), 1, save, "meadow_dew", T + 20)
			pos[1] = nil
			GL.tickAll(tick, T + 21)
			t:eq(svc:session(1), nil)
			t:eq(save.wallet.dew, before)
			t:eq(#ended, 2)
		end)

		t:test("1초 루프: 저장 데이터 없는 사람은 건너뛰고, 한 사람의 오류가 다른 사람을 막지 않음", function()
			local save1, svc = newWorld()
			local save2 = deps.SaveSchema.newSave({
				gd = deps.gd,
				startSpirits = deps.Config.START_SPIRITS,
				milli = deps.Formulas.MILLI,
				vigorTick = deps.CaptureLogic.VIGOR_TICK,
			}, T)
			local pos = { [1] = near(DEW, 0, 0), [2] = near(DEW, 0, 0), [3] = near(DEW, 0, 0) }
			local saves: { [number]: any } = { [1] = save1, [2] = save2, [3] = save2 }
			local d = startDeps(svc, pos)
			GL.start(d, 1, save1, "meadow_dew", T)
			GL.start(d, 2, save2, "meadow_dew", T)
			GL.start(d, 3, save2, "meadow_dew", T)
			svc:session(1).rate = -1 -- accrueSeconds が error になる壊れたセッション
			saves[3] = nil -- 錠外し中など
			local logs = {}
			local n = GL.tickAll({
				gather = svc,
				nodes = NODES,
				radius = R,
				getSave = function(userId: number)
					return saves[userId]
				end,
				rootPosition = d.rootPosition,
				onEnded = function() end,
				onGained = function() end,
				log = function(msg: string)
					table.insert(logs, msg)
				end,
			}, T + 1)
			t:eq(n, 2)
			t:eq(#logs, 1)
			t:eq(save2.wallet.dew, (160800 * 1) // 3600, "u_2 는 계속 적립")
			t:ok(svc:session(3) ~= nil, "저장 데이터 없는 u_3 은 건드리지 않음")
		end)

		t:test("저장 전: 채집 정산 → 방치 정산 순서, 채집 정산이 실패해도 방치 정산은 진행", function()
			local save, svc = newWorld()
			GL.start(startDeps(svc, { [1] = near(DEW, 0, 0) }), 1, save, "meadow_dew", T)
			local seen: { any } = {}
			local idle = {
				beforeSave = function(_self: any, s: any, now: number)
					table.insert(seen, { s.wallet.dew, now })
				end,
			}
			local logs = {}
			local function log(msg: string)
				table.insert(logs, msg)
			end
			GL.beforeSave(svc, idle, log, save, T + 2, 1)
			t:eq(seen, { { (160800 * 2) // 3600, T + 2 } }, "방치 정산이 불릴 때 이미 채집 2초가 지갑에 있음")
			t:eq(svc:session(1).lastSec, T + 2)
			GL.beforeSave(svc, idle, log, save, T + 2, 1)
			t:eq(save.wallet.dew, (160800 * 2) // 3600, "같은 시각에 두 번 저장해도 이중 적립 없음")
			local broken = {
				settle = function()
					error("boom")
				end,
			}
			GL.beforeSave(broken, idle, log, save, T + 3, 1)
			t:eq(#seen, 3, "채집 실패 뒤에도 방치 정산")
			t:eq(#logs, 1)
		end)

		t:test("퇴장: SessionCleanup(채집 정산·종료) 뒤에 releaseAsync, 종료: 전원 정리 뒤 closeAll", function()
			local save, svc, act = newWorld()
			GL.start(startDeps(svc, { [1] = near(DEW, 0, 0) }), 1, save, "meadow_dew", T)
			svc:tick(1, save, T + 1, true)
			local calls = {}
			local captureCalls, wildCalls = 0, 0
			local cleanup = {
				capture = {
					finish = function()
						captureCalls += 1
						return nil
					end,
				},
				gather = svc,
				wild = {
					clear = function()
						wildCalls += 1
					end,
				},
				activity = act,
			}
			local pd = {
				get = function(_self: any, userId: number)
					table.insert(calls, "get:" .. userId)
					return if userId == 1 then save else nil
				end,
				releaseAsync = function(_self: any, userId: number)
					-- 保存の時点で採集は閉じていて、退出の時刻までの産出が入っている
					table.insert(calls, { "release", userId, svc:session(userId) == nil, act:get(userId) == nil, save.wallet.dew })
					return true
				end,
				closeAll = function(_self: any)
					table.insert(calls, { "closeAll", svc:session(1) == nil, svc:session(2) == nil })
				end,
			}
			t:eq(deps.SessionCleanup.leave(cleanup, pd, 1, T + 3), true)
			t:eq(calls, { "get:1", { "release", 1, true, true, (160800 * 3) // 3600 } })
			t:eq({ captureCalls, wildCalls }, { 1, 1 })

			-- 終了: u_1 は採集中、u_2 は読み込み前（save なし）
			calls = {}
			GL.start(startDeps(svc, { [1] = near(DEW, 0, 0) }), 1, save, "meadow_dew", T + 10)
			act:set(2, "gather")
			deps.SessionCleanup.closeAll(cleanup, pd, { 1, 2 }, T + 12)
			t:eq(calls, { "get:1", "get:2", { "closeAll", true, true } })
			t:eq(act:get(2), nil, "save 없는 사람도 활동은 정리")
			t:eq(save.wallet.dew, (160800 * 3) // 3600 + (160800 * 2) // 3600)
		end)
	end,
}
