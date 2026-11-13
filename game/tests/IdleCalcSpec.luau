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
-- 帰還要約の精霊別配分（2026-11-13）の期待値: 同じ data で econ_sim の Economy.slot_power・facility_rate と
--   formulas.night_segments・accrue_milli を python3 -c で呼び、Python で別に書いた最大剰余法（同点は並び順）で配った値:
--   開始 3 種の昼 power（dew）= sparkle 50000・dewdrop 72000・flower_lamp 36000
--   → 762192 を {"1": 241200, "2": 347328, "3": 173664}、7 分の 7410 を {2345, 3377, 1688}、hunt_meadow 7 を {3, 2, 2}（同点 uid 昇順）
--   夜の例（moon_fox 2000bps）: 昼 452166・夜 513422、power 昼 {a 105000, b 50000}・夜 {a 126000, b 50000} → {a 673869, b 291719}
--   2 施設が同じ資源（bloom_garden.produces を dew に変えた data）: 施設率 dew_spring[sparkle,dewdrop] 49044・bloom_garden[flower_lamp] 14472、
--   7 分 7410 → 施設 {5722, 1688} → dew_spring 内 {"1": 2345, "2": 3377}

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

		-- ---- 帰還要約: 精霊別配分 ----

		local function sumByRes(by: any): { [string]: number }
			local out: { [string]: number } = {}
			for _, m in by do
				for res, v in m do
					out[res] = (out[res] or 0) + v
				end
			end
			return out
		end

		t:test("정령별 배분: 오프라인 13시간(시작 3종) 합계 = gained, 기존 결과 불변", function()
			local a, b = startInput(), startInput()
			a.offlineSinceMin, b.offlineSinceMin = BASE, BASE
			local ra = I.settle(econ, a, BASE + 780)
			local rb = I.settle(econ, b, BASE + 780, true)
			t:eq(ra.parts, nil)
			t:eq(a.wallet, b.wallet)
			t:eq(a.carry, b.carry)
			for _, k in { "fromMin", "toMin", "creditedMinutes", "lostMinutes", "gained", "newSettledMin" } do
				t:eq((rb :: any)[k], (ra :: any)[k], k)
			end
			local by = I.spiritBreakdown(econ, b, rb.parts :: any)
			t:eq(by, {
				["1"] = { dew = 241200, hunt_meadow = 250 },
				["2"] = { dew = 347328, hunt_meadow = 250 },
				["3"] = { dew = 173664, hunt_meadow = 250 },
			})
			t:eq(sumByRes(by), rb.gained)
		end)

		t:test("정령별 배분: 동점 나머지는 uid 오름차순, 결정성", function()
			local input = startInput()
			local r = I.settle(econ, input, BASE + 7, true)
			t:eq(r.gained, { dew = 7410, hunt_meadow = 7 })
			local by = I.spiritBreakdown(econ, input, r.parts :: any)
			t:eq(by, {
				["1"] = { dew = 2345, hunt_meadow = 3 },
				["2"] = { dew = 3377, hunt_meadow = 2 },
				["3"] = { dew = 1688, hunt_meadow = 2 },
			})
			-- 配置の並び順を変えても同じ（同点の判定は配置順ではなく uid）
			local input2 = startInput()
			input2.facilities.dew_spring.assigned = { "3", "1", "2" }
			local r2 = I.settle(econ, input2, BASE + 7, true)
			t:eq(I.spiritBreakdown(econ, input2, r2.parts :: any), by)
			-- 同じ入力なら同じ結果
			t:eq(I.spiritBreakdown(econ, input, r.parts :: any), by)
		end)

		t:test("apportion·uidLess: 최대 나머지, 동점은 앞쪽, 10진 uid는 숫자 순", function()
			t:eq(I.apportion(7, { 1, 1, 1 }), { 3, 2, 2 })
			t:eq(I.apportion(10, { 1, 2, 2 }), { 2, 4, 4 })
			t:eq(I.apportion(5, { 0, 3, 0, 3 }), { 0, 3, 0, 2 })
			t:eq(I.apportion(0, { 0, 0 }), { 0, 0 })
			t:throws(function()
				I.apportion(3, { 0, 0 })
			end, "가중치 합 0")
			t:eq(I.uidLess("9", "10"), true)
			t:eq(I.uidLess("10", "9"), false)
			t:eq(I.uidLess("2", "a"), true)
			t:eq(I.uidLess("a", "b"), true)
			-- uid "10" と "9" が同点: 数値順で "9" が先に端数をもらう
			local input = startInput()
			input.facilities.dew_spring.assigned = { "10", "9" }
			input.roster = { ["9"] = spirit("sparkle"), ["10"] = spirit("sparkle") }
			input.dex = { sparkle = 0 }
			local r = I.settle(econ, input, BASE + 7, true)
			local by = I.spiritBreakdown(econ, input, r.parts :: any)
			t:eq(r.gained.hunt_meadow, 4)
			t:eq(by["9"].hunt_meadow, 2)
			t:eq(by["10"].hunt_meadow, 2)
			t:eq(by["9"].dew - by["10"].dew, r.gained.dew % 2)
			t:eq(sumByRes(by), r.gained)
		end)

		t:test("정령별 배분: 밤/낮 power 변화 반영 + 사냥 재료(밤 특성 2000bps data)", function()
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
			local r = I.settle(econ2, input, BASE + 780, true)
			local parts = r.parts :: any
			t:eq(parts.idle[false], { dew = 452166 })
			t:eq(parts.idle[true], { dew = 513422 })
			local by = I.spiritBreakdown(econ2, input, parts)
			-- 昼の比（105000:50000）だけで配ると a = 654108 になる。夜の power 126000 を反映して 673869
			t:eq(by, {
				a = { dew = 673869, hunt_cave = 650 },
				b = { dew = 291719, hunt_meadow = 270 },
			})
			t:eq(sumByRes(by), r.gained)
		end)

		t:test("정령별 배분: 같은 자원을 만드는 시설이 둘이면 시설률 → 배치 power 순서로", function()
			local docs = deps.loadDocs()
			for _, f in docs.facilities.facilities do
				if f.id == "bloom_garden" then
					f.produces = "dew"
				end
			end
			local econ3 = deps.Economy.new(deps.GameData.build(docs))
			local input = startInput()
			input.facilities.dew_spring.assigned = { "1", "2" }
			input.facilities.bloom_garden.assigned = { "3" }
			local r = I.settle(econ3, input, BASE + 7, true)
			t:eq(r.gained.dew, 7410)
			local by = I.spiritBreakdown(econ3, input, r.parts :: any)
			t:eq(by["1"].dew, 2345)
			t:eq(by["2"].dew, 3377)
			t:eq(by["3"].dew, 1688)
			t:eq(sumByRes(by), r.gained)
		end)

		t:test("정령별 배분: 빈 시설·0분 구간·연구 배율", function()
			local input = startInput()
			input.facilities.dew_spring.assigned = {}
			local r = I.settle(econ, input, BASE + 600, true)
			t:eq(r.gained, {})
			t:eq(I.spiritBreakdown(econ, input, r.parts :: any), {})
			local input2 = startInput()
			local r2 = I.settle(econ, input2, BASE, true)
			t:eq(r2.creditedMinutes, 0)
			t:eq(I.spiritBreakdown(econ, input2, r2.parts :: any), {})
			-- 研究倍率は資源単位の共通倍率: 合計は gained と一致し、比は power の比（50000:72000）のまま
			-- （昼・夜それぞれで端数を配るので、1 体あたり最大 ±1 × 2 区分のずれ）
			local input3 = startInput()
			input3.researchIdleBps = { dew = 400 }
			local r3 = I.settle(econ, input3, BASE + 780, true)
			local by3 = I.spiritBreakdown(econ, input3, r3.parts :: any)
			t:eq(r3.gained.dew, 858728)
			t:eq(sumByRes(by3), r3.gained)
			t:eq(math.abs(by3["2"].dew * 50000 // 72000 - by3["1"].dew) <= 2, true)
		end)

		t:test("returnReport: 기여 큰 순 정렬, 0 제외, 경과 60분 경계", function()
			local input = startInput()
			input.offlineSinceMin = BASE
			local r = I.settle(econ, input, BASE + 780, true)
			local by = I.spiritBreakdown(econ, input, r.parts :: any)
			local rep = I.returnReport(input.roster, r, by, 780, 60, 12)
			t:eq(rep.show, true)
			t:eq(rep.offlineMinutes, 780)
			t:eq(rep.creditedMinutes, 720)
			t:eq(rep.lostMinutes, 60)
			t:eq(rep.offlineCapHours, 12)
			t:eq(rep.gained, { dew = 762192, hunt_meadow = 750 })
			t:eq(rep.gained ~= r.gained, true, "gained는 사본")
			t:eq(rep.spirits, {
				{ uid = "2", species = "dewdrop", resources = { dew = 347328, hunt_meadow = 250 }, total = 347578 },
				{ uid = "1", species = "sparkle", resources = { dew = 241200, hunt_meadow = 250 }, total = 241450 },
				{ uid = "3", species = "flower_lamp", resources = { dew = 173664, hunt_meadow = 250 }, total = 173914 },
			})
			t:eq(I.returnReport(input.roster, r, by, 59, 60, 12).show, false)
			t:eq(I.returnReport(input.roster, r, by, 60, 60, 12).show, true)
			t:eq(I.returnReport(input.roster, r, by, -5, 60, 12).offlineMinutes, 0)
			-- 同点の total は uid 昇順、寄与 0 の精霊は入れない
			local rep2 = I.returnReport(input.roster, r, { ["3"] = { dew = 5 }, ["1"] = { dew = 5 }, ["2"] = { dew = 0 } }, 60, 60, 12)
			t:eq(#rep2.spirits, 2)
			t:eq(rep2.spirits[1].uid, "1")
			t:eq(rep2.spirits[2].uid, "3")
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
