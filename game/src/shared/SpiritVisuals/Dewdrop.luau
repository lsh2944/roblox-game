--!strict
-- 光の精霊「이슬방울(dewdrop)」★1 の見た目をコードだけで組み立てるモジュール
-- 3D モデルを使わず、Neon パーツ・パーティクル・ライトで表現する(Sparkle.luau と同じ方式)
--   半透明の水色のしずく体 + 中の光の芯 + 小さめの目・目のハイライト・頬の赤み・体のつや
--   動き: ぽよんと弾む(着地でつぶれる)・ゆっくり左右を向く・まばたき、下へ落ちる水滴の粒子
-- 配置: ReplicatedStorage.Shared.SpiritVisuals.Dewdrop(Rojo: game/src/shared/SpiritVisuals/Dewdrop.luau)
-- 利用: クライアント専用の見た目(判定・報酬には使わない)。依存モジュール: なし(RunService のみ)
-- 構成: パーツ 10 / ParticleEmitter 1 / PointLight 1 / Attachment 1
-- 座標は体の中心が原点、前方 = -Z。全パーツ Anchored で Heartbeat ごとに CFrame を更新する
-- (本番で数が増えたら workspace:BulkMoveTo などで最適化する想定。Sparkle と同じ)

local RunService = game:GetService("RunService")

local Dewdrop = {}

-- 配色(外見スキン商品はこの表の差し替えで作れる)
export type Palette = {
	body: Color3, -- 体: 半透明の水色
	core: Color3, -- 体の中の光の芯
	gloss: Color3, -- 体のつや・目のハイライト
	eye: Color3, -- 目
	cheek: Color3, -- 頬の赤み
	drop: Color3, -- 落ちる水滴の粒子・ライト
}

local DEFAULT_PALETTE: Palette = {
	body = Color3.fromRGB(150, 220, 255),
	core = Color3.fromRGB(215, 245, 255),
	gloss = Color3.fromRGB(255, 255, 255),
	eye = Color3.fromRGB(40, 52, 84),
	cheek = Color3.fromRGB(255, 160, 190),
	drop = Color3.fromRGB(170, 230, 255),
}

local BODY_SIZE = Vector3.new(1.1, 1.0, 1.1)
local BODY_RADII = BODY_SIZE / 2
local BOUNCE_PERIOD = 1.6 -- 弾む周期(秒)
local BOUNCE_HEIGHT = 0.35
local SQUASH = 0.14 -- 着地でつぶれる量(縦の縮み率)
local BLINK_PERIOD = 3.4
local BLINK_TIME = 0.12
local BLINK_SCALE = Vector3.new(1, 0.15, 1) -- まばたき中は目を細い線にする

type Item = { part: BasePart, cf: CFrame } -- cf は体中心からの相対位置(つぶれに合わせて位置だけ伸縮)

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

-- 楕円体(SpecialMesh Sphere)。メッシュの Scale でつぶし・まばたきを表す
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

-- 下へ落ちる水滴の粒子
local function addDrops(attachment: Attachment, palette: Palette): ParticleEmitter
	local pe = Instance.new("ParticleEmitter")
	pe.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	pe.LightEmission = 0.8
	pe.LightInfluence = 0
	pe.Color = ColorSequence.new(palette.drop)
	pe.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.18),
		NumberSequenceKeypoint.new(1, 0.06),
	})
	pe.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	pe.Lifetime = NumberRange.new(0.6, 1.0)
	pe.Rate = 6
	pe.Speed = NumberRange.new(0.3, 0.6)
	pe.EmissionDirection = Enum.NormalId.Bottom
	pe.SpreadAngle = Vector2.new(20, 20)
	pe.Acceleration = Vector3.new(0, -3, 0) -- しずくがぽたっと落ちる
	pe.Parent = attachment
	return pe
end

-- 精霊を生成する。戻り値: model, destroy関数
-- palette を渡すと配色を差し替えられる(スキン用)
function Dewdrop.create(parent: Instance, origin: CFrame, palette: Palette?): (Model, () -> ())
	local pal: Palette = palette or DEFAULT_PALETTE
	-- 多数が同時に出ても動きがそろわないよう、開始位相とまばたき位相をずらす(見た目だけの乱数)
	local rng = Random.new()
	local timeOffset = rng:NextNumber(0, 10)
	local blinkOffset = rng:NextNumber(0, BLINK_PERIOD)

	local model = Instance.new("Model")
	model.Name = "Dewdrop"

	local items: { Item } = {}
	local function add(part: BasePart, cf: CFrame)
		table.insert(items, { part = part, cf = cf })
	end

	-- 体: 半透明の丸いしずく + 頭頂の小さなとんがり(少し後ろへ反らす)
	local body, bodyMesh = makeEllipsoid("Body", BODY_SIZE, pal.body, Enum.Material.Neon, 0.4, model)
	local tip = makeEllipsoid("Tip", Vector3.new(0.32, 0.55, 0.32), pal.body, Enum.Material.Neon, 0.4, model)
	add(tip, CFrame.new(0, 0.5, 0.04) * CFrame.Angles(math.rad(15), 0, 0))

	-- 中の光の芯(半透明の体ごしに見える。顔と重ならないよう目より下・少し奥に置く)
	local core = makePart("Core", Vector3.new(0.4, 0.4, 0.4), pal.core, Enum.Material.Neon, 0.5, model)
	core.Shape = Enum.PartType.Ball
	add(core, CFrame.new(0, -0.18, 0.12))

	-- 体のつや(左上)
	local gloss = makeEllipsoid("Gloss", Vector3.new(0.14, 0.22, 0.05), pal.gloss, Enum.Material.Neon, 0.15, model)
	add(gloss, onSurface(BODY_RADII, -0.27, 0.2, 0))

	-- 顔: 小さめの目 + ハイライト + 頬の赤み
	local eyeMeshes: { SpecialMesh } = {}
	local shines: { BasePart } = {}
	for _, s in { -1, 1 } do
		local eye, eyeMesh = makeEllipsoid("Eye", Vector3.new(0.15, 0.2, 0.08), pal.eye, Enum.Material.SmoothPlastic, 0, model)
		add(eye, onSurface(BODY_RADII, s * 0.18, 0, 0))
		table.insert(eyeMeshes, eyeMesh)
		local shine = makeEllipsoid("EyeShine", Vector3.new(0.06, 0.06, 0.03), pal.gloss, Enum.Material.Neon, 0, model)
		add(shine, onSurface(BODY_RADII, s * 0.18 - 0.03, 0.05, 0.04))
		table.insert(shines, shine)
		local cheek = makeEllipsoid("Cheek", Vector3.new(0.17, 0.09, 0.04), pal.cheek, Enum.Material.SmoothPlastic, 0.25, model)
		add(cheek, onSurface(BODY_RADII, s * 0.32, -0.13, 0))
	end

	-- 周囲を照らす光
	local light = Instance.new("PointLight")
	light.Color = pal.drop
	light.Range = 10
	light.Brightness = 1.4
	light.Shadows = false
	light.Parent = core

	-- 体の下端から水滴を落とす
	local dripPoint = Instance.new("Attachment")
	dripPoint.Name = "DripPoint"
	dripPoint.Position = Vector3.new(0, -BODY_RADII.Y + 0.05, 0)
	dripPoint.Parent = body
	addDrops(dripPoint, pal)

	model.PrimaryPart = body
	model.Parent = parent

	-- アニメーション: ぽよんと弾む(着地でつぶれて横に広がる)・ゆっくり左右を向く・光の明滅・まばたき
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
		local h = math.sin(math.pi * ((t / BOUNCE_PERIOD) % 1)) -- 0(着地)→1(頂点)→0
		local s = SQUASH * (1 - h) ^ 6 -- 着地の瞬間だけつぶれる
		local scale = Vector3.new(1 + s * 0.7, 1 - s, 1 + s * 0.7)
		-- つぶれても下端の高さが変わらないよう中心を下げる
		local root = origin
			* CFrame.new(0, BOUNCE_HEIGHT * h - BODY_RADII.Y * s, 0)
			* CFrame.Angles(0, math.sin(t * 0.5) * 0.4, 0)

		body.CFrame = root
		bodyMesh.Scale = scale
		for _, it in items do
			it.part.CFrame = root * CFrame.new(it.cf.Position * scale) * it.cf.Rotation
		end
		light.Brightness = 1.4 + 0.4 * math.sin(t * 2.5)

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

Dewdrop.DEFAULT_PALETTE = DEFAULT_PALETTE

return Dewdrop
