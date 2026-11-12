--!strict
-- CaptureServiceSpec: 野生の出現（next_spawn_at）・遭遇の検証順・開始時の確定（芯・活力・統計）・完了/途中退出の反映・ServerRng
-- 配置: ServerStorage.Tests.CaptureServiceSpec（Rojo: game/tests/CaptureServiceSpec.luau）
-- 依存: deps.CaptureService・WildSpawnService・GatherService・RosterService・Activity・ServerRng・CaptureLogic・RosterRules・
--   GatherCalc・Net・Ledger・SaveSchema・Config・Formulas・TestKit・SessionCleanup・econ・gd
--   2026-11-12 追加: イベントの段階送信（dueEvents、時刻前に result を出さない）、未来時刻の切り詰め（上限 52・112 秒は
--   CaptureLogicSpec の手計算）、出現表が空なら副作用なし、SessionCleanup の順番、分境界をまたぐ遭遇の活力回復停止
-- 期待値の出典: EncounterSpec と同じ python3 -c の値（★2 sunset_bird: 弱体化 10 秒・活力 4 点 = 240 tick・2 試行で成功・78 秒）、
--   計画書 4.3（next_spawn_at = 直前の遭遇の終了 + encounter_base_seconds 60、途中退出は即確定・反映、個体値 intInclusive(10000,12000)、
--   採集 → 戦闘の順 = sim.py _complete_encounter）、Q4 決定（満杯なら捕獲開始を止める）、開始状態（芯 21、uid 1..3 = sparkle・dewdrop・flower_lamp）

local T = 1762819200 -- 秒（60 の倍数）
local K = 10

return {
	name = "CaptureService",
	run = function(t: any, deps: any)
		local E = deps.Net.ErrorCode
		local TK = deps.TestKit

		-- capture ブロック: [1]=0.9（sunset_bird ★2）、[2]=0.9（1 回目失敗）、[3]=0.1（2 回目成功）、他 0.5（逃走しない）
		local function successBlock(): { number }
			local b = table.create(1 + 2 * K, 0.5)
			b[1], b[2], b[3] = 0.9, 0.9, 0.1
			return b
		end

		local function newWorld(captureNumbers: { number }?, individual: { number }?, gdOverride: any?): any
			local w: any = { logs = {} }
			w.save = deps.SaveSchema.newSave({
				gd = deps.gd,
				startSpirits = deps.Config.START_SPIRITS,
				milli = deps.Formulas.MILLI,
				vigorTick = deps.CaptureLogic.VIGOR_TICK,
			}, T)
			w.save.party = { "1" } -- sparkle ★1
			w.calls = {}
			w.rng = deps.ServerRng.new(function(stream: string): any
				if stream == "capture" then
					return TK.seqProvider(captureNumbers, nil)
				elseif stream == "individual" then
					return TK.seqProvider(nil, individual)
				end
				return TK.seqProvider(nil, nil)
			end)
			w.act = deps.Activity.new()
			w.ledger = deps.Ledger.new(deps.gd)
			local function before(userId: number, save: any, now: number)
				-- 精算は図鑑登録の前（dex = その時点の図鑑登録の有無）
				table.insert(w.calls, { now = now, wick = save.wallet.wick, dex = save.dex.sunset_bird ~= nil })
			end
			local function log(msg: string)
				table.insert(w.logs, msg)
			end
			w.gather = deps.GatherService.new({
				GatherCalc = deps.GatherCalc,
				econ = deps.econ,
				ledger = w.ledger,
				activity = w.act,
				radius = deps.Config.GATHER_RADIUS,
				maxGapSeconds = deps.Config.GATHER_MAX_CREDIT_SECONDS,
			})
			w.roster = deps.RosterService.new({
				gd = deps.gd,
				RosterRules = deps.RosterRules,
				Net = deps.Net,
				ledger = w.ledger,
				activity = w.act,
				allocUid = deps.SaveSchema.allocUid,
				vigorTick = deps.CaptureLogic.VIGOR_TICK,
			})
			w.wild = deps.WildSpawnService.new({ rng = w.rng, CaptureLogic = deps.CaptureLogic, rule = deps.gd.capture, log = log })
			w.svc = deps.CaptureService.new({
				gd = gdOverride or deps.gd,
				CaptureLogic = deps.CaptureLogic,
				RosterRules = deps.RosterRules,
				Net = deps.Net,
				ledger = w.ledger,
				rng = w.rng,
				activity = w.act,
				wild = w.wild,
				gather = w.gather,
				roster = w.roster,
				uidNum = deps.SaveSchema.uidNum,
				radius = deps.Config.CAPTURE_RADIUS,
				beforeChange = before,
				log = log,
			})
			return w
		end

		t:test("ServerRng: 범위 밖 값은 다시 뽑고, 계속 밖이면 오류. 없는 스트림은 오류", function()
			local rng = deps.ServerRng.new(function(stream: string): any
				return TK.seqProvider({ 1, -0.1, 0.25 }, { 9, 3 })
			end)
			t:eq(rng:uniform("capture"), 0.25)
			t:eq(rng:intInclusive("individual", 1, 5), 3)
			t:throws(function()
				rng:uniform("nope")
			end, "nope")
			local bad = deps.ServerRng.new(function(): any
				return { number = function()
					return 1
				end, integer = function()
					return 0
				end }
			end)
			t:throws(function()
				bad:uniform("spawn")
			end)
			t:throws(function()
				bad:intInclusive("spawn", 1, 2)
			end)
		end)

		t:test("야생 출현: next_spawn_at 이후·해금 필드에서 1마리, 다시 부르면 같은 개체", function()
			local w = newWorld()
			w.save.next_spawn_at = T + 10
			t:eq(w.wild:ensure(1, w.save, T + 9, "meadow"), nil)
			t:eq(w.wild:ensure(1, w.save, T + 10, "forest"), nil, "미해금 필드")
			local a = w.wild:ensure(1, w.save, T + 10, "meadow")
			t:eq(a.fieldId, "meadow")
			t:eq(w.wild:ensure(1, w.save, T + 11, "meadow"), a)
			t:ok(w.wild:ensure(2, w.save, T + 11, "meadow").id ~= a.id, "플레이어별 id")
		end)

		t:test("등롱 검증 순서: 소유 → 거리 → 심지 → 유휴 → 보관함(Q4)", function()
			local w = newWorld()
			local R = deps.Config.CAPTURE_RADIUS
			t:eq(w.svc:engage(1, w.save, "w1", 0, T).code, E.NOT_FOUND, "야생 없음")
			local wd = w.wild:ensure(1, w.save, T, "meadow")
			t:eq(w.svc:engage(1, w.save, "w999", 0, T).code, E.NOT_FOUND, "남의 id")
			t:eq(w.svc:engage(1, w.save, wd.id, 1 / 0, T).code, E.BAD_ARG, "무한 거리")
			t:eq(w.svc:engage(1, w.save, wd.id, R + 1, T).code, E.TOO_FAR)
			w.save.wallet.wick = 999
			t:eq(w.svc:engage(1, w.save, wd.id, R, T).code, E.NO_WICK, "심지 1개 미만")
			w.save.wallet.wick = 21000
			w.act:set(1, "encounter")
			t:eq(w.svc:engage(1, w.save, wd.id, R, T).code, E.BUSY)
			w.act:clear(1)
			for i = 4, 100 do
				w.save.roster[tostring(i)] = table.clone(w.save.roster["1"])
			end
			w.save.next_uid = 101
			t:eq(deps.RosterRules.capacity(deps.gd, w.save), 100)
			t:eq(w.svc:engage(1, w.save, wd.id, R, T).code, E.STORAGE_FULL)
			t:eq(w.save.wallet.wick, 21000, "거부 시 변경 없음")
			t:eq(#w.calls, 0, "거부 시 정산 hook 미호출")
		end)

		t:test("성공: 시작 시 확정(심지·활력·통계·next_spawn_at), 완료 시각에 포획·개체값·도감 반영", function()
			local w = newWorld(successBlock(), { 10000, 12000 })
			local wd = w.wild:ensure(1, w.save, T, "meadow")
			local r = w.svc:engage(1, w.save, wd.id, 0, T)
			t:eq(r.ok, true)
			t:eq(w.svc:getPending(1).endsAt, T + 18)
			t:eq(w.calls[1], { now = T, wick = 21000, dex = false }, "정산 hook이 심지 차감 전")
			t:eq(w.save.wallet.wick, 19000, "심지 2개 즉시 차감")
			t:eq({ w.save.roster["1"].vigor_ticks, w.save.roster["1"].vigor_min }, { 6000 - 240, T // 60 })
			t:eq({ w.save.stats.encounters, w.save.stats.attempts, w.save.stats.captures }, { 1, 2, 0 })
			t:eq(w.save.next_spawn_at, T + 78)
			t:eq(w.wild:get(1), nil, "야생 소비")
			t:eq(w.act:get(1), "encounter")
			t:eq(w.svc:complete(1, w.save, T + 17), nil, "완료 전")
			t:eq(w.save.roster["4"], nil)
			local a = w.svc:complete(1, w.save, T + 30)
			t:eq(w.calls[2], { now = T + 18, wick = 19000, dex = false }, "반영 시 정산이 도감 등록보다 먼저, 시각 = 완료 시각")
			t:eq(#a.events, 3, "보내지 않은 이벤트(attempt 2개·result)를 함께 반환")
			t:eq(a.events[3].result, "success")
			a.events = nil
			t:eq(a, { result = "success", species = "sunset_bird", uid = "4", gatherBps = 10000, combatBps = 12000 })
			t:eq(w.save.roster["4"], {
				species = "sunset_bird",
				level = 1,
				gather_bps = 10000,
				combat_bps = 12000,
				vigor_ticks = 6000,
				vigor_min = (T + 18) // 60,
				origin = "capture",
				caught_at = T + 18,
			})
			t:eq({ w.save.dex.sunset_bird, w.save.first_capture.sunset_bird, w.save.stats.captures }, { T + 18, T + 18, 1 })
			t:eq(w.save.next_uid, 5)
			t:eq(w.act:get(1), nil)
			t:eq((deps.SaveSchema.check(w.save)), true, "저장 형태 유지")
			t:eq(w.wild:ensure(1, w.save, T + 77, "meadow"), nil, "쿨다운 중")
			t:ok(w.wild:ensure(1, w.save, T + 78, "meadow") ~= nil, "직전 조우 종료 + 60초")
		end)

		t:test("중간 이탈: finish가 즉시 확정 반영, 도망은 정령·개체값 추첨 없음", function()
			local w = newWorld(successBlock(), { 11000, 10500 })
			local wd = w.wild:ensure(1, w.save, T, "meadow")
			w.svc:engage(1, w.save, wd.id, 0, T)
			local a = w.svc:finish(1, w.save, T + 5)
			t:eq({ a.result, a.uid, w.save.roster["4"].caught_at, w.save.roster["4"].gather_bps }, { "success", "4", T + 5, 11000 })
			t:eq(#a.events, 3, "중간 이탈도 남은 이벤트를 반환")
			t:eq(w.svc:finish(1, w.save, T + 6), nil, "두 번째는 없음")

			local fb = table.create(1 + 2 * K, 0.5)
			fb[1], fb[2], fb[1 + K + 1] = 0.9, 0.9, 0.01
			local f = newWorld(fb, {}) -- individual 수열이 비어 있음: 뽑으면 오류
			local fw = f.wild:ensure(1, f.save, T, "meadow")
			f.svc:engage(1, f.save, fw.id, 0, T)
			local fr = f.svc:complete(1, f.save, T + 14)
			t:eq({ fr.result, fr.species, fr.uid }, { "flee", "sunset_bird", nil })
			t:eq({ f.save.wallet.wick, f.save.stats.captures, f.save.next_uid, f.save.first_capture.sunset_bird }, { 20000, 0, 4, nil })
		end)

		t:test("채집 중 등롱: 채집을 정산·종료하고 조우 시작, 조우 중 채집 시작은 BUSY", function()
			local w = newWorld(successBlock(), { 10000, 10000 })
			w.gather:start(1, w.save, "meadow_dew", 0, T - 2)
			local wd = w.wild:ensure(1, w.save, T, "meadow")
			t:eq(w.svc:engage(1, w.save, wd.id, 0, T).ok, true)
			t:eq(w.gather:session(1), nil)
			local rate = deps.GatherCalc.rate(deps.econ, w.save, deps.gd.nodes.meadow_dew.node) -- 同行 sparkle 込みの率
			t:eq(w.save.wallet.dew, deps.GatherCalc.accrueSeconds(rate, 2, 0), "2초분 정산")
			t:eq(w.gather:start(1, w.save, "meadow_dew", 0, T + 1).code, E.BUSY)
		end)

		local function phases(evs: { any }): { string }
			local out = {}
			for _, e in evs do
				table.insert(out, e.phase)
			end
			return out
		end

		t:test("단계별 전송: RF 응답은 시각 0 이벤트만(결과·종료 시각 없음), dueEvents는 시각이 된 것만 한 번씩", function()
			local w = newWorld(successBlock(), { 10000, 12000 })
			local wd = w.wild:ensure(1, w.save, T, "meadow")
			local r = w.svc:engage(1, w.save, wd.id, 0, T)
			t:eq(phases(r.data.events), { "reveal", "weaken" })
			t:eq({ r.data.durationSeconds, r.data.endsAt }, { nil, nil }, "시도 수가 드러나는 값 미포함")
			t:eq(w.svc:dueEvents(1, T), {}, "이미 보낸 것은 다시 안 나옴")
			t:eq(w.svc:dueEvents(1, T + 9), {})
			local e1 = w.svc:dueEvents(1, T + 10)
			t:eq({ phases(e1), e1[1].attempt, e1[1].result }, { { "attempt" }, 1, nil })
			t:eq(w.svc:dueEvents(1, T + 13), {})
			t:eq(phases(w.svc:dueEvents(1, T + 17)), { "attempt" })
			t:eq(w.svc:complete(1, w.save, T + 17), nil)
			local last = w.svc:dueEvents(1, T + 18)
			t:eq({ phases(last), last[1].result }, { { "result" }, "success" }, "result는 완료 시각에만")
			local a = w.svc:complete(1, w.save, T + 18)
			t:eq({ a.result, a.events }, { "success", {} }, "다 보낸 뒤 반영은 남은 이벤트 없음")
			t:eq(w.svc:dueEvents(1, T + 19), {}, "조우 밖은 빈 목록")
		end)

		t:test("단계별 전송: 여러 시각을 건너뛰면 순서대로 한꺼번에", function()
			local w = newWorld(successBlock(), { 10000, 12000 })
			local wd = w.wild:ensure(1, w.save, T, "meadow")
			w.svc:engage(1, w.save, wd.id, 0, T)
			t:eq(phases(w.svc:dueEvents(1, T + 100)), { "attempt", "attempt", "result" })
		end)

		t:test("출현 표가 비면 부작용(정산·채집 종료·난수·야생 소비) 전에 거부", function()
			local gd2 = setmetatable({ fields = { meadow = { capture = { table = {} } } } }, { __index = deps.gd })
			local w = newWorld(successBlock(), {}, gd2)
			w.gather:start(1, w.save, "meadow_dew", 0, T - 2)
			local wd = w.wild:ensure(1, w.save, T, "meadow")
			t:eq(w.svc:engage(1, w.save, wd.id, 0, T).code, E.NOT_FOUND)
			t:eq({ #w.calls, w.act:get(1), w.wild:get(1) }, { 0, "gather", wd })
			t:ok(w.gather:session(1) ~= nil, "채집 계속")
			t:eq({ w.save.wallet.wick, w.save.stats.encounters }, { 21000, 0 })
			t:eq(w.rng:uniform("capture"), 0.9, "capture 난수 미소비")
		end)

		t:test("분 경계를 넘는 조우: 공격자 활력은 조우가 끝나는 분까지 회복하지 않음", function()
			local w = newWorld(successBlock(), { 10000, 12000 })
			local wd = w.wild:ensure(1, w.save, T + 50, "meadow")
			t:eq(w.svc:engage(1, w.save, wd.id, 0, T + 50).ok, true) -- 끝 = T + 68（다음 분）
			local rec = w.save.roster["1"]
			local m = T // 60
			t:eq({ rec.vigor_ticks, rec.vigor_min }, { 6000 - 240, m + 1 })
			local CL = deps.CaptureLogic
			local rule = deps.gd.capture
			t:eq(CL.vigorAt(rec.vigor_ticks, rec.vigor_min, m + 1, rule), 5760, "조우 중인 분은 회복 0")
			t:eq(CL.vigorAt(rec.vigor_ticks, rec.vigor_min, m + 2, rule), 5780, "다음 분부터 20tick/분")
		end)

		t:test("미래 시각 잘라내기: next_spawn_at 상한(112초) 정확히는 유지, 초과는 now로 고쳐 저장·로그", function()
			local w = newWorld()
			w.save.next_spawn_at = T + 112
			t:eq(w.wild:ensure(1, w.save, T, "meadow"), nil)
			t:eq({ w.save.next_spawn_at, #w.logs }, { T + 112, 0 })
			w.save.next_spawn_at = T + 113
			t:ok(w.wild:ensure(1, w.save, T, "meadow") ~= nil, "바로 출현")
			t:eq({ w.save.next_spawn_at, #w.logs }, { T, 1 })
		end)

		t:test("미래 시각 잘라내기: 동행 vigor_min 상한 초과는 now 분으로 고친 뒤 조우 계산", function()
			local w = newWorld(successBlock(), { 10000, 12000 })
			local now = T + 600
			local m = now // 60
			w.save.roster["1"].vigor_ticks = 4000
			w.save.roster["1"].vigor_min = m + 1 -- 상한 = (now + 52) // 60 = m
			w.save.next_spawn_at = 0
			local wd = w.wild:ensure(1, w.save, now, "meadow")
			t:eq(w.svc:engage(1, w.save, wd.id, 0, now).ok, true)
			t:eq({ w.save.roster["1"].vigor_ticks, w.save.roster["1"].vigor_min }, { 3760, (now + 18) // 60 })
			t:eq(#w.logs, 1)
			local v = newWorld(successBlock(), { 10000, 12000 })
			v.save.roster["1"].vigor_ticks = 4000
			v.save.roster["1"].vigor_min = m -- 상한 정확히는 유지
			local vd = v.wild:ensure(1, v.save, now, "meadow")
			v.svc:engage(1, v.save, vd.id, 0, now)
			t:eq({ v.save.roster["1"].vigor_min, #v.logs }, { m, 0 })
		end)

		t:test("미래 시각 잘라내기: 시계가 되돌아가 endsAt이 최장 조우(52초)보다 미래면 now에 반영", function()
			local w = newWorld(successBlock(), { 10000, 12000 })
			local wd = w.wild:ensure(1, w.save, T, "meadow")
			w.svc:engage(1, w.save, wd.id, 0, T) -- endsAt = T + 18
			t:eq(w.svc:complete(1, w.save, T - 34), nil, "차이 52초 = 정상 범위")
			t:eq(#w.logs, 0)
			local a = w.svc:complete(1, w.save, T - 35)
			t:eq({ a.result, w.save.roster["4"].caught_at, #a.events, #w.logs }, { "success", T - 35, 3, 1 })
			t:eq(w.act:get(1), nil, "조우에서 풀림")
		end)

		t:test("SessionCleanup: capture:finish → gather:stop → wild:clear → activity:clear 순서, 실패해도 다음 단계 계속", function()
			local order = {}
			local function rec(name: string, ret: any): any
				return function(...)
					table.insert(order, name)
					if ret == "error" then
						error("boom")
					end
					return ret
				end
			end
			local fake = {
				capture = { finish = rec("capture:finish", "error") },
				gather = { stop = rec("gather:stop", 7) },
				wild = { clear = rec("wild:clear", nil) },
				activity = { clear = rec("activity:clear", nil) },
			}
			local r = deps.SessionCleanup.run(fake, 1, {}, T)
			t:eq(order, { "capture:finish", "gather:stop", "wild:clear", "activity:clear" })
			t:eq({ r.capture, r.gathered, #r.errors }, { nil, 7, 1 })
			t:ok(string.find(r.errors[1], "capture", 1, true) ~= nil)
			order = {}
			deps.SessionCleanup.run(fake, 1, nil, T)
			t:eq(order, { "wild:clear", "activity:clear" }, "저장 데이터 없으면 저장에 닿는 단계 생략")
		end)

		t:test("SessionCleanup: 조우 중 퇴장은 포획을 반영한 뒤 저장 가능한 상태, 두 번 불러도 한 번만 반영", function()
			local w = newWorld(successBlock(), { 10000, 12000 })
			local wd = w.wild:ensure(1, w.save, T, "meadow")
			w.svc:engage(1, w.save, wd.id, 0, T)
			local cdeps = { capture = w.svc, gather = w.gather, wild = w.wild, activity = w.act }
			local r = deps.SessionCleanup.run(cdeps, 1, w.save, T + 5)
			t:eq({ r.capture.result, r.capture.uid, #r.errors }, { "success", "4", 0 })
			t:eq({ w.save.stats.captures, w.save.roster["4"].caught_at }, { 1, T + 5 })
			t:eq({ w.svc:getPending(1), w.act:get(1), w.wild:get(1) }, { nil, nil, nil })
			t:eq((deps.SaveSchema.check(w.save)), true, "저장 형태 유지")
			local r2 = deps.SessionCleanup.run(cdeps, 1, w.save, T + 6)
			t:eq({ r2.capture, w.save.stats.captures, w.save.next_uid }, { nil, 1, 5 })

			local g = newWorld()
			g.gather:start(1, g.save, "meadow_dew", 0, T)
			g.wild:ensure(1, g.save, T, "meadow")
			local gr = deps.SessionCleanup.run({ capture = g.svc, gather = g.gather, wild = g.wild, activity = g.act }, 1, g.save, T + 3)
			t:ok(gr.gathered > 0, "채집 정산")
			t:eq({ g.gather:session(1), g.act:get(1), g.wild:get(1) }, { nil, nil, nil })
		end)
	end,
}
