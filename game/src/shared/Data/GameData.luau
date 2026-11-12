--!strict
-- GameData: data/*.json（Rojo の JSON→ModuleScript 変換）を読み、manifest 確認・ID 索引・生成表索引・深い freeze を行う
-- 配置: ReplicatedStorage.Shared.Data.GameData（Rojo: game/src/shared/Data/GameData.luau）
-- 依存: ReplicatedStorage.GameData フォルダ（default.project.json が manifest の path どおりに 1 ファイルずつ写像する）
--
-- 純粋部（build / assertRefs）は Roblox API を使わない。Lune は data/*.json を @lune/fs・@lune/serde で読み、
-- manifest の id をキーにした docs を build に渡す（game/tests/lune_run.luau）。
-- Roblox 依存は collectDocs / load だけ（Instance を辿って require する）。
-- 全体検証は Luau で作り直さない。同期前に cwd tools/econ_sim で `python3 -m econ_sim validate` と
-- `python3 -m econ_sim gen-tables --check` を通す（計画書 5 節）。

local GameData = {}

GameData.SCHEMA_VERSION = 1
-- ゲームが読む role（test_vectors は ServerStorage.TestData に置き、クライアントへ複製しない）
GameData.LOADED_ROLES = table.freeze({ source = true, generated = true })

export type Cost = { resource: string, amount: number }

export type GameData = {
	docs: { [string]: any }, -- manifest の id → 文書（manifest 自身は docs.manifest）
	fileCount: number, -- 読み込んだ data ファイル数（manifest を除く、source + generated）
	resources: { [string]: any },
	resourceOrder: { string },
	spirits: { [string]: any },
	spiritOrder: { string },
	fields: { [string]: any },
	fieldOrder: { string }, -- (order, id) 昇順
	nodes: { [string]: { fieldId: string, node: any } },
	facilities: { [string]: any },
	facilityOrder: { string },
	tools: { [string]: any },
	recipes: { [string]: any },
	recipeOrder: { string },
	quests: { [string]: any },
	aptBps: { [string]: number },
	constants: any,
	rules: any,
	capture: any,
	hub: any,
	-- 生成表: cost[curveId][fromLevel] = コスト配列、costMax[curveId] = 最大レベル、bonus[curveId][level] = mult_bps
	cost: { [string]: { [number]: { Cost } } },
	costMax: { [string]: number },
	bonus: { [string]: { [number]: number } },
}

local function byId(items: { any }, kind: string): ({ [string]: any }, { string })
	local map: { [string]: any } = {}
	local order: { string } = {}
	for _, item in items do
		local id = item.id
		if type(id) ~= "string" then
			error(`GameData: {kind}에 id가 없는 항목`)
		end
		if map[id] ~= nil then
			error(`GameData: {kind} id 중복 '{id}'`)
		end
		map[id] = item
		table.insert(order, id)
	end
	return map, order
end

local function deepFreeze(t: any)
	if type(t) ~= "table" or table.isfrozen(t) then
		return
	end
	table.freeze(t)
	for _, v in t do
		deepFreeze(v)
	end
end
GameData.deepFreeze = deepFreeze

-- manifest の path（例 "generated/upgrade_tables.json"）→ インスタンス名の列（{"generated", "upgrade_tables"}）
function GameData.pathSegments(path: string): { string }
	local stem = string.gsub(path, "%.json$", "")
	return string.split(stem, "/")
end

-- 純粋: manifest と docs を検査して索引を作り、docs 全体を深く freeze する
-- docs は { manifest = ..., [manifest の id] = 文書 }。読み込み対象のファイルが 1 つでも欠ければ error
function GameData.build(docs: { [string]: any }): GameData
	local manifest = docs.manifest
	if type(manifest) ~= "table" then
		error("GameData: manifest가 없음")
	end
	if manifest.schema_version ~= GameData.SCHEMA_VERSION then
		error(`GameData: manifest schema_version {tostring(manifest.schema_version)} ≠ {GameData.SCHEMA_VERSION}`)
	end
	local count = 0
	local missing = {}
	for _, f in manifest.files do
		if GameData.LOADED_ROLES[f.role] then
			if type(docs[f.id]) ~= "table" then
				table.insert(missing, `{f.id}({f.path})`)
			else
				count += 1
			end
		end
	end
	if #missing > 0 then
		error("GameData: data 파일 누락(default.project.json 매핑 확인): " .. table.concat(missing, ", "))
	end

	local gd = {} :: GameData
	gd.docs = docs
	gd.fileCount = count
	gd.resources, gd.resourceOrder = byId(docs.resources.resources, "resources")
	gd.spirits, gd.spiritOrder = byId(docs.spirits.spirits, "spirits")
	gd.fields = byId(docs.fields.fields, "fields")
	local fieldList = table.clone(docs.fields.fields)
	table.sort(fieldList, function(a, b)
		if a.order ~= b.order then
			return a.order < b.order
		end
		return a.id < b.id
	end)
	gd.fieldOrder = {}
	gd.nodes = {}
	for _, f in fieldList do
		table.insert(gd.fieldOrder, f.id)
	end
	for _, f in docs.fields.fields do
		for _, n in f.gather_nodes do
			if gd.nodes[n.id] ~= nil then
				error(`GameData: 채집 노드 id 중복 '{n.id}'`)
			end
			gd.nodes[n.id] = { fieldId = f.id, node = n }
		end
	end
	gd.facilities, gd.facilityOrder = byId(docs.facilities.facilities, "facilities")
	gd.tools = byId(docs.tools.tools, "tools")
	gd.recipes, gd.recipeOrder = byId(docs.crafting.recipes, "recipes")
	gd.quests = byId(docs.daily_quests.quests, "quests")
	gd.aptBps = {}
	for _, a in docs.rules.aptitude_bps do
		gd.aptBps[a.id] = a.bps
	end
	gd.constants = docs.rules.constants
	gd.rules = docs.rules
	gd.capture = docs.capture
	gd.hub = docs.hub

	gd.cost, gd.costMax, gd.bonus = {}, {}, {}
	for _, t in docs.upgrade_tables.cost_tables do
		local rows: { [number]: { Cost } } = {}
		for _, row in t.levels do
			rows[row.from_level] = row.costs
		end
		gd.cost[t.id] = rows
		gd.costMax[t.id] = t.max_level
	end
	for _, t in docs.upgrade_tables.bonus_tables do
		local rows: { [number]: number } = {}
		for _, row in t.levels do
			rows[row.level] = row.mult_bps
		end
		gd.bonus[t.id] = rows
	end

	deepFreeze(gd)
	return gd
end

export type Refs = {
	spirits: { string }?,
	nodes: { string }?,
	facilities: { string }?,
	recipes: { string }?,
	quests: { string }?,
	questFields: { string }?, -- 日次依頼の rewards_by_field に行が必要なフィールド
	resources: { string }?,
}

-- ゲームが実際に参照する ID だけを軽く確認する（計画書 5 節）。欠けていれば error
function GameData.assertRefs(gd: GameData, refs: Refs)
	local missing = {}
	local function check(list: { string }?, map: { [string]: any }, kind: string)
		for _, id in list or {} do
			if map[id] == nil then
				table.insert(missing, `{kind}:{id}`)
			end
		end
	end
	check(refs.spirits, gd.spirits, "spirit")
	check(refs.nodes, gd.nodes, "node")
	check(refs.facilities, gd.facilities, "facility")
	check(refs.recipes, gd.recipes, "recipe")
	check(refs.quests, gd.quests, "quest")
	check(refs.resources, gd.resources, "resource")
	for _, fid in refs.questFields or {} do
		for _, qid in refs.quests or {} do
			local q = gd.quests[qid]
			local found = false
			if q ~= nil then
				for _, row in q.rewards_by_field do
					if row.field_id == fid then
						found = true
					end
				end
			end
			if not found then
				table.insert(missing, `quest_row:{qid}/{fid}`)
			end
		end
	end
	if #missing > 0 then
		error("GameData: 참조 id 없음: " .. table.concat(missing, ", "))
	end
end

-- ---- Roblox 依存部（Studio / ゲームサーバーのみ） -------------------------------------

-- ReplicatedStorage.GameData フォルダから manifest の path どおりに ModuleScript を require して docs を作る
function GameData.collectDocs(folder: Instance): { [string]: any }
	local manifestModule = folder:FindFirstChild("manifest")
	if manifestModule == nil or not manifestModule:IsA("ModuleScript") then
		error("GameData: GameData.manifest ModuleScript가 없음")
	end
	local docs: { [string]: any } = { manifest = (require :: any)(manifestModule) }
	local missing = {}
	for _, f in docs.manifest.files do
		if GameData.LOADED_ROLES[f.role] then
			local inst: Instance? = folder
			for _, seg in GameData.pathSegments(f.path) do
				inst = if inst ~= nil then inst:FindFirstChild(seg) else nil
			end
			if inst ~= nil and inst:IsA("ModuleScript") then
				docs[f.id] = (require :: any)(inst)
			else
				table.insert(missing, f.path)
			end
		end
	end
	if #missing > 0 then
		error("GameData: GameData 폴더에 없음(default.project.json 매핑 확인): " .. table.concat(missing, ", "))
	end
	return docs
end

local cached: GameData? = nil

-- 1 回だけ読み込んでキャッシュする（Main と Dev/TestRunner が両方呼んでも同じ索引を返す）
function GameData.load(folder: Instance): GameData
	if cached ~= nil then
		return cached
	end
	local gd = GameData.build(GameData.collectDocs(folder))
	cached = gd
	return gd
end

return GameData
