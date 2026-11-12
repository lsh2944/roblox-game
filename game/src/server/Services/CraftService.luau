--!strict
-- CraftService: 在庫制作（S9。stock レシピ・許可リスト・回数 1..100、保存データ PlayerSaveV1 の wallet を更新する）
-- 配置: ServerScriptService.Server.Services.CraftService（Rojo: game/src/server/Services/CraftService.luau）
-- 依存（new の deps で注入）: ReplicatedStorage.Shared の CraftRules・Ledger インスタンス・GameData.build の結果、
--   Config.CRAFT_ALLOWED・CRAFT_MAX_TIMES、フック beforeChange（変更前の精算）。Roblox API 不使用（Lune でも動く）
--
-- 原子性: 産出の資源を先に検査し（Ledger.need が未知・atomic を error にする）、投入を Ledger.spend（全部払うか何もしない）で
-- 差し引いてから産出を付与する。払えなければ wallet は一切変わらない。

local CraftService = {}
CraftService.__index = CraftService

type Deps = {
	gd: any,
	CraftRules: any,
	ledger: any,
	allowed: { string },
	maxTimes: number,
	beforeChange: ((userId: number, save: any, nowSec: number) -> ())?,
}

export type CraftService = typeof(setmetatable({} :: { deps: Deps }, CraftService))

function CraftService.new(deps: Deps): CraftService
	return setmetatable({ deps = deps }, CraftService)
end

-- Craft(recipeId, times)。戻り値 RemoteResult（data = { recipeId, times, output }）
function CraftService.craft(self: CraftService, userId: number, save: any, recipeId: any, times: any, nowSec: number): any
	local d = self.deps
	local inputs, output, code = d.CraftRules.check(d.gd, recipeId, times, d.allowed, d.maxTimes)
	if code ~= nil then
		return { ok = false, code = code }
	end
	d.ledger:need({ output :: any }) -- 産出の資源を差し引く前に検査（error なら何も変わらない）
	if d.beforeChange ~= nil then
		d.beforeChange(userId, save, nowSec)
	end
	local ok, err = d.ledger:spend(save.wallet, inputs)
	if not ok then
		return { ok = false, code = err }
	end
	d.ledger:grant(save.wallet, { output :: any })
	return { ok = true, data = { recipeId = recipeId, times = times, output = output } }
end

return CraftService
