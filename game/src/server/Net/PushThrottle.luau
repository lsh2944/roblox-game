--!strict
-- PushThrottle: StateChanged（S→C）の送信をプレイヤーごとにまとめる（変更の印 → 間隔の下限を守って 1 回にまとめて送る）
-- 配置: ServerScriptService.Server.Net.PushThrottle（Rojo: game/src/server/Net/PushThrottle.luau）
-- 依存: なし（時刻は due の引数）。Roblox API 不使用（Lune でも動く）
--
-- 規則（計画書 4.3 Remote 表「StateChanged: 서버 스로틀 4/s」）:
-- - mark(userId) は印を付けるだけ（何度呼んでも次の送信は 1 回）
-- - due(now) は「印があり、前回の送信から minInterval 秒以上たった」プレイヤーを返し、印を消して送信時刻を記録する。
--   返したプレイヤーへ送るのは呼び出し側（送信に失敗しても印は戻さない: 次の変更か毎分の更新でまた送る）
-- - 時計が戻った（now < 前回の送信）ときは間隔を満たしたとみなす（永久に送れなくなるのを防ぐ）
-- - forget(userId) は退出時に消す

local PushThrottle = {}
PushThrottle.__index = PushThrottle

export type PushThrottle = typeof(setmetatable(
	{} :: { minInterval: number, dirty: { [number]: boolean }, lastSent: { [number]: number } },
	PushThrottle
))

function PushThrottle.new(minInterval: number): PushThrottle
	assert(type(minInterval) == "number" and minInterval > 0, "PushThrottle: minInterval 은 양수")
	return setmetatable({ minInterval = minInterval, dirty = {}, lastSent = {} }, PushThrottle)
end

function PushThrottle.mark(self: PushThrottle, userId: number)
	self.dirty[userId] = true
end

function PushThrottle.isDirty(self: PushThrottle, userId: number): boolean
	return self.dirty[userId] == true
end

-- 送ってよいプレイヤー（userId 昇順。順序を固定してテストできるようにする）
function PushThrottle.due(self: PushThrottle, now: number): { number }
	local out = {}
	for userId in self.dirty do
		local last = self.lastSent[userId]
		if last == nil or now - last >= self.minInterval or now < last then
			table.insert(out, userId)
		end
	end
	table.sort(out)
	for _, userId in out do
		self.dirty[userId] = nil
		self.lastSent[userId] = now
	end
	return out
end

function PushThrottle.forget(self: PushThrottle, userId: number)
	self.dirty[userId] = nil
	self.lastSent[userId] = nil
end

return PushThrottle
