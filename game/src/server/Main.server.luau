--!strict
-- Main: サーバーの起動点（GameData 読み込み → サービスの初期化 → PlayerAdded/Removing・BindToClose・自動保存）
-- 配置: ServerScriptService.Server.Main（Script。Rojo: game/src/server/Main.server.luau）
-- 依存: ReplicatedStorage.Shared の Data.GameData・Economy・Formulas・CaptureLogic・IdleCalc・Text、ReplicatedStorage.GameData（data/*.json）、
--   ServerScriptService.Server の Config・Clock・Data.{DataStoreAdapter, PlayerDataService, SaveSchema}・Services.IdleService
--
-- S4 時点: 保存（PlayerDataService）と放置精算（IdleService）まで。Remote の結線・ワールド・クライアントは S5 以降。
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

local Server = script.Parent
local Config = require(Server:WaitForChild("Config")) :: any
local Clock = require(Server:WaitForChild("Clock")) :: any
local DataFolder = Server:WaitForChild("Data")
local DataStoreAdapter = require(DataFolder:WaitForChild("DataStoreAdapter")) :: any
local PlayerDataService = require(DataFolder:WaitForChild("PlayerDataService")) :: any
local SaveSchema = require(DataFolder:WaitForChild("SaveSchema")) :: any
local IdleService = require(Server:WaitForChild("Services"):WaitForChild("IdleService")) :: any

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
local idle = IdleService.new(IdleCalc, econ)
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
			local r = idle:settle(save, nowSec, true)
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

local function onPlayerAdded(player: Player)
	playerData:loadAsync(player.UserId)
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
