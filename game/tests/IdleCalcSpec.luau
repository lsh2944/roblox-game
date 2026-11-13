--!strict
-- IdleCalcSpec: 放置精算（オフライン上限・carry の持ち越し・家の素材の日単位積算・夜区間の分割）
-- 配置: ServerStorage.Tests.IdleCalcSpec（Rojo: game/tests/IdleCalcSpec.luau）
-- 依存: deps.IdleCalc、deps.econ、deps.GameData、deps.Economy、deps.loadDocs、deps.TestKit
-- 期待値の出典（cwd tools/econ_sim の python3 -c、2026-11-12 の data（図鑑改編後）、シミュ実行なし）:
--   図鑑 = 開始 3 種 → Economy.dex_map の resource_output = {dew 50, bloom 100}
--   rate = Economy.facility_rate('dew_spring', 1, 開始 3 種, False, 50) = 63516
--   formulas.accrue_milli(63516, 720, 0) = (762192, 0)、divmod(1500 × 720, 1440) = (750, 0)
--   accrue_milli(63516, 7, 0) = (7410, 12)、accrue_milli(63516, 53, 12) = (56106, 0)
--   divmod(1500 × 7, 1440) = (7, 420)、divmod(1500 × 53 + 420, 1440) = (55, 720)
--   研究フック: research_scaled_milli(63516, 400) = 66056
--   夜: moon_fox の night_output_bps を 2000 に変えた Model で facility_rate('dew_spring', 2, [moon_fox, sparkle], 夜/昼, 200)
--   （図鑑 {moon_fox, sparkle} の dew = moon_fox ★3 の 200、改編前の 2 種 × 100 と同じ値）
--   = 78988 / 69564、night_segments(29000000, 29000780, 60, 30, 30)（rules.night ゲーム内時計、2026-11-11 決定）
--   = 27 区間（昼 10 分から始まり夜 390 分・昼 390 分）→ 区間ごとに accrue_milli を carry 付きで合計 965588、carry 0
--   家の素材: hunt_cave(★3) 1200/日 × 780 分 = (650, 0)、hunt_meadow(★1) 500/日 × 780 分 = (270, 1200)

local BASE = 29000000 -- UTC 通算分（mod 60 = 20、ゲーム内時計の昼区間の途中）

local function spirit(species: string): any
	return { species = species, level = 1, gather_bps = 10000, combat_bps = 10000 }
end

local function startInput(): any
	return {
		wallet = {},
		carry = {},
		settledMin = BASE,
		offlineSinceMin = nil,
		offlineCapHours = 12,
		facilities = {
			dew_spring = { level = 1, assigned = { "1", "2", "3" } },
			bloom_garden = { level = 1, assigned = {} },
		},
		roster = { ["1"] = spirit("sparkle"), ["2"] = spirit("dewdrop"), ["3"] = spirit("flower_lamp") },
		dex = { sparkle = 0, dewdrop = 0, flower_lamp = 0 }, -- save.dex と同じ形（種 → 初登録時刻）
	}
end

return {
	name = "IdleCalc",
	run = function(t: any, deps: any)
		local I = deps.IdleCalc
		local econ = deps.econ

		t:test("creditRange: 온라인·오프라인 상한·시계 역행", function()
			t:eq({ I.creditRange(BASE, BASE + 30, nil, 12) }, { BASE, BASE + 30, 0 })
			t:eq({ I.creditRange(BASE, BASE + 780, BASE, 12) }, { BASE, BASE + 720, 60 })
			t:eq({ I.creditRange(BASE, BASE + 300, BASE, 12) }, { BASE, BASE + 300, 0 })
			t:eq({ I.creditRange(BASE, BASE - 5, nil, 12) }, { BASE, BASE, 0 })
			-- 精算済み時刻が既に上限を過ぎている: 認定 0、失効は精算済み以降だけ
			t:eq({ I.creditRange(BASE + 800, BASE + 900, BASE, 12) }, { BASE + 800, BASE + 800, 100 })
		end)

		t:test("오프라인 13시간 → 12시간만 인정(시작 3종, 이슬 샘 Lv1)", function()
			local input = startInput()
			input.offlineSinceMin = BASE
			local r = I.settle(econ, input, BASE + 780)
			t:eq(r.creditedMinutes, 720)
			t:eq(r.lostMinutes, 60)
			t:eq(r.newSettledMin, BASE + 780)
			t:eq(input.wallet, { dew = 762192, hunt_meadow = 750 })
			t:eq(input.carry["idle:dew"], 0)
			t:eq(input.carry["home:g1:hunt_meadow"], 0)
		end)

		t:test("carry 이월: 7분 + 53분 = 1시간분과 같다", function()
			local input = startInput()
			local r1 = I.settle(econ, input, BASE + 7)
			t:eq(r1.gained, { dew = 7410, hunt_meadow = 7 })
			t:eq(input.carry["idle:dew"], 12)
			t:eq(input.carry["home:g1:hunt_meadow"], 420)
			input.settledMin = r1.newSettledMin
			local r2 = I.settle(econ, input, BASE + 60)
			t:eq(r2.gained, { dew = 56106, hunt_meadow = 55 })
			t:eq(input.wallet, { dew = 63516, hunt_meadow = 62 })
			t:eq(input.carry["idle:dew"], 0)
			t:eq(input.carry["home:g1:hunt_meadow"], 720)
		end)

		t:test("시계가 거꾸로 가면 적립하지 않음", function()
			local input = startInput()
			local r = I.settle(econ, input, BASE - 10)
			t:eq(r.creditedMinutes, 0)
			t:eq(r.newSettledMin, BASE)
			t:eq(input.wallet, {})
		end)

		t:test("밤/낮 구간별 생산율로 나눠 적립(밤 특성 2000bps로 바꾼 data)", function()
			local docs = deps.loadDocs()
			for _, s in docs.spirits.spirits do
				if s.id == "moon_fox" then
					s.traits[1].value_bps = 2000
				end
			end
			local econ2 = deps.Economy.new(deps.GameData.build(docs))
			local input = startInput()
			input.facilities = { dew_spring = { level = 2, assigned = { "a", "b" } } }
			input.roster = { a = spirit("moon_fox"), b = spirit("sparkle") }
			input.dex = { moon_fox = 0, sparkle = 0 }
			t:eq(I.idleRates(econ2, input, true), { dew = 78988 })
			t:eq(I.idleRates(econ2, input, false), { dew = 69564 })
			local r = I.settle(econ2, input, BASE + 780)
			t:eq(r.gained, { dew = 965588, hunt_cave = 650, hunt_meadow = 270 })
			t:eq(input.carry["idle:dew"], 0)
			t:eq(input.carry["home:g3:hunt_cave"], 0)
			t:eq(input.carry["home:g1:hunt_meadow"], 1200)
		end)

		t:test("연구 배율 hook(자원별 bps, 기본 0)", function()
			local input = startInput()
			-- 空の施設（bloom_garden）も 0 で並ぶ（sim.py idle_rates と同じ）
			t:eq(I.idleRates(econ, input, false), { dew = 63516, bloom = 0 })
			input.researchIdleBps = { dew = 400 }
			-- research_scaled_milli(63516, 400) = 63516 × 10400 // 10000 = 66056
			t:eq(I.idleRates(econ, input, false), { dew = 66056, bloom = 0 })
		end)

		t:test("도감 보너스는 자원별(시설은 생산 자원, 집 재료는 그 사냥 재료)", function()
			local input = startInput()
			input.facilities.bloom_garden.assigned = { "3" }
			input.facilities.dew_spring.assigned = { "1", "2" }
			local raw = I.idleRates(econ, { facilities = input.facilities, roster = input.roster, dex = {} } :: any, false)
			local rates = I.idleRates(econ, input, false)
			-- 開始 3 種の図鑑: dew +50（dewdrop）、bloom +100（sparkle・flower_lamp）
			t:eq(rates.dew, raw.dew * 10050 // 10000)
			t:eq(rates.bloom, raw.bloom * 10100 // 10000)
			t:eq(I.homeDetail(econ, input), { { resource = "hunt_meadow", grade = 1, milli = 1500 } }, "hunt_meadow 보너스 없음")
			input.dex.sunset_bird = 0 -- hunt_meadow +100
			t:eq(I.homeDetail(econ, input), { { resource = "hunt_meadow", grade = 1, milli = 1515 } })
		end)

		t:test("배치된 uid가 보관함에 없으면 오류", function()
			local input = startInput()
			input.facilities.dew_spring.assigned = { "99" }
			t:throws(function()
				I.settle(econ, input, BASE + 10)
			end, "uid=99")
		end)
	end,
}
