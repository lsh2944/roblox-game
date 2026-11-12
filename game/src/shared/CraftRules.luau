--!strict
-- CraftRules: 在庫制作（stock レシピ）の純粋な判定と費用・産出の計算
-- 配置: ReplicatedStorage.Shared.CraftRules（Rojo: game/src/shared/CraftRules.luau）
-- 依存: Net（同じフォルダ）、GameData.build の結果（引数）。Roblox API 不使用（Lune でも動く）
-- 状態の変更は ServerScriptService.Server.Services.CraftService（Ledger で原子的に差し引き・付与）。
--
-- 規則の出典（計画書 4.2・4.3 Remote 表）: stock レシピだけ、許可リスト（スライスは wick_from_meadow、Config.CRAFT_ALLOWED）、
-- 回数 times は整数 1..上限（Config.CRAFT_MAX_TIMES = 100）。投入 = inputs × times、産出 = output × times（sim.py craft）

local Net = require("./Net")

local E = Net.ErrorCode

local CraftRules = {}

export type Cost = { resource: string, amount: number }

-- 戻り値 (投入, 産出, nil) | (nil, nil, エラーコード)
function CraftRules.check(gd: any, recipeId: any, times: any, allowed: { string }, maxTimes: number): ({ Cost }?, Cost?, string?)
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
	local inputs = {}
	for _, x in rec.inputs do
		table.insert(inputs, { resource = x.resource, amount = x.amount * times })
	end
	return inputs, { resource = rec.output.resource, amount = rec.output.amount * times }, nil
end

return table.freeze(CraftRules)
