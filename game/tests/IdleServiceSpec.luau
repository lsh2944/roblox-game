--!strict
-- IdleServiceSpec: 保存データに対する精算（オフライン上限 12 時間・時計逆行で無積算・保存前のオンライン精算）と Clock のオフセット
-- 配置: ServerStorage.Tests.IdleServiceSpec（Rojo: game/tests/IdleServiceSpec.luau）
-- 依存: deps.IdleService・deps.IdleCalc・deps.econ・deps.SaveSchema・deps.Clock・deps.Formulas・deps.CaptureLogic・deps.Config・deps.TestKit・deps.gd
-- 失敗時の不変: S4 リビュー Nit（2026-11-11 進行記録）「精算は写しで計算し、成功したときだけ一括反映」。
-- 期待値の出典（cwd tools/econ_sim の python3 -c、2026-11-11 の data、シミュ実行なし。IdleCalcSpec と同じ値）:
--   Economy.facility_rate('dew_spring', 1, 開始 3 種, False, 300) = 65096 → accrue_milli(65096, 720, 0) = (781152, 0)、
--   家の素材 hunt_meadow ★1 500/日 × 3 体: divmod(1500 × 720, 1440) = (750, 0)。夜の効果は data で 0（昼夜とも同じ率）

local T = 1762819200 -- 秒（60 の倍数）

return {
	name = "IdleService",
	run = function(t: any, deps: any)
		local svc = deps.IdleService.new(deps.IdleCalc, deps.econ)
		local ctx = {
			gd = deps.gd,
			startSpirits = deps.Config.START_SPIRITS,
			milli = deps.Formulas.MILLI,
			vigorTick = deps.CaptureLogic.VIGOR_TICK,
		}
		local function placed(): any
			local s = deps.SaveSchema.newSave(ctx, T)
			s.facilities.dew_spring.assigned = { "1", "2", "3" }
			return s
		end

		t:test("오프라인 13시간 → 12시간만 인정(신규 상태 + 시작 3종 이슬 샘 배치)", function()
			local s = placed()
			local r = svc:settle(s, T + 13 * 3600, true)
			t:eq(r.creditedMinutes, 720)
			t:eq(r.lostMinutes, 60)
			t:eq(s.wallet, { wick = 21000, dew = 781152, hunt_meadow = 750 })
			t:eq(s.settled_min, T // 60 + 780)
			t:eq(s.carry["idle:dew"], 0)
		end)

		t:test("now < settled_min이면 적립하지 않고 settled_min을 되돌리지 않음", function()
			local s = placed()
			s.settled_min = T // 60 + 100
			local r = svc:settle(s, T + 60 * 30, true)
			t:eq(r.creditedMinutes, 0)
			t:eq(s.wallet, { wick = 21000 })
			t:eq(s.settled_min, T // 60 + 100)
		end)

		t:test("저장 전 온라인 정산: 상한 없이 인정하고 last_online_at 기록", function()
			local s = placed()
			local r = svc:beforeSave(s, T + 13 * 3600)
			t:eq(r.creditedMinutes, 780)
			t:eq(r.lostMinutes, 0)
			t:eq(s.last_online_at, T + 13 * 3600)
			t:eq(s.settled_min, T // 60 + 780)
		end)

		t:test("정산 중 오류면 wallet·carry·settled_min·last_online_at 모두 원래대로(부분 적립 없음)", function()
			-- (a) 実際の IdleCalc: 露の積算で 2^53−1 を超えて assertSafe が error
			local s = placed()
			s.wallet.dew = 9007199254740991 - 1
			s.carry["idle:dew"] = 7
			local before = deps.TestKit.deepCopy(s)
			local walletRef, carryRef = s.wallet, s.carry
			t:eq((pcall(function()
				svc:beforeSave(s, T + 13 * 3600)
			end)), false)
			t:eq(s, before)
			-- (b) 途中まで書き換えてから error する IdleCalc（どの資源から積むかの順序に依らず確かめる）
			local fake = {
				settle = function(_econ: any, input: any, _nowMin: number): any
					input.wallet.dew = 5
					input.wallet.bloom = 9
					input.carry["idle:dew"] = 59
					error("정산 도중 실패 흉내")
				end,
			}
			local s2 = placed()
			local before2 = deps.TestKit.deepCopy(s2)
			t:eq((pcall(function()
				deps.IdleService.new(fake, deps.econ):settle(s2, T + 3600, true)
			end)), false)
			t:eq(s2, before2)
			-- 成功時は同じテーブルへ反映（参照の同一性を保つ）
			local s3 = placed()
			local w3, c3 = s3.wallet, s3.carry
			svc:settle(s3, T + 13 * 3600, true)
			t:eq(s3.wallet == w3 and s3.carry == c3, true)
			t:eq(w3, { wick = 21000, dew = 781152, hunt_meadow = 750 })
			t:eq(walletRef == s.wallet and carryRef == s.carry, true)
		end)

		t:test("Clock: Studio 오프셋은 정수 초만, 그 밖은 0", function()
			local C = deps.Clock
			t:eq(C.new(function()
				return T + 0.9
			end):now(), T)
			local off: any = 3600
			local c = C.new(function()
				return T
			end, function()
				return off
			end)
			t:eq(c:now(), T + 3600)
			t:eq(c:nowMin(), (T + 3600) // 60)
			for _, bad in { 1.5, 0 / 0, "60", 1e12, true } do
				off = bad
				t:eq(c:now(), T, `offset={tostring(bad)}`)
			end
			off = nil
			t:eq(c:now(), T)
			off = -1000
			t:eq(C.new(function()
				return 100
			end, function()
				return off
			end):now(), 0)
		end)
	end,
}
