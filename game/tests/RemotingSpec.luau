--!strict
-- RemotingSpec: C→S 要求の唯一の入口（レート → 検証 → 読み込み確認 → 処理）、RF 応答の形、例外の扱い、StateChanged のまとめ送信
-- 配置: ServerStorage.Tests.RemotingSpec（Rojo: game/tests/RemotingSpec.luau）
-- 依存: deps.Remoting・deps.RateLimiter・deps.PushThrottle・deps.Validate・deps.Net・deps.Config・deps.gd・deps.TestKit（偽の Remote を使う）
-- 期待値の出典: 計画書 4.3（RF は { ok, code?, data? }、InvokeClient 不使用、レート超過は捨てて記録・追放なし、検証の共通規則）、
--   world_hud_design W3・W5 決定（入口は既存 Remote 一つ）、S5 指示（未結線の S6〜S9 Remote は検証・レートの後に未実装コード、
--   処理の例外は pcall で失敗応答）、Remote 表「StateChanged 서버 스로틀 4/s」

return {
	name = "Remoting",
	run = function(t: any, deps: any)
		local Net = deps.Net
		local EC = Net.ErrorCode

		local function fakeRE(): any
			local re = { handlers = {}, fired = {} }
			re.OnServerEvent = {
				Connect = function(_self: any, fn: any)
					table.insert(re.handlers, fn)
				end,
			}
			function re.FireClient(self: any, player: any, data: any)
				table.insert(self.fired, { player = player, data = data })
			end
			return re
		end

		-- opts: rates（Config.REMOTE_RATES の代わり）、saves（userId → 保存データ）、build（buildSnapshot）
		local function setup(opts: any?): any
			local o = opts or {}
			local env: any = { clock = 0, logs = {}, saves = o.saves or { [1] = { tag = "save1" }, [2] = { tag = "save2" } } }
			env.remotes = {}
			for name, kind in Net.RemoteKinds do
				env.remotes[name] = if kind == "RF" then {} else fakeRE()
			end
			env.limiter = deps.RateLimiter.new(o.rates or deps.Config.REMOTE_RATES, function()
				return env.clock
			end)
			env.throttle = deps.PushThrottle.new(deps.Config.PUSH_MIN_INTERVAL_SECONDS)
			env.r = deps.Remoting.new({
				Net = Net,
				remotes = env.remotes,
				limiter = env.limiter,
				throttle = env.throttle,
				schemas = o.schemas or deps.Validate.schemas(deps.gd, deps.Config, Net),
				Validate = deps.Validate,
				getSave = function(userId: number)
					return env.saves[userId]
				end,
				now = function()
					return 5000
				end,
				buildSnapshot = o.build or function(userId: number, save: any, nowSec: number, seq: number, forResponse: boolean)
					return { userId = userId, tag = save.tag, now = nowSec, seq = seq, forResponse = forResponse }
				end,
				log = function(msg: string)
					table.insert(env.logs, msg)
				end,
			})
			env.p1 = { UserId = 1 }
			env.p2 = { UserId = 2 }
			function env.invoke(name: string, player: any, ...: any): any
				return env.remotes[name].OnServerInvoke(player, ...)
			end
			return env
		end

		t:test("start: C→S RF·RE 전부 결선, S→C RE 는 수신하지 않음", function()
			local e = setup()
			e.r:start()
			for name, dir in Net.Directions do
				local kind = Net.RemoteKinds[name]
				local rem = e.remotes[name]
				if dir == "C2S" and kind == "RF" then
					t:eq(type(rem.OnServerInvoke), "function", name)
				elseif dir == "C2S" then
					t:eq(#rem.handlers, 1, name)
				else
					t:eq(#rem.handlers, 0, name)
				end
			end
		end)

		t:test("GetSnapshot: { ok=true, data } 응답, seq 증가, 응답용 표시", function()
			local e = setup()
			e.r:bind("GetSnapshot", function(ctx: any)
				return { ok = true, data = e.r:snapshot(ctx.userId, ctx.save, ctx.now, true) }
			end)
			e.r:start()
			local res = e.invoke("GetSnapshot", e.p1)
			t:eq(res, { ok = true, data = { userId = 1, tag = "save1", now = 5000, seq = 1, forResponse = true } })
			e.clock = 1
			t:eq(e.invoke("GetSnapshot", e.p1).data.seq, 2)
		end)

		t:test("잘못된 인자(숫자 대신 문자열, NaN, 남는 인자)는 BAD_ARG, 처리 호출 없음", function()
			local e = setup()
			local calls = 0
			e.r:bind("Craft", function(_ctx: any)
				calls += 1
				return { ok = true }
			end)
			e.r:start()
			t:eq(e.invoke("Craft", e.p1, "wick_from_meadow", "5"), { ok = false, code = EC.BAD_ARG })
			e.clock = 10
			t:eq(e.invoke("Craft", e.p1, "wick_from_meadow", 0 / 0), { ok = false, code = EC.BAD_ARG })
			e.clock = 20
			t:eq(e.invoke("Craft", e.p1, 5, 1), { ok = false, code = EC.BAD_ARG })
			e.clock = 30
			t:eq(e.invoke("GetSnapshot", e.p1, "extra"), { ok = false, code = EC.BAD_ARG })
			t:eq(calls, 0)
			e.clock = 40
			t:eq(e.invoke("Craft", e.p1, "wick_from_meadow", 3), { ok = true })
			t:eq(calls, 1)
		end)

		t:test("순서: 레이트가 검증보다 먼저(잘못된 인자도 토큰 소비), 초과는 RATE_LIMITED", function()
			local e = setup()
			e.r:start()
			t:eq(e.invoke("CaptureEngage", e.p1, 1).code, EC.BAD_ARG)
			t:eq(e.invoke("CaptureEngage", e.p1, "w1").code, EC.RATE_LIMITED, "1/s 소진")
			t:eq(e.invoke("CaptureEngage", e.p2, "w1").code, EC.NOT_IMPLEMENTED, "다른 플레이어는 별개")
		end)

		t:test("레이트 초과 로그는 1·10·100회째만(로그 폭주 방지), 추방 없음", function()
			local e = setup()
			e.r:start()
			for _ = 1, 26 do
				e.invoke("ClaimDaily", e.p1)
			end
			local n = 0
			for _, m in e.logs do
				if string.find(m, "레이트 초과", 1, true) then
					n += 1
				end
			end
			t:eq(n, 2) -- 25 回捨てた: 1 回目と 10 回目
			t:eq(e.limiter:dropCount(1, "ClaimDaily"), 25)
		end)

		t:test("저장 데이터 불러오기 전은 NOT_READY, 처리 호출 없음", function()
			local e = setup({ saves = {} })
			local calls = 0
			e.r:bind("GetSnapshot", function(_ctx: any)
				calls += 1
				return { ok = true }
			end)
			e.r:start()
			t:eq(e.invoke("GetSnapshot", e.p1), { ok = false, code = EC.NOT_READY })
			t:eq(calls, 0)
		end)

		t:test("처리 미등록 C→S Remote: 검증 통과 시 NOT_IMPLEMENTED, 잘못된 인자는 BAD_ARG", function()
			local e = setup()
			e.r:start()
			t:eq(e.invoke("GatherStart", e.p1, "meadow_dew"), { ok = false, code = EC.NOT_IMPLEMENTED })
			t:eq(e.invoke("UpgradeFacility", e.p1, 0 / 0), { ok = false, code = EC.BAD_ARG })
			-- RE（GatherStop）: 応答は捨てられ、error にならない
			e.remotes.GatherStop.handlers[1](e.p1)
			e.remotes.GatherStop.handlers[1](e.p1, "extra")
		end)

		t:test("처리 중 예외는 INTERNAL, 형식이 틀린 결과도 INTERNAL, 이후 요청은 정상", function()
			local e = setup()
			local mode = "throw"
			e.r:bind("ClaimDaily", function(_ctx: any): any
				if mode == "throw" then
					error("boom")
				elseif mode == "bad" then
					return "yes"
				elseif mode == "badcode" then
					return { ok = false, code = 5 }
				end
				return { ok = true, data = { day = 1 } }
			end, { mutates = true })
			e.r:start()
			t:eq(e.invoke("ClaimDaily", e.p1), { ok = false, code = EC.INTERNAL })
			mode = "bad"
			e.clock = 1
			t:eq(e.invoke("ClaimDaily", e.p1), { ok = false, code = EC.INTERNAL })
			mode = "badcode"
			e.clock = 2
			t:eq(e.invoke("ClaimDaily", e.p1), { ok = false, code = EC.INTERNAL })
			t:eq(e.throttle:isDirty(1), false, "실패는 상태 변경 표시 없음")
			mode = "ok"
			e.clock = 3
			t:eq(e.invoke("ClaimDaily", e.p1), { ok = true, data = { day = 1 } })
			t:eq(e.throttle:isDirty(1), true, "성공한 변경 처리 → 표시")
		end)

		t:test("mutates 아닌 처리·실패 응답은 표시하지 않음", function()
			local e = setup()
			e.r:bind("GetSnapshot", function(_ctx: any)
				return { ok = true }
			end)
			e.r:bind("SetParty", function(_ctx: any)
				return { ok = false, code = EC.IN_ENCOUNTER }
			end, { mutates = true })
			e.r:start()
			e.invoke("GetSnapshot", e.p1)
			t:eq(e.invoke("SetParty", e.p1, { "1" }), { ok = false, code = EC.IN_ENCOUNTER })
			t:eq(e.throttle:isDirty(1), false)
		end)

		t:test("같은 플레이어의 처리 중 재진입은 BUSY", function()
			local e = setup()
			local inner: any = nil
			e.r:bind("Craft", function(ctx: any)
				inner = e.invoke("UpgradeFacility", ctx.player, "dew_spring")
				return { ok = true }
			end)
			e.r:start()
			t:eq(e.invoke("Craft", e.p1, "wick_from_meadow", 1), { ok = true })
			t:eq(inner, { ok = false, code = EC.BUSY })
			t:eq(e.invoke("UpgradeFacility", e.p1, "dew_spring").code, EC.NOT_IMPLEMENTED, "끝난 뒤에는 정상")
		end)

		t:test("입구 이중화 금지: 중복 등록·S→C 등록·start 후 등록·start 2회는 오류", function()
			local e = setup()
			e.r:bind("Craft", function(_ctx: any)
				return { ok = true }
			end)
			t:throws(function()
				e.r:bind("Craft", function(_ctx: any)
					return { ok = true }
				end)
			end, "이미 등록됨")
			t:throws(function()
				e.r:bind("StateChanged", function(_ctx: any)
					return { ok = true }
				end)
			end, "C→S Remote 가 아님")
			e.r:start()
			t:throws(function()
				e.r:bind("GatherStart", function(_ctx: any)
					return { ok = true }
				end)
			end, "start 후")
			t:throws(function()
				e.r:start()
			end, "두 번")
		end)

		t:test("C→S Remote 의 레이트·스키마 누락은 생성 시 오류", function()
			local rates = table.clone(deps.Config.REMOTE_RATES)
			rates.MoveSlot = nil
			t:throws(function()
				setup({ rates = rates })
			end, "레이트 미정의")
			local schemas = table.clone(deps.Validate.schemas(deps.gd, deps.Config, Net))
			schemas.MoveSlot = nil
			t:throws(function()
				setup({ schemas = schemas })
			end, "스키마 미정의")
		end)

		t:test("flush: 표시된 플레이어에게만 StateChanged, seq 는 GetSnapshot 과 이어짐, 한 명 실패가 다른 사람을 막지 않음", function()
			local e = setup({
				build = function(userId: number, save: any, _nowSec: number, seq: number, forResponse: boolean)
					if userId == 2 then
						error("broken save")
					end
					return { tag = save.tag, seq = seq, forResponse = forResponse }
				end,
			})
			e.r:bind("GetSnapshot", function(ctx: any)
				return { ok = true, data = e.r:snapshot(ctx.userId, ctx.save, ctx.now, true) }
			end)
			e.r:start()
			t:eq(e.invoke("GetSnapshot", e.p1).data.seq, 1)
			local players = { [1] = e.p1, [2] = e.p2 }
			local function lookup(userId: number)
				return players[userId]
			end
			t:eq(e.r:flush(0, lookup), 0, "표시 없음")
			e.r:markDirty(1)
			e.r:markDirty(2)
			e.r:markDirty(3) -- 退出済み（Player が無い）
			t:eq(e.r:flush(0, lookup), 1)
			local fired = e.remotes.StateChanged.fired
			t:eq(#fired, 1)
			t:eq(fired[1].player, e.p1)
			t:eq(fired[1].data, { tag = "save1", seq = 2, forResponse = false })
			local failLogged = false
			for _, m in e.logs do
				if string.find(m, "u_2 StateChanged 전송 실패", 1, true) then
					failLogged = true
				end
			end
			t:eq(failLogged, true)
		end)

		t:test("forget: 레이트·표시·seq 초기화", function()
			local e = setup()
			e.r:bind("GetSnapshot", function(ctx: any)
				return { ok = true, data = e.r:snapshot(ctx.userId, ctx.save, ctx.now, true) }
			end)
			e.r:start()
			e.invoke("GetSnapshot", e.p1)
			e.invoke("GetSnapshot", e.p1)
			t:eq(e.invoke("GetSnapshot", e.p1).code, EC.RATE_LIMITED)
			e.r:markDirty(1)
			e.r:forget(1)
			t:eq(e.throttle:isDirty(1), false)
			t:eq(e.invoke("GetSnapshot", e.p1).data.seq, 1)
		end)
	end,
}
