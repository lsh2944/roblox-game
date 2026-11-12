--!strict
-- ServerRng: 用途別の乱数ストリーム（spawn・capture・individual）。乱数源は注入する（本番 = Roblox Random、テスト = 固定数列）
-- 配置: ServerScriptService.Server.ServerRng（Rojo: game/src/server/ServerRng.luau）
-- 依存: なし。Roblox API はモジュール読み込み時に呼ばない（Random は Main が robloxFactory に渡す）。Lune でも動く
--
-- 計画書 4.3「서버 RNG 규약」:
-- - 用途別にストリームを分ける（捕獲判定が出現回数・個体値の抽選回数に影響されない）
-- - uniform は [0,1)。乱数源が範囲外を返したら引き直す（Random:NextNumber の範囲は公式に明記なし。S7 の標本で確認）
-- - intInclusive(a, b) は両端を含む整数。範囲外・非整数なら引き直す（NextInteger の端の扱いも公式に明記なし）
-- - 遭遇ごとの固定ブロック（1 + 2·K_max 個）は block で引く。ブロックはクライアントへ送らない
-- sim の sha256 シード派生・メルセンヌツイスタは移植しない（シミュの対比較用）。

local ServerRng = {}
ServerRng.__index = ServerRng

ServerRng.STREAMS = table.freeze({ "spawn", "capture", "individual" })
ServerRng.MAX_REDRAW = 16

-- 乱数源: number() は [0,1) を、integer(a, b) は a..b の整数を返す想定（守られなければ引き直し → 上限で error）
export type Provider = {
	number: () -> number,
	integer: (a: number, b: number) -> number,
}

export type ServerRng = typeof(setmetatable({} :: { streams: { [string]: Provider } }, ServerRng))

-- factory(stream 名) がストリームごとに独立した乱数源を返す
function ServerRng.new(factory: (stream: string) -> Provider): ServerRng
	local streams: { [string]: Provider } = {}
	for _, s in ServerRng.STREAMS do
		streams[s] = factory(s)
	end
	return setmetatable({ streams = streams }, ServerRng)
end

-- 本番用: Roblox の Random コンストラクタ（Random.new）を受け取り、ストリームごとに別インスタンスを作る（シードは自動）
function ServerRng.robloxFactory(randomNew: () -> any): (stream: string) -> Provider
	return function(_stream: string): Provider
		local r = randomNew()
		return {
			number = function(): number
				return r:NextNumber()
			end,
			integer = function(a: number, b: number): number
				return r:NextInteger(a, b)
			end,
		}
	end
end

local function stream(self: ServerRng, name: string): Provider
	local p = self.streams[name]
	if p == nil then
		error(`ServerRng: 없는 스트림 '{tostring(name)}'`)
	end
	return p
end

function ServerRng.uniform(self: ServerRng, name: string): number
	local p = stream(self, name)
	for _ = 1, ServerRng.MAX_REDRAW do
		local u = p.number()
		if type(u) == "number" and u >= 0 and u < 1 then
			return u
		end
	end
	error(`ServerRng: {name} 스트림이 [0,1) 밖의 값을 계속 반환함`)
end

function ServerRng.block(self: ServerRng, name: string, n: number): { number }
	local out = table.create(n)
	for i = 1, n do
		out[i] = self:uniform(name)
	end
	return out
end

function ServerRng.intInclusive(self: ServerRng, name: string, a: number, b: number): number
	if type(a) ~= "number" or type(b) ~= "number" or math.floor(a) ~= a or math.floor(b) ~= b or a > b then
		error(`ServerRng.intInclusive: 정수 a ≤ b 필요 ({tostring(a)}, {tostring(b)})`)
	end
	local p = stream(self, name)
	for _ = 1, ServerRng.MAX_REDRAW do
		local v = p.integer(a, b)
		if type(v) == "number" and math.floor(v) == v and v >= a and v <= b then
			return v
		end
	end
	error(`ServerRng: {name} 스트림이 [{a},{b}] 밖의 정수를 계속 반환함`)
end

return ServerRng
