--!strict
-- TravelSpec: HUD の移動ボタン（Travel(dest) RF）の判定と実行（遭遇中の拒否・キャラクターが無いときの拒否・採集の終了・行き先）と
--   Remoting 経由の入口（列挙の検証・レート・mutates）
-- 配置: ServerStorage.Tests.TravelSpec（Rojo: game/tests/TravelSpec.luau）
-- 依存: deps.TravelService・deps.Net・deps.Activity・deps.GatherService・deps.GatherCalc・deps.Ledger・deps.SaveSchema・deps.Config・
--   deps.Formulas・deps.CaptureLogic・deps.econ・deps.gd・deps.TestKit・deps.Remoting・deps.RateLimiter・deps.PushThrottle・deps.Validate
--   （キャラクター・移動・行き先は偽物を渡す。Roblox API の PivotTo・CFrame は Studio で確認）
-- 期待値の出典: 2026-11-24 ユーザー決定（Travel(dest) 新設、dest ∈ {"meadow","home"}、座標はサーバーが決める、
--   遭遇（捕獲）中なら BUSY、移動すると進行中の直接採集を止める、ほかの制限は付けない）、メイン指示（キャラクター・HumanoidRootPart が
--   無ければ失敗コードだけ返して保存データに触れない、Remoting の入口規則、レート 1/s）、GatherService の契約（stop = その時点まで積算して閉じる）

local T = 1762819200 -- 秒（60 の倍数）

return {
	name = "Travel",
	run = function(t: any, deps: any)
		local Net = deps.Net
		local EC = Net.ErrorCode
		local copy = deps.TestKit.deepCopy

		local function newSave(): any
			return deps.SaveSchema.newSave({
				gd = deps.gd,
				startSpirits = deps.Config.START_SPIRITS,
				milli = deps.Formulas.MILLI,
				vigorTick = deps.CaptureLogic.VIGOR_TICK,
			}, T)
		end

		local function newGather(act: any): any
			return deps.GatherService.new({
				GatherCalc = deps.GatherCalc,
				econ = deps.econ,
				ledger = deps.Ledger.new(deps.gd),
				activity = act,
				radius = deps.Config.GATHER_RADIUS,
				maxGapSeconds = deps.Config.GATHER_MAX_CREDIT_SECONDS,
			})
		end

		-- opts: capture・gather・activity（任意）、chars（player → キャラクター。無ければ nil）
		local function setup(opts: any?): any
			local o = opts or {}
			local env: any = { pivots = {}, resolved = {} }
			env.player = { UserId = 1 }
			env.chars = o.chars or { [env.player] = { name = "char1" } }
			env.svc = deps.TravelService.new({
				Net = Net,
				resolve = function(userId: number, dest: string): any
					table.insert(env.resolved, dest)
					if dest == Net.TravelDest.Home then
						return { kind = "home", userId = userId }
					elseif dest == Net.TravelDest.Meadow then
						return { kind = "meadow" }
					end
					return nil
				end,
				findCharacter = function(player: any): any
					return env.chars[player]
				end,
				pivot = function(character: any, target: any)
					table.insert(env.pivots, { character = character, target = target })
				end,
				capture = o.capture,
				gather = o.gather,
				activity = o.activity,
			})
			return env
		end

		local function ctxOf(env: any, save: any, now: number): any
			return { userId = 1, player = env.player, save = save, now = now }
		end

		t:test("home·meadow: 서버가 정한 목적지로 이동, 저장 데이터 불변(채집 세션 없음)", function()
			local e = setup()
			local save = newSave()
			local before = copy(save)
			t:eq(e.svc:travel(ctxOf(e, save, T + 5), "home"), { ok = true, data = { dest = "home", gatherStopped = false } })
			t:eq(e.pivots[1], { character = { name = "char1" }, target = { kind = "home", userId = 1 } })
			t:eq(e.svc:travel(ctxOf(e, save, T + 6), "meadow"), { ok = true, data = { dest = "meadow", gatherStopped = false } })
			t:eq(e.pivots[2].target, { kind = "meadow" })
			t:eq(save, before)
		end)

		t:test("조우(포획) 중이면 BUSY: 이동·채집 정지·목적지 계산 없음(CaptureService pending 또는 Activity encounter)", function()
			-- CaptureService の遭遇中（getPending）
			local pending = { [1] = { startSec = T } }
			local fakeCapture = {
				getPending = function(_self: any, userId: number): any
					return pending[userId]
				end,
			}
			local act = deps.Activity.new()
			local gather = newGather(act)
			local save = newSave()
			local e = setup({ capture = fakeCapture, gather = gather, activity = act })
			local before = copy(save)
			t:eq(e.svc:travel(ctxOf(e, save, T + 5), "home"), { ok = false, code = EC.BUSY })
			t:eq(#e.pivots, 0)
			t:eq(#e.resolved, 0)
			t:eq(save, before)
			-- 遭遇が終われば通る
			pending[1] = nil
			t:eq(e.svc:travel(ctxOf(e, save, T + 6), "home").ok, true)
			-- Activity だけが遭遇中（CaptureService 無し）でも BUSY
			local act2 = deps.Activity.new()
			act2:set(1, "encounter")
			local e2 = setup({ activity = act2 })
			t:eq(e2.svc:travel(ctxOf(e2, save, T + 7), "meadow"), { ok = false, code = EC.BUSY })
			t:eq(#e2.pivots, 0)
			-- 採集中は遭遇ではない（BUSY にしない）
			act2:set(1, "gather")
			t:eq(e2.svc:travel(ctxOf(e2, save, T + 8), "meadow").ok, true)
		end)

		t:test("캐릭터·HumanoidRootPart 없음: NOT_READY, 채집 세션·저장 데이터 그대로", function()
			local act = deps.Activity.new()
			local gather = newGather(act)
			local save = newSave()
			t:eq(gather:start(1, save, "meadow_dew", 0, T).ok, true)
			local e = setup({ gather = gather, activity = act, chars = {} })
			local before = copy(save)
			t:eq(e.svc:travel(ctxOf(e, save, T + 2), "home"), { ok = false, code = EC.NOT_READY })
			t:eq(#e.pivots, 0)
			t:eq(save, before)
			t:ok(gather:session(1) ~= nil, "채집 세션 유지")
			t:eq(act:get(1), "gather")
		end)

		t:test("이동하면 진행 중인 직접 채집을 멈춤: GatherService.stop 과 같은 적립·세션 종료", function()
			-- A: Travel で止める / B: 同じ時刻に GatherService.stop を直接呼ぶ。保存データ（財布・carry）が同じになること
			local actA, actB = deps.Activity.new(), deps.Activity.new()
			local gA, gB = newGather(actA), newGather(actB)
			local saveA, saveB = newSave(), newSave()
			t:eq(gA:start(1, saveA, "meadow_dew", 0, T).ok, true)
			t:eq(gB:start(1, saveB, "meadow_dew", 0, T).ok, true)
			local e = setup({ gather = gA, activity = actA })
			local dewBefore = saveA.wallet.dew or 0
			local res = e.svc:travel(ctxOf(e, saveA, T + 3), "meadow")
			t:eq(res, { ok = true, data = { dest = "meadow", gatherStopped = true } })
			gB:stop(1, saveB, T + 3)
			t:eq(saveA, saveB)
			t:ok((saveA.wallet.dew or 0) > dewBefore, "멈추기 전까지 적립")
			t:eq(gA:session(1), nil)
			t:eq(actA:get(1), nil)
			t:eq(#e.pivots, 1)
			-- 2 回目はセッションが無いので何も変えない
			local after = copy(saveA)
			t:eq(e.svc:travel(ctxOf(e, saveA, T + 10), "home").data.gatherStopped, false)
			t:eq(saveA, after)
		end)

		t:test("목록 밖 목적지는 BAD_ARG(검증 뒤 방어), 목적지 계산 실패는 오류(INTERNAL 경로)", function()
			local e = setup()
			local save = newSave()
			for _, bad in { "Meadow", "plaza", "", 1 :: any } do
				t:eq(e.svc:travel(ctxOf(e, save, T), bad), { ok = false, code = EC.BAD_ARG }, tostring(bad))
			end
			t:eq(e.svc:travel(ctxOf(e, save, T), nil), { ok = false, code = EC.BAD_ARG }, "nil")
			t:eq(#e.pivots, 0)
			local e2 = deps.TravelService.new({
				Net = Net,
				resolve = function(_u: number, _d: string): any
					return nil
				end,
				findCharacter = function(_p: any): any
					return {}
				end,
				pivot = function(_c: any, _t: any) end,
			})
			t:throws(function()
				e2:travel(ctxOf(e, save, T), "home")
			end, "home")
		end)

		t:test("Remoting 경유: 열거 검증(BAD_ARG)·레이트 1/s·성공 시 StateChanged 표시·불러오기 전 NOT_READY", function()
			local clock = 0
			local saves: { [number]: any } = { [1] = newSave() }
			local remotes: { [string]: any } = {}
			for name, kind in Net.RemoteKinds do
				remotes[name] = if kind == "RF"
					then {}
					else { OnServerEvent = { Connect = function(_s: any, _f: any) end }, FireClient = function() end }
			end
			local throttle = deps.PushThrottle.new(deps.Config.PUSH_MIN_INTERVAL_SECONDS)
			local r = deps.Remoting.new({
				Net = Net,
				remotes = remotes,
				limiter = deps.RateLimiter.new(deps.Config.REMOTE_RATES, function()
					return clock
				end),
				throttle = throttle,
				schemas = deps.Validate.schemas(deps.gd, deps.Config, Net),
				Validate = deps.Validate,
				getSave = function(userId: number)
					return saves[userId]
				end,
				now = function()
					return T
				end,
				log = function(_m: string) end,
			})
			local e = setup()
			local p2 = { UserId = 2 }
			e.chars[p2] = { name = "char2" }
			r:bind("Travel", function(ctx: any, dest: any)
				return e.svc:travel(ctx, dest)
			end, { mutates = true })
			r:start()
			local function invoke(player: any, ...: any): any
				return remotes.Travel.OnServerInvoke(player, ...)
			end
			t:eq(invoke(e.player, "Meadow"), { ok = false, code = EC.BAD_ARG })
			t:eq(#e.pivots, 0)
			clock = 10
			t:eq(invoke(e.player, "meadow"), { ok = true, data = { dest = "meadow", gatherStopped = false } })
			t:eq(throttle:isDirty(1), true, "성공 → StateChanged 표시")
			t:eq(invoke(e.player, "home"), { ok = false, code = EC.RATE_LIMITED }, "같은 초 두 번째")
			t:eq(#e.pivots, 1)
			clock = 11
			t:eq(invoke(e.player, "home").ok, true)
			-- 読み込み前（保存データ無し）
			t:eq(invoke(p2, "home"), { ok = false, code = EC.NOT_READY })
			t:eq(#e.pivots, 2)
		end)
	end,
}
