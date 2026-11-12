--!strict
-- Clock: ゲーム時刻（秒）。Studio だけデバッグ用のオフセットでオフライン・日付境界・夜を試せる（計画書 4.2 節）
-- 配置: ServerScriptService.Server.Clock（Rojo: game/src/server/Clock.luau）
-- 依存: なし。オフセットの読み取り関数は呼び出し側（Main）が渡す。モジュール読み込み時に Roblox API を呼ばない
--
-- Studio での使い方（Main が渡す読み取り関数の前提）: ServerStorage の属性 DebugClockOffsetSeconds（整数・秒）を
-- Properties か コマンドバー `game.ServerStorage:SetAttribute("DebugClockOffsetSeconds", 13 * 3600)` で設定する。
-- 読み取りは毎回行うので、プレイ中に変えるとすぐ効く。ライブ（Studio 以外）では Main が読み取り関数を渡さず常に 0。
-- セッション錠（locked_at）と updated_at はこの時計ではなく実時間 os.time() を使う（オフセットで錠が延びないように）。

local Clock = {}
Clock.__index = Clock

export type Clock = typeof(setmetatable(
	{} :: { timeFn: () -> number, offsetFn: (() -> any)? },
	Clock
))

-- timeFn: os.time、offsetFn: Studio のときだけ渡す（nil ならオフセット 0）
function Clock.new(timeFn: () -> number, offsetFn: (() -> any)?): Clock
	return setmetatable({ timeFn = timeFn, offsetFn = offsetFn }, Clock)
end

-- オフセットの検証: 整数・有限・±10 年以内でなければ 0（壊れた属性で時計が暴れないように）
function Clock.sanitizeOffset(v: any): number
	if type(v) ~= "number" or v ~= v or math.floor(v) ~= v or math.abs(v) > 10 * 365 * 86400 then
		return 0
	end
	return v
end

function Clock.offset(self: Clock): number
	local f = self.offsetFn
	if f == nil then
		return 0
	end
	return Clock.sanitizeOffset(f())
end

-- ゲーム時刻（秒、整数）。負にはしない
function Clock.now(self: Clock): number
	return math.max(0, math.floor(self.timeFn()) + self:offset())
end

-- ゲーム時刻（分）= now // 60（IdleCalc・夜判定・settled_min と同じ UTC 通算分）
function Clock.nowMin(self: Clock): number
	return self:now() // 60
end

return Clock
