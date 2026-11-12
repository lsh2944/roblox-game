--!strict
-- QuestRules: 日次依頼（接続報酬）の純粋な判定
-- 配置: ReplicatedStorage.Shared.QuestRules（Rojo: game/src/shared/QuestRules.luau）
-- 依存: Net・FacilityRules（同じフォルダ）、GameData.build の結果（引数）。Roblox API 不使用（Lune でも動く）
-- 状態の変更は ServerScriptService.Server.Services.QuestService。
--
-- 規則の出典:
-- - Q12 決定: 日付は UTC 0 時で切り替え。UTC 日 = floor(秒 / 86400)（sim と同じ UTC 基準。ゲーム時計 Clock.now の秒を渡す）
-- - 1 日 1 回: save.quest_day ≥ 今日 なら受取済み（== だけでなく ≥ にして、時計が戻ったときの二重受取を防ぐ）
-- - reward_mode = highest_unlocked_field: 解禁済みで最も順位が高いフィールドの行だけ（sim.py quest_rewards_now）
-- - requires = "login" の依頼だけ扱う（data に他は無い。未知の値は誤りとして止める）

local Net = require("./Net")
local FacilityRules = require("./FacilityRules")

local QuestRules = {}

QuestRules.SECONDS_PER_DAY = 86400

function QuestRules.utcDay(nowSec: number): number
	return nowSec // QuestRules.SECONDS_PER_DAY
end

-- 今日受け取れる報酬（個のコスト配列、data の並び順）
function QuestRules.rewards(gd: any, save: any): { { resource: string, amount: number } }
	local top = FacilityRules.topUnlockedField(gd, save.unlocked)
	local out = {}
	for _, q in gd.docs.daily_quests.quests do
		if q.requires ~= "login" or q.reward_mode ~= "highest_unlocked_field" then
			error(`QuestRules: 미지원 의뢰 '{q.id}' requires={q.requires} reward_mode={q.reward_mode}`)
		end
		for _, row in q.rewards_by_field do
			if row.field_id == top then
				for _, r in row.rewards do
					table.insert(out, { resource = r.resource, amount = r.amount })
				end
			end
		end
	end
	return out
end

-- 受取の検証。戻り値 (UTC 日 | nil, エラーコード | nil)
function QuestRules.checkClaim(save: any, nowSec: number): (number?, string?)
	local day = QuestRules.utcDay(nowSec)
	if save.quest_day >= day then
		return nil, Net.ErrorCode.ALREADY_CLAIMED
	end
	return day, nil
end

return table.freeze(QuestRules)
