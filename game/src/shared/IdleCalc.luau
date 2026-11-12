--!strict
-- IdleCalc: 放置生産の精算（IdleService の純粋な計算部）
-- 配置: ReplicatedStorage.Shared.IdleCalc（Rojo: game/src/shared/IdleCalc.luau）
-- 依存: Formulas（同じフォルダ）、Economy インスタンス（引数）。Roblox API 不使用（Lune でも動く）
-- サーバーの Services/IdleService（S4 以降）がこのモジュールを呼び、保存データの wallet・carry・settled_min を更新する。
--
-- sim.py _advance（:504-543）と同じ規則:
-- - オンライン中は [settled, now] をそのまま認定。オフラインは [settled, min(now, 退出 + 上限時間)] を認定し、超過は失効
-- - 認定区間を夜/昼境界（rules.night のゲーム内時計、UTC の通算分）で分け、区間ごとの生産率で accrue_milli（carry は資源別に持ち越す）
-- - 施設で働く精霊の固有狩り素材は milli/日 を divmod(per_day × 分 + carry, 1440) で積む（(資源, 等級) 別の carry）
-- - 研究倍率は資源別 bps のフック（MVP1 は 0）。図鑑ボーナス込みの資源別合計に 1 回だけ掛ける
-- - 日境界での分割は行わない（carry 付き積算は区間を分けても合計が同じ。sim の日分割は日別集計のため）
-- - 同行と施設配置は排他（計画書 Q3 決定）なので、sim の exclude（同行中の除外）は扱わない

local Formulas = require("./Formulas")

local MINUTES_PER_DAY = Formulas.MINUTES_PER_DAY

local IdleCalc = {}

export type SpiritRec = {
	species: string,
	level: number,
	gather_bps: number,
	combat_bps: number,
}

export type FacilityRec = {
	level: number,
	assigned: { string }, -- roster の uid 文字列
}

export type SettleInput = {
	wallet: { [string]: number }, -- milli（更新される）
	carry: { [string]: number }, -- 端数（更新される）
	settledMin: number, -- 精算済みの時刻（分）
	offlineSinceMin: number?, -- オフラインなら退出時刻（分）。オンライン中は nil
	offlineCapHours: number,
	facilities: { [string]: FacilityRec },
	roster: { [string]: SpiritRec },
	dexCount: number, -- 図鑑登録種数（開始精霊を含む）
	researchIdleBps: { [string]: number }?, -- 資源別の研究倍率（MVP1 は nil = 0）
}

export type SettleResult = {
	fromMin: number,
	toMin: number, -- 認定区間の終わり
	creditedMinutes: number,
	lostMinutes: number, -- オフライン上限を超えて失効した分
	gained: { [string]: number }, -- 資源別の獲得 milli
	newSettledMin: number,
}

-- carry のキー（保存スキーマ carry={[key]=int}）
function IdleCalc.idleCarryKey(res: string): string
	return "idle:" .. res
end

function IdleCalc.homeCarryKey(res: string, grade: number): string
	return `home:g{grade}:{res}`
end

-- 認定区間。戻り値 (from, to, lost)。now < settled（サーバー間の時計差）なら何も認定しない
function IdleCalc.creditRange(settledMin: number, nowMin: number, offlineSinceMin: number?, capHours: number): (number, number, number)
	Formulas.assertSafe(settledMin, nowMin, capHours)
	if nowMin <= settledMin then
		return settledMin, settledMin, 0
	end
	if offlineSinceMin == nil then
		return settledMin, nowMin, 0
	end
	Formulas.assertSafe(offlineSinceMin)
	local capEnd = offlineSinceMin + capHours * 60
	local toMin = math.max(settledMin, math.min(nowMin, capEnd))
	local lost = if nowMin > capEnd then nowMin - math.max(settledMin, capEnd) else 0
	return settledMin, toMin, lost
end

-- 施設で働く精霊（Economy.Member の配列）
local function facilityMembers(input: SettleInput, fac: FacilityRec): { any }
	local members = {}
	for _, uid in fac.assigned do
		local s = input.roster[uid]
		if s == nil then
			error(`IdleCalc: 배치된 정령이 보관함에 없음 uid={uid}`)
		end
		table.insert(members, { species = s.species, level = s.level, gatherBps = s.gather_bps, combatBps = s.combat_bps })
	end
	return members
end

-- 資源別の放置生産率（milli/時）。研究倍率を資源別合計に 1 回だけ掛ける（sim.py idle_rates）
function IdleCalc.idleRates(econ: any, input: SettleInput, night: boolean): { [string]: number }
	local gd = econ.gd
	local dex = econ:dexBps(input.dexCount)
	local rates: { [string]: number } = {}
	for _, fid in gd.facilityOrder do
		local fac = input.facilities[fid]
		if fac ~= nil then
			local res = gd.facilities[fid].produces
			local r = econ:facilityRate(fid, fac.level, facilityMembers(input, fac), night, dex)
			rates[res] = (rates[res] or 0) + r
		end
	end
	local research = input.researchIdleBps
	if research ~= nil then
		for res, v in rates do
			rates[res] = Formulas.researchScaledMilli(v, research[res] or 0)
		end
	end
	return rates
end

-- 施設で働く全精霊の固有狩り素材（(資源, 等級) 別の milli/日）
function IdleCalc.homeDetail(econ: any, input: SettleInput): { any }
	local members = {}
	for _, fid in econ.gd.facilityOrder do
		local fac = input.facilities[fid]
		if fac ~= nil then
			for _, m in facilityMembers(input, fac) do
				table.insert(members, m)
			end
		end
	end
	return econ:homeMaterialDetail(members, econ:dexBps(input.dexCount))
end

local function addGain(input: SettleInput, gained: { [string]: number }, res: string, milli: number)
	if milli > 0 then
		local total = (input.wallet[res] or 0) + milli
		Formulas.assertSafe(total)
		input.wallet[res] = total
		gained[res] = (gained[res] or 0) + milli
	end
end

-- 精算: nowMin まで進め、input.wallet・input.carry を更新して結果を返す（呼び出し側は settledMin を newSettledMin に更新する）
function IdleCalc.settle(econ: any, input: SettleInput, nowMin: number): SettleResult
	local fromMin, toMin, lost = IdleCalc.creditRange(input.settledMin, nowMin, input.offlineSinceMin, input.offlineCapHours)
	local gained: { [string]: number } = {}
	if toMin > fromMin then
		local night = econ.gd.rules.night
		local home = IdleCalc.homeDetail(econ, input)
		local rateCache: { [boolean]: { [string]: number } } = {}
		for _, seg in Formulas.nightSegments(fromMin, toMin, night.cycle_minutes, night.night_start_offset_minutes, night.night_minutes) do
			local s, e, isNight = seg[1] :: number, seg[2] :: number, seg[3] :: boolean
			local mins = e - s
			local rates = rateCache[isNight]
			if rates == nil then
				rates = IdleCalc.idleRates(econ, input, isNight)
				rateCache[isNight] = rates
			end
			for res, rate in rates :: { [string]: number } do
				local key = IdleCalc.idleCarryKey(res)
				local g, c = Formulas.accrueMilli(rate, mins, input.carry[key] or 0)
				input.carry[key] = c
				addGain(input, gained, res, g)
			end
			for _, row in home do
				local key = IdleCalc.homeCarryKey(row.resource, row.grade)
				local total = row.milli * mins + (input.carry[key] or 0)
				Formulas.assertSafe(total)
				local g = Formulas.idiv(total, MINUTES_PER_DAY)
				input.carry[key] = total - g * MINUTES_PER_DAY
				addGain(input, gained, row.resource, g)
			end
		end
	end
	return {
		fromMin = fromMin,
		toMin = toMin,
		creditedMinutes = toMin - fromMin,
		lostMinutes = lost,
		gained = gained,
		newSettledMin = math.max(input.settledMin, nowMin),
	}
end

return table.freeze(IdleCalc)
