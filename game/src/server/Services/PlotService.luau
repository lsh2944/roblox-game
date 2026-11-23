--!strict
-- PlotService: プレイヤーごとの家の部地の割り当て（接続順に空いている一番小さい番号、退出で返却）
-- 配置: ServerScriptService.Server.Services.PlotService（Rojo: game/src/server/Services/PlotService.luau）
-- 依存: なし（部地の数は new の引数。Main は #Config.WORLD.plots）。Roblox API 不使用（Lune でも動く）
--
-- 規則（world_hud_design W1 決定: サーバー 8 人 = 部地 8 個、W4: 接続時は自分の部地から始める）:
-- - assign は同じプレイヤーには同じ番号を返す（二重の PlayerAdded でも 2 つ取らない）
-- - 満員なら nil（Experience の最大人数を部地の数に合わせるのが前提。nil のプレイヤーは広場から始まり、ログを残す）
-- - release で返却した番号は次の assign で再び使う（空き番号の小さい順）
-- - 部地は実行時だけの状態（保存しない）。後の訪問機能はこの対応表（ownerOf）を使う

local PlotService = {}
PlotService.__index = PlotService

export type PlotService = typeof(setmetatable(
	{} :: { count: number, byUser: { [number]: number }, owner: { [number]: number } },
	PlotService
))

function PlotService.new(count: number): PlotService
	assert(type(count) == "number" and count >= 1 and math.floor(count) == count, "PlotService: count 는 1 이상 정수")
	return setmetatable({ count = count, byUser = {}, owner = {} }, PlotService)
end

-- 戻り値: 部地の番号（1..count）、満員なら nil
function PlotService.assign(self: PlotService, userId: number): number?
	local cur = self.byUser[userId]
	if cur ~= nil then
		return cur
	end
	for i = 1, self.count do
		if self.owner[i] == nil then
			self.owner[i] = userId
			self.byUser[userId] = i
			return i
		end
	end
	return nil
end

-- 返却。戻り値 = 返した番号（持っていなければ nil）
function PlotService.release(self: PlotService, userId: number): number?
	local i = self.byUser[userId]
	if i == nil then
		return nil
	end
	self.byUser[userId] = nil
	if self.owner[i] == userId then
		self.owner[i] = nil
	end
	return i
end

function PlotService.plotOf(self: PlotService, userId: number): number?
	return self.byUser[userId]
end

function PlotService.ownerOf(self: PlotService, index: number): number?
	return self.owner[index]
end

return PlotService
