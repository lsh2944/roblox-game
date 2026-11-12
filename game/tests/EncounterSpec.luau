--!strict
-- EncounterSpec: 遭遇の計画（種・攻撃者・結果を開始時に確定）と再生イベント列、夜判定
-- 配置: ServerStorage.Tests.EncounterSpec（Rojo: game/tests/EncounterSpec.luau）
-- 依存: deps.CaptureLogic・deps.gd（capture.json・fields.json・spirits.json）
-- 期待値の出典（cwd tools/econ_sim の python3 -c、2026-11-12 の data、シミュ実行なし）:
--   K_max = capture_k_max(rule) = 10（ブロック 21 個）。meadow 出現表 sparkle40・dewdrop35・flower_lamp25・sunset_bird10・shard_light5
--   → u[1]=0.9 は x=103.5 で sunset_bird(★2)、u[1]=0 は sparkle(★1)（sim.py:289-295 の抽選）。
--   weaken_seconds(1,1,2,100) = 10、weaken_vigor_cost(1,2) = 4（= 240 tick）。capture_attempt_bps(2,20) = 7500、(1,100) = 10000、
--   flee_bps(1) = 300、flee_bps(2) = 1500。resolve_encounter_tool(grade, rule, uniforms, wicks, wsec, 0):
--   ★2 [0.9, 0.1, …, K+1:0.5] wicks21 wsec10 → success 2 試行 78 秒 / ★1 → success 1 試行 64 秒 /
--   ★2 K+1:0.01 → flee 1 試行 74 秒 / ★2 wicks1 → wick_out 1 試行 74 秒 / ★2 灯籠 wsec12 → success 2 試行 80 秒
--   夜: rules.night（周期 60 分・開始 30 分・30 分）→ 通算分 mod 60 が 30..59 なら夜

return {
	name = "Encounter",
	run = function(t: any, deps: any)
		local C = deps.CaptureLogic
		local gd = deps.gd
		local rule = gd.capture
		local K = 10

		-- block（1 始まり）: [1] = 種、[1+i] = i 回目の試行、[1+K+i] = i 回目の失敗後の逃走。指定外は 0.5
		local function block(over: { [number]: number }): { number }
			local b = table.create(1 + 2 * K, 0.5)
			for i, v in over do
				b[i] = v
			end
			return b
		end

		local function plan(b: { number }, party: { any }, wicks: number): any
			return C.planEncounter({
				field = gd.fields.meadow,
				night = false,
				block = b,
				rule = rule,
				spirits = gd.spirits,
				party = party,
				wicksAvailable = wicks,
			})
		end

		local sparkleFull = { uid = 1, grade = 1, level = 1, vigorTicks = 6000 }

		t:test("블록 크기 21, 블록이 짧으면 오류", function()
			t:eq(C.blockSize(rule), 21)
			t:throws(function()
				plan(table.create(20, 0.5), {}, 21)
			end, "21")
		end)

		t:test("★2 성공: 동행이 약화(10초·활력 240) → 시도 1 실패 → 시도 2 성공", function()
			local p = plan(block({ [1] = 0.9, [2] = 0.9, [3] = 0.1 }), { sparkleFull }, 21)
			t:eq(p.species, "sunset_bird")
			t:eq({ p.grade, p.weakened, p.attackerUid, p.weakenSeconds, p.vigorCostTicks }, { 2, true, 1, 10, 240 })
			t:eq(p.result, { result = "success", attempts = 2, wicksUsed = 2, seconds = 78, toolsUsed = 0 })
			t:eq(p.durationSeconds, 18)
			t:eq(C.encounterEvents(p, rule), {
				{ phase = "reveal", at = 0, species = "sunset_bird", grade = 2 },
				{ phase = "weaken", at = 0, seconds = 10, assist = false },
				{ phase = "attempt", at = 10, attempt = 1, light = 20, bps = 7500, fleeBps = 300 },
				{ phase = "attempt", at = 14, attempt = 2, light = 20, bps = 7500, fleeBps = 1500 },
				{ phase = "result", at = 18, attempt = 2, result = "success" },
			})
		end)

		t:test("★1은 약화 생략, 1회 시도로 성공(성공률 10000)", function()
			local p = plan(block({ [1] = 0, [2] = 0.99 }), { sparkleFull }, 21)
			t:eq({ p.species, p.weakened, p.attackerUid, p.weakenSeconds, p.vigorCostTicks }, { "sparkle", false, nil, 0, 0 })
			t:eq(p.result.seconds, 64)
			t:eq(C.encounterEvents(p, rule), {
				{ phase = "reveal", at = 0, species = "sparkle", grade = 1 },
				{ phase = "attempt", at = 0, attempt = 1, light = 100, bps = 10000, fleeBps = 300 },
				{ phase = "result", at = 4, attempt = 1, result = "success" },
			})
		end)

		t:test("도망·심지 부족·등롱 보조 약화", function()
			local f = plan(block({ [1] = 0.9, [2] = 0.9, [1 + K + 1] = 0.01 }), { sparkleFull }, 21)
			t:eq({ f.result.result, f.result.attempts, f.result.wicksUsed, f.result.seconds }, { "flee", 1, 1, 74 })
			local w = plan(block({ [1] = 0.9, [2] = 0.9 }), { sparkleFull }, 1)
			t:eq({ w.result.result, w.result.attempts, w.result.wicksUsed, w.result.seconds }, { "wick_out", 1, 1, 74 })
			local ev = C.encounterEvents(w, rule)
			t:eq(ev[#ev], { phase = "result", at = 14, attempt = 1, result = "wick_out" })
			local a = plan(block({ [1] = 0.9, [2] = 0.9, [3] = 0.1 }), {}, 21)
			t:eq({ a.attackerUid, a.weakenSeconds, a.vigorCostTicks, a.result.seconds }, { nil, 12, 0, 80 })
			t:eq(C.encounterEvents(a, rule)[2], { phase = "weaken", at = 0, seconds = 12, assist = true })
		end)

		t:test("밤 판정: 게임 내 시계(매시 30~59분이 밤)", function()
			local n = gd.rules.night
			t:eq({ C.isNight(29, n), C.isNight(30, n), C.isNight(59, n), C.isNight(60, n) }, { false, true, true, false })
		end)
	end,
}
