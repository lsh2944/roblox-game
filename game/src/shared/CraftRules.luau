--!strict
-- CraftRules: 在庫制作（stock レシピ）の純粋な判定と費用・産出の計算
-- 配置: ReplicatedStorage.Shared.CraftRules（Rojo: game/src/shared/CraftRules.luau）
-- 依存: Formulas・Net（同じフォルダ）、GameData.build の結果（引数）。Roblox API 不使用（Lune でも動く）
-- 状態の変更は ServerScriptService.Server.Services.CraftService（Ledger で原子的に差し引き・付与）。
--
-- 規則の出典（計画書 4.2・4.3 Remote 表）: stock レシピだけ、許可リスト（スライスは wick_from_meadow、Config.CRAFT_ALLOWED）、
-- 回数 times は整数 1..上限（Config.CRAFT_MAX_TIMES = 100）。投入 = inputs × times、産出 = output × times（sim.py craft）
-- 図鑑の制作材料減少（craft_cost_down、2026-11-12 決定）: 1 回の制作の総量（inputs × times）に項目ごとに掛ける（費用は切り上げ）。
-- dexSet（save.dex）を省略すると割引なし

local Formulas = require("./Formulas")
local Net = require("./Net")

local E = Net.ErrorCode

local CraftRules = {}

export type Cost = { resource: string, amount: number }

-- 戻り値 (投入, 産出, nil) | (nil, nil, エラーコード)
function CraftRules.check(
	gd: any,
	recipeId: any,
	times: any,
	allowed: { string },
	maxTimes: number,
	dexSet: { [string]: any }?
): ({ Cost }?, Cost?, string?)
	if type(recipeId) ~= "string" or type(times) ~= "number" or times ~= times or math.floor(times) ~= times then
		return nil, nil, E.BAD_ARG
	end
	if times < 1 or times > maxTimes then
		return nil, nil, E.BAD_ARG
	end
	local rec = gd.recipes[recipeId]
	if rec == nil then
		return nil, nil, E.NOT_FOUND
	end
	if rec.mode ~= "stock" or table.find(allowed, recipeId) == nil then
		return nil, nil, E.NOT_ALLOWED
	end
	local discount = if dexSet ~= nil then Formulas.dexBonusMapForSet(dexSet, gd.spirits, gd.rules.dex_bonus).craft_cost_down else 0
	local inputs = {}
	for _, x in rec.inputs do
		table.insert(inputs, { resource = x.resource, amount = Formulas.discountedCost(x.amount * times, discount) })
	end
	return inputs, { resource = rec.output.resource, amount = rec.output.amount * times }, nil
end

return table.freeze(CraftRules)
