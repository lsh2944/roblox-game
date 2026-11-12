--!strict
-- lune_run: Studio を使わずに黄金ベクトルと単体テストを実行する Lune 用の入口
-- 実行: cwd roblox-game で `lune run game/tests/lune_run.luau`（Lune 0.11 系。失敗が 1 件でもあれば終了コード 1）
-- 依存: @lune/fs・@lune/serde・@lune/process、game/src/shared の純粋モジュール（Text を含む）、game/src/server の Config・Clock・
--   Data/{SaveSchema, Migrations, DataStoreAdapter, PlayerDataService}・ServerRng・Services/{IdleService, Activity, GatherService,
--   WildSpawnService, CaptureService, RosterService, FacilityService, QuestService, CraftService, SessionCleanup}（Roblox API は deps 注入なので読み込める）、game/tests の TestKit・VectorRunner・*Spec
-- default.project.json の globIgnorePaths で Rojo の同期対象から外している（ServerStorage.Tests に入らない）。
-- data は manifest の path どおりに data/*.json を読み、Studio の GameData フォルダと同じ docs を作る。
-- あわせて default.project.json の写像（GameData・TestData・Remotes）が manifest・Net と一致するかを確認する。

local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")

local Formulas = require("../src/shared/Formulas")
local Economy = require("../src/shared/Economy")
local CaptureLogic = require("../src/shared/CaptureLogic")
local Ledger = require("../src/shared/Ledger")
local IdleCalc = require("../src/shared/IdleCalc")
local Net = require("../src/shared/Net")
local Text = require("../src/shared/Text")
local GameData = require("../src/shared/Data/GameData")
local Config = require("../src/server/Config")
local Clock = require("../src/server/Clock")
local SaveSchema = require("../src/server/Data/SaveSchema")
local Migrations = require("../src/server/Data/Migrations")
local DataStoreAdapter = require("../src/server/Data/DataStoreAdapter")
local PlayerDataService = require("../src/server/Data/PlayerDataService")
local IdleService = require("../src/server/Services/IdleService")
local GatherCalc = require("../src/shared/GatherCalc")
local RosterRules = require("../src/shared/RosterRules")
local FacilityRules = require("../src/shared/FacilityRules")
local QuestRules = require("../src/shared/QuestRules")
local CraftRules = require("../src/shared/CraftRules")
local ServerRng = require("../src/server/ServerRng")
local Activity = require("../src/server/Services/Activity")
local GatherService = require("../src/server/Services/GatherService")
local WildSpawnService = require("../src/server/Services/WildSpawnService")
local CaptureService = require("../src/server/Services/CaptureService")
local RosterService = require("../src/server/Services/RosterService")
local FacilityService = require("../src/server/Services/FacilityService")
local QuestService = require("../src/server/Services/QuestService")
local CraftService = require("../src/server/Services/CraftService")
local SessionCleanup = require("../src/server/Services/SessionCleanup")
local TestKit = require("./TestKit")
local VectorRunner = require("./VectorRunner")

-- Spec の一覧（Studio は ServerStorage.Tests の子から自動で集める。ここでは明示し、ディレクトリと一致するか確認する）
local SPECS: { [string]: any } = {
	CaptureLogicSpec = require("./CaptureLogicSpec"),
	CaptureSampleSpec = require("./CaptureSampleSpec"),
	CaptureServiceSpec = require("./CaptureServiceSpec"),
	EncounterSpec = require("./EncounterSpec"),
	FacilityServiceSpec = require("./FacilityServiceSpec"),
	GatherSpec = require("./GatherSpec"),
	QuestCraftSpec = require("./QuestCraftSpec"),
	RosterServiceSpec = require("./RosterServiceSpec"),
	EconomySpec = require("./EconomySpec"),
	FormulasSpec = require("./FormulasSpec"),
	GameDataSpec = require("./GameDataSpec"),
	IdleCalcSpec = require("./IdleCalcSpec"),
	IdleServiceSpec = require("./IdleServiceSpec"),
	LedgerSpec = require("./LedgerSpec"),
	NetSpec = require("./NetSpec"),
	PlayerDataSpec = require("./PlayerDataSpec"),
	SaveSchemaSpec = require("./SaveSchemaSpec"),
	TextSpec = require("./TextSpec"),
}

if not fs.isFile("data/manifest.json") then
	print("data/manifest.json 이 없음: cwd를 roblox-game 으로 하고 실행할 것")
	process.exit(2)
end

local function readJson(path: string): any
	return serde.decode("json", fs.readFile(path))
end

-- manifest どおりに data を読む（毎回新しい未凍結のテーブル）
local function loadDocs(): { [string]: any }
	local manifest = readJson("data/manifest.json")
	local docs: { [string]: any } = { manifest = manifest }
	for _, f in manifest.files do
		if GameData.LOADED_ROLES[f.role] then
			docs[f.id] = readJson("data/" .. f.path)
		end
	end
	return docs
end

local failures = 0

-- 1) default.project.json の写像確認
local project = readJson("default.project.json")
local tree = project.tree
local projectErrors = {}
do
	local manifest = readJson("data/manifest.json")
	local gdNode = tree.ReplicatedStorage.GameData
	local mapped = 0
	for _, f in manifest.files do
		if GameData.LOADED_ROLES[f.role] then
			local node = gdNode
			for _, seg in GameData.pathSegments(f.path) do
				node = if node ~= nil then node[seg] else nil
			end
			if node == nil or node["$path"] ~= "data/" .. f.path then
				table.insert(projectErrors, `GameData 매핑 누락/불일치: {f.path}`)
			else
				mapped += 1
			end
		elseif f.role == "test_vectors" then
			local tv = tree.ServerStorage.TestData.test_vectors
			if tv == nil or tv["$path"] ~= "data/" .. f.path then
				table.insert(projectErrors, "ServerStorage.TestData.test_vectors 매핑 불일치")
			end
		end
	end
	if gdNode.manifest == nil or gdNode.manifest["$path"] ~= "data/manifest.json" then
		table.insert(projectErrors, "GameData.manifest 매핑 없음")
	end
	-- manifest に無い data ファイル（variants など）を写像していないか
	local allowed: { [string]: boolean } = { ["data/manifest.json"] = true }
	for _, f in manifest.files do
		if GameData.LOADED_ROLES[f.role] then
			allowed["data/" .. f.path] = true
		end
	end
	local function walk(node: any)
		for k, v in node do
			if k == "$path" then
				if not allowed[v] then
					table.insert(projectErrors, `manifest 밖의 매핑: {v}`)
				end
			elseif type(v) == "table" then
				walk(v)
			end
		end
	end
	walk(gdNode)
	print(`[project] GameData 매핑 {mapped}개, 오류 {#projectErrors}개`)
end
for _, e in projectErrors do
	print("[project] FAIL " .. e)
end
failures += #projectErrors

local remoteClasses: { [string]: string } = {}
for name, node in tree.ReplicatedStorage.Remotes do
	if string.sub(name, 1, 1) ~= "$" then
		remoteClasses[name] = node["$className"]
	end
end

-- Spec 一覧とディレクトリの一致
for _, entry in fs.readDir("game/tests") do
	local stem = string.match(entry, "^(.-Spec)%.luau$")
	if stem ~= nil and SPECS[stem] == nil then
		print(`[unit] FAIL lune_run.luau 의 SPECS 에 없는 Spec 파일: {entry}`)
		failures += 1
	end
end

-- 2) 黄金ベクトル
local vectors = readJson("data/test_vectors.json")
local vs = VectorRunner.run(vectors, Formulas)
for _, msg in vs.failures do
	print("[vectors] FAIL " .. msg)
end
print("[vectors] " .. VectorRunner.format(vs))
failures += vs.fail

-- 3) 単体テスト
local gd = GameData.build(loadDocs())
print(`[data] GameData OK ({gd.fileCount} files)`)
local deps = {
	env = "lune",
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
	sampleRngFactory = TestKit.xorshiftFactory, -- 標本検査の乱数源（Studio は Roblox Random）
	TestKit = TestKit,
	gd = gd,
	econ = Economy.new(gd),
	loadDocs = loadDocs,
	remoteClasses = remoteClasses,
}
local names = {}
for name in SPECS do
	table.insert(names, name)
end
table.sort(names)
local suites = {}
for _, name in names do
	table.insert(suites, SPECS[name])
end
local ur = TestKit.runSuites(suites, deps, function(line: string)
	print("[unit] " .. line)
end)
print(`[unit] {TestKit.format(ur)} ({#suites} suites)`)
failures += ur.fail

process.exit(if failures > 0 then 1 else 0)
