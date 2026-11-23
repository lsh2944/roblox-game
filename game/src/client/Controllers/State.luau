--!strict
-- State: クライアントが受け取った最新のスナップショット（GetSnapshot の応答・StateChanged）と、表示用の推定値
-- 配置: StarterPlayer.StarterPlayerScripts.Client.Controllers.State（ModuleScript。Rojo: game/src/client/Controllers/State.luau）
-- 依存: new の引数で受け取る時計 clock（Main は os.clock）と ReplicatedStorage.Shared.HudFormat。Roblox API 不使用
--   （Lune の ClientStateSpec、Studio の TestRunner は StarterPlayer から読む）
--
-- 規則:
-- - seq が今より大きいスナップショットだけ採用する（GetSnapshot の応答と StateChanged の到着順が入れ替わっても古い状態に戻らない）
-- - 帰還収穫の要約（returnReport、GetSnapshot の応答にだけ入る）は seq に関係なく最初の 1 回だけ受け取り、takeReturnReport で 1 回だけ渡す
--   （S5 決定: サーバーはセッション中ずっと応答に入れ、表示を 1 回にするのはクライアント。画面は S8）
-- - サーバー時刻の推定 = snapshot.serverNow + (clock() − 受信時刻)。端末の時計ではなく受信からの経過で数える（Studio の時計オフセットにも追従）
-- - 財布の表示 = HudFormat.projectMilli(wallet, perHour, homePerDay, (serverNow − walletAt) + 受信からの経過, 上限) を units で切り捨て

local State = {}
State.__index = State

export type State = typeof(setmetatable(
	{} :: {
		clock: () -> number,
		HudFormat: any,
		snap: any?,
		receivedAt: number,
		listeners: { (snap: any) -> () },
		report: any?,
		reportTaken: boolean,
	},
	State
))

function State.new(clock: () -> number, HudFormat: any): State
	return setmetatable({
		clock = clock,
		HudFormat = HudFormat,
		snap = nil,
		receivedAt = 0,
		listeners = {},
		report = nil,
		reportTaken = false,
	}, State)
end

-- 受け取ったスナップショットを反映する。戻り値 = 採用したか（古い seq・形の崩れたものは捨てる）
function State.apply(self: State, snap: any): boolean
	if type(snap) ~= "table" or type(snap.seq) ~= "number" or type(snap.serverNow) ~= "number" then
		return false
	end
	if snap.returnReport ~= nil and self.report == nil and not self.reportTaken then
		self.report = snap.returnReport
	end
	local cur = self.snap
	if cur ~= nil and snap.seq <= cur.seq then
		return false
	end
	self.snap = snap
	self.receivedAt = self.clock()
	-- 聞き手の失敗で他の聞き手・反映を止めない（listener は yield しないこと）
	for _, fn in self.listeners do
		local ok, err = pcall(fn, snap)
		if not ok then
			print(`[State] listener 오류: {tostring(err)}`)
		end
	end
	return true
end

function State.get(self: State): any?
	return self.snap
end

function State.onChanged(self: State, fn: (snap: any) -> ())
	table.insert(self.listeners, fn)
end

-- サーバー時刻（ゲーム時計の秒）の推定。スナップショットが無ければ nil
function State.serverNow(self: State): number?
	local s = self.snap
	if s == nil then
		return nil
	end
	return s.serverNow + math.max(0, self.clock() - self.receivedAt)
end

-- 資源の表示整数（補間込み）。スナップショットが無ければ nil
function State.units(self: State, res: string): number?
	local s = self.snap
	if s == nil then
		return nil
	end
	local now = self:serverNow() :: number
	local idle = s.idle or {}
	local milli = self.HudFormat.projectMilli(
		(s.wallet or {})[res] or 0,
		(idle.perHour or {})[res],
		(idle.homePerDay or {})[res],
		now - (s.walletAt or now),
		self.HudFormat.PROJECT_MAX_SECONDS
	)
	return self.HudFormat.units(milli)
end

-- 帰還収穫の要約を 1 回だけ取り出す（show = false の要約も 1 回で消える。表示するかは呼び出し側が show を見る）
function State.takeReturnReport(self: State): any?
	if self.reportTaken or self.report == nil then
		return nil
	end
	self.reportTaken = true
	local r = self.report
	self.report = nil
	return r
end

return State
