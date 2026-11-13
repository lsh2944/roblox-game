--!strict
-- Formulas: econ_sim の tools/econ_sim/econ_sim/formulas.py を 1:1 で移植した純粋関数
-- 配置: ReplicatedStorage.Shared.Formulas（Rojo: game/src/shared/Formulas.luau）
-- 依存: なし（Roblox API を使わない。Studio と Lune の両方で動く）
--
-- 単位と丸めの約束（formulas.py と同じ）:
-- - 倍率は bps（10000 = 1.0 倍）、生産量は milli（1000 = 1 個）の整数で扱う
-- - 丸めは各段の整数除算（切り捨て）。段の順序は関数ごとに固定
-- - 中間値が 2^53-1 を超えたら FormulaError（Python _safe と同じ。formulas.py:26-31）
-- - 整数除算は idiv（double の a // b を余りで補正した厳密な床除算）を使う
-- 対象外（Python 専用）: exp_ceil_cost 系（有理数の累乗が 2^53 を超える。ゲームは generated/*_tables.json を引く）、
--   capture_success_per_encounter / geometric_quantile / g2_ratio / direct_share / encounter_expectation（分析用 Fraction）

local Formulas = {}

local BPS = 10000
local MILLI = 1000
local MINUTES_PER_HOUR = 60
local MINUTES_PER_DAY = 1440
local MAX_SAFE_INT = 9007199254740991 -- 2^53 - 1

Formulas.BPS = BPS
Formulas.MILLI = MILLI
Formulas.MINUTES_PER_HOUR = MINUTES_PER_HOUR
Formulas.MINUTES_PER_DAY = MINUTES_PER_DAY
Formulas.MAX_SAFE_INT = MAX_SAFE_INT

export type EncounterResult = {
	result: string, -- "success" | "flee" | "wick_out"
	attempts: number,
	wicksUsed: number,
	seconds: number,
	toolsUsed: number,
}

export type NightSegment = { number | boolean } -- {start, end, isNight}（ベクトルの配列形と同じ）

local function fail(msg: string): any
	error("FormulaError: " .. msg, 3)
end

-- 有限の整数か（bool・NaN・inf・小数を弾く）
local function isInt(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge and math.floor(v) == v
end
Formulas.isInt = isInt

-- Python _safe 相当: 整数で |v| <= 2^53-1
local function assertSafe(...: any)
	for i = 1, select("#", ...) do
		local v = select(i, ...)
		if not isInt(v) then
			fail(`정수가 아님: {tostring(v)}`)
		end
		if math.abs(v) > MAX_SAFE_INT then
			fail(`2^53-1 초과: {tostring(v)}`)
		end
	end
end
Formulas.assertSafe = assertSafe

-- Python _nonneg 相当（name は報告用）
local function nonneg(name: string, v: any)
	assertSafe(v)
	if v < 0 then
		fail(`{name}는 0 이상이어야 함: {tostring(v)}`)
	end
end

-- Python の a // b（床除算）と同じ結果を返す整数除算。
-- double の a // b は |a| が 2^53 付近で丸めにより 1 ずれうるため、余りで補正する（a, b は安全整数、b ≠ 0）
local function idiv(a: number, b: number): number
	if b == 0 then
		fail("0으로 나눔")
	end
	local q = a // b
	local r = a - q * b
	if b > 0 then
		if r < 0 then
			q -= 1
		elseif r >= b then
			q += 1
		end
	else
		if r > 0 then
			q -= 1
		elseif r <= b then
			q += 1
		end
	end
	return q
end
Formulas.idiv = idiv

-- Python の a % b（b > 0 なら 0..b-1）
local function imod(a: number, b: number): number
	return a - idiv(a, b) * b
end
Formulas.imod = imod

-- ---- 強化曲線 ---------------------------------------------------------------

-- 倍率 = (1 + per_level×(L-1)) × Π{到達済みマイルストーンの倍率}。milestones は {{level, mult}, ...}
function Formulas.linearMilestoneBps(perLevelBps: number, level: number, milestones: { { number } }): number
	nonneg("per_level_bps", perLevelBps)
	assertSafe(level)
	if level < 1 then
		fail(`level은 1 이상: {level}`)
	end
	local value = BPS + perLevelBps * (level - 1)
	for _, m in milestones do
		local mLevel, mult = m[1], m[2]
		nonneg("m_level", mLevel)
		nonneg("mult", mult)
		if level >= mLevel then
			value *= mult
		end
	end
	assertSafe(value)
	return value
end

-- ---- 生産・採集・狩り ----------------------------------------------------------

-- 配置 1 枠の寄与（採集力×能力倍率×適性×(1+特性)）。単位は「採集力×bps」
function Formulas.slotPowerBps(gather: number, abilityBps: number, aptitudeBps: number, traitBps: number?): number
	local trait = traitBps or 0
	nonneg("gather", gather)
	nonneg("ability_bps", abilityBps)
	nonneg("aptitude_bps", aptitudeBps)
	assertSafe(trait)
	local raw = gather * abilityBps * aptitudeBps
	assertSafe(raw)
	local power = idiv(raw, BPS)
	local factor = math.max(0, BPS + trait) -- 特性合計が -100% 未満なら 0 に止める
	assertSafe(power * factor)
	return idiv(power * factor, BPS)
end

-- 施設 1 つの放置生産（milli/時）= 基本率×施設倍率×Σ(枠寄与)/G_REF
function Formulas.idleRateMilliPerHour(basePerHour: number, facilityMultBps: number, slotPowersBps: { number }, gatherRef: number): number
	nonneg("base_per_hour", basePerHour)
	nonneg("facility_mult_bps", facilityMultBps)
	if gatherRef < 1 then
		fail("gather_ref는 1 이상")
	end
	local staff = 0
	for _, p in slotPowersBps do
		nonneg("slot_power", p)
		staff += p
	end
	assertSafe(staff)
	local scaled = basePerHour * MILLI * facilityMultBps
	assertSafe(scaled)
	scaled = idiv(scaled, BPS)
	assertSafe(scaled * staff)
	return idiv(scaled * staff, gatherRef * BPS)
end

-- 同行精霊による直接採集ボーナス（bps）= k × Σ(枠寄与)/G_REF
function Formulas.companionBonusBps(companionPowersBps: { number }, kBps: number, gatherRef: number): number
	nonneg("k_bps", kBps)
	if gatherRef < 1 then
		fail("gather_ref는 1 이상")
	end
	local total = 0
	for _, p in companionPowersBps do
		nonneg("companion_power", p)
		total += p
	end
	assertSafe(kBps * total)
	return idiv(kBps * total, gatherRef * BPS)
end

-- 直接採集（milli/活動時間）= ノード基本率×道具倍率×(1+同行ボーナス)
function Formulas.directRateMilliPerHour(nodePerHour: number, toolMultBps: number, companionBonus: number): number
	nonneg("node_per_hour", nodePerHour)
	nonneg("tool_mult_bps", toolMultBps)
	nonneg("companion_bonus", companionBonus)
	local scaled = nodePerHour * MILLI * toolMultBps
	assertSafe(scaled)
	scaled = idiv(scaled, BPS)
	assertSafe(scaled * (BPS + companionBonus))
	return idiv(scaled * (BPS + companionBonus), BPS)
end

-- 研究効果（決定 C2）: 既存の計算結果に経路別に 1 回だけ掛ける（切り捨て）
function Formulas.researchScaledMilli(amountMilli: number, researchBps: number): number
	nonneg("amount_milli", amountMilli)
	nonneg("research_bps", researchBps)
	assertSafe(amountMilli * (BPS + researchBps))
	return idiv(amountMilli * (BPS + researchBps), BPS)
end

-- 適用順: 図鑑ボーナス（その資源の bps）→ 切り捨て → 研究 → 切り捨て（施設放置・直接採集で同じ）
function Formulas.idleDexResearchMilli(rawMilli: number, dexBps: number, researchBps: number): number
	nonneg("raw_milli", rawMilli)
	nonneg("dex_bps", dexBps)
	assertSafe(rawMilli * (BPS + dexBps)) -- Python は多倍長なので検査なし。Luau では精度のため検査する
	return Formulas.researchScaledMilli(idiv(rawMilli * (BPS + dexBps), BPS), researchBps)
end

-- ---- 図鑑ボーナス（2026-11-12 ユーザー決定、docs/spirit_roster_expansion_20261112.md 図鑑ボーナス改編） ----
-- 種ごとに dex_bonus を 1 つ持ち、数値は rules.dex_bonus（等級・種類別）だけで決める。全経路がこの結果を使う（formulas.py と同じ）

Formulas.DEX_RESOURCE = "resource_output"
Formulas.DEX_SPECIAL_TYPES = table.freeze({ "upgrade_cost_down", "craft_cost_down", "capture_attempt_up" })
-- 費用減少として使える種類（それ以外を費用に掛けるのは誤り）
Formulas.DEX_COST_TYPES = table.freeze({ "upgrade_cost_down", "craft_cost_down" })

export type DexMap = {
	resource_output: { [string]: number }, -- 資源 → bps（0 の資源は含めない）
	upgrade_cost_down: number,
	craft_cost_down: number,
	capture_attempt_up: number,
}

-- 図鑑登録種の配列 → 種類別の図鑑ボーナス（formulas.py dex_bonus_map）。data に無い種は無視し、重複は 1 回だけ数える。
-- 合計してから種類別の上限 cap_bps で切る（resource_output は資源別）
function Formulas.dexBonusMap(registered: { string }, spirits: { [string]: any }, rule: any): DexMap
	local res: { [string]: number } = {}
	local out: DexMap = { resource_output = res, upgrade_cost_down = 0, craft_cost_down = 0, capture_attempt_up = 0 }
	local seen: { [string]: boolean } = {}
	for _, sid in registered do
		if seen[sid] then
			continue
		end
		seen[sid] = true
		local s = spirits[sid]
		if s == nil then
			continue
		end
		local b = s.dex_bonus
		local t = b.type
		if t == Formulas.DEX_RESOURCE then
			local v = rule.grade_bps[tostring(s.grade)]
			if v == nil then
				fail(`등급 {s.grade}의 도감 보너스 수치가 없음: {sid}`)
			end
			res[b.resource] = (res[b.resource] or 0) + v
		elseif table.find(Formulas.DEX_SPECIAL_TYPES, t) ~= nil then
			local o = out :: any
			o[t] += rule.special_bps[t]
		else
			fail(`알 수 없는 도감 보너스 종류: {tostring(t)}`)
		end
	end
	local cap = rule.cap_bps
	for r, v in res do
		local c = math.min(cap[Formulas.DEX_RESOURCE], v)
		res[r] = if c > 0 then c else nil
	end
	out.upgrade_cost_down = math.min(cap.upgrade_cost_down, out.upgrade_cost_down)
	out.craft_cost_down = math.min(cap.craft_cost_down, out.craft_cost_down)
	out.capture_attempt_up = math.min(cap.capture_attempt_up, out.capture_attempt_up)
	return out
end

-- 保存データの図鑑（save.dex = { [種] = 初登録時刻 }）→ dexBonusMap。キーの順は結果に影響しない
function Formulas.dexBonusMapForSet(dexSet: { [string]: any }, spirits: { [string]: any }, rule: any): DexMap
	local ids = {}
	for sid in dexSet do
		table.insert(ids, sid)
	end
	return Formulas.dexBonusMap(ids, spirits, rule)
end

-- 生産量に図鑑ボーナスを掛ける: amount × (10000 + dex) // 10000（切り捨て）
function Formulas.dexScaledMilli(amountMilli: number, dexBps: number): number
	nonneg("amount_milli", amountMilli)
	nonneg("dex_bps", dexBps)
	assertSafe(amountMilli * (BPS + dexBps))
	return idiv(amountMilli * (BPS + dexBps), BPS)
end

-- 費用の割引: amount − amount × r // 10000（割引額を切り捨て = 費用は切り上げ）。r < 10000 なら amount ≥ 1 → 結果 ≥ 1
function Formulas.discountedCost(amount: number, discountBps: number): number
	nonneg("amount", amount)
	nonneg("discount_bps", discountBps)
	if discountBps > BPS then
		fail(`discount_bps는 0..{BPS}: {discountBps}`)
	end
	assertSafe(amount * discountBps)
	return amount - idiv(amount * discountBps, BPS)
end

-- 費用の各項目に discountedCost を掛けた新しい配列（割引 0 でも写しを返す）
function Formulas.discountedCosts(costs: { { resource: string, amount: number } }, discountBps: number): { { resource: string, amount: number } }
	local out = {}
	for _, c in costs do
		table.insert(out, { resource = c.resource, amount = Formulas.discountedCost(c.amount, discountBps) })
	end
	return out
end

-- 図鑑の捕獲確率ボーナス: 道具適用後の成功率 p に加算。p > 0 のときだけ min(10000, p + bonus)、p ≤ 0（散り）はそのまま
function Formulas.captureBonusAttemptBps(pBps: number, bonusBps: number): number
	assertSafe(pBps)
	nonneg("bonus_bps", bonusBps)
	if pBps <= 0 then
		return pBps
	end
	return math.min(BPS, pBps + bonusBps)
end

-- パーティ戦闘力 = Σ(戦闘力×能力倍率bps)。members は {{combat, ability_bps}, ...}
function Formulas.partyPowerBps(members: { { number } }): number
	local total = 0
	for _, m in members do
		local combat, abilityBps = m[1], m[2]
		nonneg("combat", combat)
		nonneg("ability_bps", abilityBps)
		total += combat * abilityBps
	end
	assertSafe(total)
	return total
end

-- 狩りドロップ（milli/活動時間）。戦力比が下限未満なら 0、上限で頭打ち
function Formulas.huntRateMilliPerHour(
	dropPerHour: number,
	partyPower: number,
	recommendedPower: number,
	bonusBps: number,
	minRatioBps: number,
	maxRatioBps: number
): number
	nonneg("drop_per_hour", dropPerHour)
	nonneg("party_power", partyPower)
	nonneg("bonus_bps", bonusBps)
	nonneg("min_ratio_bps", minRatioBps)
	nonneg("max_ratio_bps", maxRatioBps)
	if recommendedPower < 1 then
		fail("recommended_power는 1 이상")
	end
	local ratio = idiv(partyPower, recommendedPower)
	if ratio < minRatioBps then
		return 0
	end
	local eff = math.min(ratio, maxRatioBps)
	local scaled = dropPerHour * MILLI * eff
	assertSafe(scaled)
	scaled = idiv(scaled, BPS)
	assertSafe(scaled * (BPS + bonusBps))
	return idiv(scaled * (BPS + bonusBps), BPS)
end

-- ---- 時間（オフライン上限・夜間境界・端数繰越） ------------------------------------

-- (認定分, 失効分)。上限を超えた分は生産しない
function Formulas.offlineCreditMinutes(gapMinutes: number, capMinutes: number): (number, number)
	nonneg("gap_minutes", gapMinutes)
	nonneg("cap_minutes", capMinutes)
	local credited = math.min(gapMinutes, capMinutes)
	return credited, gapMinutes - credited
end

-- 一定生産率の区間を閉じた式で積算する。carry は (milli×分) の端数で 0..59。戻り値 (獲得 milli, 新しい carry)
function Formulas.accrueMilli(rateMilliPerHour: number, minutes: number, carry: number): (number, number)
	nonneg("rate_milli_per_hour", rateMilliPerHour)
	nonneg("minutes", minutes)
	nonneg("carry", carry)
	if carry >= MINUTES_PER_HOUR then
		fail("carry는 0..59")
	end
	local total = rateMilliPerHour * minutes + carry
	assertSafe(total)
	local q = idiv(total, MINUTES_PER_HOUR)
	return q, total - q * MINUTES_PER_HOUR
end

-- [start, end) をゲーム内時計の夜/昼境界で分割する（formulas.night_segments と同じ）。
-- 分は UTC 通算分（ゲームは os.time()//60、シミュは day0 00:00 起点で同じ軸）。
-- (分 - offset) mod cycle < nightMinutes なら夜（2026-11-11 決定: cycle 60・offset 30・夜 30 分 = 毎時 30〜60 分が夜、全世界同期）
function Formulas.nightSegments(
	startMinute: number,
	endMinute: number,
	cycleMinutes: number,
	nightStartOffsetMinutes: number,
	nightMinutes: number
): { NightSegment }
	nonneg("start_minute", startMinute)
	nonneg("end_minute", endMinute)
	if endMinute < startMinute then
		fail("end < start")
	end
	assertSafe(cycleMinutes, nightStartOffsetMinutes, nightMinutes)
	if
		cycleMinutes < 1
		or not (nightStartOffsetMinutes >= 0 and nightStartOffsetMinutes < cycleMinutes)
		or not (nightMinutes >= 0 and nightMinutes <= cycleMinutes)
	then
		fail("cycle ≥ 1, 0 ≤ offset < cycle, 0 ≤ night_minutes ≤ cycle")
	end
	local segs: { NightSegment } = {}
	if startMinute == endMinute then
		return segs
	end
	if nightMinutes == 0 or nightMinutes == cycleMinutes then
		table.insert(segs, { startMinute, endMinute, nightMinutes == cycleMinutes })
		return segs
	end
	-- 0 < nightMinutes < cycle なので隣り合う区間は必ず昼夜が入れ替わる（結合不要、Python と同じ）
	local t = startMinute
	while t < endMinute do
		local phase = imod(t - nightStartOffsetMinutes, cycleMinutes)
		local flag = phase < nightMinutes
		local step = if flag then nightMinutes - phase else cycleMinutes - phase
		local segEnd = math.min(endMinute, t + step)
		table.insert(segs, { t, segEnd, flag })
		t = segEnd
	end
	return segs
end

-- ---- 捕獲の状態機械（capture.json の規則で計算する純粋関数） -------------------------
-- rule は capture.json の文書（必要なキーだけの部分集合でもよい。ベクトルは部分 rule を渡す）

local function gradeBps(rule: any, grade: number): number
	for _, g in rule.base_success_bps_by_grade do
		if g.grade == grade then
			return g.bps
		end
	end
	return fail(`등급 {grade}의 성공률이 없음`)
end

-- 1 回の試行の成功率（bps）= 等級の基本成功率 × 光区間の倍率（切り捨て、上限 10000）。散り限界以下なら 0
function Formulas.captureAttemptBps(grade: number, light: number, rule: any): number
	assertSafe(grade, light)
	local lt = rule.light
	if light <= lt.scatter_at_or_below then
		return 0
	end
	local mult = BPS
	for _, b in lt.bands do -- above の降順。最初に light > above となる区間
		if light > b.above then
			mult = b.mult_bps
			break
		end
	end
	return math.min(BPS, idiv(gradeBps(rule, grade) * mult, BPS))
end

-- 失敗 failures 回目の直後に逃げる確率（bps）= min(max, first + step×(failures−1))
function Formulas.fleeBps(failures: number, rule: any): number
	assertSafe(failures)
	if failures < 1 then
		fail("failures는 1 이상")
	end
	local fl = rule.flee_after_failure
	return math.min(fl.max_bps, fl.first_bps + fl.step_bps * (failures - 1))
end

-- 1 遭遇の最大試行数 = 逃走確率が 100% に達する失敗回数。limit 以内に達しなければ FormulaError
function Formulas.captureKMax(rule: any, limit: number?): number
	local lim = limit or 20
	for k = 1, lim do
		if Formulas.fleeBps(k, rule) >= BPS then
			return k
		end
	end
	return fail(`실패 {lim}회 안에 도망 확률이 100%에 도달하지 않음`)
end

-- 簡易モードで弱体化するか（skip_when_no_gain: 成功率が上がらないなら飛ばす。既定 true）
function Formulas.weakenNeeded(grade: number, rule: any): boolean
	local lt = rule.light
	local stop = rule.easy_mode.stop_at_light
	local wk = rule.weaken
	local skip = true
	if wk ~= nil and wk.skip_when_no_gain ~= nil then
		skip = wk.skip_when_no_gain
	end
	if not skip then
		return true
	end
	return Formulas.captureAttemptBps(grade, stop, rule) > Formulas.captureAttemptBps(grade, lt.max, rule)
end

-- 簡易モードの試行光: 弱体化するなら停止点、しないなら最大値
function Formulas.easyAttemptLight(grade: number, rule: any): number
	if Formulas.weakenNeeded(grade, rule) then
		return rule.easy_mode.stop_at_light
	end
	return rule.light.max
end

local function gapMultBps(rule: any, gap: number): number
	for _, g in rule.weaken.grade_gap_mult_bps do
		if g.gap == gap then
			return g.bps
		end
	end
	return fail(`등급 차 {gap}의 배율이 없음`)
end

-- weaken_seconds の整数 tick 版（sim.py の pick_attacker は Fraction(v, VIGOR_TICK) を渡す。ここでは tick のまま比較して厳密にする）
-- vigorTicks / ticksPerPoint が活力点。活力 0 以下は −1（行動不可）
function Formulas.weakenSecondsTicks(
	attackerGrade: number,
	attackerLevel: number,
	targetGrade: number,
	vigorTicks: number,
	ticksPerPoint: number,
	rule: any
): number
	assertSafe(attackerGrade, attackerLevel, targetGrade)
	if attackerLevel < 1 then
		fail("attacker_level은 1 이상")
	end
	assertSafe(vigorTicks, ticksPerPoint)
	if ticksPerPoint < 1 then
		fail("ticksPerPoint는 1 이상")
	end
	if vigorTicks <= 0 then
		return -1
	end
	local wk, vg, lt = rule.weaken, rule.vigor, rule.light
	local gap = math.max(-3, math.min(3, attackerGrade - targetGrade))
	local m = gapMultBps(rule, gap)
	local b = BPS + math.min(wk.level_bps_per_level * (attackerLevel - 1), wk.level_bps_cap)
	-- v <= low ⇔ vigorTicks <= low × ticksPerPoint（整数比較）
	local vm = if vigorTicks <= vg.low_at_or_below * ticksPerPoint then vg.low_mult_bps else BPS
	local need = lt.max - rule.easy_mode.stop_at_light
	local num = need * BPS * BPS * BPS
	local den = lt.standard_attack.damage * m * b * vm
	assertSafe(num, den)
	if den <= 0 then
		fail("약화 피해가 0")
	end
	local n = -idiv(-num, den)
	return math.max(wk.min_seconds, math.min(wk.max_seconds, lt.standard_attack.seconds * n))
end

-- 同行精霊 1 体が簡易モードの弱体化にかける秒数（ベクトル用。vigor は整数の活力点）
function Formulas.weakenSeconds(attackerGrade: number, attackerLevel: number, targetGrade: number, vigor: number, rule: any): number
	return Formulas.weakenSecondsTicks(attackerGrade, attackerLevel, targetGrade, vigor, 1, rule)
end

-- 弱体化 1 回（1 遭遇）の活力消費（点）= base + per_gap × max(攻撃−対象, 0)（等級差は 3 で頭打ち）
function Formulas.weakenVigorCost(attackerGrade: number, targetGrade: number, rule: any): number
	assertSafe(attackerGrade, targetGrade)
	local c = rule.vigor.weaken_cost
	return c.base + c.per_gap * math.max(0, math.min(3, attackerGrade - targetGrade))
end

-- ---- 捕獲補助道具（2026-11-11 ユーザー決定。rule.capture_tool が無ければ常に無効） ----

local function hasCaptureTool(rule: any): boolean
	local ct = rule.capture_tool
	return ct ~= nil and next(ct) ~= nil
end

-- 等級の道具倍率（bps）。capture_tool が無い・その等級の倍率が無い（★1）なら BPS
function Formulas.captureToolMultBps(grade: number, rule: any): number
	assertSafe(grade)
	if not hasCaptureTool(rule) then
		return BPS
	end
	for _, g in rule.capture_tool.mult_bps_by_grade do
		if g.grade == grade then
			return g.bps
		end
	end
	return BPS
end

-- 道具を使った 1 回の試行の成功率（bps）= min(max_bps, 基本成功率 × 等級倍率)（切り捨て）。基本より下がらない
function Formulas.captureToolAttemptBps(grade: number, light: number, rule: any): number
	local base = Formulas.captureAttemptBps(grade, light, rule)
	local mult = Formulas.captureToolMultBps(grade, rule)
	if base <= 0 or mult <= BPS then
		return base
	end
	local cap = rule.capture_tool.max_bps
	return math.max(base, math.min(cap, idiv(base * mult, BPS)))
end

-- この遭遇に効く道具の資源 ID（効かなければ nil）。固有フィールド（home_field）の道具で決まる
function Formulas.captureToolItem(homeField: string, grade: number, unlockedFields: { string }, directlyCaptured: boolean, rule: any): string?
	if not hasCaptureTool(rule) or Formulas.captureToolMultBps(grade, rule) <= BPS then
		return nil
	end
	local ct = rule.capture_tool
	if table.find(unlockedFields, ct.unlock_after_field) == nil or not directlyCaptured then
		return nil
	end
	for _, it in ct.items do
		if it.field_id == homeField then
			return it.resource
		end
	end
	return nil
end

-- 簡易モード 1 遭遇の結果（捕獲補助道具あり）。formulas.py resolve_encounter_tool と同じ
-- captureBonusBps（省略 = 0）は図鑑の捕獲確率ボーナス。道具の有無を決めた後の各試行の成功率に captureBonusAttemptBps で加える
-- （逃走・乱数の位置・道具の消費は変えない）
-- uniforms は [試行成功 K_max 個, 逃走 K_max 個]（1 始まり: i 回目の試行は uniforms[i]、i 回目の失敗後の逃走は uniforms[K+i]）
-- wicksAvailable < 0 は芯無制限（wicksUsed は 0）。比較は u × 10000 < p_bps（double 同士、Python float と同じ）
function Formulas.resolveEncounterTool(
	grade: number,
	rule: any,
	uniforms: { number },
	wicksAvailable: number,
	weakenS: number,
	toolsAvailable: number,
	captureBonusBps: number?
): EncounterResult
	assertSafe(grade, weakenS, wicksAvailable, toolsAvailable)
	local bonus = captureBonusBps or 0
	local unlimited = wicksAvailable < 0
	local k = Formulas.captureKMax(rule)
	if #uniforms < 2 * k then
		fail(`uniforms는 {2 * k}개 필요`)
	end
	local light = Formulas.easyAttemptLight(grade, rule)
	local p = Formulas.captureBonusAttemptBps(Formulas.captureAttemptBps(grade, light, rule), bonus)
	local pt = Formulas.captureBonusAttemptBps(Formulas.captureToolAttemptBps(grade, light, rule), bonus)
	local toolPer = 0
	if toolsAvailable > 0 and Formulas.captureToolMultBps(grade, rule) > BPS then
		toolPer = rule.capture_tool.per_attempt
	end
	local per = 0
	for _, c in rule.attempt_cost do
		per += c.amount
	end
	local attempts, used, toolsUsed = 0, 0, 0
	local result = "flee"
	for i = 1, k do
		if not unlimited and wicksAvailable - used < per then
			result = "wick_out"
			break
		end
		attempts += 1
		used += per
		local pi = p
		if toolPer > 0 and toolsAvailable - toolsUsed >= toolPer then
			toolsUsed += toolPer
			pi = pt
		end
		if uniforms[i] * BPS < pi then
			result = "success"
			break
		end
		if uniforms[k + i] * BPS < Formulas.fleeBps(i, rule) then
			result = "flee"
			break
		end
	end
	local t = rule.time
	return {
		result = result,
		attempts = attempts,
		wicksUsed = if unlimited then 0 else used,
		seconds = t.encounter_base_seconds + weakenS + t.attempt_seconds * attempts,
		toolsUsed = toolsUsed,
	}
end

-- 簡易モード 1 遭遇の結果（道具なし）= resolveEncounterTool(..., 0)。toolsUsed は常に 0
function Formulas.resolveEncounter(grade: number, rule: any, uniforms: { number }, wicksAvailable: number, weakenS: number): EncounterResult
	return Formulas.resolveEncounterTool(grade, rule, uniforms, wicksAvailable, weakenS, 0)
end

-- 狩りの産出を活力で縮める: rate × Σ(戦闘力_i × 倍率_i) / (Σ戦闘力_i × BPS)（切り捨て）
function Formulas.vigorHuntScaledMilli(rateMilli: number, powers: { number }, multsBps: { number }): number
	nonneg("rate_milli", rateMilli)
	if #powers ~= #multsBps then
		fail("powers와 mults_bps의 길이가 다름")
	end
	local total, num = 0, 0
	for i, p in powers do
		total += p
		num += p * multsBps[i]
	end
	if total <= 0 then
		return 0
	end
	assertSafe(total, num, rateMilli * num)
	return idiv(rateMilli * num, total * BPS)
end

return table.freeze(Formulas)
