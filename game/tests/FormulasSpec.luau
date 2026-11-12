--!strict
-- FormulasSpec: Formulas の補助（整数除算・安全整数検査・tick 版の弱体化秒）の単体テスト
-- 配置: ServerStorage.Tests.FormulasSpec（Rojo: game/tests/FormulasSpec.luau）
-- 依存: deps.Formulas（実行側が渡す）。黄金ベクトルの照合は VectorRunner が別に行う
-- 期待値の出典: Python の整数演算（python3 -c で // と % を評価、2026-11-11）と
--   formulas.weaken_seconds(4, 1, 4, Fraction(v, 60), capture.json)（sim.py pick_attacker と同じ呼び方）

return {
	name = "Formulas",
	run = function(t: any, deps: any)
		local F = deps.Formulas
		local rule = deps.gd.capture

		t:test("idiv는 Python //와 같다(큰 수·음수)", function()
			t:eq(F.idiv(9007199254740991, 2), 4503599627370495)
			t:eq(F.idiv(9007199254740991, 7), 1286742750677284)
			t:eq(F.imod(9007199254740991, 7), 3)
			t:eq(F.idiv(9007199254740990, 3), 3002399751580330)
			t:eq(F.idiv(9007199254740990, 9007199254740991), 0)
			t:eq(F.idiv(-7, 2), -4)
			t:eq(F.idiv(7, -2), -4)
			t:eq(F.imod(-7, 3), 2)
		end)

		t:test("assertSafe는 2^53 이상·소수·NaN·bool을 거부", function()
			F.assertSafe(0, -9007199254740991, 9007199254740991)
			t:throws(function()
				F.assertSafe(9007199254740992)
			end, "2^53-1")
			t:throws(function()
				F.assertSafe(0.5)
			end, "정수가 아님")
			t:throws(function()
				F.assertSafe(0 / 0)
			end, "정수가 아님")
			t:throws(function()
				F.assertSafe(true :: any)
			end, "정수가 아님")
		end)

		t:test("곱이 2^53-1을 넘으면 FormulaError", function()
			t:throws(function()
				F.slotPowerBps(9007199254740991, 10000, 10000, 0)
			end, "FormulaError")
		end)

		t:test("weakenSecondsTicks: 활력 tick 경계(50점=3000tick)는 Python Fraction 결과와 같다", function()
			-- Python: weaken_seconds(4,1,4,Fraction(3001,60)) = 8, Fraction(3000,60) = 12, Fraction(1,60) = 12
			t:eq(F.weakenSecondsTicks(4, 1, 4, 3001, 60, rule), 8)
			t:eq(F.weakenSecondsTicks(4, 1, 4, 3000, 60, rule), 12)
			t:eq(F.weakenSecondsTicks(4, 1, 4, 1, 60, rule), 12)
			t:eq(F.weakenSecondsTicks(4, 1, 4, 0, 60, rule), -1)
		end)

		-- 期待値の出典: python3 -c で formulas.night_segments を評価（2026-11-11、tests/test_formulas.py と同じ入力）
		t:test("nightSegments: 밤 0분·항상 밤·주기 걸침 밤·잘못된 시계", function()
			t:eq(F.nightSegments(100, 200, 60, 30, 0), { { 100, 200, false } })
			t:eq(F.nightSegments(100, 200, 60, 30, 60), { { 100, 200, true } })
			t:eq(F.nightSegments(0, 60, 60, 50, 20), { { 0, 10, true }, { 10, 50, false }, { 50, 60, true } })
			t:eq(F.nightSegments(50, 50, 60, 30, 30), {})
			for _, bad in { { 0, 0, 0 }, { 60, 60, 30 }, { 60, 30, 61 }, { 60, -1, 30 } } do
				t:throws(function()
					F.nightSegments(0, 10, bad[1], bad[2], bad[3])
				end)
			end
		end)

		t:test("K_max와 난수 블록 크기(1 + 2·K_max = 21, 계획서 4.3)", function()
			t:eq(F.captureKMax(rule), 10)
		end)
	end,
}
