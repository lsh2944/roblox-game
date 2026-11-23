--!strict
-- Remoting: Remote の結線と、C→S 要求の唯一の入口（レート → 検証 → 読み込み確認 → 処理）、StateChanged のまとめ送信
-- 配置: ServerScriptService.Server.Net.Remoting（Rojo: game/src/server/Net/Remoting.luau）
-- 依存（new の deps で注入）: ReplicatedStorage.Shared.Net、Net.RateLimiter・Net.PushThrottle インスタンス、Net.Validate の schemas の結果、
--   Remote 実体（名前 → RemoteFunction / RemoteEvent。Main が ReplicatedStorage.Remotes から集める）、保存データの取得 getSave、
--   ゲーム時計 now、log。Roblox API は Remote 実体のメソッド（OnServerInvoke・OnServerEvent:Connect・FireClient）だけ
--   （Lune では偽の Remote を渡して dispatch・送信を検証する）
--
-- 規則（計画書 4.3、world_hud_design W3・W5 決定）:
-- - C→S Remote（Net.Directions = "C2S"）の受け口はここだけ。OnServerInvoke・OnServerEvent を設定するのはこのモジュールだけ
--   （ProximityPrompt などの別の入口を作らない。lune_run がソース全体を走査して確かめる）
-- - 順序: レート（超過は捨てて RATE_LIMITED、回数を記録・追放なし）→ 引数の検証（BAD_ARG）→ 保存データの読み込み済み確認（NOT_READY）
--   → 同じプレイヤーの処理中でないか（BUSY。サービスは同期処理なので通常は起きない防御）→ 処理（pcall。例外は INTERNAL）
-- - RF の応答は { ok, code?, data? }。処理の戻り値がこの形でなければ INTERNAL（形の崩れた応答を返さない）
-- - 処理を登録していない C→S Remote は start が「未実装」処理（NOT_IMPLEMENTED）で結線する: レートと検証は通常どおり通る
-- - 状態を変える処理（opts.mutates）は成功（ok=true）したら StateChanged の印を付ける。状態変更前の精算（IdleService.settle）は
--   各サービスの beforeChange フックが検証の後に行う（サービスの既存契約）。例外時の状態の扱いもサービスの契約に従う
--   （サービスは検証を状態変更の前にまとめ、精算は写しで計算して成功時だけ反映する）
-- - 1 つの Remote に処理を 2 回登録すると error（入口を二重にしない）

local Remoting = {}
Remoting.__index = Remoting

export type Ctx = { userId: number, player: any, save: any, now: number }
export type Handler = (ctx: Ctx, ...any) -> any
export type BindOpts = { mutates: boolean? }

type Deps = {
	Net: any,
	remotes: { [string]: any }, -- 名前 → Remote 実体
	limiter: any, -- RateLimiter
	throttle: any, -- PushThrottle
	schemas: { [string]: { any } }, -- Validate.schemas
	Validate: any,
	getSave: (userId: number) -> any, -- 読み込み済みの保存データ（無ければ nil）
	now: () -> number, -- ゲーム時計の秒（Clock:now）
	-- スナップショットの作成（Main が Snapshot.build を包む）。seq は Remoting がプレイヤーごとに 1 ずつ増やして渡す。
	-- forResponse = true は GetSnapshot の応答（帰還要約を含める）、false は StateChanged
	buildSnapshot: ((userId: number, save: any, nowSec: number, seq: number, forResponse: boolean) -> any)?,
	log: (msg: string) -> (),
}

export type Remoting = typeof(setmetatable(
	{} :: {
		deps: Deps,
		handlers: { [string]: { fn: Handler, mutates: boolean } },
		inFlight: { [number]: boolean },
		badArgs: { [number]: number },
		seq: { [number]: number },
		started: boolean,
	},
	Remoting
))

local function response(ok: boolean, code: string?, data: any?): any
	return { ok = ok, code = code, data = data }
end

function Remoting.new(deps: Deps): Remoting
	local self = setmetatable({ deps = deps, handlers = {}, inFlight = {}, badArgs = {}, seq = {}, started = false }, Remoting)
	-- C→S Remote はすべてレートとスキーマを持つこと（漏れは起動時に止める）
	for name, dir in deps.Net.Directions do
		if dir == "C2S" then
			deps.limiter:rate(name) -- 無ければ error
			if deps.schemas[name] == nil then
				error(`Remoting: 스키마 미정의 Remote '{name}'`)
			end
		end
	end
	return self
end

-- 処理の登録（start の前に呼ぶ）
function Remoting.bind(self: Remoting, name: string, fn: Handler, opts: BindOpts?)
	local Net = self.deps.Net
	if self.started then
		error(`Remoting.bind: start 후에는 등록할 수 없음 '{name}'`)
	end
	if Net.Directions[name] ~= "C2S" then
		error(`Remoting.bind: C→S Remote 가 아님 '{name}'`)
	end
	if self.handlers[name] ~= nil then
		error(`Remoting.bind: 이미 등록됨 '{name}'(입구를 두 개 만들지 않음)`)
	end
	self.handlers[name] = { fn = fn, mutates = opts ~= nil and opts.mutates == true }
end

-- 回数を 1, 10, 100, … のときだけログに出す（ログを溢れさせない）
local function isLogPoint(n: number): boolean
	while n >= 10 and n % 10 == 0 do
		n //= 10
	end
	return n == 1
end

-- 要求 1 件の処理（RF の応答を返す。RE でも同じ順序で通し、応答は捨てる）
function Remoting.dispatch(self: Remoting, name: string, player: any, n: number, ...: any): any
	local d = self.deps
	local Net = d.Net
	local userId = player.UserId
	local okRate, drops = d.limiter:take(userId, name)
	if not okRate then
		if isLogPoint(drops) then
			d.log(`[Net] u_{userId} {name} 레이트 초과로 버림(누적 {drops}회)`)
		end
		return response(false, Net.ErrorCode.RATE_LIMITED)
	end
	local okArgs, why = d.Validate.args(d.schemas[name], n, ...)
	if not okArgs then
		local c = (self.badArgs[userId] or 0) + 1
		self.badArgs[userId] = c
		if isLogPoint(c) then
			d.log(`[Net] u_{userId} {name} 잘못된 인자 거부: {why}(누적 {c}회)`)
		end
		return response(false, Net.ErrorCode.BAD_ARG)
	end
	local save = d.getSave(userId)
	if save == nil then
		return response(false, Net.ErrorCode.NOT_READY)
	end
	if self.inFlight[userId] then
		return response(false, Net.ErrorCode.BUSY)
	end
	local h = self.handlers[name]
	if h == nil then
		return response(false, Net.ErrorCode.NOT_IMPLEMENTED)
	end
	local ctx: Ctx = { userId = userId, player = player, save = save, now = d.now() }
	self.inFlight[userId] = true
	local okCall, res = pcall(h.fn, ctx, ...)
	self.inFlight[userId] = nil
	if not okCall then
		d.log(`[Net] u_{userId} {name} 처리 중 오류: {tostring(res)}`)
		return response(false, Net.ErrorCode.INTERNAL)
	end
	if type(res) ~= "table" or type(res.ok) ~= "boolean" or (res.code ~= nil and type(res.code) ~= "string") then
		d.log(`[Net] u_{userId} {name} 처리 결과 형식 오류`)
		return response(false, Net.ErrorCode.INTERNAL)
	end
	if res.ok and h.mutates then
		d.throttle:mark(userId)
	end
	return response(res.ok, res.code, res.data)
end

-- 全 C→S Remote を結線する（未登録は NOT_IMPLEMENTED のまま dispatch が返す）。1 回だけ
function Remoting.start(self: Remoting)
	local d = self.deps
	if self.started then
		error("Remoting.start: 두 번 호출됨")
	end
	self.started = true
	for name, dir in d.Net.Directions do
		local remote = d.remotes[name]
		if remote == nil then
			error(`Remoting.start: Remote 실체 없음 '{name}'`)
		end
		if dir ~= "C2S" then
			continue
		end
		local kind = d.Net.RemoteKinds[name]
		if kind == "RF" then
			remote.OnServerInvoke = function(player: any, ...: any): any
				return self:dispatch(name, player, select("#", ...), ...)
			end
		else
			remote.OnServerEvent:Connect(function(player: any, ...: any)
				self:dispatch(name, player, select("#", ...), ...)
			end)
		end
	end
end

-- 状態が変わったことの印（サービスの外の変更・毎分の財布更新など）
function Remoting.markDirty(self: Remoting, userId: number)
	self.deps.throttle:mark(userId)
end

-- スナップショットを 1 つ作る（seq を進める）。GetSnapshot の処理（forResponse = true）と flush が使う
function Remoting.snapshot(self: Remoting, userId: number, save: any, nowSec: number, forResponse: boolean): any
	local build = self.deps.buildSnapshot
	if build == nil then
		error("Remoting.snapshot: buildSnapshot 없음")
	end
	local n = (self.seq[userId] or 0) + 1
	self.seq[userId] = n
	return build(userId, save, nowSec, n, forResponse)
end

-- StateChanged のまとめ送信（Main の送信ループが呼ぶ）。players = userId → Player。戻り値 = 送った人数
-- 送信の失敗（スナップショット作成の例外など）は 1 人ずつ pcall で包み、他のプレイヤーの送信を止めない
function Remoting.flush(self: Remoting, clockNow: number, players: (userId: number) -> any): number
	local d = self.deps
	if d.buildSnapshot == nil then
		return 0
	end
	local remote = d.remotes[d.Net.Remotes.StateChanged]
	local sent = 0
	for _, userId in d.throttle:due(clockNow) do
		local player = players(userId)
		local save = d.getSave(userId)
		if player ~= nil and save ~= nil then
			local ok, err = pcall(function()
				local snap = self:snapshot(userId, save, d.now(), false)
				remote:FireClient(player, snap)
			end)
			if ok then
				sent += 1
			else
				d.log(`[Net] u_{userId} StateChanged 전송 실패: {tostring(err)}`)
			end
		end
	end
	return sent
end

-- 退出時の後始末
function Remoting.forget(self: Remoting, userId: number)
	self.deps.limiter:forget(userId)
	self.deps.throttle:forget(userId)
	self.inFlight[userId] = nil
	self.badArgs[userId] = nil
	self.seq[userId] = nil
end

return Remoting
