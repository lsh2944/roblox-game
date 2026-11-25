--!strict
-- TestRunner: Studio 専用のテスト実行（黄金ベクトル + 単体テスト）
-- 配置: ServerScriptService.Server.Dev.TestRunner（Script。Rojo: game/src/server/Dev/TestRunner.server.luau）
-- 依存: ReplicatedStorage.Shared の Formulas・Economy・CaptureLogic・Ledger・IdleCalc・Net・Text・Data.GameData・
--   GatherCalc・RosterRules・FacilityRules・QuestRules・CraftRules、
--   ReplicatedStorage.GameData（data）、ReplicatedStorage.Remotes、ServerStorage.TestData.test_vectors、
--   ServerScriptService.Server の Clock・ServerRng・Data.{SaveSchema, Migrations, DataStoreAdapter, PlayerDataService}・
--   Services.{IdleService, Activity, GatherService, WildSpawnService, CaptureService, RosterService, FacilityService, QuestService, CraftService, SessionCleanup, PlotService, GatherLoop, TravelService}（MockStore のみ使用、実 DataStore には触れない）、
--   Net.{Validate, RateLimiter, PushThrottle, Remoting, Snapshot}・World.MeadowBuilder（純粋関数だけ。ワールドは作らない）、Shared.HudFormat、
--   StarterPlayer.StarterPlayerScripts.Client.Controllers.State（純粋。テストだけで読む）、
--   ServerStorage.Tests（TestKit・VectorRunner・名前が "Spec" で終わるモジュール）、ServerScriptService.Server.Config
-- RunService:IsStudio() のときだけ動く（ライブサーバーでは何もしない）。
-- 同じテストを Lune でも実行できる: cwd roblox-game で `lune run game/tests/lune_run.luau`

local RunService = game:GetService("RunService")
if not RunService:IsStudio() then
	return
end

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Tests = ServerStorage:WaitForChild("Tests")

local Formulas = require(Shared:WaitForChild("Formulas")) :: any
local Economy = require(Shared:WaitForChild("Economy")) :: any
local CaptureLogic = require(Shared:WaitForChild("CaptureLogic")) :: any
local Ledger = require(Shared:WaitForChild("Ledger")) :: any
local IdleCalc = require(Shared:WaitForChild("IdleCalc")) :: any
local Net = require(Shared:WaitForChild("Net")) :: any
local Text = require(Shared:WaitForChild("Text")) :: any
local GameData = require(Shared:WaitForChild("Data"):WaitForChild("GameData")) :: any
local Server = script.Parent.Parent
local Config = require(Server:WaitForChild("Config")) :: any
local Clock = require(Server:WaitForChild("Clock")) :: any
local DataFolder = Server:WaitForChild("Data")
local SaveSchema = require(DataFolder:WaitForChild("SaveSchema")) :: any
local Migrations = require(DataFolder:WaitForChild("Migrations")) :: any
local DataStoreAdapter = require(DataFolder:WaitForChild("DataStoreAdapter")) :: any
local PlayerDataService = require(DataFolder:WaitForChild("PlayerDataService")) :: any
local Services = Server:WaitForChild("Services")
local IdleService = require(Services:WaitForChild("IdleService")) :: any
local GatherCalc = require(Shared:WaitForChild("GatherCalc")) :: any
local RosterRules = require(Shared:WaitForChild("RosterRules")) :: any
local FacilityRules = require(Shared:WaitForChild("FacilityRules")) :: any
local QuestRules = require(Shared:WaitForChild("QuestRules")) :: any
local CraftRules = require(Shared:WaitForChild("CraftRules")) :: any
local ServerRng = require(Server:WaitForChild("ServerRng")) :: any
local Activity = require(Services:WaitForChild("Activity")) :: any
local GatherService = require(Services:WaitForChild("GatherService")) :: any
local WildSpawnService = require(Services:WaitForChild("WildSpawnService")) :: any
local CaptureService = require(Services:WaitForChild("CaptureService")) :: any
local RosterService = require(Services:WaitForChild("RosterService")) :: any
local FacilityService = require(Services:WaitForChild("FacilityService")) :: any
local QuestService = require(Services:WaitForChild("QuestService")) :: any
local CraftService = require(Services:WaitForChild("CraftService")) :: any
local SessionCleanup = require(Services:WaitForChild("SessionCleanup")) :: any
local GatherLoop = require(Services:WaitForChild("GatherLoop")) :: any
local PlotService = require(Services:WaitForChild("PlotService")) :: any
local TravelService = require(Services:WaitForChild("TravelService")) :: any
local HudFormat = require(Shared:WaitForChild("HudFormat")) :: any
local NetFolder = Server:WaitForChild("Net")
local Validate = require(NetFolder:WaitForChild("Validate")) :: any
local RateLimiter = require(NetFolder:WaitForChild("RateLimiter")) :: any
local PushThrottle = require(NetFolder:WaitForChild("PushThrottle")) :: any
local Remoting = require(NetFolder:WaitForChild("Remoting")) :: any
local Snapshot = require(NetFolder:WaitForChild("Snapshot")) :: any
local MeadowBuilder = require(Server:WaitForChild("World"):WaitForChild("MeadowBuilder")) :: any
-- クライアントの純粋モジュール（サーバーからも StarterPlayer の中身は読める）
local ClientState = require(
	game:GetService("StarterPlayer"):WaitForChild("StarterPlayerScripts"):WaitForChild("Client"):WaitForChild("Controllers"):WaitForChild("State")
) :: any
local TestKit = require(Tests:WaitForChild("TestKit")) :: any
local VectorRunner = require(Tests:WaitForChild("VectorRunner")) :: any

local dataFolder = ReplicatedStorage:WaitForChild("GameData")
local gd = GameData.load(dataFolder)

-- 1) 黄金ベクトル
local vectorsModule = ServerStorage:WaitForChild("TestData"):WaitForChild("test_vectors")
local vectors = (require :: any)(vectorsModule)
local vs = VectorRunner.run(vectors, Formulas)
for _, msg in vs.failures do
	warn("[vectors] FAIL " .. msg)
end
print("[vectors] " .. VectorRunner.format(vs))

-- 2) 単体テスト（ServerStorage.Tests の *Spec、名前順）
local remoteClasses: { [string]: string } = {}
for _, r in ReplicatedStorage:WaitForChild("Remotes"):GetChildren() do
	remoteClasses[r.Name] = r.ClassName
end

local deps = {
	env = "studio",
	Formulas = Formulas,
	Economy = Economy,
	CaptureLogic = CaptureLogic,
	Ledger = Ledger,
	IdleCalc = IdleCalc,
	Net = Net,
	Text = Text,
	GameData = GameData,
	Config = Config,
	Clock = Clock,
	SaveSchema = SaveSchema,
	Migrations = Migrations,
	DataStoreAdapter = DataStoreAdapter,
	PlayerDataService = PlayerDataService,
	IdleService = IdleService,
	GatherCalc = GatherCalc,
	RosterRules = RosterRules,
	FacilityRules = FacilityRules,
	QuestRules = QuestRules,
	CraftRules = CraftRules,
	ServerRng = ServerRng,
	Activity = Activity,
	GatherService = GatherService,
	WildSpawnService = WildSpawnService,
	CaptureService = CaptureService,
	RosterService = RosterService,
	FacilityService = FacilityService,
	QuestService = QuestService,
	CraftService = CraftService,
	SessionCleanup = SessionCleanup,
	GatherLoop = GatherLoop,
	PlotService = PlotService,
	TravelService = TravelService,
	HudFormat = HudFormat,
	Validate = Validate,
	RateLimiter = RateLimiter,
	PushThrottle = PushThrottle,
	Remoting = Remoting,
	Snapshot = Snapshot,
	MeadowBuilder = MeadowBuilder,
	ClientState = ClientState,
	-- 標本検査（CaptureSampleSpec）の乱数源: 本番と同じ Roblox Random（ストリームごとに別シード）
	sampleRngFactory = function(seed: number)
		return ServerRng.robloxFactory(function()
			seed += 7919
			return Random.new(seed)
		end)
	end,
	TestKit = TestKit,
	gd = gd,
	econ = Economy.new(gd),
	-- 凍結されていない data のコピー（壊れたケースを作るため）
	loadDocs = function()
		return TestKit.deepCopy(GameData.collectDocs(dataFolder))
	end,
	remoteClasses = remoteClasses,
}

local specs = {}
for _, m in Tests:GetChildren() do
	if m:IsA("ModuleScript") and string.sub(m.Name, -4) == "Spec" then
		table.insert(specs, m)
	end
end
table.sort(specs, function(a, b)
	return a.Name < b.Name
end)
local suites = {}
for _, m in specs do
	table.insert(suites, (require :: any)(m))
end
local ur = TestKit.runSuites(suites, deps, function(line: string)
	warn("[unit] " .. line)
end)
print(`[unit] {TestKit.format(ur)} ({#suites} suites)`)
