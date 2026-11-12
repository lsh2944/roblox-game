--!strict
-- RosterServiceSpec: 保有上限・同行の編成（Q3 排他・枠 3・遭遇中不可）・手動の放出（研究ポイント）・精霊レベルアップ（Q6）
-- 配置: ServerStorage.Tests.RosterServiceSpec（Rojo: game/tests/RosterServiceSpec.luau）
-- 依存: deps.RosterService・RosterRules・Activity・Net・Ledger・SaveSchema・Config・Formulas・CaptureLogic・gd
-- 期待値の出典: hub.json（base 100・max 200・rank1 bonus 0）、rules.json constants.companion_slots = 3、
--   spirits.json release_research_by_grade（★1 = 1）、cwd tools/econ_sim の python3 -c（2026-11-12 の data、シミュ実行なし）:
--   Economy.spirit_level_cost('sparkle', 1) = dew 7・bloom 7、max_spirit_level('sparkle') = 30

local T = 1762819200

return {
	name = "RosterService",
	run = function(t: any, deps: any)
		local E = deps.Net.ErrorCode

		local function newWorld(): any
			local w: any = { calls = {} }
			w.save = deps.SaveSchema.newSave({
				gd = deps.gd,
				startSpirits = deps.Config.START_SPIRITS,
				milli = deps.Formulas.MILLI,
				vigorTick = deps.CaptureLogic.VIGOR_TICK,
			}, T)
			w.act = deps.Activity.new()
			w.svc = deps.RosterService.new({
				gd = deps.gd,
				RosterRules = deps.RosterRules,
				Net = deps.Net,
				ledger = deps.Ledger.new(deps.gd),
				activity = w.act,
				allocUid = deps.SaveSchema.allocUid,
				vigorTick = deps.CaptureLogic.VIGOR_TICK,
				beforeChange = function(_u: number, save: any, now: number)
					table.insert(w.calls, "before")
					if w.onBefore then
						w.onBefore(save, now)
					end
				end,
				afterChange = function()
					table.insert(w.calls, "after")
				end,
			})
			return w
		end

		t:test("보유 상한: 기본 100, 상품 보너스 포함 최대 200", function()
			local w = newWorld()
			local R = deps.RosterRules
			t:eq({ R.count(w.save), R.capacity(deps.gd, w.save), R.isFull(deps.gd, w.save) }, { 3, 100, false })
			w.save.storage_bonus = 150
			t:eq(R.capacity(deps.gd, w.save), 200)
		end)

		t:test("동행: 3칸·중복·보유·시설 배치(Q3)·조우 중 검증", function()
			local w = newWorld()
			t:eq(w.svc:setParty(1, w.save, "1", T).code, E.BAD_ARG)
			t:eq(w.svc:setParty(1, w.save, { 1 }, T).code, E.BAD_ARG, "숫자 uid")
			t:eq(w.svc:setParty(1, w.save, { "1", "2", "3", "1" }, T).code, E.PARTY_FULL)
			t:eq(w.svc:setParty(1, w.save, { "1", "1" }, T).code, E.DUPLICATE)
			t:eq(w.svc:setParty(1, w.save, { "9" }, T).code, E.NOT_FOUND)
			w.save.facilities.dew_spring.assigned = { "2" }
			t:eq(w.svc:setParty(1, w.save, { "1", "2" }, T).code, E.ASSIGNED_ELSEWHERE)
			w.act:set(1, "encounter")
			t:eq(w.svc:setParty(1, w.save, { "1" }, T).code, E.IN_ENCOUNTER)
			w.act:clear(1)
			t:eq(#w.calls, 0, "거부 시 hook 없음")
			local input = { "1", "3" }
			local r = w.svc:setParty(1, w.save, input, T)
			t:eq({ r.ok, w.save.party, w.calls }, { true, { "1", "3" }, { "before", "after" } })
			input[1] = "2"
			t:eq(w.save.party, { "1", "3" }, "입력 테이블을 그대로 저장하지 않음")
			t:eq(w.svc:setParty(1, w.save, {}, T).ok, true, "비우기")
		end)

		t:test("놓아주기: 등급별 연구 포인트 지급, 동행·배치 중은 거부", function()
			local w = newWorld()
			w.save.party = { "1" }
			w.save.facilities.bloom_garden.assigned = { "3" }
			t:eq(w.svc:release(1, w.save, "1", T).code, E.ASSIGNED_ELSEWHERE, "동행 중")
			t:eq(w.svc:release(1, w.save, "3", T).code, E.ASSIGNED_ELSEWHERE, "배치 중")
			t:eq(w.svc:release(1, w.save, "7", T).code, E.NOT_FOUND)
			local r = w.svc:release(1, w.save, "2", T)
			t:eq(r, { ok = true, data = { uid = "2", research = 1 } })
			t:eq({ w.save.roster["2"], w.save.wallet.research, w.save.stats.releases }, { nil, 1000, 1 })
			t:eq(w.save.dex.dewdrop, T, "도감 기록은 유지")
		end)

		t:test("레벨업: 비용 차감 전 정산 hook, 부족하면 변경 없음, 상한 30", function()
			local w = newWorld()
			local r = w.svc:levelUp(1, w.save, "1", T)
			t:eq(r.code, E.INSUFFICIENT)
			t:eq({ w.save.roster["1"].level, w.save.wallet.dew }, { 1, nil })
			-- 精算で dew・bloom が 7 ずつ入る状況: hook が差し引きより先なら払える
			w.onBefore = function(save: any)
				save.wallet.dew = (save.wallet.dew or 0) + 7000
				save.wallet.bloom = (save.wallet.bloom or 0) + 7000
			end
			w.calls = {}
			r = w.svc:levelUp(1, w.save, "1", T)
			t:eq(r, { ok = true, data = { uid = "1", level = 2 } })
			t:eq({ w.save.wallet.dew, w.save.wallet.bloom, w.calls }, { 0, 0, { "before", "after" } })
			w.save.roster["1"].level = 30
			t:eq(w.svc:levelUp(1, w.save, "1", T).code, E.LEVEL_CAP)
			t:eq(w.svc:levelUp(1, w.save, 1, T).code, E.BAD_ARG)
		end)
	end,
}
