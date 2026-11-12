--!strict
-- Activity: プレイヤーごとの現在の活動（採集 ⟂ 捕獲。活動は一度に 1 つ、計画書 4.3）。実行時だけの状態で保存しない
-- 配置: ServerScriptService.Server.Services.Activity（Rojo: game/src/server/Services/Activity.luau）
-- 依存: なし。Roblox API 不使用（Lune でも動く）。GatherService と CaptureService が同じインスタンスを共有する

local Activity = {}
Activity.__index = Activity

export type Kind = "gather" | "encounter"

export type Activity = typeof(setmetatable({} :: { cur: { [number]: Kind } }, Activity))

function Activity.new(): Activity
	return setmetatable({ cur = {} }, Activity)
end

-- 現在の活動（無ければ nil = 遊休）
function Activity.get(self: Activity, userId: number): Kind?
	return self.cur[userId]
end

function Activity.set(self: Activity, userId: number, kind: Kind)
	self.cur[userId] = kind
end

-- kind を渡したときは、その活動中のときだけ外す（別の活動を誤って消さない）
function Activity.clear(self: Activity, userId: number, kind: Kind?)
	if kind == nil or self.cur[userId] == kind then
		self.cur[userId] = nil
	end
end

return Activity
