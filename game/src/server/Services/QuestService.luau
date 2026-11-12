--!strict
-- QuestService: 日次依頼（接続報酬）の受取（S9。保存データ PlayerSaveV1 の quest_day・wallet を更新する）
-- 配置: ServerScriptService.Server.Services.QuestService（Rojo: game/src/server/Services/QuestService.luau）
-- 依存（new の deps で注入）: ReplicatedStorage.Shared の QuestRules・Ledger インスタンス・GameData.build の結果、
--   フック beforeChange（変更前の精算）。Roblox API 不使用（Lune でも動く）
--
-- 規則は QuestRules の頭書き（UTC 日 = floor(秒/86400)、1 日 1 回、解禁済み最高フィールドの行）。
-- 接続時の自動付与（読み込み → オフライン精算の後）と ClaimDaily の両方からこの claim を呼ぶ。nowSec はゲーム時計 Clock.now()。

local QuestService = {}
QuestService.__index = QuestService

type Deps = {
	gd: any,
	QuestRules: any,
	ledger: any,
	beforeChange: ((userId: number, save: any, nowSec: number) -> ())?,
}

export type QuestService = typeof(setmetatable({} :: { deps: Deps }, QuestService))

function QuestService.new(deps: Deps): QuestService
	return setmetatable({ deps = deps }, QuestService)
end

-- 戻り値 RemoteResult（data = { day, rewards }）
function QuestService.claim(self: QuestService, userId: number, save: any, nowSec: number): any
	local d = self.deps
	local day, code = d.QuestRules.checkClaim(save, nowSec)
	if code ~= nil then
		return { ok = false, code = code }
	end
	local rewards = d.QuestRules.rewards(d.gd, save)
	if d.beforeChange ~= nil then
		d.beforeChange(userId, save, nowSec)
	end
	d.ledger:grant(save.wallet, rewards) -- 全行を検査してから付与（途中の error で一部だけ付与されない）
	save.quest_day = day
	return { ok = true, data = { day = day, rewards = rewards } }
end

return QuestService
