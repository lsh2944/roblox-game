--!strict
-- RosterRules: 保管箱・同行・放出・精霊レベルアップの純粋な判定（状態は変えない）
-- 配置: ReplicatedStorage.Shared.RosterRules（Rojo: game/src/shared/RosterRules.luau）
-- 依存: Net（同じフォルダ）、GameData.build の結果（引数）。Roblox API 不使用（Lune でも動く）
-- 状態の変更は ServerScriptService.Server.Services.RosterService（同行・放出・レベルアップ）と CaptureService（捕獲の追加）。
--
-- 規則の出典:
-- - 保有上限 = min(storage.max_capacity, base_capacity + 拠点等級の storage_bonus 合計 + save.storage_bonus)（sim.py capacity）
-- - Q4 決定: 保管箱が満杯なら捕獲開始を止め、手動の放出を案内する（自動放出はしない）
-- - Q3 決定: 同行と施設配置は排他。同行枠 = rules.constants.companion_slots
-- - 放出の研究ポイント = spirits.release_research_by_grade の等級別 amount（個）を kind=research の資源へ（sim.py _release_one）
-- - 精霊レベルアップ（Q6）: 費用 = 生成表 cost[level_cost_curve][level]、上限 = その表の max_level（economy.py max_spirit_level）

local Net = require("./Net")

local E = Net.ErrorCode

local RosterRules = {}

function RosterRules.count(save: any): number
	local n = 0
	for _ in save.roster do
		n += 1
	end
	return n
end

function RosterRules.capacity(gd: any, save: any): number
	local hub = gd.hub
	local bonus = 0
	for _, r in hub.ranks do
		if r.rank <= save.hub_rank then
			bonus += r.storage_bonus
		end
	end
	return math.min(hub.storage.max_capacity, hub.storage.base_capacity + bonus + save.storage_bonus)
end

function RosterRules.isFull(gd: any, save: any): boolean
	return RosterRules.count(save) >= RosterRules.capacity(gd, save)
end

-- uid がどこかの施設に配置されていれば施設 ID
function RosterRules.assignedFacility(save: any, uid: string): string?
	for fid, f in save.facilities do
		if table.find(f.assigned, uid) ~= nil then
			return fid
		end
	end
	return nil
end

-- 同行の検証（uids = 新しい同行の全体）。戻り値 エラーコード | nil
function RosterRules.checkParty(gd: any, save: any, uids: any): string?
	if type(uids) ~= "table" then
		return E.BAD_ARG
	end
	local n = 0
	for k, v in uids do
		n += 1
		if type(k) ~= "number" or type(v) ~= "string" then
			return E.BAD_ARG
		end
	end
	if n ~= #uids then
		return E.BAD_ARG
	end
	if n > gd.constants.companion_slots then
		return E.PARTY_FULL
	end
	local seen: { [string]: boolean } = {}
	for _, uid in uids do
		if save.roster[uid] == nil then
			return E.NOT_FOUND
		end
		if seen[uid] then
			return E.DUPLICATE
		end
		seen[uid] = true
		if RosterRules.assignedFacility(save, uid) ~= nil then
			return E.ASSIGNED_ELSEWHERE
		end
	end
	return nil
end

-- 研究ポイントの資源（kind=research の最初の資源。無ければ nil = 付与なし、sim と同じ）
function RosterRules.researchResource(gd: any): string?
	for _, rid in gd.resourceOrder do
		if gd.resources[rid].kind == "research" then
			return rid
		end
	end
	return nil
end

-- 等級別の放出報酬（個）
function RosterRules.releaseResearch(gd: any, grade: number): number
	for _, g in gd.docs.spirits.release_research_by_grade do
		if g.grade == grade then
			return g.amount
		end
	end
	error(`RosterRules: release_research_by_grade에 등급 {grade} 없음`)
end

-- 放出の検証。同行中・施設配置中の精霊は放出できない（先に外す。生産・同行が黙って変わらないように）
function RosterRules.checkRelease(save: any, uid: any): string?
	if type(uid) ~= "string" then
		return E.BAD_ARG
	end
	if save.roster[uid] == nil then
		return E.NOT_FOUND
	end
	if table.find(save.party, uid) ~= nil or RosterRules.assignedFacility(save, uid) ~= nil then
		return E.ASSIGNED_ELSEWHERE
	end
	return nil
end

-- レベルアップの費用（level → level+1）。上限なら (nil, LEVEL_CAP)
function RosterRules.levelUpCost(gd: any, species: string, level: number): ({ { resource: string, amount: number } }?, string?)
	local sp = gd.spirits[species]
	if sp == nil then
		error(`RosterRules: 정령 없음 '{species}'`)
	end
	local curve = sp.level_cost_curve
	local maxLv = gd.costMax[curve]
	if maxLv == nil then
		error(`RosterRules: 비용 표 없음 '{curve}'`)
	end
	if level >= maxLv then
		return nil, E.LEVEL_CAP
	end
	local row = gd.cost[curve][level]
	if row == nil or gd.bonus[sp.ability_curve][level + 1] == nil then
		error(`RosterRules: 표에 레벨 없음 {species} Lv{level}`)
	end
	local out = {}
	for _, c in row do
		table.insert(out, { resource = c.resource, amount = c.amount })
	end
	return out, nil
end

return table.freeze(RosterRules)
