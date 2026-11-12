--!strict
-- 光の精霊「노을새(sunset_bird)」★2 の見た目をコードだけで組み立てるモジュール
-- 3D モデルを使わず、Neon パーツ・Beam・パーティクル・ライトで表現する(Sparkle.luau と同じ方式)
--   丸い橙色の小鳥 + 桃色のおなか・羽・尾、くちばし・頭の飾り羽・大きめの目・頬の赤み
--   尾から後ろへ 2 本の光の帯(Beam)を流す。止まっていても見えるよう Trail ではなく Beam を使う
--   ★1 より一回り大きく(体 1.15×1.05×1.2)、演出を増やす
--   動き: 羽ばたき(羽ばたく時間と滑空する時間を繰り返す)・羽ばたきに合わせた小さな上下・首をかしげる
--         尾振り・光の帯が波打つ・光の色が橙⇔桃に移る・まばたき
-- 配置: ReplicatedStorage.Shared.SpiritVisuals.SunsetBird(Rojo: game/src/shared/SpiritVisuals/SunsetBird.luau)
-- 利用: クライアント専用の見た目(判定・報酬には使わない)。依存モジュール: なし(RunService のみ)
-- 構成: パーツ 13 / Beam 2 / ParticleEmitter 1 / PointLight 1 / Attachment 3
-- 座標は体の中心が原点、前方 = -Z。全パーツ Anchored で Heartbeat ごとに CFrame を更新する

local RunService = game:GetService("RunService")

local SunsetBird = {}

-- 配色(外見スキン商品はこの表の差し替えで作れる)
export type Palette = {
	body: Color3, -- 体: 夕焼けの橙
	belly: Color3, -- おなか: 淡い桃
	wing: Color3, -- 羽: 桃
	tail: Color3, -- 尾・頭の飾り羽: 濃い桃
	beak: Color3, -- くちばし
	shine: Color3, -- 目のハイライト
	eye: Color3, -- 目
	cheek: Color3, -- 頬の赤み
	trail0: Color3, -- 光の帯・粒子・光の色(根元: 橙)
	trail1: Color3, -- 同(先: 桃)
}

local DEFAULT_PALETTE: Palette = {
	body = Color3.fromRGB(255, 168, 112),
	belly = Color3.fromRGB(255, 196, 210),
	wing = Color3.fromRGB(255, 140, 170),
	tail = Color3.fromRGB(255, 120, 170),
	beak = Color3.fromRGB(255, 214, 120),
	shine = Color3.fromRGB(255, 255, 255),
	eye = Color3.fromRGB(60, 34, 52),
	cheek = Color3.fromRGB(255, 110, 140),
	trail0 = Color3.fromRGB(255, 180, 110),
	trail1 = Color3.fromRGB(255, 120, 190),
}

local BODY_SIZE = Vector3.new(1.15, 1.05, 1.2)
local BODY_RADII = BODY_SIZE / 2
local WING_SIZE = Vector3.new(0.55, 0.1, 0.42) -- 横へ張り出す丸い羽
local WING_HINGE_X = 0.5
local WING_REST = math.rad(-10) -- 滑空中の羽の角度(わずかに下げる)
local FLAP_AMP = math.rad(40)
local FLAP_SPEED = 18 -- rad/秒
local FLAP_CYCLE = 3.0 -- 羽ばたき+滑空の 1 周期(秒)
local TAIL_POS = CFrame.new(0, 0.05, 0.62)
local TAIL_TILT = CFrame.Angles(math.rad(-25), 0, 0) -- 尾の先(+Z)を少し上げる
local BLINK_PERIOD = 3.5
local BLINK_TIME = 0.12
local BLINK_SCALE = Vector3.new(1, 0.15, 1)

type Item = { part: BasePart, cf: CFrame } -- cf は原点からの相対
type Wing = { part: BasePart, side: number }
type Streamer = { beam: Beam, phase: number }

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

-- 尾から後ろへ流れる光の帯(2 本で根元の Attachment を共有)
local function addStreamers(tail: BasePart, palette: Palette): { Streamer }
	local base = Instance.new("Attachment")
	base.Name = "StreamerBase"
	base.Position = Vector3.new(0, 0, 0.2)
	base.Parent = tail
	local list: { Streamer } = {}
	for _, s in { -1, 1 } do
		local tip = Instance.new("Attachment")
		tip.Name = "StreamerTip"
		tip.Position = Vector3.new(s * 0.55, 0.15, 1.5)
		tip.Parent = tail
		local beam = Instance.new("Beam")
		beam.Attachment0 = base
		beam.Attachment1 = tip
		beam.Color = ColorSequence.new(palette.trail0, palette.trail1)
		beam.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.15),
			NumberSequenceKeypoint.new(1, 1),
		})
		beam.LightEmission = 1
		beam.LightInfluence = 0
		beam.Width0 = 0.32
		beam.Width1 = 0.04
		beam.FaceCamera = true
		beam.Segments = 16
		beam.Parent = tail
		table.insert(list, { beam = beam, phase = if s > 0 then 0 else 1.6 })
	end
	return list
end

-- 体からこぼれる暖色のきらきら
local function addSparkles(parent: BasePart, palette: Palette): ParticleEmitter
	local pe = Instance.new("ParticleEmitter")
	pe.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	pe.LightEmission = 1
	pe.LightInfluence = 0
	pe.Color = ColorSequence.new(palette.trail0, palette.trail1)
	pe.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.22),
		NumberSequenceKeypoint.new(1, 0),
	})
	pe.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	pe.Lifetime = NumberRange.new(0.8, 1.4)
	pe.Rate = 8
	pe.Speed = NumberRange.new(0.3, 0.7)
	pe.SpreadAngle = Vector2.new(180, 180)
	pe.Acceleration = Vector3.new(0, -0.4, 0) -- 羽のようにゆっくり落ちる
	pe.Parent = parent
	return pe
end

-- 精霊を生成する。戻り値: model, destroy関数
-- palette を渡すと配色を差し替えられる(スキン用)
function SunsetBird.create(parent: Instance, origin: CFrame, palette: Palette?): (Model, () -> ())
	local pal: Palette = palette or DEFAULT_PALETTE
	-- 多数が同時に出ても動きがそろわないよう、開始位相とまばたき位相をずらす(見た目だけの乱数)
	local rng = Random.new()
	local timeOffset = rng:NextNumber(0, 10)
	local blinkOffset = rng:NextNumber(0, BLINK_PERIOD)

	local model = Instance.new("Model")
	model.Name = "SunsetBird"

	local items: { Item } = {}
	local function add(part: BasePart, cf: CFrame)
		table.insert(items, { part = part, cf = cf })
	end

	-- 体・おなか(前下に少しはみ出す楕円体)・頭の飾り羽・くちばし
	local body = makeEllipsoid("Body", BODY_SIZE, pal.body, Enum.Material.Neon, 0, model)
	local belly = makeEllipsoid("Belly", Vector3.new(0.82, 0.72, 0.6), pal.belly, Enum.Material.Neon, 0, model)
	add(belly, CFrame.new(0, -0.16, -0.31))
	local crest = makeEllipsoid("Crest", Vector3.new(0.1, 0.32, 0.2), pal.tail, Enum.Material.Neon, 0, model)
	add(crest, CFrame.new(0, 0.6, -0.1) * CFrame.Angles(math.rad(-25), 0, 0)) -- 先を前へ傾ける
	local beak = makeEllipsoid("Beak", Vector3.new(0.2, 0.13, 0.22), pal.beak, Enum.Material.Neon, 0, model)
	add(beak, onSurface(BODY_RADII, 0, 0, 0.04))

	-- 顔: 大きめの目 + ハイライト + 頬の赤み
	local eyeMeshes: { SpecialMesh } = {}
	local shines: { BasePart } = {}
	for _, s in { -1, 1 } do
		local eye, eyeMesh = makeEllipsoid("Eye", Vector3.new(0.16, 0.21, 0.08), pal.eye, Enum.Material.SmoothPlastic, 0, model)
		add(eye, onSurface(BODY_RADII, s * 0.22, 0.12, 0))
		table.insert(eyeMeshes, eyeMesh)
		local shine = makeEllipsoid("EyeShine", Vector3.new(0.06, 0.06, 0.03), pal.shine, Enum.Material.Neon, 0, model)
		add(shine, onSurface(BODY_RADII, s * 0.22 - 0.03, 0.17, 0.04))
		table.insert(shines, shine)
		local cheek = makeEllipsoid("Cheek", Vector3.new(0.16, 0.08, 0.04), pal.cheek, Enum.Material.SmoothPlastic, 0.25, model)
		add(cheek, onSurface(BODY_RADII, s * 0.36, -0.04, 0))
	end

	-- 羽(左右)
	local wings: { Wing } = {}
	for _, s in { -1, 1 } do
		local wing = makeEllipsoid("Wing", WING_SIZE, pal.wing, Enum.Material.Neon, 0.1, model)
		table.insert(wings, { part = wing, side = s })
	end

	-- 尾と光の帯
	local tail = makeEllipsoid("Tail", Vector3.new(0.45, 0.1, 0.5), pal.tail, Enum.Material.Neon, 0, model)
	local streamers = addStreamers(tail, pal)

	local light = Instance.new("PointLight")
	light.Color = pal.trail0
	light.Range = 13
	light.Brightness = 1.8
	light.Shadows = false
	light.Parent = body

	addSparkles(body, pal)

	model.PrimaryPart = body
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
		-- 周期の前半は羽ばたき、後半は滑空(0〜1 の強さをなめらかに変える)
		local burst = math.clamp(math.sin(t * 2 * math.pi / FLAP_CYCLE) * 2, 0, 1)
		local flapWave = math.sin(t * FLAP_SPEED)
		local bob = 0.15 * math.sin(t * 1.6) + 0.04 * burst * flapWave
		local root = origin
			* CFrame.new(0, bob, 0)
			* CFrame.Angles(math.rad(5) * math.sin(t * 0.9), math.sin(t * 0.5) * 0.4, math.rad(7) * math.sin(t * 0.7))

		body.CFrame = root
		for _, it in items do
			it.part.CFrame = root * it.cf
		end

		local angle = WING_REST + FLAP_AMP * burst * flapWave + math.rad(10) * (1 - burst)
		for _, w in wings do
			local s = w.side
			-- 体の横の付け根を軸に上下(Z 軸まわり)→ 外側へずらす
			w.part.CFrame = root * CFrame.new(s * WING_HINGE_X, 0, 0.08) * CFrame.Angles(0, 0, s * angle) * CFrame.new(s * WING_SIZE.X / 2, 0, 0)
		end

		tail.CFrame = root * TAIL_POS * CFrame.Angles(0, math.rad(10) * math.sin(t * 2.2), 0) * TAIL_TILT
		for _, st in streamers do
			st.beam.CurveSize0 = 0.5 * math.sin(t * 2.4 + st.phase)
			st.beam.CurveSize1 = -0.4 * math.sin(t * 2.0 + st.phase)
		end

		light.Color = pal.trail0:Lerp(pal.trail1, 0.5 + 0.5 * math.sin(t * 0.6))

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

SunsetBird.DEFAULT_PALETTE = DEFAULT_PALETTE

return SunsetBird
