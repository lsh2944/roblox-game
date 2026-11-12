--!strict
-- CaptureLogicSpec: 自動攻撃者の同点処理・活力の遅延評価・種の抽選・遭遇結果の確定
-- 配置: ServerStorage.Tests.CaptureLogicSpec（Rojo: game/tests/CaptureLogicSpec.luau）
-- 依存: deps.CaptureLogic、deps.gd（rule = capture.json）
-- 期待値の出典: 2026-11-11 の data で Python Simulator のメソッドを直接呼んだ結果（シミュ実行なし）。
--   Simulator(...) を作り _add_spirit で shadow_lantern(★4)=uid4, shard_light(★2)=uid5, sunset_bird(★2)=uid6,
--   sparkle(★1)=uid7, shadow_lantern=uid8 を加え、state.vigor を設定して sim.pick_attacker(party, 対象等級, t) を評価。
--   use_vigor / vigor_at、capture_table('meadow') の抽選ループ（sim.py:289-295）、formulas.resolve_encounter_tool も同様。

local function A(uid: number, grade: number, level: number, vigorTicks: number): any
	return { uid = uid, grade = grade, level = level, vigorTicks = vigorTicks }
end

return {
	name = "CaptureLogic",
	run = function(t: any, deps: any)
		local C = deps.CaptureLogic
		local rule = deps.gd.capture

		local function pick(party: { any }, target: number): { any }
			local u, sec, cost = C.pickAttacker(party, target, rule)
			return { u or "lantern", sec, cost }
		end

		t:test("pickAttacker: 활력 소비 최소 우선, 활력 ≤50은 후보 밖, 전원 0이면 등롱", function()
			t:eq(pick({ A(4, 4, 1, 6000), A(5, 2, 1, 6000) }, 2), { 5, 8, 240 }, "A")
			t:eq(pick({ A(4, 4, 1, 6000), A(5, 2, 1, 3000) }, 2), { 4, 6, 480 }, "B")
			t:eq(pick({ A(4, 4, 1, 0), A(5, 2, 1, 0) }, 2), { "lantern", 12, 0 }, "C")
		end)

		t:test("pickAttacker 동점: 비용 → 초 → 활력 높은 쪽 → uid 작은 쪽(순서 무관)", function()
			t:eq(pick({ A(6, 2, 1, 5400), A(5, 2, 1, 6000) }, 2), { 5, 8, 240 }, "D 활력")
			t:eq(pick({ A(5, 2, 1, 6000), A(6, 2, 1, 5400) }, 2), { 5, 8, 240 }, "D 순서 반대")
			t:eq(pick({ A(6, 2, 1, 6000), A(5, 2, 1, 6000) }, 2), { 5, 8, 240 }, "E uid")
		end)

		t:test("pickAttacker 대체 경로: 후보 없음 → 가장 빠른 동행(등롱 12초보다 빠를 때만)", function()
			t:eq(pick({ A(5, 2, 1, 2400), A(4, 4, 1, 2400), A(6, 2, 1, 2400) }, 2), { 4, 8, 480 }, "F")
			t:eq(pick({ A(7, 1, 1, 6000) }, 4), { "lantern", 12, 0 }, "G ★1→★4는 12초")
			t:eq(pick({ A(8, 4, 1, 2400), A(4, 4, 1, 1800) }, 2), { 8, 8, 480 }, "H 활력 높은 쪽")
			t:eq(pick({ A(8, 4, 1, 2400), A(4, 4, 1, 2400) }, 2), { 4, 8, 480 }, "H2 uid")
		end)

		t:test("pickAttacker: 레벨 효과·활력 tick 경계", function()
			t:eq(pick({ A(7, 1, 11, 6000) }, 2), { 7, 10, 240 }, "I Lv11 ★1")
			t:eq(pick({ A(5, 2, 1, 3001) }, 2), { 5, 8, 240 }, "J 3001tick은 50점 초과")
		end)

		t:test("활력 지연 평가(회복 20tick/분, 상한 6000)와 소비", function()
			t:eq(C.vigorAt(600, 420, 450, rule), 1200)
			t:eq(C.vigorAt(600, 420, 1420, rule), 6000)
			t:eq(C.vigorAt(600, 420, 400, rule), 600, "과거 시각은 그대로")
			t:eq({ C.useVigor(6000, 420, 430, 240, 432, rule) }, { 5760, 432 })
			t:eq({ C.useVigor(1000, 500, 450, 2000, 460, rule) }, { 0, 500 })
		end)

		-- 未来時刻の上限（2026-11-12 決定）。期待値は capture.json から手計算: weaken.max_seconds 12・assist_seconds 12、
		-- attempt_seconds 4、K_max 10（flee 300 + 1200×9 ≥ 10000）、encounter_base_seconds 60 → 最長遭遇 12 + 4×10 = 52 秒、出現待ち 112 秒
		t:test("미래 시각 상한: 최장 조우 52초·출현 대기 112초, 상한 정확히는 유지·1 초과는 now로", function()
			t:eq({ C.maxEncounterSeconds(rule), C.maxSpawnAheadSeconds(rule) }, { 52, 112 })
			t:eq({ C.clampFuture(1112, 1000, 112) }, { 1112, false })
			t:eq({ C.clampFuture(1113, 1000, 112) }, { 1000, true })
			t:eq({ C.clampFuture(5, 1000, 112) }, { 5, false }, "과거는 그대로")
			-- vigor_min ≤ (now + 52) // 60。now = 600 → 상한 10분, now = 610 → (662)//60 = 11분
			t:eq({ C.clampVigorMin(10, 600, rule) }, { 10, false })
			t:eq({ C.clampVigorMin(11, 600, rule) }, { 10, true })
			t:eq({ C.clampVigorMin(11, 610, rule) }, { 11, false })
			t:eq({ C.clampVigorMin(12, 610, rule) }, { 10, true })
		end)

		t:test("출현 표·종 추첨(sim.py 루프와 같은 경계)", function()
			local tbl = C.captureTable(deps.gd.fields.meadow, false)
			t:eq(#tbl, 5)
			t:eq(C.pickSpecies(tbl, 0), "sparkle")
			t:eq(C.pickSpecies(tbl, 39.999 / 115), "sparkle")
			t:eq(C.pickSpecies(tbl, 40 / 115), "dewdrop")
			t:eq(C.pickSpecies(tbl, 0.5), "dewdrop")
			t:eq(C.pickSpecies(tbl, 0.99), "shard_light")
			t:eq(C.pickSpecies(tbl, 0.999999), "shard_light")
			t:eq(C.pickSpecies({}, 0.5), nil)
		end)

		t:test("resolveEasy: 블록 21개(종 1 + 시도·도망 각 10), 결과는 시작 시 확정", function()
			t:eq(C.blockSize(rule), 21)
			local function block(rest: { number }): { number }
				local b = { 0.5 }
				for _, x in rest do
					table.insert(b, x)
				end
				return b
			end
			local u1 = { 0.99, 0.1, 0.99, 0.99, 0.99, 0.99, 0.99, 0.99, 0.99, 0.99 }
			for _ = 1, 10 do
				table.insert(u1, 0.9)
			end
			local r = C.resolveEasy(4, rule, block(u1), 20, 8)
			t:eq({ r.result, r.attempts, r.wicksUsed, r.seconds, r.toolsUsed }, { "success", 2, 2, 76, 0 })
			local u2 = {}
			for i = 1, 20 do
				u2[i] = if i <= 10 then 0.6 else 0.5
			end
			r = C.resolveEasy(2, rule, block(u2), 3, 8)
			t:eq({ r.result, r.attempts, r.wicksUsed, r.seconds }, { "success", 1, 1, 72 })
			local u3 = table.create(20, 0.999)
			r = C.resolveEasy(1, rule, block(u3), 0, 0)
			t:eq({ r.result, r.attempts, r.wicksUsed, r.seconds }, { "wick_out", 0, 0, 60 })
			t:throws(function()
				C.resolveEasy(4, rule, { 0.5, 0.5 }, 20, 8)
			end, "21")
		end)
	end,
}
