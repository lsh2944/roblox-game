--!strict
-- GatherService: 直接採集のセッション（S6、計画書 4.3「채집 세션」）。保存データ（PlayerSaveV1）の wallet・carry を更新する
-- 配置: ServerScriptService.Server.Services.GatherService（Rojo: game/src/server/Services/GatherService.luau）
-- 依存（new の deps で注入）: ReplicatedStorage.Shared の GatherCalc・Ledger インスタンス・Economy インスタンス、
--   Services.Activity インスタンス、Config の GATHER_RADIUS・GATHER_MAX_CREDIT_SECONDS。Roblox API 不使用（Lune でも動く）
--
-- 使い方（Remote・ループの結線は S5 以降の Net/Remoting と Main）:
-- - GatherStart(nodeId) → start(userId, save, nodeId, 距離, now)。距離は呼び出し側がキャラクター位置とノード位置で測る
-- - サーバーが 1 秒ごとに tick(userId, save, now, 範囲内か) を呼ぶ。範囲内なら前回からの秒（上限あり）を積算、範囲外なら
--   その区間は認定せずに終了する。GatherStop・遭遇開始・退出は stop
-- - 同行・道具 Lv が変わる処理の前に settle（その時点までを旧い率で積算）、後に refresh（新しい率）を呼ぶ
-- - 採集中に別ノードの GatherStart が来たら、前のセッションを積算して閉じてから始める（連打しても産出は時間でしか増えない）
-- 時刻はゲーム時計 Clock.now() の秒。産出は wallet（milli）と carry["gather:<資源>"]（1 milli 未満の端数）へ。

local GatherService = {}
GatherService.__index = GatherService

export type Session = {
	nodeId: string,
	resource: string,
	rate: number, -- milli/時（開始・refresh 時点の率）
	lastSec: number, -- ここまで認定済み
}

type Deps = {
	GatherCalc: any,
	econ: any,
	ledger: any,
	activity: any,
	radius: number,
	maxGapSeconds: number,
	researchGatherBps: { [string]: number }?, -- 研究フック（MVP1 は nil = 0）
}

export type GatherService = typeof(setmetatable({} :: { deps: Deps, sessions: { [number]: Session } }, GatherService))

function GatherService.new(deps: Deps): GatherService
	return setmetatable({ deps = deps, sessions = {} }, GatherService)
end

function GatherService.session(self: GatherService, userId: number): Session?
	return self.sessions[userId]
end

local function accrue(self: GatherService, save: any, s: Session, seconds: number): number
	local GC = self.deps.GatherCalc
	if seconds <= 0 then
		return 0
	end
	local key = GC.carryKey(s.resource)
	local g, c = GC.accrueSeconds(s.rate, seconds, save.carry[key] or 0)
	-- 付与が error（assertSafe）なら carry も変えない
	self.deps.ledger:grantMilli(save.wallet, s.resource, g)
	save.carry[key] = c
	return g
end

local function computeRate(self: GatherService, save: any, nodeId: string): number
	local entry = self.deps.econ.gd.nodes[nodeId]
	return self.deps.GatherCalc.rate(self.deps.econ, save, entry.node, self.deps.researchGatherBps)
end

-- 開始。戻り値 RemoteResult（data = {nodeId, resource, rate}）
function GatherService.start(self: GatherService, userId: number, save: any, nodeId: any, distance: any, nowSec: number): any
	local d = self.deps
	local cur = d.activity:get(userId)
	local entry, code = d.GatherCalc.checkStart(d.econ.gd, save, nodeId, distance, d.radius, cur ~= nil and cur ~= "gather")
	if code ~= nil then
		return { ok = false, code = code }
	end
	local rate = d.GatherCalc.rate(d.econ, save, entry.node, d.researchGatherBps)
	if rate <= 0 then
		-- 特殊ノード（requires_node_trait）で対応特性の同行がいない
		return { ok = false, code = d.GatherCalc.CODE_NODE_CLOSED }
	end
	if self.sessions[userId] ~= nil then
		self:stop(userId, save, nowSec)
	end
	self.sessions[userId] = { nodeId = nodeId, resource = entry.node.resource, rate = rate, lastSec = nowSec }
	d.activity:set(userId, "gather")
	return { ok = true, data = { nodeId = nodeId, resource = entry.node.resource, rate = rate } }
end

-- 1 秒ごとの再確認。戻り値 (獲得 milli, 続行中か)
function GatherService.tick(self: GatherService, userId: number, save: any, nowSec: number, inRange: boolean): (number, boolean)
	local s = self.sessions[userId]
	if s == nil then
		return 0, false
	end
	if not inRange then
		-- 範囲外: 前回の確認以降は認定しない
		self:_close(userId)
		return 0, false
	end
	local sec = self.deps.GatherCalc.creditSeconds(s.lastSec, nowSec, self.deps.maxGapSeconds)
	local g = accrue(self, save, s, sec)
	s.lastSec = math.max(s.lastSec, nowSec)
	return g, true
end

-- 状態変更・保存の前に、その時点までを積算する（範囲の再確認はしない。間隔の上限は tick と同じ）
function GatherService.settle(self: GatherService, userId: number, save: any, nowSec: number): number
	local s = self.sessions[userId]
	if s == nil then
		return 0
	end
	local sec = self.deps.GatherCalc.creditSeconds(s.lastSec, nowSec, self.deps.maxGapSeconds)
	local g = accrue(self, save, s, sec)
	s.lastSec = math.max(s.lastSec, nowSec)
	return g
end

-- 同行・道具 Lv が変わった後に率を計算し直す（settle を先に呼んでおくこと）
function GatherService.refresh(self: GatherService, userId: number, save: any)
	local s = self.sessions[userId]
	if s ~= nil then
		s.rate = computeRate(self, save, s.nodeId)
	end
end

function GatherService._close(self: GatherService, userId: number)
	self.sessions[userId] = nil
	self.deps.activity:clear(userId, "gather")
end

-- 終了（GatherStop・遭遇開始・退出）。その時点までを積算して閉じる。戻り値 獲得 milli
function GatherService.stop(self: GatherService, userId: number, save: any, nowSec: number): number
	if self.sessions[userId] == nil then
		return 0
	end
	local g = self:settle(userId, save, nowSec)
	self:_close(userId)
	return g
end

return GatherService
