--!strict
-- EconomySpec: Economy の値が Python econ_sim.economy.Economy と同じか
-- 配置: ServerStorage.Tests.EconomySpec（Rojo: game/tests/EconomySpec.luau）
-- 依存: deps.econ（Economy.new(gd)）、deps.gd
-- 期待値の出典: 2026-11-11 の data/*.json で Python の Economy メソッドを直接呼んだ結果（シミュ実行なし）。
--   cwd tools/econ_sim: python3 -c "from econ_sim.economy import Economy; ... e.facility_rate('dew_spring', 1, start, False, e.dex_bps(3))"
--   data（placeholder 数値）を変えたらこの期待値も Python で取り直す。

local function M(species: string, level: number, g: number?, c: number?): any
	return { species = species, level = level, gatherBps = g, combatBps = c }
end

return {
	name = "Economy",
	run = function(t: any, deps: any)
		local e = deps.econ
		local gd = deps.gd
		local start = { M("sparkle", 1), M("dewdrop", 1), M("flower_lamp", 1) }
		local ind = { M("sparkle", 3, 11234, 10500), M("dewdrop", 2, 12000, 10000), M("sunset_bird", 1, 10001, 12000) }

		t:test("시작 3종 배치: 이슬 샘·꽃빛 정원 Lv1 생산율(계획서 S3 완료 기준)", function()
			t:eq(e:dexBps(3), 300)
			t:eq(e:facilityRate("dew_spring", 1, start, false, 300), 65096, "dew_spring Lv1 dex3")
			t:eq(e:facilityRate("bloom_garden", 1, start, false, 300), 65096, "bloom_garden Lv1 dex3")
			t:eq(e:facilityRate("dew_spring", 1, start, false, 0), 63200, "dew_spring Lv1 dex0")
		end)

		t:test("개체값·레벨·특성(-20%)·도감 반영", function()
			t:eq(e:facilityRate("dew_spring", 7, ind, false, 500), 122652)
			t:eq(e:facilityRate("bloom_garden", 10, ind, false, 1000), 230051)
			t:eq(e:slotPower("sunset_bird", 1, "dew", false, 10001), 32003)
			t:eq(e:slotPower("sparkle", 3, "dew", false, 11234), 60660)
			t:eq(e:abilityBps("sparkle", 1), 10000)
			t:eq(e:abilityBps("sparkle", 3), 10800)
		end)

		t:test("혼합 배치 보너스(서로 다른 종 수 조건)", function()
			local mix = { M("rainbow_butterfly", 1), M("sparkle", 1), M("dewdrop", 1) }
			local mix2 = { M("rainbow_butterfly", 1), M("sparkle", 1) }
			t:eq(e:mixedBonus(mix), 1000)
			t:eq(e:facilityRate("dew_spring", 1, mix, false, 0), 74800)
			t:eq(e:mixedBonus(mix2), 0)
			t:eq(e:facilityRate("dew_spring", 1, mix2, false, 0), 39200)
		end)

		t:test("빈 시설·레벨 0은 0", function()
			t:eq(e:facilityRate("dew_spring", 1, {}, false, 300), 0)
			t:eq(e:facilityRate("dew_spring", 0, start, false, 300), 0)
		end)

		t:test("도감 보너스 상한", function()
			t:eq(e:dexBps(0), 0)
			t:eq(e:dexBps(5), 500)
			t:eq(e:dexBps(30), 1000)
		end)

		t:test("집 재료(등급별 milli/일, 출현 순)", function()
			local rows = e:homeMaterialDetail({ M("sparkle", 1), M("dewdrop", 1), M("flower_lamp", 1), M("sunset_bird", 1, 11000, 10000) }, 0)
			t:eq(rows, {
				{ resource = "hunt_meadow", grade = 1, milli = 1500 },
				{ resource = "hunt_meadow", grade = 2, milli = 800 },
			})
			t:eq(e:homeMaterialDetail({ M("rainbow_butterfly", 1) }, 0), { { resource = "hunt_forest", grade = 3, milli = 1200 } })
			t:eq(e:homeMaterialPerDay({ M("sparkle", 1), M("sunset_bird", 1) }, 0), { hunt_meadow = 1300 })
		end)

		t:test("시설 강화 비용(생성 표 + 사냥 재료 관문)", function()
			t:eq(e:facilityLevelCost("dew_spring", 1), { { resource = "dew", amount = 40 }, { resource = "bloom", amount = 20 } })
			t:eq(
				e:facilityLevelCost("dew_spring", 3),
				{ { resource = "dew", amount = 53 }, { resource = "bloom", amount = 27 }, { resource = "hunt_meadow", amount = 9 } }
			)
			t:eq(
				e:facilityLevelCost("bloom_garden", 9),
				{ { resource = "bloom", amount = 123 }, { resource = "dew", amount = 62 }, { resource = "hunt_meadow", amount = 9 } }
			)
		end)

		t:test("직접 채집(도구 배율·동행 보너스·특수 노드)", function()
			t:eq(e:toolMult("gather_tool", 1), 10000)
			t:eq(e:toolMult("gather_tool", 10), 19000)
			local dewNode = gd.nodes.meadow_dew.node
			local bloomNode = gd.nodes.meadow_bloom.node
			t:eq(e:directRate(dewNode, "gather_tool", 1, {}), 160000)
			t:eq(e:directRate(dewNode, "gather_tool", 1, start), 210560)
			t:eq(e:directRate(bloomNode, "gather_tool", 5, ind), 289206)
			t:eq(e:companionPower("dewdrop", 1, "dew"), 72000)
			t:eq(e:companionPower("sparkle", 3, "dew", 11234), 60660)
			local big = gd.nodes.big_crystal.node
			t:eq(e:directRate(big, "gather_tool", 1, { M("sparkle", 1) }), 0, "특성 없는 동행은 닫힘")
			t:eq(e:directRate(big, "gather_tool", 1, { M("shard_light", 1) }), 224000)
		end)

		t:test("없는 id는 error", function()
			t:throws(function()
				e:facilityRate("nope", 1, start, false, 0)
			end, "시설 없음")
			t:throws(function()
				e:abilityBps("sparkle", 999)
			end, "레벨 없음")
		end)
	end,
}
