--!strict
-- 光の精霊「조각빛(shard_light)」★2 の見た目をコードだけで組み立てるモジュール
-- 3D モデルを使わず、Neon パーツ・パーティクル・ライトで表現する(Sparkle.luau と同じ方式)
--   丸い光の芯(顔つき)+ 光輪 + 頭の小さな宝石、そのまわりを青緑・紫の角ばった結晶片 5 個が回る
--   ★1 より一回り大きく(結晶の軌道を含む幅 約 2.3)、演出を増やす
--   動き: ふわふわ上下・ゆっくり左右を向く・結晶が傾いた輪の上を公転しつつ自転・結晶のまたたき
--         頭の宝石の自転・光輪の明滅・光の色が青緑⇔紫に移る・まばたき
-- 配置: ReplicatedStorage.Shared.SpiritVisuals.ShardLight(Rojo: game/src/shared/SpiritVisuals/ShardLight.luau)
-- 利用: クライアント専用の見た目(判定・報酬には使わない)。依存モジュール: なし(RunService のみ)
-- 構成: パーツ 14 / ParticleEmitter 1 / PointLight 1
-- 座標は芯の中心が原点、前方 = -Z。全パーツ Anchored で Heartbeat ごとに CFrame を更新する

local RunService = game:GetService("RunService")

local ShardLight = {}

-- 配色(外見スキン商品はこの表の差し替えで作れる)
export type Palette = {
	core: Color3, -- 芯: 青みの白
	halo: Color3, -- 光輪
	shardA: Color3, -- 結晶: 青緑(偶数番)
	shardB: Color3, -- 結晶: 紫(奇数番)・頭の宝石
	shine: Color3, -- 目のハイライト
	eye: Color3, -- 目
	cheek: Color3, -- 頬の赤み
}

local DEFAULT_PALETTE: Palette = {
	core = Color3.fromRGB(225, 250, 255),
	halo = Color3.fromRGB(150, 235, 240),
	shardA = Color3.fromRGB(90, 225, 215),
	shardB = Color3.fromRGB(180, 145, 255),
	shine = Color3.fromRGB(255, 255, 255),
	eye = Color3.fromRGB(36, 40, 72),
	cheek = Color3.fromRGB(255, 165, 205),
}

local CORE_SIZE = 1.1
local CORE_RADII = Vector3.new(CORE_SIZE, CORE_SIZE, CORE_SIZE) / 2
local HALO_SIZE = 1.9
local SHARD_COUNT = 5
local SHARD_SIZE = Vector3.new(0.16, 0.48, 0.16) -- 細長い角柱(ほぼ立てて自転させる)
local ORBIT_RADIUS = 1.05
local ORBIT_TILT = 0.35 -- 輪の傾き(正面を通るときは顔より下を通る)
local ORBIT_SPEED = 0.9 -- rad/秒
local GEM_SIZE = 0.22
local GEM_ROT = CFrame.Angles(math.rad(45), 0, math.rad(35.26)) -- 立方体を頂点で立たせる
local BLINK_PERIOD = 3.3
local BLINK_TIME = 0.12
local BLINK_SCALE = Vector3.new(1, 0.15, 1)

type Item = { part: BasePart, cf: CFrame } -- cf は原点からの相対
type Shard = { part: BasePart, index: number }

-- 当たり判定・影なしの装飾パーツを作る
local function makePart(name: string, size: Vector3, color: Color3, material: Enum.Material, transparency: number, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = material
	p.Transparency = transparency
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Parent = parent
	return p
end

-- 楕円体(SpecialMesh Sphere)
local function makeEllipsoid(name: string, size: Vector3, color: Color3, material: Enum.Material, transparency: number, parent: Instance): (Part, SpecialMesh)
	local p = makePart(name, size, color, material, transparency, parent)
	local m = Instance.new("SpecialMesh")
	m.MeshType = Enum.MeshType.Sphere
	m.Parent = p
	return p, m
end

-- 楕円体(半径 radii)の前面(-Z 側)の点 (x, y) に、表面の向きへ沿わせて置く CFrame を返す
-- 返す CFrame の -Z が表面の外向き。lift だけ外へ浮かせる
local function onSurface(radii: Vector3, x: number, y: number, lift: number): CFrame
	local k = 1 - (x / radii.X) ^ 2 - (y / radii.Y) ^ 2
	local z = -radii.Z * math.sqrt(math.max(k, 0))
	local p = Vector3.new(x, y, z)
	local n = Vector3.new(x / radii.X ^ 2, y / radii.Y ^ 2, z / radii.Z ^ 2).Unit
	return CFrame.lookAt(p + n * lift, p + n * (lift + 1))
end

-- 立ちのぼるきらきら
local function addSparkles(parent: BasePart, palette: Palette): ParticleEmitter
	local pe = Instance.new("ParticleEmitter")
	pe.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	pe.LightEmission = 1
	pe.LightInfluence = 0
	pe.Color = ColorSequence.new(palette.shardA, palette.shardB)
	pe.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.25),
		NumberSequenceKeypoint.new(1, 0),
	})
	pe.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	pe.Lifetime = NumberRange.new(0.8, 1.4)
	pe.Rate = 10
	pe.Speed = NumberRange.new(0.5, 1.0)
	pe.SpreadAngle = Vector2.new(180, 180)
	pe.Acceleration = Vector3.new(0, 0.3, 0)
	pe.Parent = parent
	return pe
end

-- 精霊を生成する。戻り値: model, destroy関数
-- palette を渡すと配色を差し替えられる(スキン用)
function ShardLight.create(parent: Instance, origin: CFrame, palette: Palette?): (Model, () -> ())
	local pal: Palette = palette or DEFAULT_PALETTE
	-- 多数が同時に出ても動きがそろわないよう、開始位相とまばたき位相をずらす(見た目だけの乱数)
	local rng = Random.new()
	local timeOffset = rng:NextNumber(0, 10)
	local blinkOffset = rng:NextNumber(0, BLINK_PERIOD)

	local model = Instance.new("Model")
	model.Name = "ShardLight"

	local items: { Item } = {}
	local function add(part: BasePart, cf: CFrame)
		table.insert(items, { part = part, cf = cf })
	end

	-- 芯と光輪
	local core = makePart("Core", Vector3.new(CORE_SIZE, CORE_SIZE, CORE_SIZE), pal.core, Enum.Material.Neon, 0, model)
	core.Shape = Enum.PartType.Ball
	local halo = makePart("Halo", Vector3.new(HALO_SIZE, HALO_SIZE, HALO_SIZE), pal.halo, Enum.Material.Neon, 0.85, model)
	halo.Shape = Enum.PartType.Ball

	-- 頭の小さな宝石(立方体を頂点で立たせて自転させる)
	local gem = makePart("Gem", Vector3.new(GEM_SIZE, GEM_SIZE, GEM_SIZE), pal.shardB, Enum.Material.Neon, 0.1, model)

	-- 結晶片(青緑・紫を交互に)
	local shards: { Shard } = {}
	for i = 0, SHARD_COUNT - 1 do
		local color = if i % 2 == 0 then pal.shardA else pal.shardB
		local shard = makePart("Shard", SHARD_SIZE, color, Enum.Material.Neon, 0.15, model)
		table.insert(shards, { part = shard, index = i })
	end

	-- 顔: 大きめの目 + ハイライト + 頬の赤み
	local eyeMeshes: { SpecialMesh } = {}
	local shines: { BasePart } = {}
	for _, s in { -1, 1 } do
		local eye, eyeMesh = makeEllipsoid("Eye", Vector3.new(0.17, 0.22, 0.08), pal.eye, Enum.Material.SmoothPlastic, 0, model)
		add(eye, onSurface(CORE_RADII, s * 0.19, 0.06, 0))
		table.insert(eyeMeshes, eyeMesh)
		local shine = makeEllipsoid("EyeShine", Vector3.new(0.065, 0.065, 0.03), pal.shine, Enum.Material.Neon, 0, model)
		add(shine, onSurface(CORE_RADII, s * 0.19 - 0.035, 0.12, 0.04))
		table.insert(shines, shine)
		local cheek = makeEllipsoid("Cheek", Vector3.new(0.16, 0.08, 0.04), pal.cheek, Enum.Material.SmoothPlastic, 0.25, model)
		add(cheek, onSurface(CORE_RADII, s * 0.33, -0.1, 0))
	end

	-- 周囲を照らす光(色は青緑⇔紫に移る)
	local light = Instance.new("PointLight")
	light.Color = pal.shardA
	light.Range = 14
	light.Brightness = 2
	light.Shadows = false
	light.Parent = core

	addSparkles(core, pal)

	model.PrimaryPart = core
	model.Parent = parent

	-- アニメーション
	local t0 = os.clock() - timeOffset
	local lastBlink = false
	local conn: RBXScriptConnection? = nil
	conn = RunService.Heartbeat:Connect(function()
		if not model.Parent then
			if conn then
				conn:Disconnect()
			end
			return
		end
		local t = os.clock() - t0
		local root = origin * CFrame.new(0, 0.22 * math.sin(t * 1.8), 0) * CFrame.Angles(0, math.sin(t * 0.5) * 0.4, 0)

		core.CFrame = root
		halo.CFrame = root
		halo.Transparency = 0.82 + 0.06 * math.sin(t * 3)
		for _, it in items do
			it.part.CFrame = root * it.cf
		end
		gem.CFrame = root * CFrame.new(0, 0.7, 0) * CFrame.Angles(0, t * 1.5, 0) * GEM_ROT

		for _, sh in shards do
			local i = sh.index
			local theta = t * ORBIT_SPEED + i * 2 * math.pi / SHARD_COUNT
			-- 傾いた輪: 正面(-Z)を通るとき低く、背面で高くなる
			local pos = Vector3.new(
				ORBIT_RADIUS * math.cos(theta),
				ORBIT_TILT * math.sin(theta) + 0.08 * math.sin(t * 2 + i * 1.3),
				ORBIT_RADIUS * math.sin(theta)
			)
			sh.part.CFrame = root * CFrame.new(pos) * CFrame.Angles(0, t * 2 + i, 0) * CFrame.Angles(0, 0, math.rad(15)) * CFrame.Angles(0, math.rad(45), 0)
			sh.part.Transparency = 0.1 + 0.3 * (0.5 + 0.5 * math.sin(t * 3 + i * 1.7)) -- またたき
		end

		light.Color = pal.shardA:Lerp(pal.shardB, 0.5 + 0.5 * math.sin(t * 0.7))
		light.Brightness = 2 + 0.5 * math.sin(t * 3)

		local blink = ((t + blinkOffset) % BLINK_PERIOD) < BLINK_TIME
		if blink ~= lastBlink then
			lastBlink = blink
			for _, m in eyeMeshes do
				m.Scale = if blink then BLINK_SCALE else Vector3.one
			end
			for _, s in shines do
				s.Transparency = if blink then 1 else 0
			end
		end
	end)

	local function destroy()
		if conn then
			conn:Disconnect()
		end
		model:Destroy()
	end
	return model, destroy
end

ShardLight.DEFAULT_PALETTE = DEFAULT_PALETTE

return ShardLight
