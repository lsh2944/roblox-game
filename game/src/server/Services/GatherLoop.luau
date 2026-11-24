--!strict
-- GatherLoop: 直接採集（S6）の結線部の純粋な処理（距離の測定、GatherStart の受け付け、1 秒ごとの再確認ループの 1 回分）
-- 配置: ServerScriptService.Server.Services.GatherLoop（Rojo: game/src/server/Services/GatherLoop.luau）
-- 依存（各関数の deps で注入）: Services.GatherService インスタンス、Config.WORLD.nodes（ノード座標）・Config.GATHER_RADIUS、
--   保存データの取得 getSave、キャラクター位置の取得 rootPosition、終了・産出の通知 onEnded・onGained、log。
--   Roblox API 不使用（Lune でも動く。Main がキャラクター・Remote・Players を包んで渡す）
--
-- 規則（計画書 4.3「채집 세션」、2026-11-24 S6 承認範囲）:
-- - ノード位置は Config.WORLD.nodes の座標（MeadowBuilder がノードの Part をこの座標に置く。Part を探さないので、
--   ワールドの Instance が無い・名前が変わったときも判定が変わらず、Lune で同じ判定を検証できる）
-- - 距離は水平（XZ）距離。描かれた範囲の円（{id}_Range、半径 GatherRadius）と同じ形で、キャラクターの腰の高さで
--   範囲の縁が狭くならない（クライアントの ProximityPrompt は 3 次元距離なので、Prompt が出る位置は必ずサーバーの範囲内）
-- - キャラクターが無い・死亡（rootPosition が nil）は距離 = math.huge（開始は GatherCalc.checkStart が拒否、確認では範囲外）
-- - 産出は GatherService がサーバー時間に縛る（連打・瞬間移動で増えない）。ここは距離を測って渡すだけ

local GatherLoop = {}

export type Pos = { X: number, Y: number, Z: number } -- Vector3 互換（X・Z だけ使う）
export type NodePos = { x: number, z: number } -- Config.WORLD.nodes の項目

export type StartDeps = {
	gather: any, -- GatherService
	nodes: { [string]: NodePos },
	rootPosition: (userId: number) -> Pos?,
}

export type TickDeps = {
	gather: any, -- GatherService
	nodes: { [string]: NodePos },
	radius: number,
	getSave: (userId: number) -> any,
	rootPosition: (userId: number) -> Pos?,
	onEnded: (userId: number, nodeId: string) -> (), -- 範囲外で終了した（Notify と StateChanged の印）
	onGained: (userId: number) -> (), -- 財布が増えた（StateChanged の印）
	log: (msg: string) -> (),
}

-- ノードまでの水平距離。位置が無い・ノードの座標が無いときは math.huge
function GatherLoop.distance(nodes: { [string]: NodePos }, nodeId: any, pos: Pos?): number
	if pos == nil or type(nodeId) ~= "string" then
		return math.huge
	end
	local n = nodes[nodeId]
	if n == nil then
		return math.huge
	end
	local dx, dz = pos.X - n.x, pos.Z - n.z
	local d = math.sqrt(dx * dx + dz * dz)
	if d ~= d then
		return math.huge
	end
	return d
end

-- GatherStart の処理本体（Remoting の bind から呼ぶ。引数の型・レート・読み込み確認は Remoting が済ませている）
function GatherLoop.start(deps: StartDeps, userId: number, save: any, nodeId: any, nowSec: number): any
	local d = GatherLoop.distance(deps.nodes, nodeId, deps.rootPosition(userId))
	return deps.gather:start(userId, save, nodeId, d, nowSec)
end

-- 保存直前のフック本体（PlayerDataService の beforeSave。自動保存・退出・終了の全保存がここを通る）:
-- 採集をその時点まで積算してから放置のオンライン精算（IdleService.beforeSave）。採集の失敗は log して精算・保存を止めない
-- （SessionCleanup の段ごとの pcall と同じ扱い。放置精算の失敗は呼び出し側 PlayerDataService が log する）
function GatherLoop.beforeSave(gather: any, idle: any, log: (msg: string) -> (), save: any, nowSec: number, userId: number)
	local ok, err = pcall(function()
		gather:settle(userId, save, nowSec)
	end)
	if not ok then
		log(`[Gather] u_{userId} 저장 전 채집 정산 실패: {tostring(err)}`)
	end
	idle:beforeSave(save, nowSec)
end

-- 1 秒ごとの再確認（Main のループが Config.GATHER_CHECK_SECONDS ごとに呼ぶ）。採集中の全員について距離を測って tick する。
-- 1 人の失敗（例外）は log して他のプレイヤーを止めない。保存データが無い（錠外し中など）人は飛ばす。戻り値 = 確認した人数
function GatherLoop.tickAll(deps: TickDeps, nowSec: number): number
	local ids = {}
	for userId in deps.gather.sessions do
		table.insert(ids, userId)
	end
	table.sort(ids) -- 順序を固定する（テストの再現性）
	local n = 0
	for _, userId in ids do
		local s = deps.gather:session(userId)
		local save = deps.getSave(userId)
		if s == nil or save == nil then
			continue
		end
		n += 1
		local nodeId = s.nodeId
		local ok, err = pcall(function()
			local inRange = GatherLoop.distance(deps.nodes, nodeId, deps.rootPosition(userId)) <= deps.radius
			local g, cont = deps.gather:tick(userId, save, nowSec, inRange)
			if not cont then
				deps.onEnded(userId, nodeId)
			elseif g > 0 then
				deps.onGained(userId)
			end
		end)
		if not ok then
			deps.log(`[Gather] u_{userId} 재확인 실패: {tostring(err)}`)
		end
	end
	return n
end

return table.freeze(GatherLoop)
