--!strict
-- TravelService: HUD の "Meadow"・"Home" 移動ボタン（Travel(dest) RF、2026-11-24 ユーザー決定）の判定と実行
-- 配置: ServerScriptService.Server.Services.TravelService（Rojo: game/src/server/Services/TravelService.luau）
-- 依存（new の deps で注入）: ReplicatedStorage.Shared.Net、行き先の決定 resolve・キャラクターの取得 findCharacter・移動 pivot
--   （Main が World.MeadowBuilder の handle・Services.PlotService・Roblox API で作る）、Services の CaptureService・GatherService・
--   Activity インスタンス（任意: S6・S7 で結線するまでは nil）。このモジュール自体は Roblox API を使わない（Lune でも動く）
--
-- 規則（world_hud_design 2 節「이동」、2026-11-24 決定。ここに無い制限（クールダウン・距離・戦闘中など）は付けない）:
-- - クライアントが送るのは行き先の名前（Net.TravelDest）だけ。座標はサーバーが決める（meadow = Config.WORLD.meadowEntry、
--   home = 自分の部地の出現位置。部地が無ければ広場 = 出現時と同じ規則。resolve が返す）
-- - 遭遇（捕獲）の途中なら BUSY で断る（CaptureService の pending、または Activity が "encounter"）
-- - キャラクターまたは HumanoidRootPart が無ければ NOT_READY で断る。断るときは保存データに触れない
-- - 移動するときは直接採集のセッションを閉じる（GatherService.stop: その時点までを積算して閉じる。セッションが無ければ何もしない）
-- - 順番: 遭遇中の確認 → 行き先の決定 → キャラクターの確認 → 採集の終了 → 移動。確認はすべて状態を変える前に行う
--   （Remoting の処理はこの間 yield しないので、確認と移動の間にキャラクターが消えることはない。pivot が例外を投げた場合は
--   Remoting が INTERNAL を返し、閉じた採集の積算はそのまま残る: 正当な積算なので消失・重複はない）
-- 状態（保存データ）を変えるのは採集の終了だけ。Remoting.bind は mutates = true（成功したら StateChanged を送る）。

local TravelService = {}
TravelService.__index = TravelService

type Deps = {
	Net: any,
	-- 行き先の名前 → 目標（Roblox では CFrame）。未知の名前なら nil（Validate が先に断るので通常は来ない）
	resolve: (userId: number, dest: string) -> any?,
	-- 移動できるキャラクター（HumanoidRootPart を持ち、ワールドの中にあるもの）。無ければ nil
	findCharacter: (player: any) -> any?,
	pivot: (character: any, target: any) -> (),
	capture: any?, -- CaptureService（S7 で結線）
	gather: any?, -- GatherService（S6 で結線）
	activity: any?, -- Activity（S6・S7 で結線）
}

export type TravelService = typeof(setmetatable({} :: { deps: Deps }, TravelService))

function TravelService.new(deps: Deps): TravelService
	return setmetatable({ deps = deps }, TravelService)
end

-- 遭遇（捕獲）の途中か（CaptureService.engage の BUSY 判定と同じ条件）
function TravelService.inEncounter(self: TravelService, userId: number): boolean
	local d = self.deps
	if d.capture ~= nil and d.capture:getPending(userId) ~= nil then
		return true
	end
	return d.activity ~= nil and d.activity:get(userId) == "encounter"
end

-- 行き先の名前が Net.TravelDest にあるか（純粋）
function TravelService.isDest(self: TravelService, dest: any): boolean
	if type(dest) ~= "string" then
		return false
	end
	for _, v in self.deps.Net.TravelDest do
		if v == dest then
			return true
		end
	end
	return false
end

-- Travel の処理（Remoting.bind の処理。ctx = { userId, player, save, now }）。戻り値 RemoteResult
-- data = { dest, gatherStopped（採集を閉じたか）}
function TravelService.travel(self: TravelService, ctx: any, dest: any): any
	local d = self.deps
	local codes = d.Net.ErrorCode
	if not self:isDest(dest) then
		return { ok = false, code = codes.BAD_ARG } -- Validate が先に断る（ここは防御）
	end
	local userId = ctx.userId
	if self:inEncounter(userId) then
		return { ok = false, code = codes.BUSY }
	end
	local target = d.resolve(userId, dest)
	if target == nil then
		error(`TravelService: 목적지 '{dest}' 를 정할 수 없음`) -- 設定の誤り（Remoting が INTERNAL を返す）
	end
	local character = d.findCharacter(ctx.player)
	if character == nil then
		return { ok = false, code = codes.NOT_READY }
	end
	local gatherStopped = false
	local gather = d.gather
	if gather ~= nil and gather:session(userId) ~= nil then
		gather:stop(userId, ctx.save, ctx.now)
		gatherStopped = true
	end
	d.pivot(character, target)
	return { ok = true, data = { dest = dest, gatherStopped = gatherStopped } }
end

return TravelService
