--!strict
-- Main: サーバーの起動点（GameData 読み込み → サービスの初期化 → ワールド・部地 → Remote 結線 → PlayerAdded/Removing・BindToClose・
--   自動保存・StateChanged の送信ループ）
-- 配置: ServerScriptService.Server.Main（Script。Rojo: game/src/server/Main.server.luau）
-- 依存: ReplicatedStorage.Shared の Data.GameData・Economy・Formulas・CaptureLogic・IdleCalc・Text・Net・RosterRules・QuestRules・
--   FacilityRules、ReplicatedStorage.GameData（data/*.json）、ReplicatedStorage.Remotes、
--   ServerScriptService.Server の Config・Clock・Data.{DataStoreAdapter, PlayerDataService, SaveSchema}・Services.{IdleService, PlotService}・
--   Net.{Validate, RateLimiter, PushThrottle, Remoting, Snapshot}・World.MeadowBuilder
--
-- S5 時点: 保存・放置精算に加えて、ワールド（Workspace.MeadowWorld、Rojo 管理外）・部地の割り当てと自分の部地での出現・
--   Remote の結線（全 C→S Remote をレート → 検証 → 処理で受ける。処理は GetSnapshot だけ、S6〜S9 は NOT_IMPLEMENTED）・
--   StateChanged（変更の印と毎分の財布更新、最大 4 回/秒）。S6〜S9 のサービス結線と SessionCleanup は各段階で行う。
-- 実 DataStore を使うのはライブサーバー、または Studio で Config.STUDIO_USE_REAL_DATASTORE=true かつ API 接続確認が通ったときだけ。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local DataStoreService = game:GetService("DataStoreService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameData = require(Shared:WaitForChild("Data"):WaitForChild("GameData")) :: any
local Economy = require(Shared:WaitForChild("Economy")) :: any
local Formulas = require(Shared:WaitForChild("Formulas")) :: any
local CaptureLogic = require(Shared:WaitForChild("CaptureLogic")) :: any
local IdleCalc = require(Shared:WaitForChild("IdleCalc")) :: any
local Text = require(Shared:WaitForChild("Text")) :: any
local Net = require(Shared:WaitForChild("Net")) :: any
local RosterRules = require(Shared:WaitForChild("RosterRules")) :: any
local QuestRules = require(Shared:WaitForChild("QuestRules")) :: any
local FacilityRules = require(Shared:WaitForChild("FacilityRules")) :: any

local Server = script.Parent
local Config = require(Server:WaitForChild("Config")) :: any
local Clock = require(Server:WaitForChild("Clock")) :: any
local DataFolder = Server:WaitForChild("Data")
local DataStoreAdapter = require(DataFolder:WaitForChild("DataStoreAdapter")) :: any
local PlayerDataService = require(DataFolder:WaitForChild("PlayerDataService")) :: any
local SaveSchema = require(DataFolder:WaitForChild("SaveSchema")) :: any
local ServicesFolder = Server:WaitForChild("Services")
local IdleService = require(ServicesFolder:WaitForChild("IdleService")) :: any
local PlotService = require(ServicesFolder:WaitForChild("PlotService")) :: any
local NetFolder = Server:WaitForChild("Net")
local Validate = require(NetFolder:WaitForChild("Validate")) :: any
local RateLimiter = require(NetFolder:WaitForChild("RateLimiter")) :: any
local PushThrottle = require(NetFolder:WaitForChild("PushThrottle")) :: any
local Remoting = require(NetFolder:WaitForChild("Remoting")) :: any
local Snapshot = require(NetFolder:WaitForChild("Snapshot")) :: any
local MeadowBuilder = require(Server:WaitForChild("World"):WaitForChild("MeadowBuilder")) :: any

-- 1) data
local gd = GameData.load(ReplicatedStorage:WaitForChild("GameData"))
GameData.assertRefs(gd, Config.SLICE_REFS)
print(`GameData OK ({gd.fileCount} files)`)
local econ = Economy.new(gd)

-- 2) 時計（Studio だけ ServerStorage の属性でオフセット）
local isStudio = RunService:IsStudio()
local clock = Clock.new(os.time, if isStudio
	then function()
		return ServerStorage:GetAttribute(Config.DEBUG_CLOCK_ATTRIBUTE)
	end
	else nil)

-- 3) 保存先の選択（Studio 既定 Mock、ライブは実ストアのみ）
local storeName = DataStoreAdapter.storeName(Config.DATASTORE_PREFIX, isStudio)
local realAvailable = not isStudio
if isStudio and Config.STUDIO_USE_REAL_DATASTORE then
	local ok, err = DataStoreAdapter.probeReal(DataStoreService, storeName)
	realAvailable = ok
	if not ok then
		warn(`[PlayerData] Studio에서 실제 DataStore 사용 불가 → Mock 사용: {err}`)
	end
end
local mockStore = DataStoreAdapter.newMock()
local realStore: any = nil
local function storeFor(userId: number): any
	if DataStoreAdapter.decide(isStudio, Config.STUDIO_USE_REAL_DATASTORE, realAvailable, userId) == "real" then
		if realStore == nil then
			realStore = DataStoreAdapter.newReal(DataStoreService, storeName, task.wait, Config.BUDGET_WAIT_SECONDS)
		end
		return realStore
	end
	return mockStore
end
print(`[PlayerData] 저장소: {if isStudio and not (Config.STUDIO_USE_REAL_DATASTORE and realAvailable) then "Mock" else storeName}`)

-- 4) サービス
local idle = IdleService.new(IdleCalc, econ, { reportMinOfflineMinutes = Config.RETURN_REPORT_MIN_OFFLINE_MINUTES, log = print })
local rng = Random.new()
local newSaveCtx = { gd = gd, startSpirits = Config.START_SPIRITS, milli = Formulas.MILLI, vigorTick = CaptureLogic.VIGOR_TICK }

local function countKeys(t: { [any]: any }): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

local playerData = PlayerDataService.new({
	serverId = HttpService:GenerateGUID(false),
	newToken = function()
		return HttpService:GenerateGUID(false)
	end,
	storeFor = storeFor,
	lockNow = os.time,
	gameNow = function()
		return clock:now()
	end,
	makeNew = function(nowSec: number)
		return SaveSchema.newSave(newSaveCtx, nowSec)
	end,
	wait = function(s: number)
		task.wait(s)
	end,
	spawn = function(fn: () -> ())
		task.spawn(fn)
	end,
	random = function()
		return rng:NextNumber()
	end,
	kick = function(userId: number, message: string)
		local p = Players:GetPlayerByUserId(userId)
		if p ~= nil then
			p:Kick(message)
		end
	end,
	text = Text.get,
	isPresent = function(userId: number)
		return Players:GetPlayerByUserId(userId) ~= nil
	end,
	log = print,
	-- 読み込み直後: オフライン精算（新規は不要）
	onLoaded = function(userId: number, save: any, decision: string, nowSec: number)
		if decision ~= "new" then
			-- オフライン精算 + 帰還収穫の要約（要約はセッションメモリだけ。S5 GetSnapshot で idle:getReturnReport を返す予定）
			local r = idle:settleOnLoad(userId, save, nowSec)
			print(`[Idle] u_{userId} 오프라인 정산: 인정 {r.creditedMinutes}분, 소실 {r.lostMinutes}분`)
		end
		local wick = (save.wallet.wick or 0) // Formulas.MILLI
		print(`[PlayerData] u_{userId} 상태: 심지 {wick}, 정령 {countKeys(save.roster)}, 시설 {countKeys(save.facilities)}`)
	end,
	-- 保存直前: オンライン精算と最終オンライン時刻
	beforeSave = function(save: any, nowSec: number)
		idle:beforeSave(save, nowSec)
	end,
	config = Config,
})

-- 5) ワールドと部地（W1: 8 人 = 部地 8 個。Workspace 直下の Rojo 管理外フォルダに作る）
local world = MeadowBuilder.build(workspace, Config.WORLD, gd, Text, Config.GATHER_RADIUS)
local plots = PlotService.new(#Config.WORLD.plots)
print(`[World] {Config.WORLD.folderName} 생성: 부지 {#Config.WORLD.plots}개`)

-- 6) Remote（C→S の唯一の入口。レート → 検証 → 読み込み確認 → 処理）
local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local remotes: { [string]: Instance } = {}
for name in Net.Remotes do
	remotes[name] = remotesFolder:WaitForChild(name)
end
local snapCtx = {
	gd = gd,
	econ = econ,
	IdleService = IdleService,
	IdleCalc = IdleCalc,
	CaptureLogic = CaptureLogic,
	RosterRules = RosterRules,
	QuestRules = QuestRules,
	FacilityRules = FacilityRules,
}
local remoting = Remoting.new({
	Net = Net,
	remotes = remotes,
	limiter = RateLimiter.new(Config.REMOTE_RATES, os.clock),
	throttle = PushThrottle.new(Config.PUSH_MIN_INTERVAL_SECONDS),
	schemas = Validate.schemas(gd, Config),
	Validate = Validate,
	getSave = function(userId: number)
		return playerData:get(userId)
	end,
	now = function()
		return clock:now()
	end,
	-- 帰還要約はセッションの間ずっと GetSnapshot の応答にだけ入れる（S5 決定: 表示は 1 回だけにする判断はクライアント、
	-- 応答が届かなくても次の GetSnapshot でまた受け取れる。StateChanged には入れない。退出で clearReturnReport）
	buildSnapshot = function(userId: number, save: any, nowSec: number, seq: number, forResponse: boolean)
		return Snapshot.build(snapCtx, save, nowSec, {
			seq = seq,
			plot = plots:plotOf(userId),
			returnReport = if forResponse then idle:getReturnReport(userId) else nil,
		})
	end,
	log = function(msg: string)
		warn(msg)
	end,
})
-- GetSnapshot: 状態を変えない（mutates なし）。S6〜S9 の Remote は登録しないので start が NOT_IMPLEMENTED で結線する
remoting:bind(Net.Remotes.GetSnapshot, function(ctx: any)
	return { ok = true, data = remoting:snapshot(ctx.userId, ctx.save, ctx.now, true) }
end)
remoting:start()

-- 出現位置: 自分の部地（W4）。部地が無い（満員）なら広場
local function placeCharacter(player: Player, character: Model)
	local index = plots:plotOf(player.UserId)
	local cf = if index ~= nil then world.spawnCFrame(index) else world.plazaSpawnCFrame()
	-- 既定の出現処理の後に動かす（CharacterAdded の直後に動かすと上書きされることがあるため defer）
	task.defer(function()
		character:WaitForChild("HumanoidRootPart", 5)
		if character.Parent ~= nil then
			character:PivotTo(cf)
		end
	end)
end

local function onPlayerAdded(player: Player)
	local userId = player.UserId
	local index = plots:assign(userId)
	if index ~= nil then
		world.setPlotOwner(index, player.DisplayName, userId)
	else
		warn(`[Plot] u_{userId} 부지 없음(만원 {#Config.WORLD.plots}) → 광장에서 시작`)
	end
	player.CharacterAdded:Connect(function(character)
		placeCharacter(player, character)
	end)
	if player.Character ~= nil then
		placeCharacter(player, player.Character)
	end
	local ok = playerData:loadAsync(userId)
	if ok then
		remoting:markDirty(userId) -- 読み込み前の GetSnapshot は NOT_READY なので、読み込み後に最初の状態を送る
	end
	-- 読み込み中に退出した（onLoaded の後に "left" で終わった）なら、PlayerRemoving より後に作られた帰還要約を捨てる
	if not ok and Players:GetPlayerByUserId(userId) == nil then
		idle:clearReturnReport(userId)
	end
end

Players.PlayerAdded:Connect(function(player)
	task.spawn(onPlayerAdded, player)
end)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

-- TODO(S5 以降の結線、Studio 段階): 遭遇・採集・野生を作ったら、保存の前に Services.SessionCleanup.run で後始末する
--   （順番 capture:finish → gather:stop → wild:clear → activity:clear。遭遇中の捕獲を保存に入れるため）。
--   PlayerRemoving: releaseAsync の前に SessionCleanup.run(cleanupDeps, userId, playerData:get(userId), clock:now())
--   BindToClose: closeAll の前に、読み込み済みの全員へ同じ呼び出し
Players.PlayerRemoving:Connect(function(player)
	local userId = player.UserId
	remoting:forget(userId) -- レート・送信の印・seq を捨てる
	local index = plots:release(userId)
	if index ~= nil then
		world.setPlotOwner(index, nil, nil)
	end
	idle:clearReturnReport(userId) -- 帰還要約（セッションメモリ）を捨てる
	task.spawn(function()
		-- TODO: ここで SessionCleanup.run（releaseAsync の前）
		playerData:releaseAsync(player.UserId)
	end)
end)

game:BindToClose(function()
	-- TODO: ここで全員に SessionCleanup.run（closeAll の前）
	playerData:closeAll()
end)

task.spawn(function()
	while true do
		task.wait(Config.AUTOSAVE_TICK_SECONDS)
		playerData:autosaveTick()
	end
end)

-- StateChanged の送信ループ: 分が変わったら全員に印（財布のプレビュー・生産率を送り直す）、印のある人へ最大 4 回/秒でまとめて送る
-- （S5 決定: 毎秒の精算は保存データを変えない。精算のプレビューを送り、間はクライアントが生産率で補間する）
task.spawn(function()
	local lastMin = clock:now() // 60
	while true do
		task.wait(Config.PUSH_LOOP_SECONDS)
		local m = clock:now() // 60
		if m ~= lastMin then
			lastMin = m
			for _, p in Players:GetPlayers() do
				remoting:markDirty(p.UserId)
			end
		end
		remoting:flush(os.clock(), function(userId: number)
			return Players:GetPlayerByUserId(userId)
		end)
	end
end)
