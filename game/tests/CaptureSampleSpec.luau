--!strict
-- CaptureSampleSpec: 捕獲の標本検査（ServerRng 経由で resolveEasy を等級ごとに 1 万回）と個体値 intInclusive の両端
-- 配置: ServerStorage.Tests.CaptureSampleSpec（Rojo: game/tests/CaptureSampleSpec.luau）
-- 依存: deps.ServerRng・deps.CaptureLogic・deps.gd・deps.sampleRngFactory（Lune = xorshift32、Studio = Roblox Random）
-- 期待値の出典: docs/sinks_capture_impl_plan.md:197-205 の表 = formulas.encounter_expectation(grade, rule)（芯無制限、python3 -c で再確認）
--   ★1 Q=1・E[A]=1 / ★2 Q=0.9787972・E[A]=1.3050629 / ★3 Q=0.8074060・E[A]=2.1530826 / ★4 Q=0.4638520・E[A]=3.0923464
-- 許容幅: 1 万回の標準誤差の約 5 倍（Q: sqrt(Q(1−Q)/10000)。E[A] の標準偏差 ★2 0.602・★3 1.256・★4 1.576 は
--   formulas.resolve_encounter_tool を python3 -c で 10 万回呼んだ標本値）。★1 は確率 1 なので完全一致。
-- Lune（xorshift32、シード 20261112+等級）の実測 2026-11-12: ★2 Q 0.9788・E[A] 1.3032 / ★3 0.8018・2.1981 / ★4 0.4718・3.0832
-- 芯は K_max 個（= 無制限と同じ結果。1 試行 1 個 × 最大 K_max 試行）。

local N = 10000

local EXPECT = {
	{ grade = 1, q = 1, ea = 1, qTol = 0, eaTol = 0 },
	{ grade = 2, q = 0.9787972, ea = 1.3050629, qTol = 0.0073, eaTol = 0.030 },
	{ grade = 3, q = 0.8074060, ea = 2.1530826, qTol = 0.0198, eaTol = 0.063 },
	{ grade = 4, q = 0.4638520, ea = 3.0923464, qTol = 0.0250, eaTol = 0.079 },
}

return {
	name = "CaptureSample",
	run = function(t: any, deps: any)
		local C = deps.CaptureLogic
		local rule = deps.gd.capture

		for i, e in EXPECT do
			t:test(`★{e.grade} 조우당 획득·평균 시도(1만 회)`, function()
				local rng = deps.ServerRng.new(deps.sampleRngFactory(20261112 + i))
				local n = C.blockSize(rule)
				local k = n // 2
				local ok, attempts = 0, 0
				for _ = 1, N do
					local r = C.resolveEasy(e.grade, rule, rng:block("capture", n), k, 0)
					if r.result == "success" then
						ok += 1
					end
					attempts += r.attempts
				end
				local q, ea = ok / N, attempts / N
				t:ok(math.abs(q - e.q) <= e.qTol, `Q={q} 기대 {e.q}±{e.qTol}`)
				t:ok(math.abs(ea - e.ea) <= e.eaTol, `E[A]={ea} 기대 {e.ea}±{e.eaTol}`)
			end)
		end

		t:test("uniform [0,1)·intInclusive(10000,12000)이 양 끝을 모두 냄(5만 회)", function()
			local rng = deps.ServerRng.new(deps.sampleRngFactory(7))
			local ind = deps.gd.rules.individual_stats
			local lo, hi = math.huge, -math.huge
			for _ = 1, 50000 do
				local v = rng:intInclusive("individual", ind.gather_bps_min, ind.gather_bps_max)
				lo, hi = math.min(lo, v), math.max(hi, v)
				local u = rng:uniform("spawn")
				t:ok(u >= 0 and u < 1)
			end
			t:eq({ lo, hi }, { 10000, 12000 })
		end)
	end,
}
