--!strict
-- 光の精霊「오로라 사슴(aurora_stag)」★4 の見た目(第5版: v4 A+B の比率調整)
-- 2026-11-12 ユーザー決定。形・数値は docs/previews/aurora_stag_v5_preview.html と同じ
--   大きな頭(頭:その下 ≒ 1:1.4)・前後に長い豆形の胴・短い首・胸の白い毛の房
--   脚は太もも(胴に半分埋める)→ 細いすね(円柱)の 2 段 + 小さな蹄・2 本枝の角(先は光の玉)
--   小さく上向きの尾・背中の斑点 5 個・頭を少しかしげた姿勢・頭の後ろの後光
--   目は表面に沿う円弧(管 3 本)の閉じ目で固定(まばたきなし)。★4 の神秘感はオーロラの帯・後光・粒子で出す
-- 3D モデルを使わず、楕円体と管(円柱+球)・Beam・パーティクル・ライトで組む
-- 配置: ReplicatedStorage.Shared.SpiritVisuals.AuroraStag(Rojo: game/src/shared/SpiritVisuals/AuroraStag.luau)
-- 利用: クライアント専用の見た目(判定・報酬には使わない)。依存モジュール: なし(RunService のみ)
-- 構成: パーツ 61 / Beam 3 / ParticleEmitter 1 / PointLight 1 / Attachment 6(帯の端点は既存パーツに付ける)
-- 座標は足元中央が原点、前方 = -Z。寸法は SCALE = 1 の値で書き、生成時に SCALE 倍する
-- 全パーツ Anchored で Heartbeat ごとに CFrame を更新する

local RunService = game:GetService("RunService")

local AuroraStag = {}

-- 全体の倍率(位置・大きさ・Beam 幅/曲がり・粒子の大きさ/速さ・光の範囲に一律でかける)
-- 1.3 で高さ約 4 スタッド。Studio で見て決める
local SCALE = 1.3

-- 配色(外見スキン商品はこの表の差し替えで作れる)。キーは第3版から変えていない
export type Palette = {
	body: Color3, -- 体: 淡いミント
	cream: Color3, -- 鼻先・斑点・尾: クリーム白
	pink: Color3, -- 頬・耳の内側
	dark: Color3, -- 目・鼻・蹄
	aurora: { Color3 }, -- 角・帯・後光のグラデーション(緑 → 水色 → 紫)の 3 色
}

local DEFAULT_PALETTE: Palette = {
	body = Color3.fromRGB(206, 242, 236),
	cream = Color3.fromRGB(246, 255, 250),
	pink = Color3.fromRGB(255, 176, 196),
	dark = Color3.fromRGB(44, 46, 66),
	aurora = {
		Color3.fromRGB(107, 255, 184),
		Color3.fromRGB(90, 215, 255),
		Color3.fromRGB(180, 140, 255),
	},
}

-- 寸法(SCALE = 1 の値)
local BODY_SIZE = Vector3.new(1.15, 0.85, 2.0) -- 前後に長い豆形
local BODY_CENTER = Vector3.new(0, 1.15, 0.2)
local BODY_RADII = BODY_SIZE / 2
local HEAD_SIZE = Vector3.new(1.3, 1.2, 1.15)
local HEAD_CENTER = Vector3.new(0, 2.3, -0.85)
local HEAD_RADII = HEAD_SIZE / 2
local HEAD_PIVOT = Vector3.new(0, 1.55, -0.65) -- 首の付け根(頭の回転軸)
local HEAD_TILT = math.rad(7) -- 頭を少しかしげた姿勢(Z 軸まわり、揺れの中心)
-- 脚: 前脚・後脚の z と太ももの大きさ(すねは太ももの中から下へ伸ばす)
local LEGS = {
	{ z = -0.45, thigh = Vector3.new(0.3, 0.55, 0.36) },
	{ z = 0.75, thigh = Vector3.new(0.38, 0.65, 0.48) },
}
local LEG_X = 0.33
local THIGH_Y = 0.97
local SHIN_TOP_Y = 0.85 -- 太ももの中に埋める
local SHIN_BOTTOM_Y = 0.12
local SHIN_W = 0.17
local HOOF_SIZE = Vector3.new(0.24, 0.13, 0.27)
local EYE_WIDTH = 0.05 -- 閉じ目の線の太さ
local HALO_SIZE = Vector3.new(0.04, 2.1, 2.1)

type Group = "body" | "head"
type Item = { part: BasePart, group: Group, cf: CFrame, antlerU: number? } -- cf はグループ基準(SCALE 済み)
type Ribbon = { beam: Beam, phase: number }

local function auroraAt(pal: Palette, u: number): Color3
	u = math.clamp(u, 0, 1)
	if u < 0.5 then
		return pal.aurora[1]:Lerp(pal.aurora[2], u * 2)
	end
	return pal.aurora[2]:Lerp(pal.aurora[3], (u - 0.5) * 2)
end

local function bezier(p0: Vector3, p1: Vector3, p2: Vector3, u: number): Vector3
	local v = 1 - u
	return p0 * (v * v) + p1 * (2 * v * u) + p2 * (u * u)
end

-- SCALE = 1 の CFrame を SCALE 倍の位置へ(向きはそのまま)
local function scaled(cf: CFrame): CFrame
	return CFrame.new(cf.Position * SCALE) * cf.Rotation
end

-- 楕円体(半径 radii)の前面(-Z 側)の点 (x, y) と外向きの法線
local function surfacePoint(radii: Vector3, x: number, y: number): (Vector3, Vector3)
	local k = 1 - (x / radii.X) ^ 2 - (y / radii.Y) ^ 2
	local z = -radii.Z * math.sqrt(math.max(k, 0))
	local p = Vector3.new(x, y, z)
	return p, Vector3.new(x / radii.X ^ 2, y / radii.Y ^ 2, z / radii.Z ^ 2).Unit
end

-- 楕円体の前面の点 (x, y) に表面へ沿わせて置く CFrame(-Z が外向き、lift だけ外へ浮かせる)
local function onSurface(radii: Vector3, x: number, y: number, lift: number): CFrame
	local p, n = surfacePoint(radii, x, y)
	return CFrame.lookAt(p + n * lift, p + n * (lift + 1))
end

-- 当たり判定・影なしの装飾パーツを作る(size は SCALE = 1 の値)
local function basePart(name: string, size: Vector3, color: Color3, material: Enum.Material, transparency: number, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size * SCALE
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

function AuroraStag.create(parent: Instance, origin: CFrame, palette: Palette?): (Model, () -> ())
	local pal: Palette = palette or DEFAULT_PALETTE
	-- 多数が同時に出ても動きがそろわないよう、開始位相をずらす(見た目だけの乱数)
	local rng = Random.new()
	local timeOffset = rng:NextNumber(0, 10)

	local model = Instance.new("Model")
	model.Name = "AuroraStag"

	local MAT = Enum.Material.SmoothPlastic
	local NEON = Enum.Material.Neon
	local items: { Item } = {}

	-- cf・座標はすべて SCALE = 1 で渡す
	local function add(part: BasePart, group: Group, cf: CFrame, antlerU: number?): BasePart
		table.insert(items, { part = part, group = group, cf = scaled(cf), antlerU = antlerU })
		return part
	end

	-- 楕円体(SpecialMesh Sphere)
	local function ell(name: string, size: Vector3, color: Color3, group: Group, cf: CFrame, material: Enum.Material?, transparency: number?): BasePart
		local p = basePart(name, size, color, material or MAT, transparency or 0, model)
		local m = Instance.new("SpecialMesh")
		m.MeshType = Enum.MeshType.Sphere
		m.Parent = p
		return add(p, group, cf)
	end

	local function ball(name: string, pos: Vector3, w: number, color: Color3, material: Enum.Material, group: Group, antlerU: number?): BasePart
		local b = basePart(name, Vector3.new(w, w, w), color, material, 0, model)
		b.Shape = Enum.PartType.Ball
		return add(b, group, CFrame.new(pos), antlerU)
	end

	-- 点 a→b の管(円柱、endBall なら終端に球)
	local function tube(name: string, a: Vector3, b: Vector3, w: number, color: Color3, material: Enum.Material, group: Group, antlerU: number?, endBall: boolean)
		local d = b - a
		local up = if math.abs(d.Unit.Y) > 0.99 then Vector3.zAxis else Vector3.yAxis
		local cyl = basePart(name, Vector3.new(d.Magnitude, w, w), color, material, 0, model)
		cyl.Shape = Enum.PartType.Cylinder
		add(cyl, group, CFrame.lookAt((a + b) / 2, b, up) * CFrame.Angles(0, math.rad(90), 0), antlerU) -- 円柱の軸(X)を進行方向へ
		if endBall then
			ball(name, b, w, color, material, group, antlerU)
		end
	end

	local headCf = CFrame.new(HEAD_CENTER)

	-- 胴・胸の白い毛・首
	local body = ell("Body", BODY_SIZE, pal.body, "body", CFrame.new(BODY_CENTER))
	ell("Chest", Vector3.new(0.68, 0.62, 0.36), pal.cream, "body", CFrame.new(0, 1.3, -0.74) * CFrame.Angles(math.rad(20), 0, 0)) -- 平たくして胴に沿わせる
	ell("Neck", Vector3.new(0.5, 0.8, 0.5), pal.body, "body", CFrame.new(0, 1.68, -0.62) * CFrame.Angles(math.rad(-22), 0, 0)) -- 上を前へ傾ける

	-- 背中の斑点(5 個、胴の上面の高さに合わせて少し埋める)
	for _, xz in { Vector2.new(-0.24, -0.05), Vector2.new(0.24, -0.05), Vector2.new(-0.27, 0.5), Vector2.new(0.27, 0.5), Vector2.new(0, 0.85) } do
		local k = 1 - ((xz.X - BODY_CENTER.X) / BODY_RADII.X) ^ 2 - ((xz.Y - BODY_CENTER.Z) / BODY_RADII.Z) ^ 2
		local y = BODY_CENTER.Y + BODY_RADII.Y * math.sqrt(math.max(k, 0)) - 0.015
		ell("Spot", Vector3.new(0.19, 0.06, 0.19), pal.cream, "body", CFrame.new(xz.X, y, xz.Y))
	end
	-- 尾: 小さく上向き(先を後ろ上へ)
	ell("Tail", Vector3.new(0.26, 0.4, 0.24), pal.cream, "body", CFrame.new(0, 1.45, 1.12) * CFrame.Angles(math.rad(25), 0, 0))

	-- 脚: 太もも(胴に半分埋める)+ 細いすね(円柱、上端は太ももの中)+ 小さな蹄
	for _, s in { -1, 1 } do
		for _, leg in LEGS do
			local x = s * LEG_X
			ell("Thigh", leg.thigh, pal.body, "body", CFrame.new(x, THIGH_Y, leg.z))
			tube("Shin", Vector3.new(x, SHIN_TOP_Y, leg.z), Vector3.new(x, SHIN_BOTTOM_Y, leg.z), SHIN_W, pal.body, MAT, "body", nil, false)
			ell("Hoof", HOOF_SIZE, pal.dark, "body", CFrame.new(x, 0.07, leg.z))
		end
	end

	-- 頭・鼻先・鼻
	local head = ell("Head", HEAD_SIZE, pal.body, "head", headCf)
	ell("Muzzle", Vector3.new(0.52, 0.36, 0.34), pal.cream, "head", headCf * onSurface(HEAD_RADII, 0, -0.27, -0.07))
	ell("Nose", Vector3.new(0.14, 0.09, 0.07), pal.dark, "head", headCf * onSurface(HEAD_RADII, 0, -0.17, 0.06))

	for _, s in { -1, 1 } do
		-- にっこり閉じた三日月目: 表面上の円弧(∩)を管 3 本でつなぐ
		local pts: { Vector3 } = {}
		for _, deg in { 160, 113, 67, 20 } do
			local a = math.rad(deg)
			local p, n = surfacePoint(HEAD_RADII, s * 0.26 + 0.12 * math.cos(a), 0.09 * math.sin(a))
			table.insert(pts, HEAD_CENTER + p + n * 0.015)
		end
		ball("Eye", pts[1], EYE_WIDTH, pal.dark, MAT, "head")
		for i = 1, 3 do
			tube("Eye", pts[i], pts[i + 1], EYE_WIDTH, pal.dark, MAT, "head", nil, true)
		end
		-- 頬の赤み
		ell("Cheek", Vector3.new(0.2, 0.1, 0.04), pal.pink, "head", headCf * onSurface(HEAD_RADII, s * 0.42, -0.14, 0), MAT, 0.25)
		-- 耳(外へ寝かせる)+ 内側の桃色
		local earCf = headCf * CFrame.new(s * 0.62, 0.28, 0.1) * CFrame.Angles(0, 0, s * math.rad(-65))
		ell("Ear", Vector3.new(0.22, 0.55, 0.36), pal.body, "head", earCf)
		ell("EarInner", Vector3.new(0.12, 0.38, 0.22), pal.pink, "head", earCf * CFrame.new(0, 0, -0.08))
	end

	-- 角: 2 節の幹 + 先の光の玉、枝 2 本(幹の 0.45 から外前へ・0.78 から内上へ、先は玉)
	-- 根元の球は頭に埋まって見えないので置かない。色はオーロラが流れる
	local antlerTips: { BasePart } = {}
	for _, s in { -1, 1 } do
		local p0 = HEAD_CENTER + Vector3.new(s * 0.24, 0.5, 0)
		local p1 = HEAD_CENTER + Vector3.new(s * 0.44, 0.92, 0)
		local p2 = HEAD_CENTER + Vector3.new(s * 0.56, 1.18, 0.12)
		local m1 = bezier(p0, p1, p2, 0.45)
		local m2 = bezier(p0, p1, p2, 0.78)
		tube("Antler", p0, m1, 0.16, auroraAt(pal, 0.3), NEON, "head", 0.3, true)
		tube("Antler", m1, p2, 0.14, auroraAt(pal, 0.7), NEON, "head", 0.7, false)
		table.insert(antlerTips, ball("AntlerTip", p2, 0.24, auroraAt(pal, 1), NEON, "head", 1))
		local b1 = m1 + Vector3.new(s * 0.2, 0.12, -0.15)
		tube("Antler", m1, b1, 0.1, auroraAt(pal, 0.55), NEON, "head", 0.55, false)
		ball("AntlerTip", b1, 0.16, auroraAt(pal, 0.85), NEON, "head", 0.85)
		local b2 = m2 + Vector3.new(-s * 0.12, 0.22, -0.06)
		tube("Antler", m2, b2, 0.09, auroraAt(pal, 0.8), NEON, "head", 0.8, false)
		ball("AntlerTip", b2, 0.15, auroraAt(pal, 0.95), NEON, "head", 0.95)
	end

	-- 後光: 頭の後ろの薄い円盤(円柱の軸を前後に向ける)
	local halo = basePart("Halo", HALO_SIZE, pal.aurora[2], NEON, 0.86, model)
	halo.Shape = Enum.PartType.Cylinder
	add(halo, "head", headCf * CFrame.new(0, 0.3, 0.6) * CFrame.Angles(0, math.rad(90), 0))

	-- オーロラの帯(Beam)。端点は既存パーツの Attachment(角の先の玉 → 胴、頭の後ろ → 胴)
	local function attach(part: BasePart, localPos: Vector3): Attachment
		local a = Instance.new("Attachment")
		a.Position = localPos * SCALE
		a.Parent = part
		return a
	end
	-- 胴の Attachment は胴の中心からの相対位置で置く
	local ribbonDefs = {
		{ a = attach(antlerTips[1], Vector3.zero), b = attach(body, Vector3.new(-1.0, 2.5, 2.4) - BODY_CENTER), phase = 1.7, w0 = 0.45 },
		{ a = attach(antlerTips[2], Vector3.zero), b = attach(body, Vector3.new(1.0, 2.5, 2.4) - BODY_CENTER), phase = 0, w0 = 0.45 },
		{ a = attach(head, Vector3.new(0, 0.3, 0.45)), b = attach(body, Vector3.new(0, 1.5, 2.4) - BODY_CENTER), phase = 0.9, w0 = 0.35 },
	}
	local ribbons: { Ribbon } = {}
	for _, r in ribbonDefs do
		local beam = Instance.new("Beam")
		beam.Attachment0 = r.a
		beam.Attachment1 = r.b
		beam.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, pal.aurora[1]),
			ColorSequenceKeypoint.new(0.5, pal.aurora[2]),
			ColorSequenceKeypoint.new(1, pal.aurora[3]),
		})
		beam.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.25),
			NumberSequenceKeypoint.new(1, 1),
		})
		beam.LightEmission = 1
		beam.LightInfluence = 0
		beam.Width0 = r.w0 * SCALE
		beam.Width1 = 0.08 * SCALE
		beam.FaceCamera = true
		beam.Segments = 24
		beam.Parent = r.a.Parent
		table.insert(ribbons, { beam = beam, phase = r.phase })
	end

	-- 胴から立ちのぼる光の粒
	local pe = Instance.new("ParticleEmitter")
	pe.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	pe.LightEmission = 1
	pe.LightInfluence = 0
	pe.Color = ColorSequence.new(pal.aurora[1], pal.aurora[3])
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3 * SCALE), NumberSequenceKeypoint.new(1, 0) })
	pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1) })
	pe.Lifetime = NumberRange.new(1.5, 2.5)
	pe.Rate = 8
	pe.Speed = NumberRange.new(0.2 * SCALE, 0.5 * SCALE)
	pe.SpreadAngle = Vector2.new(180, 180)
	pe.Acceleration = Vector3.new(0, 0.3 * SCALE, 0)
	pe.Parent = body

	local light = Instance.new("PointLight")
	light.Range = 16 * SCALE
	light.Brightness = 1.5
	light.Shadows = false
	light.Parent = body

	model.PrimaryPart = body
	model.Parent = parent

	-- アニメーション: わずかに浮遊・ゆっくりうなずき・かしげた首がゆれる・角の色が流れる・帯が波打つ・後光の明滅
	local pivot = CFrame.new(HEAD_PIVOT * SCALE)
	local pivotInv = pivot:Inverse()
	local t0 = os.clock() - timeOffset
	local conn: RBXScriptConnection? = nil
	conn = RunService.Heartbeat:Connect(function()
		if not model.Parent then
			if conn then
				conn:Disconnect()
			end
			return
		end
		local t = os.clock() - t0
		local root = origin * CFrame.new(0, 0.1 * SCALE * math.sin(t * 1.2), 0)
		local headRoot = root * pivot * CFrame.Angles(math.rad(3) * math.sin(t * 0.8), 0, HEAD_TILT + math.rad(4) * math.sin(t * 0.5)) * pivotInv

		local flow = (t * 0.15) % 1
		for _, it in items do
			it.part.CFrame = (if it.group == "head" then headRoot else root) * it.cf
			local u0 = it.antlerU
			if u0 then
				-- 三角波で 緑→紫→緑 と循環させる
				local u = (u0 + flow) % 1
				it.part.Color = auroraAt(pal, if u < 0.5 then u * 2 else (1 - u) * 2)
			end
		end
		for _, r in ribbons do
			r.beam.CurveSize0 = 1.0 * SCALE * math.sin(t * 1.3 + r.phase)
			r.beam.CurveSize1 = -0.8 * SCALE * math.sin(t * 1.1 + r.phase)
		end
		halo.Transparency = 0.86 + 0.03 * math.sin(t * 1.5)
		light.Color = auroraAt(pal, 0.5 + 0.5 * math.sin(t * 0.6))
	end)

	local function destroy()
		if conn then
			conn:Disconnect()
		end
		model:Destroy()
	end
	return model, destroy
end

AuroraStag.DEFAULT_PALETTE = DEFAULT_PALETTE

return AuroraStag
