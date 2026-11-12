--!strict
-- Ledger: milli 単位の財布の操作（払えるか・全部払うか何もしない・付与）
-- 配置: ReplicatedStorage.Shared.Ledger（Rojo: game/src/shared/Ledger.luau）
-- 依存: Formulas, Net（同じフォルダ）、GameData.build の結果（引数で受け取る。Roblox API 不使用）
--
-- 財布 wallet = { [資源 ID] = milli }（1 個 = 1000 milli、未登場の資源は 0 扱い）。コストは整数の「個」（data の amount）。
-- atomic 品目（道標など stack=atomic）は展開フック expandAtomic を差し込むまで支払い不可（error）。
-- MVP1 の meadow スライスのコストに atomic 品目は無い（フィールド解禁は範囲外）。

local Formulas = require("./Formulas")
local Net = require("./Net")

local MILLI = Formulas.MILLI
local assertSafe = Formulas.assertSafe

export type Cost = { resource: string, amount: number }
export type Wallet = { [string]: number }

type LedgerData = {
	gd: any,
	-- atomic 品目を素材へ展開するフック（後で econ_sim model.expand_costs を移植して差し込む）
	expandAtomic: ((costs: { Cost }) -> { Cost })?,
}

local Ledger = {}
Ledger.__index = Ledger

export type Ledger = typeof(setmetatable({} :: LedgerData, Ledger))

function Ledger.new(gd: any, expandAtomic: ((costs: { Cost }) -> { Cost })?): Ledger
	return setmetatable({ gd = gd, expandAtomic = expandAtomic } :: LedgerData, Ledger)
end

local function checkResource(self: Ledger, res: string)
	if type(res) ~= "string" or self.gd.resources[res] == nil then
		error(`Ledger: 알 수 없는 자원 '{tostring(res)}'`)
	end
end

-- コスト配列 → 資源別の必要 milli（同じ資源は合算）。atomic 品目は展開フックを通す
function Ledger.need(self: Ledger, costs: { Cost }): { [string]: number }
	local list = costs
	for _, c in costs do
		checkResource(self, c.resource)
		if self.gd.resources[c.resource].stack == "atomic" then
			if self.expandAtomic == nil then
				error(`Ledger: atomic 품목 '{c.resource}'의 전개 hook이 없음`)
			end
			list = (self.expandAtomic :: any)(costs)
			break
		end
	end
	local out: { [string]: number } = {}
	for _, c in list do
		checkResource(self, c.resource)
		if self.gd.resources[c.resource].stack == "atomic" then
			error(`Ledger: 전개 후에도 atomic 품목이 남음 '{c.resource}'`)
		end
		assertSafe(c.amount)
		if c.amount < 0 then
			error(`Ledger: 음수 비용 {c.resource} {c.amount}`)
		end
		local milli = c.amount * MILLI
		local total = (out[c.resource] or 0) + milli
		assertSafe(total)
		out[c.resource] = total
	end
	return out
end

function Ledger.balance(_self: Ledger, wallet: Wallet, res: string): number
	return wallet[res] or 0
end

function Ledger.canAfford(self: Ledger, wallet: Wallet, costs: { Cost }): boolean
	for res, milli in self:need(costs) do
		if (wallet[res] or 0) < milli then
			return false
		end
	end
	return true
end

-- 全部払えるときだけ差し引く。払えなければ wallet を一切変えずに (false, INSUFFICIENT)
function Ledger.spend(self: Ledger, wallet: Wallet, costs: { Cost }): (boolean, string?)
	local need = self:need(costs)
	for res, milli in need do
		if (wallet[res] or 0) < milli then
			return false, Net.ErrorCode.INSUFFICIENT
		end
	end
	for res, milli in need do
		wallet[res] = (wallet[res] or 0) - milli
	end
	return true, nil
end

-- milli 単位で付与（放置生産・採集の端数込み）
function Ledger.grantMilli(self: Ledger, wallet: Wallet, res: string, milli: number)
	checkResource(self, res)
	assertSafe(milli)
	if milli < 0 then
		error(`Ledger: 음수 지급 {res} {milli}`)
	end
	local total = (wallet[res] or 0) + milli
	assertSafe(total)
	wallet[res] = total
end

-- 個単位のコスト配列をそのまま付与（日次依頼・開始資源・制作の産出）
-- 先に全行を検査してから付与する（途中の error で一部だけ付与されることを防ぐ）
function Ledger.grant(self: Ledger, wallet: Wallet, costs: { Cost })
	for _, c in costs do
		checkResource(self, c.resource)
		assertSafe(c.amount)
		if c.amount < 0 then
			error(`Ledger: 음수 지급 {c.resource} {c.amount}`)
		end
	end
	for _, c in costs do
		self:grantMilli(wallet, c.resource, c.amount * MILLI)
	end
end

return Ledger
