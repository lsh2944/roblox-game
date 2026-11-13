--!strict
-- Economy: econ_sim economy.py のうち MVP1 が使う部分の移植（状態に依存しない経済計算）
-- 配置: ReplicatedStorage.Shared.Economy（Rojo: game/src/shared/Economy.luau）
-- 依存: Formulas（同じフォルダ）、GameData.build の結果（引数で受け取る。Roblox API 不使用）
--
-- 精霊は Member = {species, level, gatherBps?, combatBps?}（個体値の省略は 10000 = economy.py norm_member と同じ）
-- 2 段階の仮定（economy.py と同じ）: 混合配置ボーナスは施設の生産全体に掛かる（最大値 1 つ）、夜ボーナスは夜区間の特性に加算

local Formulas = require("./Formulas")

local BPS = Formulas.BPS
local idiv = Formulas.idiv
local assertSafe = Formulas.assertSafe

export type Member = {
	species: string,
	level: number,
	gatherBps: number?,
	combatBps: number?,
}

export type HomeMaterialRow = { resource: string, grade: number, milli: number }

type EconomyData = {
	gd: any,
	gRef: number,
	kComp: number,
	trait: { [string]: { [string]: number } }, -- 種 → 特性種類 → 合計 bps
	mixed: { [string]: { value: number, need: number } }, -- 混合配置ボーナスを持つ種
	homeRes: { [string]: string }, -- 種 → 固有フィールドの狩り素材
	homeRate: { [number]: number }, -- 等級 → milli/日
	nodeKinds: { [string]: { [string]: boolean } }, -- 種 → 特殊ノード種類
}

local Economy = {}
Economy.__index = Economy

export type Economy = typeof(setmetatable({} :: EconomyData, Economy))

function Economy.new(gd: any): Economy
	local c = gd.constants
	local data: EconomyData = {
		gd = gd,
		gRef = c.gather_ref,
		kComp = c.companion_gather_k_bps,
		trait = {},
		mixed = {},
		homeRes = {},
		homeRate = {},
		nodeKinds = {},
	}
	for _, sid in gd.spiritOrder do
		local s = gd.spirits[sid]
		local tr: { [string]: number } = {}
		local kinds: { [string]: boolean } = {}
		for _, t in s.traits do
			tr[t.type] = (tr[t.type] or 0) + t.value_bps
			if t.type == "mixed_placement_bps" then
				data.mixed[sid] = { value = t.value_bps, need = t.params.min_distinct_species or 2 }
			elseif t.type == "special_node" then
				kinds[t.params.node_kind or ""] = true
			end
		end
		data.trait[sid] = tr
		data.nodeKinds[sid] = kinds
		local drops = gd.fields[s.home_field].hunt.drops
		if #drops > 0 then
			data.homeRes[sid] = drops[1].resource
		end
	end
	for _, g in gd.rules.home_material.per_day_milli_by_grade do
		data.homeRate[g.grade] = g.milli
	end
	return setmetatable(data, Economy)
end

local function indOf(m: Member): (number, number)
	return m.gatherBps or BPS, m.combatBps or BPS
end

-- ---- 精霊 ----

function Economy.traitBps(self: Economy, species: string, traitType: string): number
	local tr = self.trait[species]
	if tr == nil then
		error(`Economy: 정령 없음 '{species}'`)
	end
	return tr[traitType] or 0
end

function Economy.abilityBps(self: Economy, species: string, level: number): number
	local s = self.gd.spirits[species]
	if s == nil then
		error(`Economy: 정령 없음 '{species}'`)
	end
	local v = self.gd.bonus[s.ability_curve][level]
	if v == nil then
		error(`Economy: 능력 표에 레벨 없음 {species} Lv{level}`)
	end
	return v
end

-- 能力倍率 × 個体値（F2）。個体値 10000 なら能力倍率そのまま
function Economy.abilityInd(self: Economy, species: string, level: number, indBps: number): number
	local a = self:abilityBps(species, level)
	assertSafe(a * indBps)
	return idiv(a * indBps, BPS)
end

local function aptitudeBps(self: Economy, s: any, resource: string): number
	local apt = s.aptitude[resource]
	local v = if apt ~= nil then self.gd.aptBps[apt] else nil
	if v == nil then
		error(`Economy: 적성 없음 {s.id}/{resource}`)
	end
	return v
end

-- 施設 1 枠の寄与（特性 facility_output_bps、夜は night_output_bps を加算）
function Economy.slotPower(self: Economy, species: string, level: number, resource: string, night: boolean, gatherBps: number?): number
	local s = self.gd.spirits[species]
	local trait = self:traitBps(species, "facility_output_bps")
	if night then
		trait += self:traitBps(species, "night_output_bps")
	end
	return Formulas.slotPowerBps(s.gather, self:abilityInd(species, level, gatherBps or BPS), aptitudeBps(self, s, resource), trait)
end

-- 同行 1 体の直接採集寄与（特性 companion_gather_bps）
function Economy.companionPower(self: Economy, species: string, level: number, resource: string, gatherBps: number?): number
	local s = self.gd.spirits[species]
	return Formulas.slotPowerBps(
		s.gather,
		self:abilityInd(species, level, gatherBps or BPS),
		aptitudeBps(self, s, resource),
		self:traitBps(species, "companion_gather_bps")
	)
end

-- ---- 施設 ----

-- 混合配置ボーナス（異なる種の数が条件以上の種のうち最大値 1 つ）
function Economy.mixedBonus(self: Economy, members: { Member }): number
	local species: { [string]: boolean } = {}
	local distinct = 0
	for _, m in members do
		if not species[m.species] then
			species[m.species] = true
			distinct += 1
		end
	end
	local best = 0
	for sp in species do
		local mx = self.mixed[sp]
		if mx ~= nil and distinct >= mx.need then
			best = math.max(best, mx.value)
		end
	end
	return best
end

-- 施設 1 つの放置生産（milli/時）。混合 → 図鑑の順に施設全体へ掛けて切り捨て（economy.py _facility_rate）。
-- dexBps はその施設の生産資源の図鑑ボーナス（dexMap(...).resource_output[produces]、2026-11-12 改編で資源別）
function Economy.facilityRate(self: Economy, fid: string, level: number, members: { Member }, night: boolean, dexBps: number): number
	if level <= 0 or #members == 0 then
		return 0
	end
	local fac = self.gd.facilities[fid]
	if fac == nil then
		error(`Economy: 시설 없음 '{fid}'`)
	end
	local powers = {}
	for _, m in members do
		local g = indOf(m)
		table.insert(powers, self:slotPower(m.species, m.level, fac.produces, night, g))
	end
	local mult = self.gd.bonus[fac.output_curve][level]
	if mult == nil then
		error(`Economy: 시설 배율 표에 레벨 없음 {fid} Lv{level}`)
	end
	local rate = Formulas.idleRateMilliPerHour(fac.base_per_hour, mult, powers, self.gRef)
	local mixedFactor = math.max(0, BPS + self:mixedBonus(members))
	assertSafe(rate * mixedFactor)
	rate = idiv(rate * mixedFactor, BPS)
	assertSafe(rate * (BPS + dexBps))
	return idiv(rate * (BPS + dexBps), BPS)
end

-- 図鑑（save.dex = { [種] = 初登録時刻 }）→ 種類別の図鑑ボーナス（economy.py dex_map、2026-11-12 改編）
function Economy.dexMap(self: Economy, dexSet: { [string]: any }): Formulas.DexMap
	return Formulas.dexBonusMapForSet(dexSet, self.gd.spirits, self.gd.rules.dex_bonus)
end

-- 図鑑の費用減少（kind = "upgrade_cost_down" | "craft_cost_down"）を項目ごとに掛けた新しい費用
function Economy.dexCosts(self: Economy, dexSet: { [string]: any }, costs: { { resource: string, amount: number } }, kind: string): { { resource: string, amount: number } }
	if table.find(Formulas.DEX_COST_TYPES, kind) == nil then
		error(`Economy: 비용 감소 종류가 아님 '{kind}'`)
	end
	local m = self:dexMap(dexSet) :: any
	return Formulas.discountedCosts(costs, m[kind])
end

-- (資源, 等級) 別の方置特殊財（milli/日、F1）。出現順に集計した配列を返す。
-- dexRes は資源別の図鑑ボーナス（dexMap(...).resource_output、nil = なし）。apply_dex_to_home_material のとき行ごとに掛ける
function Economy.homeMaterialDetail(self: Economy, members: { Member }, dexRes: { [string]: number }?): { HomeMaterialRow }
	local hm = self.gd.rules.home_material
	local rows: { HomeMaterialRow } = {}
	local index: { [string]: HomeMaterialRow } = {}
	for _, m in members do
		local res = self.homeRes[m.species]
		if res ~= nil then
			local grade = self.gd.spirits[m.species].grade
			local v = self.homeRate[grade]
			if v == nil then
				error(`Economy: home_material 등급 {grade} 없음`)
			end
			if hm.apply_individual_to_home_material then
				local g = indOf(m)
				v = idiv(v * g, BPS)
			end
			local key = res .. "|" .. tostring(grade)
			local row = index[key]
			if row == nil then
				row = { resource = res, grade = grade, milli = 0 }
				index[key] = row
				table.insert(rows, row)
			end
			row.milli += v
		end
	end
	if hm.apply_dex_to_home_material and dexRes ~= nil then
		for _, row in rows do
			row.milli = Formulas.dexScaledMilli(row.milli, dexRes[row.resource] or 0)
		end
	end
	return rows
end

-- 資源別に合算した方置特殊財（milli/日）
function Economy.homeMaterialPerDay(self: Economy, members: { Member }, dexRes: { [string]: number }?): { [string]: number }
	local out: { [string]: number } = {}
	for _, row in self:homeMaterialDetail(members, dexRes) do
		out[row.resource] = (out[row.resource] or 0) + row.milli
	end
	return out
end

-- level → level+1 の強化コスト（生成表 + 狩り素材の関門 hunt_gates）。新しい配列を返す
function Economy.facilityLevelCost(self: Economy, fid: string, level: number): { { resource: string, amount: number } }
	local fac = self.gd.facilities[fid]
	if fac == nil then
		error(`Economy: 시설 없음 '{fid}'`)
	end
	local base = self.gd.cost[fac.cost_curve][level]
	if base == nil then
		error(`Economy: 비용 표에 레벨 없음 {fid} Lv{level}`)
	end
	local out = {}
	for _, c in base do
		table.insert(out, { resource = c.resource, amount = c.amount })
	end
	for _, g in fac.hunt_gates do
		if g.to_level == level + 1 then
			for _, c in g.costs do
				table.insert(out, { resource = c.resource, amount = c.amount })
			end
		end
	end
	return out
end

-- ---- 直接採集 ----

function Economy.toolMult(self: Economy, toolId: string, level: number): number
	local tool = self.gd.tools[toolId]
	if tool == nil then
		error(`Economy: 도구 없음 '{toolId}'`)
	end
	local v = self.gd.bonus[tool.bonus_curve][level]
	if v == nil then
		error(`Economy: 도구 배율 표에 레벨 없음 {toolId} Lv{level}`)
	end
	return v
end

-- 特殊ノード（requires_node_trait）は対応する特性の同行がいるときだけ開く
function Economy.nodeOpen(self: Economy, node: any, party: { Member }): boolean
	if not node.requires_node_trait then
		return true
	end
	local kind = node.node_kind or ""
	for _, m in party do
		local kinds = self.nodeKinds[m.species]
		if kinds ~= nil and kinds[kind] then
			return true
		end
	end
	return false
end

-- 直接採集（milli/活動時間）。party は同行精霊
function Economy.directRate(self: Economy, node: any, toolId: string, toolLevel: number, party: { Member }): number
	if not self:nodeOpen(node, party) then
		return 0
	end
	local powers = {}
	for _, m in party do
		local g = indOf(m)
		table.insert(powers, self:companionPower(m.species, m.level, node.resource, g))
	end
	local bonus = Formulas.companionBonusBps(powers, self.kComp, self.gRef)
	return Formulas.directRateMilliPerHour(node.base_per_hour, self:toolMult(toolId, toolLevel), bonus)
end

return Economy
