--!strict
-- 光の精霊「꽃등(flower_lamp)」★1 の見た目をコードだけで組み立てるモジュール
-- 3D モデルを使わず、Neon パーツ・パーティクル・ライトで表現する(Sparkle.luau と同じ方式)
--   桃色〜橙の灯りの芯(顔つき)を、下から花びら 5 枚が包む
--   顔が常に見えるよう、花びらは芯の下半分を包み、正面は花びらの隙間にする
--   動き: ふわふわ上下・ちょうちんのような小さな揺れ・花びらがゆっくり開閉(1 枚ずつ少し遅れる)
--         開くほど灯りと花粉が増える・まばたき
-- 配置: ReplicatedStorage.Shared.SpiritVisuals.FlowerLamp(Rojo: game/src/shared/SpiritVisuals/FlowerLamp.luau)
-- 利用: クライアント専用の見た目(判定・報酬には使わない)。依存モジュール: なし(RunService のみ)
-- 構成: パーツ 12 / ParticleEmitter 1 / PointLight 1
-- 座標は体の中心が原点、前方 = -Z。全パーツ Anchored で Heartbeat ごとに CFrame を更新する

local RunService = game:GetService("RunService")

local FlowerLamp = {}

-- 配色(外見スキン商品はこの表の差し替えで作れる)
export type Palette = {
	core: Color3, -- 灯りの芯: 桃がかった橙
	petal: Color3, -- 花びら: 桃色
	shine: Color3, -- 目のハイライト
	eye: Color3, -- 目
	cheek: Color3, -- 頬の赤み
	pollen: Color3, -- 花粉の粒子
	light: Color3, -- 周囲を照らす光
}

local DEFAULT_PALETTE: Palette = {
	core = Color3.fromRGB(255, 190, 150),
	petal = Color3.fromRGB(255, 168, 205),
	shine = Color3.fromRGB(255, 255, 255),
	eye = Color3.fromRGB(70, 36, 56),
	cheek = Color3.fromRGB(255, 120, 150),
	pollen = Color3.fromRGB(255, 232, 140),
	light = Color3.fromRGB(255, 176, 120),
}

local CORE_SIZE = 0.8
local CORE_CENTER = Vector3.new(0, 0.15, 0)
local CORE_RADII = Vector3.new(CORE_SIZE, CORE_SIZE, CORE_SIZE) / 2
local PETAL_COUNT = 5
local PETAL_SIZE = Vector3.new(0.5, 0.62, 0.1) -- 幅・長さ・厚み
local HINGE = Vector3.new(0, -0.35, 0.22) -- 花びらの付け根(Y = 高さ, Z = 中心からの距離)
local TILT_CLOSED = math.rad(30) -- 閉じたときの外への傾き(鉛直から)
local TILT_OPEN = math.rad(75)
local OPEN_PERIOD = 8 -- 開閉の周期(秒)
local PETAL_DELAY = 0.15 -- 花びら 1 枚ごとの遅れ(秒)
local BLINK_PERIOD = 3.6
local BLINK_TIME = 0.12
local BLINK_SCALE = Vector3.new(1, 0.15, 1)

type Item = { part: BasePart, cf: CFrame } -- cf は原点からの相対
type Petal = { part: BasePart, yaw: CFrame, index: number }

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

-- 開き具合 0(閉)〜1(開)。cos で端がなめらか
local function openness(t: number): number
	return 0.5 - 0.5 * math.cos(t * 2 * math.pi / OPEN_PERIOD)
end

-- ふわっと舞い上がる花粉
local function addPollen(parent: BasePart, palette: Palette): ParticleEmitter
	local pe = Instance.new("ParticleEmitter")
	pe.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	pe.LightEmission = 1
	pe.LightInfluence = 0
	pe.Color = ColorSequence.new(palette.pollen, palette.petal)
	pe.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.14),
		NumberSequenceKeypoint.new(1, 0),
	})
	pe.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	pe.Lifetime = NumberRange.new(1.2, 2.0)
	pe.Rate = 3
	pe.Speed = NumberRange.new(0.2, 0.4)
	pe.SpreadAngle = Vector2.new(180, 180)
	pe.Acceleration = Vector3.new(0, 0.25, 0) -- ゆっくり上へ漂う
	pe.Parent = parent
	return pe
end

-- 精霊を生成する。戻り値: model, destroy関数
-- palette を渡すと配色を差し替えられる(スキン用)
function FlowerLamp.create(parent: Instance, origin: CFrame, palette: Palette?): (Model, () -> ())
	local pal: Palette = palette or DEFAULT_PALETTE
	-- 多数が同時に出ても動きがそろわないよう、開始位相とまばたき位相をずらす(見た目だけの乱数)
	local rng = Random.new()
	local timeOffset = rng:NextNumber(0, 10)
	local blinkOffset = rng:NextNumber(0, BLINK_PERIOD)

	local model = Instance.new("Model")
	model.Name = "FlowerLamp"

	local items: { Item } = {}
	local function add(part: BasePart, cf: CFrame)
		table.insert(items, { part = part, cf = cf })
	end

	-- 灯りの芯
	local core = makePart("Core", Vector3.new(CORE_SIZE, CORE_SIZE, CORE_SIZE), pal.core, Enum.Material.Neon, 0, model)
	core.Shape = Enum.PartType.Ball

	-- 花びら 5 枚。正面(-Z)は隙間になるよう 36° ずらして並べる
	local petals: { Petal } = {}
	for i = 0, PETAL_COUNT - 1 do
		local yaw = math.rad(36 + 360 / PETAL_COUNT * i)
		local petal = makeEllipsoid("Petal", PETAL_SIZE, pal.petal, Enum.Material.Neon, 0.15, model)
		table.insert(petals, {
			part = petal,
			yaw = CFrame.Angles(0, yaw, 0) * CFrame.new(0, HINGE.Y, -HINGE.Z),
			index = i,
		})
	end

	-- 顔(芯の表面): 目 + ハイライト + 頬の赤み
	local eyeMeshes: { SpecialMesh } = {}
	local shines: { BasePart } = {}
	local face = CFrame.new(CORE_CENTER)
	for _, s in { -1, 1 } do
		local eye, eyeMesh = makeEllipsoid("Eye", Vector3.new(0.13, 0.17, 0.07), pal.eye, Enum.Material.SmoothPlastic, 0, model)
		add(eye, face * onSurface(CORE_RADII, s * 0.14, 0.06, 0))
		table.insert(eyeMeshes, eyeMesh)
		local shine = makeEllipsoid("EyeShine", Vector3.new(0.05, 0.05, 0.03), pal.shine, Enum.Material.Neon, 0, model)
		add(shine, face * onSurface(CORE_RADII, s * 0.14 - 0.025, 0.1, 0.035))
		table.insert(shines, shine)
		local cheek = makeEllipsoid("Cheek", Vector3.new(0.13, 0.07, 0.04), pal.cheek, Enum.Material.SmoothPlastic, 0.25, model)
		add(cheek, face * onSurface(CORE_RADII, s * 0.22, -0.04, 0))
	end

	-- 灯り
	local light = Instance.new("PointLight")
	light.Color = pal.light
	light.Range = 10
	light.Brightness = 1.2
	light.Shadows = false
	light.Parent = core

	local pollen = addPollen(core, pal)

	model.PrimaryPart = core
	model.Parent = parent

	-- アニメーション: ふわふわ上下・ちょうちんの揺れ・花びらの開閉・灯りと花粉の強弱・まばたき
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
		local root = origin
			* CFrame.new(0, 0.18 * math.sin(t * 1.5), 0)
			* CFrame.Angles(0, math.sin(t * 0.45) * 0.35, math.rad(4) * math.sin(t * 1.1))

		core.CFrame = root * CFrame.new(CORE_CENTER)
		for _, it in items do
			it.part.CFrame = root * it.cf
		end

		for _, p in petals do
			local tilt = TILT_CLOSED + (TILT_OPEN - TILT_CLOSED) * openness(t - p.index * PETAL_DELAY)
			-- 付け根を軸に、上端を外側(-Z)へ倒す
			p.part.CFrame = root * p.yaw * CFrame.Angles(-tilt, 0, 0) * CFrame.new(0, PETAL_SIZE.Y / 2, 0)
		end

		local open = openness(t)
		light.Brightness = 1.2 + 0.8 * open
		pollen.Rate = 3 + 5 * open

		local blink = ((t + blinkOffset) % BLINK_PERIOD) < BLINK_TIME
		if blink ~= lastBlink then
			lastBlink = blink
			for _, m in eyeMeshes do
				m.Scale = if blink then BLINK_SCALE else Vector3.one
			end
			for _, sh in shines do
				sh.Transparency = if blink then 1 else 0
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

FlowerLamp.DEFAULT_PALETTE = DEFAULT_PALETTE

return FlowerLamp
