--!strict
-- MeadowBuilder: meadow の仮図形ワールドを実行時に作る（広場・掲示板・部地 8 個・採集ノード 2 個・野生の出現区域・森の関門）
-- 配置: ServerScriptService.Server.World.MeadowBuilder（Rojo: game/src/server/World/MeadowBuilder.luau）
-- 依存: 引数で受け取る Config.WORLD・Config.GATHER_RADIUS・GameData.build の結果・ReplicatedStorage.Shared.Text。
--   Roblox API（Instance・CFrame・Vector3・Color3・Enum）は build の中だけで使う。checkConfig・plotFrame・plotToWorld・plotLabels・
--   spawnLabelIssues・meadowEntryFrame は純粋関数（Lune の PlotSpec が読む）
--
-- 方針（docs/world_hud_design_20261112.md 1 節・ユーザー決定、2026-11-11「그래픽 = 임시 도형」）:
-- - Workspace 直下の Config.WORLD.folderName フォルダ（Rojo の管理外）に毎回作り直す。Rojo が管理するフォルダには作らない
-- - パステル + 発光（Neon の小物と PointLight）。座標・寸法は Config.WORLD（仮値、Studio で歩いて調整）
-- - ノードの Part 名と属性 NodeId = fields.json gather_nodes[].id、属性 GatherRadius = Config.GATHER_RADIUS（判定はサーバーの Config 値。
--   属性は S6 のクライアント表示用）。台座は属性 FacilityId（facilities.json の id）・PlotIndex
-- - 操作の入口（ProximityPrompt）はここでは作らない（W3・W5 決定: Prompt はクライアントの画面ボタンだけ、要求は既存 Remote）

local MeadowBuilder = {}

export type World = {
	folder: Instance,
	setPlotOwner: (index: number, displayName: string?, userId: number?) -> (),
	spawnCFrame: (index: number) -> CFrame,
	plazaSpawnCFrame: () -> CFrame,
	meadowEntryCFrame: () -> CFrame, -- Travel("meadow") の行き先（2026-11-24 決定）
}

-- 設定の検査（純粋）。ノード ID が data のそのフィールドの gather_nodes と過不足なく一致し、施設 ID が data にあること
function MeadowBuilder.checkConfig(world: any, gd: any)
	local fieldId = world.field.id
	local field = gd.fields[fieldId]
	if field == nil then
		error(`MeadowBuilder: 필드 '{tostring(fieldId)}' 가 data 에 없음`)
	end
	for _, n in field.gather_nodes do
		if world.nodes[n.id] == nil then
			error(`MeadowBuilder: 노드 '{n.id}' 의 좌표가 Config.WORLD.nodes 에 없음`)
		end
	end
	for id in world.nodes do
		local ref = gd.nodes[id]
		if ref == nil or ref.fieldId ~= fieldId then
			error(`MeadowBuilder: Config.WORLD.nodes 의 '{id}' 가 {fieldId} 의 gather_nodes 에 없음`)
		end
	end
	for fid in world.plotLayout.pedestals do
		if gd.facilities[fid] == nil then
			error(`MeadowBuilder: 받침대 시설 '{fid}' 가 data 에 없음`)
		end
	end
	if gd.facilities[world.plotLayout.reserved.id] == nil then
		error(`MeadowBuilder: 예약 시설 '{world.plotLayout.reserved.id}' 가 data 에 없음`)
	end
end

-- 部地の位置と前方向（純粋）。前 = 部地の中心から広場の中心への単位ベクトル（XZ 平面）
function MeadowBuilder.plotFrame(world: any, index: number): (number, number, number, number)
	local p = world.plots[index]
	local dx, dz = world.plaza.x - p.x, world.plaza.z - p.z
	local len = math.sqrt(dx * dx + dz * dz)
	return p.x, p.z, dx / len, dz / len
end

-- 部地ローカル（lx, lz）→ ワールドの（x, z）（純粋）。build の CFrame.lookAt(中心, 中心 + 前) と同じ変換:
-- ローカル +X = RightVector = (-fz, fx)、ローカル -Z = 前 (fx, fz)
function MeadowBuilder.plotToWorld(world: any, index: number, lx: number, lz: number): (number, number)
	local px, pz, fx, fz = MeadowBuilder.plotFrame(world, index)
	return px + lx * -fz - lz * fx, pz + lx * fx - lz * fz
end

-- 部地の中で看板（BillboardGui）を付ける物の部地ローカル位置（純粋。build もこの一覧の位置に看板を付ける）
function MeadowBuilder.plotLabels(world: any): { { name: string, x: number, z: number } }
	local L = world.plotLayout
	local sc = L.showcase[L.showcaseLabelSlot]
	if sc == nil then
		error(`MeadowBuilder: showcaseLabelSlot {tostring(L.showcaseLabelSlot)} 의 전시대가 없음`)
	end
	return {
		{ name = `reserved:{L.reserved.id}`, x = L.reserved.x, z = L.reserved.z },
		{ name = `showcase:{L.showcaseLabelSlot}`, x = sc.x, z = sc.z },
		{ name = "sign", x = L.sign.x, z = L.sign.z },
	}
end

-- 出現位置と看板の配置の検査（純粋、2026-11-24: 予約地の看板がキャラクターを隠した問題の再発防止）。全部地の出現位置について、
-- 全部地（自分以外の部地も含む）の看板を、ワールド座標で次の 2 つの規則で確かめる。戻り値 = 違反の説明の一覧（空なら問題なし）
-- 1. 水平距離 ≥ plotLayout.labelClearance
-- 2. 出現位置の正面の視線帯（向き = 部地の奥、深さ viewLane.depth・左右 viewLane.halfWidth）の中に無い
-- Studio での見え方（カメラの角度・看板の画面上の大きさ）の確認の代わりではない
function MeadowBuilder.spawnLabelIssues(world: any): { string }
	local L = world.plotLayout
	local labels = MeadowBuilder.plotLabels(world)
	local issues: { string } = {}
	for i = 1, #world.plots do
		local sx, sz = MeadowBuilder.plotToWorld(world, i, L.spawn.x, L.spawn.z)
		-- 出現位置の向き = 部地の奥（前の逆）
		local _, _, fx, fz = MeadowBuilder.plotFrame(world, i)
		local vx, vz = -fx, -fz
		for j = 1, #world.plots do
			for _, lb in labels do
				local wx, wz = MeadowBuilder.plotToWorld(world, j, lb.x, lb.z)
				local dx, dz = wx - sx, wz - sz
				local dist = math.sqrt(dx * dx + dz * dz)
				if dist < L.labelClearance then
					table.insert(issues, `부지 {i} 스폰 ↔ 부지 {j} {lb.name}: 거리 {string.format("%.1f", dist)} < {L.labelClearance}`)
				end
				local ahead = dx * vx + dz * vz
				local side = math.abs(dx * -vz + dz * vx)
				if ahead > 0 and ahead <= L.viewLane.depth and side < L.viewLane.halfWidth then
					table.insert(issues, `부지 {i} 스폰 정면 시선 안에 부지 {j} {lb.name}(앞 {string.format("%.1f", ahead)}, 옆 {string.format("%.1f", side)})`)
				end
			end
		end
	end
	return issues
end

-- 草原の入口（純粋）: 位置と向き（入口からフィールドの中心への単位ベクトル、XZ 平面）
function MeadowBuilder.meadowEntryFrame(world: any): (number, number, number, number)
	local e = world.meadowEntry
	local dx, dz = world.field.x - e.x, world.field.z - e.z
	local len = math.sqrt(dx * dx + dz * dz)
	if len == 0 then
		error("MeadowBuilder: meadowEntry 가 필드 중심과 같은 위치(향할 방향 없음)")
	end
	return e.x, e.z, dx / len, dz / len
end

-- ---- ここから Roblox API ----

-- 色（Color3 は Roblox 型なので build の中で初めて作る: Lune がこのモジュールを読み込めるように）
local PALETTE: any = nil
local NODE_COLORS: any = nil

local function initPalette()
	if PALETTE ~= nil then
		return
	end
	PALETTE = {
		base = Color3.fromRGB(206, 240, 190),
		field = Color3.fromRGB(188, 234, 168),
		plaza = Color3.fromRGB(255, 244, 207),
		path = Color3.fromRGB(236, 224, 186),
		plot = Color3.fromRGB(250, 246, 255),
		plotEdge = Color3.fromRGB(214, 204, 240),
		house = Color3.fromRGB(255, 233, 199),
		roof = Color3.fromRGB(196, 172, 255),
		door = Color3.fromRGB(176, 140, 110),
		window = Color3.fromRGB(255, 238, 160),
		dew = Color3.fromRGB(150, 215, 255),
		dewGlow = Color3.fromRGB(190, 238, 255),
		bloom = Color3.fromRGB(255, 182, 212),
		bloomGlow = Color3.fromRGB(255, 210, 232),
		reserved = Color3.fromRGB(226, 224, 236),
		wild = Color3.fromRGB(232, 220, 255),
		stone = Color3.fromRGB(216, 210, 230),
		gateDoor = Color3.fromRGB(186, 172, 222),
		wood = Color3.fromRGB(222, 196, 160),
		ink = Color3.fromRGB(60, 50, 90),
	}
	NODE_COLORS = {
		dew = { base = PALETTE.dew, glow = PALETTE.dewGlow },
		bloom = { base = PALETTE.bloom, glow = PALETTE.bloomGlow },
	}
end

local function part(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, props: { [string]: any }?): BasePart
	local p: BasePart = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if props ~= nil then
		for k, v in props do
			(p :: any)[k] = v
		end
	end
	p.Parent = parent
	return p
end

-- 円盤（Cylinder の軸を上に向ける）。height = 厚み、topY = 上面の高さ
local function disc(parent: Instance, name: string, diameter: number, height: number, x: number, topY: number, z: number, color: Color3, props: { [string]: any }?): BasePart
	local p = part(
		parent,
		name,
		Vector3.new(height, diameter, diameter),
		CFrame.new(x, topY - height / 2, z) * CFrame.Angles(0, 0, math.rad(90)),
		color,
		props
	)
	;(p :: Part).Shape = Enum.PartType.Cylinder
	return p
end

local function ghost(): { [string]: any }
	return { CanCollide = false, CanTouch = false, CanQuery = false, CastShadow = false }
end

local function glow(parent: Instance, color: Color3, range: number)
	local l = Instance.new("PointLight")
	l.Color = color
	l.Range = range
	l.Brightness = 1.5
	l.Shadows = false
	l.Parent = parent
end

-- 看板（BillboardGui + TextLabel）。戻り値 = TextLabel（部地の名札は後で書き換える）
local function billboard(adornee: BasePart, text: string, offsetY: number, maxDistance: number): TextLabel
	local g = Instance.new("BillboardGui")
	g.Name = "Label"
	g.Size = UDim2.fromOffset(220, 40)
	g.StudsOffset = Vector3.new(0, offsetY, 0)
	g.MaxDistance = maxDistance
	g.LightInfluence = 0
	g.AlwaysOnTop = false
	g.Adornee = adornee
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundColor3 = Color3.new(1, 1, 1)
	t.BackgroundTransparency = 0.15
	t.TextColor3 = PALETTE.ink
	t.Font = Enum.Font.FredokaOne
	t.TextScaled = true
	t.Text = text
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = t
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.PaddingTop = UDim.new(0, 4)
	pad.PaddingBottom = UDim.new(0, 4)
	pad.Parent = t
	t.Parent = g
	g.Parent = adornee
	return t
end

local function buildPlot(folder: Instance, world: any, index: number, Text: any): (Model, TextLabel, CFrame)
	local y = world.groundY
	local px, pz, fx, fz = MeadowBuilder.plotFrame(world, index)
	local origin = Vector3.new(px, y, pz)
	-- -Z（LookVector）= 広場の方 = 部地の前
	local cf = CFrame.lookAt(origin, origin + Vector3.new(fx, 0, fz))
	local L = world.plotLayout
	local model = Instance.new("Model")
	model.Name = `Plot{index}`
	model:SetAttribute("PlotIndex", index)
	model:SetAttribute("OwnerUserId", 0)
	local size = world.plotSize
	local ground = part(model, "Ground", Vector3.new(size, 0.4, size), cf * CFrame.new(0, 0.2, 0), PALETTE.plot, { CastShadow = false })
	part(model, "Edge", Vector3.new(size + 2, 0.3, size + 2), cf * CFrame.new(0, 0.1, 0), PALETTE.plotEdge, { CastShadow = false })
	model.PrimaryPart = ground
	local top = 0.4 -- 部地の上面（地面からの高さ）
	local function at(lx: number, ly: number, lz: number): CFrame
		return cf * CFrame.new(lx, top + ly, lz)
	end

	-- 家（仮図形: 本体 + 段の屋根 + 扉 + 光る窓）
	local h = L.house
	part(model, "House", Vector3.new(18, 10, 14), at(h.x, 5, h.z), PALETTE.house)
	part(model, "Roof", Vector3.new(20, 2, 16), at(h.x, 11, h.z), PALETTE.roof)
	part(model, "RoofTop", Vector3.new(14, 2, 10), at(h.x, 13, h.z), PALETTE.roof)
	part(model, "Door", Vector3.new(4, 6, 0.4), at(h.x, 3, h.z - 7.1), PALETTE.door)
	for _, wx in { -5.5, 5.5 } do
		local w = part(model, "Window", Vector3.new(3, 3, 0.3), at(h.x + wx, 6, h.z - 7.1), PALETTE.window, { Material = Enum.Material.Neon })
		glow(w, PALETTE.window, 8)
	end

	-- 施設の台座（dew_spring・bloom_garden）
	for fid, pos in L.pedestals do
		local colorKey = if fid == "dew_spring" then "dew" else "bloom"
		local c = NODE_COLORS[colorKey]
		local base = part(model, `Pedestal_{fid}`, Vector3.new(1.5, 10, 10), at(pos.x, 0.75, pos.z) * CFrame.Angles(0, 0, math.rad(90)), c.base)
		;(base :: Part).Shape = Enum.PartType.Cylinder
		base:SetAttribute("FacilityId", fid)
		base:SetAttribute("PlotIndex", index)
		local ring = part(model, "Ring", Vector3.new(0.3, 10.6, 10.6), at(pos.x, 1.4, pos.z) * CFrame.Angles(0, 0, math.rad(90)), c.glow, ghost())
		ring.Material = Enum.Material.Neon
		;(ring :: Part).Shape = Enum.PartType.Cylinder
		local orb = part(model, "Orb", Vector3.new(2.4, 2.4, 2.4), at(pos.x, 4, pos.z), c.glow, ghost())
		orb.Material = Enum.Material.Neon
		;(orb :: Part).Shape = Enum.PartType.Ball
		glow(orb, c.glow, 12)
	end

	-- 予約地（forest の施設）と展示台 3 枠（MVP1 範囲外、場所だけ）。看板の位置は plotLabels と同じ（PlotSpec が出現位置との距離を確かめる）
	local r = L.reserved
	local res = part(model, `Reserved_{r.id}`, Vector3.new(1, 9, 9), at(r.x, 0.5, r.z) * CFrame.Angles(0, 0, math.rad(90)), PALETTE.reserved, { Transparency = 0.4 })
	;(res :: Part).Shape = Enum.PartType.Cylinder
	res:SetAttribute("FacilityId", r.id)
	res:SetAttribute("Reserved", true)
	billboard(res, Text.get("World.Reserved"), 3, 60)
	for i, s in L.showcase do
		local pad = part(model, `Showcase{i}`, Vector3.new(8, 1, 6), at(s.x, 0.5, s.z), PALETTE.reserved, { Transparency = 0.4 })
		pad:SetAttribute("ShowcaseSlot", i)
		if i == L.showcaseLabelSlot then
			billboard(pad, Text.get("World.Showcase"), 3, 60)
		end
	end

	-- 名札（前の端、広場側から読める）
	local sg = L.sign
	part(model, "SignPost", Vector3.new(0.8, 4, 0.8), at(sg.x, 2, sg.z), PALETTE.wood)
	local board = part(model, "Sign", Vector3.new(10, 3, 0.6), at(sg.x, 4.5, sg.z), PALETTE.wood)
	local label = billboard(board, Text.get("World.PlotEmpty"), 3, 150)

	model.Parent = folder
	local sp = L.spawn
	-- 出現: 部地の上面 + 3.5（キャラクターの中心）、奥（家・台座）を向く
	local spawnCf = at(sp.x, 3.5, sp.z) * CFrame.Angles(0, math.pi, 0)
	return model, label, spawnCf
end

-- ワールドを作る（既存の同名フォルダは作り直す）。gatherRadius = Config.GATHER_RADIUS
function MeadowBuilder.build(parent: Instance, world: any, gd: any, Text: any, gatherRadius: number): World
	MeadowBuilder.checkConfig(world, gd)
	initPalette()
	local old = parent:FindFirstChild(world.folderName)
	if old ~= nil then
		old:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = world.folderName
	local y = world.groundY

	-- 地面（全体）・フィールド・広場・道
	part(folder, "Base", Vector3.new(560, 2, 560), CFrame.new(0, y - 1, -20), PALETTE.base, { CastShadow = false })
	local f = world.field
	local fieldPart = part(folder, "Field", Vector3.new(f.sizeX, 0.2, f.sizeZ), CFrame.new(f.x, y + 0.05, f.z), PALETTE.field, { CastShadow = false })
	fieldPart:SetAttribute("FieldId", f.id)
	local pl = world.plaza
	disc(folder, "Plaza", pl.radius * 2, 0.4, pl.x, y + 0.2, pl.z, PALETTE.plaza)
	local pathStart = pl.z - pl.radius
	local pathEnd = f.z + f.sizeZ / 2
	local pathLen = pathStart - pathEnd
	part(folder, "Path", Vector3.new(world.path.width, 0.3, pathLen + 2), CFrame.new(0, y + 0.15, (pathStart + pathEnd) / 2), PALETTE.path, { CastShadow = false })

	-- 広場の出現地点（部地が無い・割り当て前の予備）
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "PlazaSpawn"
	spawn.Anchored = true
	spawn.Size = Vector3.new(8, 0.4, 8)
	spawn.CFrame = CFrame.new(pl.x, y + 0.4, pl.z)
	spawn.Color = PALETTE.plaza
	spawn.Material = Enum.Material.SmoothPlastic
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Parent = folder

	-- 掲示板（日次依頼、S9 で使う）
	local b = world.board
	part(folder, "BoardPostL", Vector3.new(0.8, 6, 0.8), CFrame.new(b.x - 4, y + 3, b.z), PALETTE.wood)
	part(folder, "BoardPostR", Vector3.new(0.8, 6, 0.8), CFrame.new(b.x + 4, y + 3, b.z), PALETTE.wood)
	local boardPart = part(folder, "Board", Vector3.new(10, 5, 0.6), CFrame.new(b.x, y + 5.5, b.z), PALETTE.wood)
	boardPart:SetAttribute("Board", "daily")
	billboard(boardPart, Text.get("World.Board"), 4, 120)

	-- 採集ノード（data の gather_nodes。見た目の半径は Config、判定半径は Config.GATHER_RADIUS）
	local nodesFolder = Instance.new("Folder")
	nodesFolder.Name = "Nodes"
	nodesFolder.Parent = folder
	for id, n in world.nodes do
		local resource = gd.nodes[id].node.resource
		local c = NODE_COLORS[resource] or { base = PALETTE.reserved, glow = Color3.new(1, 1, 1) }
		local top = y + 0.35
		local node = disc(nodesFolder, id, n.radius * 2, 0.3, n.x, top, n.z, c.base)
		node:SetAttribute("NodeId", id)
		node:SetAttribute("Resource", resource)
		node:SetAttribute("GatherRadius", gatherRadius)
		disc(nodesFolder, `{id}_Range`, gatherRadius * 2, 0.05, n.x, y + 0.27, n.z, c.glow, { Transparency = 0.7, CanCollide = false, CanTouch = false, CanQuery = false, CastShadow = false })
		-- 光る小物（露は浮かぶ雫 1 個、花は小さな光の花 5 個）
		if resource == "dew" then
			local orb = part(nodesFolder, `{id}_Orb`, Vector3.new(3, 3, 3), CFrame.new(n.x, top + 4, n.z), c.glow, ghost())
			orb.Material = Enum.Material.Neon
			;(orb :: Part).Shape = Enum.PartType.Ball
			glow(orb, c.glow, 18)
		else
			for k = 1, 5 do
				local a = (k / 5) * math.pi * 2
				local bud = part(nodesFolder, `{id}_Bud`, Vector3.new(1.6, 1.6, 1.6), CFrame.new(n.x + math.cos(a) * 3.5, top + 1.2, n.z + math.sin(a) * 3.5), c.glow, ghost())
				bud.Material = Enum.Material.Neon
				;(bud :: Part).Shape = Enum.PartType.Ball
				if k == 1 then
					glow(bud, c.glow, 18)
				end
			end
		end
	end

	-- 野生の出現区域（S7 で使う。目印だけ）
	local wz = world.wildZone
	local zone = disc(folder, "WildZone", wz.radius * 2, 0.05, wz.x, y + 0.27, wz.z, PALETTE.wild, { Transparency = 0.55, CanCollide = false, CanTouch = false, CanQuery = false, CastShadow = false })
	zone:SetAttribute("WildZone", world.field.id)

	-- 森の関門（未解禁）
	local g = world.gate
	part(folder, "GatePillarL", Vector3.new(4, 16, 4), CFrame.new(g.x - 10, y + 8, g.z), PALETTE.stone)
	part(folder, "GatePillarR", Vector3.new(4, 16, 4), CFrame.new(g.x + 10, y + 8, g.z), PALETTE.stone)
	local beam = part(folder, "GateBeam", Vector3.new(26, 3, 4), CFrame.new(g.x, y + 17.5, g.z), PALETTE.stone)
	local door = part(folder, "GateDoor", Vector3.new(16, 14, 1), CFrame.new(g.x, y + 7, g.z), PALETTE.gateDoor, { Transparency = 0.25, Material = Enum.Material.Neon })
	door:SetAttribute("LockedField", "forest")
	glow(door, PALETTE.gateDoor, 14)
	billboard(beam, Text.get("World.ForestGate"), 4, 200)

	-- 部地
	local plotsFolder = Instance.new("Folder")
	plotsFolder.Name = "Plots"
	plotsFolder.Parent = folder
	local labels: { TextLabel } = {}
	local models: { Model } = {}
	local spawns: { CFrame } = {}
	for i = 1, #world.plots do
		local m, label, sp = buildPlot(plotsFolder, world, i, Text)
		models[i] = m
		labels[i] = label
		spawns[i] = sp
	end

	folder.Parent = parent

	local handle: World = {
		folder = folder,
		setPlotOwner = function(index: number, displayName: string?, userId: number?)
			local label = labels[index]
			if label == nil then
				return
			end
			if displayName ~= nil then
				label.Text = Text.format("World.PlotOwner", { name = displayName })
			else
				label.Text = Text.get("World.PlotEmpty")
			end
			models[index]:SetAttribute("OwnerUserId", userId or 0)
		end,
		spawnCFrame = function(index: number): CFrame
			return spawns[index]
		end,
		plazaSpawnCFrame = function(): CFrame
			return CFrame.new(pl.x, y + 3.5, pl.z + 6)
		end,
		-- 草原の入口: 地面 + 3.5（キャラクターの中心）、フィールドの中心を向く
		meadowEntryCFrame = function(): CFrame
			local ex, ez, efx, efz = MeadowBuilder.meadowEntryFrame(world)
			local at = Vector3.new(ex, y + 3.5, ez)
			return CFrame.lookAt(at, at + Vector3.new(efx, 0, efz))
		end,
	}
	return handle
end

return table.freeze(MeadowBuilder)
