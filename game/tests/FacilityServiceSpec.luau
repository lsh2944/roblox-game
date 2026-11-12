--!strict
-- FacilityServiceSpec: 施設の枠配置（Q3 排他・1..slots・詰めた配列）・移動（MoveSlot、入れ替え・状態不変）と強化（上限 = 解禁済み最高フィールド、費用 = 生成表 + hunt_gates、精算が先）
-- 配置: ServerStorage.Tests.FacilityServiceSpec（Rojo: game/tests/FacilityServiceSpec.luau）
-- 依存: deps.FacilityService・FacilityRules・Net・Ledger・SaveSchema・Config・Formulas・CaptureLogic・econ・gd
-- 期待値の出典（cwd tools/econ_sim の python3 -c、2026-11-12 の data、シミュ実行なし）:
--   Economy.facility_level_cost('dew_spring', 1) = dew 40・bloom 20、(…, 3) = dew 53・bloom 27・hunt_meadow 9、(…, 10) = dew 141・bloom 71
--   Model.level_cap_at_field(dew_spring, 'meadow') = 10、'forest' = 20。計画書 S8 完了基準（1→2 が 40・20、3→4 に hunt_meadow 9）

local T = 1762819200

return {
	name = "FacilityService",
	run = function(t: any, deps: any)
		local E = deps.Net.ErrorCode
		local FR = deps.FacilityRules

		local function newWorld(): any
			local w: any = { calls = {} }
			w.save = deps.SaveSchema.newSave({
				gd = deps.gd,
				startSpirits = deps.Config.START_SPIRITS,
				milli = deps.Formulas.MILLI,
				vigorTick = deps.CaptureLogic.VIGOR_TICK,
			}, T)
			w.svc = deps.FacilityService.new({
				gd = deps.gd,
				econ = deps.econ,
				FacilityRules = FR,
				ledger = deps.Ledger.new(deps.gd),
				beforeChange = function(_u: number, save: any)
					table.insert(w.calls, "before")
					if w.onBefore then
						w.onBefore(save)
					end
				end,
				afterChange = function()
					table.insert(w.calls, "after")
				end,
			})
			return w
		end

		local function assigned(w: any, fid: string): { string }
			return w.save.facilities[fid].assigned
		end

		t:test("배치: 빈 칸은 뒤에 채우고, 찬 칸은 교체, ''는 빼고 당김", function()
			local w = newWorld()
			t:eq(w.svc:assign(1, w.save, "dew_spring", 1, "1", T).ok, true)
			t:eq(w.svc:assign(1, w.save, "dew_spring", 3, "2", T).ok, true)
			t:eq(assigned(w, "dew_spring"), { "1", "2" })
			t:eq(w.svc:assign(1, w.save, "dew_spring", 1, "3", T).ok, true)
			t:eq(assigned(w, "dew_spring"), { "3", "2" }, "교체(1번은 빠짐)")
			t:eq(w.svc:assign(1, w.save, "dew_spring", 2, "2", T).ok, true, "같은 칸 같은 정령")
			t:eq(w.svc:assign(1, w.save, "dew_spring", 1, "", T).ok, true)
			t:eq(assigned(w, "dew_spring"), { "2" })
			t:eq(w.svc:assign(1, w.save, "dew_spring", 3, "", T).code, E.NOT_FOUND, "빈 칸 비우기")
			t:eq((deps.SaveSchema.check(w.save)), true, "저장 형태 유지")
		end)

		t:test("배치 거부: 칸 범위·미해금·없는 시설·동행 중(Q3)·다른 곳에 배치됨", function()
			local w = newWorld()
			w.save.facilities.dew_spring.assigned = { "1" }
			w.save.party = { "3" }
			t:eq(w.svc:assign(1, w.save, "dew_spring", 0, "2", T).code, E.BAD_ARG)
			t:eq(w.svc:assign(1, w.save, "dew_spring", 4, "2", T).code, E.BAD_ARG, "slots=3")
			t:eq(w.svc:assign(1, w.save, "dew_spring", 1.5, "2", T).code, E.BAD_ARG)
			t:eq(w.svc:assign(1, w.save, "crystal_forge", 1, "2", T).code, E.NOT_UNLOCKED)
			t:eq(w.svc:assign(1, w.save, "nope", 1, "2", T).code, E.NOT_FOUND)
			t:eq(w.svc:assign(1, w.save, "dew_spring", 2, "9", T).code, E.NOT_FOUND)
			t:eq(w.svc:assign(1, w.save, "dew_spring", 2, "3", T).code, E.ASSIGNED_ELSEWHERE, "동행 중")
			t:eq(w.svc:assign(1, w.save, "bloom_garden", 1, "1", T).code, E.ASSIGNED_ELSEWHERE, "다른 시설")
			t:eq(w.svc:assign(1, w.save, "dew_spring", 2, "1", T).code, E.ASSIGNED_ELSEWHERE, "같은 시설 다른 칸")
			t:eq(#w.calls, 0)
		end)

		-- 移動（MoveSlot、2026-11-12 決定: サーバーで一度に移動、埋まった枠なら入れ替え）。開始精霊 uid 1..3、施設は各 3 枠
		local function both(w: any): any
			return { assigned(w, "dew_spring"), assigned(w, "bloom_garden") }
		end

		t:test("이동: 같은 시설 찬 칸은 교환(앞/뒤), 같은 시설 빈 칸은 빼고 끝으로", function()
			local w = newWorld()
			w.save.facilities.dew_spring.assigned = { "1", "2", "3" }
			t:eq(w.svc:move(1, w.save, "3", "dew_spring", 1, T), { ok = true, data = { facilities = { dew_spring = { "3", "2", "1" } } } })
			t:eq(w.svc:move(1, w.save, "3", "dew_spring", 2, T).ok, true, "뒤로")
			t:eq(assigned(w, "dew_spring"), { "2", "3", "1" })
			t:eq(w.svc:move(1, w.save, "3", "dew_spring", 2, T).ok, true, "같은 칸")
			t:eq(assigned(w, "dew_spring"), { "2", "3", "1" })
			w.save.facilities.dew_spring.assigned = { "1", "2" }
			t:eq(w.svc:move(1, w.save, "1", "dew_spring", 3, T).ok, true)
			t:eq(assigned(w, "dew_spring"), { "2", "1" }, "빈 칸 = 끝")
			t:eq((deps.SaveSchema.check(w.save)), true, "저장 형태 유지")
		end)

		t:test("이동: 다른 시설 빈 칸은 끝에 추가하고 원래 시설은 당김, 찬 칸은 두 정령 교환", function()
			local w = newWorld()
			w.save.facilities.dew_spring.assigned = { "1", "2" }
			t:eq(w.svc:move(1, w.save, "1", "bloom_garden", 3, T), {
				ok = true,
				data = { facilities = { dew_spring = { "2" }, bloom_garden = { "1" } } },
			})
			w.save.facilities.dew_spring.assigned = { "2", "3" }
			t:eq(w.svc:move(1, w.save, "3", "bloom_garden", 1, T).ok, true)
			t:eq(both(w), { { "2", "1" }, { "3" } }, "1번 칸 교환")
			t:eq(w.svc:move(1, w.save, "2", "bloom_garden", 1, T).ok, true)
			t:eq(both(w), { { "3", "1" }, { "2" } }, "교환은 원래 칸 번호 유지")
			t:eq((deps.SaveSchema.check(w.save)), true, "저장 형태 유지")
		end)

		t:test("이동 거부: 범위 밖·미보유·미배치·동행 중·닫힌/없는 시설·교환 상대 동행 중, 상태 불변·hook 미호출", function()
			local w = newWorld()
			w.save.facilities.dew_spring.assigned = { "1", "2" }
			w.save.facilities.bloom_garden.assigned = { "3" }
			local snap = { table.clone(assigned(w, "dew_spring")), table.clone(assigned(w, "bloom_garden")) }
			local cases = {
				{ "1", "bloom_garden", 0, E.BAD_ARG },
				{ "1", "bloom_garden", 4, E.BAD_ARG },
				{ "1", "bloom_garden", 1.5, E.BAD_ARG },
				{ 1, "bloom_garden", 1, E.BAD_ARG },
				{ "1", 5, 1, E.BAD_ARG },
				{ "9", "bloom_garden", 1, E.NOT_FOUND },
				{ "1", "crystal_forge", 1, E.NOT_UNLOCKED },
				{ "1", "nope", 1, E.NOT_FOUND },
			}
			for i, c in cases do
				t:eq(w.svc:move(1, w.save, c[1], c[2], c[3], T).code, c[4], `case {i}`)
			end
			w.save.facilities.bloom_garden.assigned = {}
			snap[2] = {}
			w.save.party = { "3" }
			t:eq(w.svc:move(1, w.save, "3", "dew_spring", 1, T).code, E.ASSIGNED_ELSEWHERE, "동행 중")
			w.save.party = {}
			t:eq(w.svc:move(1, w.save, "3", "dew_spring", 1, T).code, E.NOT_FOUND, "배치 안 됨(새 배치는 AssignSlot)")
			t:eq(both(w), snap, "상태 불변")
			-- 壊れた保存: 別の施設の入れ替え相手が同行にもいる
			w.save.party = { "2" }
			w.save.facilities.bloom_garden.assigned = { "2" }
			w.save.facilities.dew_spring.assigned = { "1" }
			snap = { { "1" }, { "2" } }
			w.calls = {}
			t:eq(w.svc:move(1, w.save, "1", "bloom_garden", 1, T).code, E.ASSIGNED_ELSEWHERE, "교환 상대 동행 중")
			t:eq(both(w), snap, "상태 불변")
			t:eq(#w.calls, 0, "거부 시 hook 미호출")
		end)

		t:test("이동: 변경 전 정산(옛 배치), 변경 후 refresh hook", function()
			local w = newWorld()
			w.save.facilities.dew_spring.assigned = { "1", "2" }
			local seen: any = nil
			w.onBefore = function(save: any)
				seen = { table.clone(save.facilities.dew_spring.assigned), table.clone(save.facilities.bloom_garden.assigned) }
			end
			t:eq(w.svc:move(1, w.save, "2", "bloom_garden", 1, T).ok, true)
			t:eq(w.calls, { "before", "after" })
			t:eq(seen, { { "1", "2" }, {} }, "정산 시점엔 옛 배치")
			t:eq(both(w), { { "1" }, { "2" } })
		end)

		t:test("강화 상한: 해금한 최고 필드의 level_cap_by_field", function()
			local w = newWorld()
			local fac = deps.gd.facilities.dew_spring
			t:eq({ FR.levelCapAtField(deps.gd, fac, "meadow"), FR.levelCapAtField(deps.gd, fac, "forest") }, { 10, 20 })
			t:eq(FR.levelCap(deps.gd, w.save, "dew_spring"), 10)
			w.save.unlocked = { "meadow", "forest" }
			t:eq(FR.levelCap(deps.gd, w.save, "dew_spring"), 20)
		end)

		t:test("강화: 비용 차감 전 정산, 1→2 이슬 40·꽃빛 20, 3→4 hunt_meadow 9, Lv10에서 LEVEL_CAP", function()
			local w = newWorld()
			t:eq(w.svc:upgrade(1, w.save, "dew_spring", T).code, E.INSUFFICIENT)
			w.onBefore = function(save: any)
				save.wallet.dew = 40000
				save.wallet.bloom = 20000
			end
			w.calls = {}
			t:eq(w.svc:upgrade(1, w.save, "dew_spring", T), { ok = true, data = { facilityId = "dew_spring", level = 2 } })
			t:eq({ w.save.wallet.dew, w.save.wallet.bloom, w.calls }, { 0, 0, { "before", "after" } })
			w.onBefore = nil
			w.save.facilities.dew_spring.level = 3
			w.save.wallet.dew, w.save.wallet.bloom = 53000, 27000
			t:eq(w.svc:upgrade(1, w.save, "dew_spring", T).code, E.INSUFFICIENT, "hunt_meadow 없음")
			t:eq({ w.save.wallet.dew, w.save.facilities.dew_spring.level }, { 53000, 3 }, "부족 시 변경 없음")
			w.save.wallet.hunt_meadow = 9000
			t:eq(w.svc:upgrade(1, w.save, "dew_spring", T).ok, true)
			t:eq(w.save.wallet, { wick = 21000, dew = 0, bloom = 0, hunt_meadow = 0 })
			w.save.facilities.dew_spring.level = 10
			w.save.wallet.dew, w.save.wallet.bloom = 141000, 71000
			t:eq(w.svc:upgrade(1, w.save, "dew_spring", T).code, E.LEVEL_CAP)
			w.save.unlocked = { "meadow", "forest" }
			t:eq(w.svc:upgrade(1, w.save, "dew_spring", T).ok, true, "forest 해금 후")
			t:eq(w.svc:upgrade(1, w.save, "crystal_forge", T).code, E.NOT_UNLOCKED)
			t:eq(w.svc:upgrade(1, w.save, 3, T).code, E.BAD_ARG)
		end)
	end,
}
