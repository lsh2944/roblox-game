--!strict
-- RateLimiter: プレイヤーごと・Remote ごとのトークンバケット（計画書 4.3「레이트(플레이어별)」）
-- 配置: ServerScriptService.Server.Net.RateLimiter（Rojo: game/src/server/Net/RateLimiter.luau）
-- 依存: なし（時計 now は new の引数で注入。Main は os.clock）。Roblox API 不使用（Lune でも動く）
--
-- 規則:
-- - 容量 = 毎秒の補充数 = rates[remote]（例 2/s なら 2 個まで連続で通り、その後は 0.5 秒に 1 個）。最初は満杯
-- - 1 回の要求でトークン 1 個。足りなければ捨て（false）、プレイヤー・Remote 別に捨てた回数を数える。追放はしない
-- - rates に無い Remote は誤り（error。Remote を足したのに Config.REMOTE_RATES を忘れたら起動時に気付けるよう Remoting が全件を引く）
-- - 時計が戻った（now < 前回）ときは補充しない（トークンは増えも減りもしない）
-- - 退出時は forget で消す（メモリを残さない。再入室は満杯から）

local RateLimiter = {}
RateLimiter.__index = RateLimiter

type Bucket = { tokens: number, last: number }

export type RateLimiter = typeof(setmetatable(
	{} :: {
		rates: { [string]: number },
		now: () -> number,
		buckets: { [number]: { [string]: Bucket } },
		drops: { [number]: { [string]: number } },
	},
	RateLimiter
))

function RateLimiter.new(rates: { [string]: number }, now: () -> number): RateLimiter
	for name, r in rates do
		if type(r) ~= "number" or r ~= r or r <= 0 or r == math.huge then
			error(`RateLimiter: '{name}' 의 레이트가 양수가 아님: {tostring(r)}`)
		end
	end
	return setmetatable({ rates = rates, now = now, buckets = {}, drops = {} }, RateLimiter)
end

function RateLimiter.rate(self: RateLimiter, remote: string): number
	local r = self.rates[remote]
	if r == nil then
		error(`RateLimiter: 레이트 미정의 Remote '{remote}'`)
	end
	return r
end

-- 1 回分のトークンを取る。戻り値 (通すか, 捨てた累計回数)
function RateLimiter.take(self: RateLimiter, userId: number, remote: string): (boolean, number)
	local rate = self:rate(remote)
	local t = self.now()
	local perUser = self.buckets[userId]
	if perUser == nil then
		perUser = {}
		self.buckets[userId] = perUser
	end
	local b = perUser[remote]
	if b == nil then
		b = { tokens = rate, last = t }
		perUser[remote] = b
	elseif t > b.last then
		b.tokens = math.min(rate, b.tokens + (t - b.last) * rate)
		b.last = t
	end
	if b.tokens >= 1 then
		b.tokens -= 1
		return true, self:dropCount(userId, remote)
	end
	local d = self.drops[userId]
	if d == nil then
		d = {}
		self.drops[userId] = d
	end
	local n = (d[remote] or 0) + 1
	d[remote] = n
	return false, n
end

function RateLimiter.dropCount(self: RateLimiter, userId: number, remote: string): number
	local d = self.drops[userId]
	return if d ~= nil then d[remote] or 0 else 0
end

function RateLimiter.forget(self: RateLimiter, userId: number)
	self.buckets[userId] = nil
	self.drops[userId] = nil
end

return RateLimiter
