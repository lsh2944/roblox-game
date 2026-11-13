--!strict
-- GatherSpec: 直接採集（S6）。秒単位の積算・開始の検証順・1 秒ごとの再確認（範囲外で終了）・連打で増えない・同行の反映
-- 配置: ServerStorage.Tests.GatherSpec（Rojo: game/tests/GatherSpec.luau）
-- 依存: deps.GatherCalc・GatherService・Activity・Ledger・SaveSchema・Config・Formulas・CaptureLogic・econ・gd
-- 期待値の出典:
-- - 計画書 4.3「total = rate·sec + carry, gained = total // 3600」（秒単位の積算は Luau だけの補助関数）
-- - 採集率: cwd tools/econ_sim の python3 -c（2026-11-12 の data、シミュ実行なし）
--   Economy(Model(load_data('../../data'))).direct_rate(meadow_dew, 'gather_tool', Lv, party) →
--   同行なし Lv1 = 160000、Lv2 = 176000、開始 3 種（sparkle・dewdrop・flower_lamp Lv1）= 210560、sparkle 採集個体値 12000 単独 = 179200
-- - 図鑑ボーナス（2026-11-12 改編）: 新規保存の図鑑 = 開始 3 種 → dew +50bps（dewdrop ★1）。GatherCalc.rate は
--   formulas.dex_scaled_milli(上の値, 50) = 160800・176880・211612・180096（同じ python3 -c で確認）

local T = 1762819200 -- 秒（60 の倍数）

return {
	name = "Gather",
	run = function(t: any, deps: any)
		local GC = deps.GatherCalc
		local E = deps.Net.ErrorCode

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
				radius = deps.Config.GATHER_RADIUS,
				maxGapSeconds = deps.Config.GATHER_MAX_CREDIT_SECONDS,
			})
			return save, svc, act
		end

		t:test("accrueSeconds: 초 단위 적립과 carry(3600으로 나눈 나머지)", function()
			t:eq({ GC.accrueSeconds(160000, 1, 0) }, { 44, 1600 })
			t:eq({ GC.accrueSeconds(210560, 7, 100) }, { 409, 1620 })
			t:eq({ GC.accrueSeconds(0, 100, 5) }, { 0, 5 })
			-- 1 초ずつ 3600 回 = 1 時間分の率ちょうど（端数は失われない）
			local sum, c = 0, 0
			for _ = 1, 3600 do
				local g
				g, c = GC.accrueSeconds(160000, 1, c)
				sum += g
			end
			t:eq({ sum, c }, { 160000, 0 })
			t:throws(function()
				GC.accrueSeconds(-1, 1, 0)
			end)
			t:eq(GC.creditSeconds(T, T + 10, 3), 3, "간격 상한")
			t:eq(GC.creditSeconds(T + 5, T, 3), 0, "시계 역행")
		end)

		t:test("채집 배율: 도구 Lv·동행·개체값(Python direct_rate와 같음)", function()
			local save = newWorld()
			local node = deps.gd.nodes.meadow_dew.node
			t:eq(GC.rate(deps.econ, save, node), 160800, "동행 없음 Lv1(도감 dew +0.5%)")
			save.tool_level = 2
			t:eq(GC.rate(deps.econ, save, node), 176880, "도구 Lv2")
			save.tool_level = 1
			save.party = { "1", "2", "3" }
			t:eq(GC.rate(deps.econ, save, node), 211612, "시작 3종 동행")
			save.party = { "1" }
			save.roster["1"].gather_bps = 12000
			t:eq(GC.rate(deps.econ, save, node), 180096, "sparkle 개체값 12000")
		end)

		t:test("시작 검증 순서: 인자 → 노드 → 필드 해금 → 거리 → 활동 중", function()
			local save, svc, act = newWorld()
			local R = deps.Config.GATHER_RADIUS
			t:eq(svc:start(1, save, 5, 0, T).code, E.BAD_ARG, "nodeId 숫자")
			t:eq(svc:start(1, save, "meadow_dew", 0 / 0, T).code, E.BAD_ARG, "NaN 거리")
			t:eq(svc:start(1, save, "no_node", 0, T).code, E.NOT_FOUND)
			local other: string? = nil
			for id, e in deps.gd.nodes do
				if e.fieldId ~= "meadow" then
					other = id
					break
				end
			end
			t:eq(svc:start(1, save, other, 0, T).code, E.NOT_UNLOCKED, "미해금 필드 노드")
			t:eq(svc:start(1, save, "meadow_dew", R + 0.5, T).code, E.TOO_FAR)
			act:set(1, "encounter")
			t:eq(svc:start(1, save, "meadow_dew", R, T).code, E.BUSY, "조우 중")
			act:clear(1)
			local r = svc:start(1, save, "meadow_dew", R, T)
			t:eq(r.ok, true)
			t:eq(r.data.rate, 160800)
			t:eq(act:get(1), "gather")
		end)

		t:test("1초 재확인: 범위 안이면 적립, 범위 밖이면 그 구간은 인정하지 않고 종료", function()
			local save, svc, act = newWorld()
			svc:start(1, save, "meadow_dew", 0, T)
			for s = 1, 3600 do
				local _, cont = svc:tick(1, save, T + s, true)
				t:ok(cont)
			end
			t:eq(save.wallet.dew, 160800, "1시간 = 160.8/시")
			t:eq(save.carry[GC.carryKey("dew")], 0)
			local g, cont = svc:tick(1, save, T + 3601, false)
			t:eq({ g, cont }, { 0, false })
			t:eq(save.wallet.dew, 160800, "범위 밖 구간 미인정")
			t:eq(svc:session(1), nil)
			t:eq(act:get(1), nil)
		end)

		t:test("연타: 같은 초에 시작·종료를 반복해도 산출 0, 다른 노드로 바꾸면 이전 노드를 정산", function()
			local save, svc = newWorld()
			for _ = 1, 50 do
				svc:start(1, save, "meadow_dew", 0, T)
				svc:stop(1, save, T)
			end
			t:eq(save.wallet.dew, nil)
			svc:start(1, save, "meadow_dew", 0, T)
			svc:start(1, save, "meadow_bloom", 0, T + 90) -- tick が来ていない間は上限 3 秒だけ認定（settle・stop も tick と同じ上限）
			t:eq(save.wallet.dew, (160800 * 3) // 3600, "간격 상한 3초만")
			t:eq(svc:session(1).resource, "bloom")
		end)

		t:test("동행 변경: settle(이전 배율) 뒤 refresh(새 배율)", function()
			local save, svc = newWorld()
			svc:start(1, save, "meadow_dew", 0, T)
			svc:tick(1, save, T + 1, true)
			svc:settle(1, save, T + 2)
			save.party = { "1", "2", "3" }
			svc:refresh(1, save)
			t:eq(svc:session(1).rate, 211612)
			svc:tick(1, save, T + 3, true)
			local g1, c1 = GC.accrueSeconds(160800, 2, 0)
			local g2, c2 = GC.accrueSeconds(211612, 1, c1)
			t:eq(save.wallet.dew, g1 + g2)
			t:eq(save.carry[GC.carryKey("dew")], c2)
		end)
	end,
}
