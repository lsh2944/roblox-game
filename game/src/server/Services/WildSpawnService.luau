--!strict
-- WildSpawnService: プレイヤーごとの野生精霊（灯籠を使える対象は最大 1 体、計画書 4.3「야생 출현」）
-- 配置: ServerScriptService.Server.Services.WildSpawnService（Rojo: game/src/server/Services/WildSpawnService.luau）
-- 依存（new の deps で注入）: ServerRng インスタンス（spawn ストリーム）、ReplicatedStorage.Shared.CaptureLogic、capture.json（gd.capture）、
--   出現地点数の関数（World、S5 以降。無ければ 1 地点）、log（任意）。Roblox API 不使用（Lune でも動く）
--
-- 規則:
-- - 出現は save.next_spawn_at（ゲーム時計の秒、保存される）以降。再接続で待ち時間を消せない
-- - next_spawn_at は CaptureService が遭遇開始時に「開始 + 弱体化秒 + 試行秒 × 試行数 + encounter_base_seconds」に設定する
--   （= 直前の遭遇の終了 + capture.time.encounter_base_seconds。結果は開始時に確定しているので開始時に書ける）
-- - 種はここでは決めない（Q2 決定: 灯籠を使ったときに公開。普段は「光の塊」）。地点だけ spawn ストリームで選ぶ
-- - 野生精霊は実行時だけの状態（保存しない）。退出で消え、再入室時に next_spawn_at を過ぎていれば出し直す
-- - next_spawn_at が 今 + CaptureLogic.maxSpawnAheadSeconds を超えて未来なら壊れた値として今へ切り詰め、保存データにも書き戻す
--   （2026-11-12 決定。使う時点で確かめるので、読み込み時の破損とプレイ中の時計の巻き戻りの両方に効く）

local WildSpawnService = {}
WildSpawnService.__index = WildSpawnService

export type Wild = { id: string, fieldId: string, point: number }

type Deps = {
	rng: any,
	CaptureLogic: any,
	rule: any, -- gd.capture
	pointCount: ((fieldId: string) -> number)?,
	log: ((msg: string) -> ())?,
}

export type WildSpawnService = typeof(setmetatable(
	{} :: { deps: Deps, wilds: { [number]: Wild }, seq: number, maxAhead: number },
	WildSpawnService
))

function WildSpawnService.new(deps: Deps): WildSpawnService
	local maxAhead = deps.CaptureLogic.maxSpawnAheadSeconds(deps.rule)
	return setmetatable({ deps = deps, wilds = {}, seq = 0, maxAhead = maxAhead }, WildSpawnService)
end

function WildSpawnService.get(self: WildSpawnService, userId: number): Wild?
	return self.wilds[userId]
end

-- いなければ（出現時刻を過ぎていて、そのフィールドが解禁済みなら）出す。戻り値 現在の野生精霊 | nil
function WildSpawnService.ensure(self: WildSpawnService, userId: number, save: any, nowSec: number, fieldId: string): Wild?
	local cur = self.wilds[userId]
	if cur ~= nil then
		return cur
	end
	local nextAt, bad = self.deps.CaptureLogic.clampFuture(save.next_spawn_at, nowSec, self.maxAhead)
	if bad then
		local f = self.deps.log
		if f ~= nil then
			f(`[Wild] u_{userId} next_spawn_at {save.next_spawn_at} 이 미래 상한 초과 → {nextAt}`)
		end
		save.next_spawn_at = nextAt
	end
	if table.find(save.unlocked, fieldId) == nil or nowSec < nextAt then
		return nil
	end
	local n = if self.deps.pointCount ~= nil then self.deps.pointCount(fieldId) else 1
	local point = if n > 1 then self.deps.rng:intInclusive("spawn", 1, n) else 1
	self.seq += 1
	local w: Wild = { id = "w" .. tostring(self.seq), fieldId = fieldId, point = point }
	self.wilds[userId] = w
	return w
end

-- 遭遇開始で消費、または退出で消す
function WildSpawnService.clear(self: WildSpawnService, userId: number)
	self.wilds[userId] = nil
end

return WildSpawnService
