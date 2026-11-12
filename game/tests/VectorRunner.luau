--!strict
-- VectorRunner: data/test_vectors.json の黄金ベクトルを Formulas で実行して照合する
-- 配置: ServerStorage.Tests.VectorRunner（Rojo: game/tests/VectorRunner.luau）
-- 依存: なし（Formulas とベクトル文書は引数で受け取る。Studio の Dev/TestRunner と Lune の lune_run.luau が共用）
--
-- 規則（計画書 docs/game_mvp1_impl_plan.md 5 節）:
-- - CALL にある fn は実行して深い比較（PASS/FAIL）
-- - PYTHON_ONLY にある fn は SKIP（有理数・2^53 超の Python 専用 30 件）
-- - どちらにも無い fn は FAIL（新しいベクトルが黙って抜けるのを防ぐ）

local VectorRunner = {}

export type Summary = {
	pass: number,
	skip: number,
	fail: number,
	failures: { string },
	byFn: { [string]: { pass: number, skip: number, fail: number } },
}

-- Python 専用（formulas.py の Fraction・累乗）。ゲームは generated 表を引くか、分析専用なので移植しない
VectorRunner.PYTHON_ONLY = table.freeze({
	exp_ceil_cost = true,
	exp_ceil_capped_cost = true,
	linear_ceil_capped_cost = true,
	capture_success_per_encounter = true,
	geometric_quantile = true,
	g2_ratio = true,
	direct_share = true,
	encounter_expectation = true,
})

local function encounterArray(r: any, withTools: boolean): { any }
	local out: { any } = { r.result, r.attempts, r.wicksUsed, r.seconds }
	if withTools then
		table.insert(out, r.toolsUsed)
	end
	return out
end

-- fn 名 → (Formulas, args) -> JSON 比較可能な値（formulas.py VECTOR_FUNCS と同じ引数名）
local CALL: { [string]: (any, any) -> any } = {
	linear_milestone_bps = function(F, a)
		return F.linearMilestoneBps(a.per_level_bps, a.level, a.milestones)
	end,
	slot_power_bps = function(F, a)
		return F.slotPowerBps(a.gather, a.ability_bps, a.aptitude_bps, a.trait_bps)
	end,
	idle_rate_milli_per_hour = function(F, a)
		return F.idleRateMilliPerHour(a.base_per_hour, a.facility_mult_bps, a.slot_powers_bps, a.gather_ref)
	end,
	companion_bonus_bps = function(F, a)
		return F.companionBonusBps(a.companion_powers_bps, a.k_bps, a.gather_ref)
	end,
	direct_rate_milli_per_hour = function(F, a)
		return F.directRateMilliPerHour(a.node_per_hour, a.tool_mult_bps, a.companion_bonus)
	end,
	research_scaled_milli = function(F, a)
		return F.researchScaledMilli(a.amount_milli, a.research_bps)
	end,
	idle_dex_research_milli = function(F, a)
		return F.idleDexResearchMilli(a.raw_milli, a.dex_bps, a.research_bps)
	end,
	party_power_bps = function(F, a)
		return F.partyPowerBps(a.members)
	end,
	hunt_rate_milli_per_hour = function(F, a)
		return F.huntRateMilliPerHour(a.drop_per_hour, a.party_power, a.recommended_power, a.bonus_bps, a.min_ratio_bps, a.max_ratio_bps)
	end,
	offline_credit_minutes = function(F, a)
		local c, l = F.offlineCreditMinutes(a.gap_minutes, a.cap_minutes)
		return { c, l }
	end,
	accrue_milli = function(F, a)
		local g, c = F.accrueMilli(a.rate_milli_per_hour, a.minutes, a.carry)
		return { g, c }
	end,
	night_segments = function(F, a)
		return F.nightSegments(a.start_minute, a.end_minute, a.cycle_minutes, a.night_start_offset_minutes, a.night_minutes)
	end,
	capture_attempt_bps = function(F, a)
		return F.captureAttemptBps(a.grade, a.light, a.rule)
	end,
	flee_bps = function(F, a)
		return F.fleeBps(a.failures, a.rule)
	end,
	capture_k_max = function(F, a)
		return F.captureKMax(a.rule, a.limit)
	end,
	weaken_needed = function(F, a)
		return F.weakenNeeded(a.grade, a.rule)
	end,
	easy_attempt_light = function(F, a)
		return F.easyAttemptLight(a.grade, a.rule)
	end,
	weaken_seconds = function(F, a)
		return F.weakenSeconds(a.attacker_grade, a.attacker_level, a.target_grade, a.vigor, a.rule)
	end,
	weaken_vigor_cost = function(F, a)
		return F.weakenVigorCost(a.attacker_grade, a.target_grade, a.rule)
	end,
	resolve_encounter = function(F, a)
		return encounterArray(F.resolveEncounter(a.grade, a.rule, a.uniforms, a.wicks_available, a.weaken_s), false)
	end,
	vigor_hunt_scaled_milli = function(F, a)
		return F.vigorHuntScaledMilli(a.rate_milli, a.powers, a.mults_bps)
	end,
	capture_tool_mult_bps = function(F, a)
		return F.captureToolMultBps(a.grade, a.rule)
	end,
	capture_tool_attempt_bps = function(F, a)
		return F.captureToolAttemptBps(a.grade, a.light, a.rule)
	end,
	-- JSON に null を置かないため「効く道具なし」は空文字列で比較する（formulas.py:611-612 と同じ）
	capture_tool_item = function(F, a)
		return F.captureToolItem(a.home_field, a.grade, a.unlocked_fields, a.directly_captured, a.rule) or ""
	end,
	resolve_encounter_tool = function(F, a)
		return encounterArray(
			F.resolveEncounterTool(a.grade, a.rule, a.uniforms, a.wicks_available, a.weaken_s, a.tools_available),
			true
		)
	end,
}
VectorRunner.CALL = CALL

-- JSON 由来の値の深い比較（配列は長さと要素、数値は ==）
local function deepEqual(a: any, b: any): boolean
	if type(a) ~= type(b) then
		return false
	end
	if type(a) ~= "table" then
		return a == b
	end
	for k, v in a do
		if not deepEqual(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end
VectorRunner.deepEqual = deepEqual

local function show(v: any): string
	if type(v) ~= "table" then
		return tostring(v)
	end
	local parts = {}
	for _, x in v do
		table.insert(parts, show(x))
	end
	return "[" .. table.concat(parts, ", ") .. "]"
end
VectorRunner.show = show

VectorRunner.EXPECTED_COUNTS = table.freeze({ total = 130, skip = 30 })

function VectorRunner.run(vectorsDoc: any, Formulas: any): Summary
	local s: Summary = { pass = 0, skip = 0, fail = 0, failures = {}, byFn = {} }
	for _, vec in vectorsDoc.vectors do
		local fn: string = vec.fn
		local slot = s.byFn[fn]
		if slot == nil then
			slot = { pass = 0, skip = 0, fail = 0 }
			s.byFn[fn] = slot
		end
		local call = CALL[fn]
		if call == nil then
			if VectorRunner.PYTHON_ONLY[fn] then
				s.skip += 1
				slot.skip += 1
			else
				s.fail += 1
				slot.fail += 1
				table.insert(s.failures, `{vec.id}: 알 수 없는 fn '{fn}'(CALL·PYTHON_ONLY 어디에도 없음)`)
			end
			continue
		end
		local ok, got = pcall(call, Formulas, vec.args)
		if ok and deepEqual(got, vec.expected) then
			s.pass += 1
			slot.pass += 1
		else
			s.fail += 1
			slot.fail += 1
			local detail = if ok then `got {show(got)} expected {show(vec.expected)}` else `error {tostring(got)}`
			table.insert(s.failures, `{vec.id} ({fn}): {detail}`)
		end
	end
	-- 件数の固定（レビュー Minor 2）: ベクトルの削除や PYTHON_ONLY 側への追加が黙って通らないようにする。
	-- test_vectors.json を更新したら計画書 5 節とこの値を同時に更新する
	local total = s.pass + s.skip + s.fail
	local exp = VectorRunner.EXPECTED_COUNTS
	if total ~= exp.total or s.skip ~= exp.skip then
		s.fail += 1
		table.insert(s.failures, `件数不一致: 総数 {total}（期待 {exp.total}）/ SKIP {s.skip}（期待 {exp.skip}）`)
	end
	return s
end

function VectorRunner.format(s: Summary): string
	return `PASS {s.pass} / SKIP {s.skip} / FAIL {s.fail}`
end

return VectorRunner
