--!strict
-- GatherCalc: 直接採集（S6）の純粋な計算・判定（秒単位の積算、開始条件、同行の Member 化、採集率）
-- 配置: ReplicatedStorage.Shared.GatherCalc（Rojo: game/src/shared/GatherCalc.luau）
-- 依存: Formulas・Net（同じフォルダ）、Economy インスタンスと GameData.build の結果（引数）。Roblox API 不使用（Lune でも動く）
--
-- 計画書 4.3「채집 세션」:
-- - 産出は directRate（milli/時）× 経過秒。秒単位の積算 total = rate·sec + carry、gained = total // 3600（Luau だけの補助関数）
-- - 開始の検証順: ノードが存在 → ノードのフィールドが解禁済み → 距離 ≤ 半径 → 活動中でない（遭遇中は BUSY）
-- - 研究倍率 A（basic_gather_bps）は資源別 bps のフック（MVP1 は 0）。既存の採集率に 1 回だけ掛ける（sim.py direct_rate）
-- 距離はキャラクター位置（クライアント所有）から呼び出し側が測る。最善努力の検査なので、産出はサーバー時間に縛る。

local Formulas = require("./Formulas")
local Net = require("./Net")

local GatherCalc = {}

GatherCalc.SECONDS_PER_HOUR = 3600
-- 特殊ノード（requires_node_trait）で対応特性の同行がいない = 採集率 0 のときの開始拒否コード
GatherCalc.CODE_NODE_CLOSED = Net.ErrorCode.NOT_UNLOCKED

-- 保存スキーマ carry={[key]=int} のキー（1 milli 未満の端数を資源別に持ち越す）
function GatherCalc.carryKey(res: string): string
	return "gather:" .. res
end

-- 秒単位の積算。戻り値 (獲得 milli, 新しい carry)。carry は 0 ≤ carry < 3600
function GatherCalc.accrueSeconds(rateMilliPerHour: number, seconds: number, carry: number): (number, number)
	Formulas.assertSafe(rateMilliPerHour, seconds, carry)
	if rateMilliPerHour < 0 or seconds < 0 or carry < 0 then
		error("GatherCalc.accrueSeconds: 음수 입력")
	end
	local total = rateMilliPerHour * seconds + carry
	Formulas.assertSafe(total)
	local gained = Formulas.idiv(total, GatherCalc.SECONDS_PER_HOUR)
	return gained, total - gained * GatherCalc.SECONDS_PER_HOUR
end

-- 1 回の確認で認定する秒数 = clamp(now − last, 0, maxGap)（ループが止まっていた間の範囲外を認定しすぎない）
function GatherCalc.creditSeconds(lastSec: number, nowSec: number, maxGapSeconds: number): number
	return math.max(0, math.min(nowSec - lastSec, maxGapSeconds))
end

-- 採集道具（tools.json の kind=gather の最初の 1 つ）
function GatherCalc.gatherToolId(gd: any): string
	for _, t in gd.docs.tools.tools do
		if t.kind == "gather" then
			return t.id
		end
	end
	error("GatherCalc: kind=gather 도구가 data에 없음")
end

-- 同行（save.party の uid 文字列）→ Economy.Member の配列
function GatherCalc.partyMembers(save: any): { any }
	local out = {}
	for _, uid in save.party do
		local s = save.roster[uid]
		if s == nil then
			error(`GatherCalc: 동행 uid가 보관함에 없음 {uid}`)
		end
		table.insert(out, { species = s.species, level = s.level, gatherBps = s.gather_bps, combatBps = s.combat_bps })
	end
	return out
end

-- 採集率（milli/時）= Economy.directRate（道具 Lv・同行）× 研究フック
function GatherCalc.rate(econ: any, save: any, node: any, researchGatherBps: { [string]: number }?): number
	local r = econ:directRate(node, GatherCalc.gatherToolId(econ.gd), save.tool_level, GatherCalc.partyMembers(save))
	local a = if researchGatherBps ~= nil then researchGatherBps[node.resource] or 0 else 0
	if a ~= 0 then
		r = Formulas.researchScaledMilli(r, a)
	end
	return r
end

-- 開始の検証。戻り値 (gd.nodes の項目 | nil, エラーコード | nil)。busy = 遭遇など採集以外の活動中
function GatherCalc.checkStart(gd: any, save: any, nodeId: any, distance: any, radius: number, busy: boolean): (any, string?)
	if type(nodeId) ~= "string" or type(distance) ~= "number" or distance ~= distance or distance < 0 or distance == math.huge then
		return nil, Net.ErrorCode.BAD_ARG
	end
	local entry = gd.nodes[nodeId]
	if entry == nil then
		return nil, Net.ErrorCode.NOT_FOUND
	end
	if table.find(save.unlocked, entry.fieldId) == nil then
		return nil, Net.ErrorCode.NOT_UNLOCKED
	end
	if distance > radius then
		return nil, Net.ErrorCode.TOO_FAR
	end
	if busy then
		return nil, Net.ErrorCode.BUSY
	end
	return entry, nil
end

return table.freeze(GatherCalc)
