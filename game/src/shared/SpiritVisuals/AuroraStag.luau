-- 光の精霊「오로라 사슴(aurora_stag)」★4 の見た目サンプル(未確定案, 第3版: かわいい子鹿寄り)
-- 3D モデルを使わず、楕円体と管(円柱+球)の組み合わせで作る
--   頭を大きく丸く・大きな目とハイライト・短い鼻先・頬の赤み・大きな耳・短く太い脚・背中の白い斑点・ふわふわの尾
--   角は第2版の曲線・先細り・色の流れを維持(頭の大きさに合わせて縮小)
-- 座標は足元中央が原点、前方 = -Z。試作のため全パーツ Anchored で毎フレーム CFrame を更新する

local RunService = game:GetService("RunService")

local AuroraStag = {}

local DEFAULT_PALETTE = {
	body = Color3.fromRGB(206, 242, 236), -- 体: 淡いミント
	cream = Color3.fromRGB(246, 255, 250), -- 鼻先・斑点・尾: クリーム白
	pink = Color3.fromRGB(255, 176, 196), -- 頬・耳の内側
	dark = Color3.fromRGB(44, 46, 66), -- 目・鼻・蹄
	aurora = { -- 角・帯のグラデーション(緑 → 水色 → 紫)
		Color3.fromRGB(107, 255, 184),
		Color3.fromRGB(90, 215, 255),
		Color3.fromRGB(180, 140, 255),
	},
}

local HEAD_PIVOT = CFrame.new(0, 2.4, -0.9) -- 首の付け根(頭の回転軸)
local LOOK_UP = math.rad(10) -- 少し上を見上げる姿勢

local function auroraAt(pal, u)
	u = math.clamp(u, 0, 1)
	if u < 0.5 then
		return pal.aurora[1]:Lerp(pal.aurora[2], u * 2)
	end
	return pal.aurora[2]:Lerp(pal.aurora[3], (u - 0.5) * 2)
end

local function bezier(p0, p1, p2, u)
	local v = 1 - u
	return p0 * (v * v) + p1 * (2 * v * u) + p2 * (u * u)
end

local function basePart(name, size, color, material, transparency, parent)
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

function AuroraStag.create(parent, origin, palette)
	palette = palette or DEFAULT_PALETTE

	local model = Instance.new("Model")
	model.Name = "AuroraStag"

	local items = {} -- { part, group("body"|"head"), cf(ローカル), antlerU }
	local function add(part, group, cf, antlerU)
		table.insert(items, { part = part, group = group, cf = cf, antlerU = antlerU })
		return part
	end

	local MAT = Enum.Material.SmoothPlastic

	-- 楕円体(SpecialMesh Sphere)
	local function ell(name, size, color, group, cf, material, transparency)
		local p = basePart(name, size, color, material or MAT, transparency or 0, model)
		local m = Instance.new("SpecialMesh")
		m.MeshType = Enum.MeshType.Sphere
		m.Parent = p
		return add(p, group, cf)
	end

	local function ball(name, p, w, color, material, group, antlerU)
		local b = basePart(name, Vector3.new(w, w, w), color, material, 0, model)
		b.Shape = Enum.PartType.Ball
		return add(b, group, CFrame.new(p), antlerU)
	end

	-- 点 a→b の円柱 + 終端の球(管)
	local function tube(name, a, b, w, color, material, group, antlerU)
		local d = b - a
		local up = math.abs(d.Unit.Y) > 0.99 and Vector3.zAxis or Vector3.yAxis
		local cyl = basePart(name, Vector3.new(d.Magnitude, w, w), color, material, 0, model)
		cyl.Shape = Enum.PartType.Cylinder
		add(cyl, group, CFrame.lookAt((a + b) / 2, b, up) * CFrame.Angles(0, math.rad(90), 0), antlerU) -- 円柱の軸(X)を進行方向へ
		ball(name, b, w, color, material, group, antlerU)
	end

	-- 角用: 2次ベジェ曲線に沿って管を並べ、太さ w0→w1、色はオーロラ(u0→u1)
	local function antler(p0, p1, p2, n, w0, w1, u0, u1)
		ball("Antler", p0, w0, auroraAt(palette, u0), Enum.Material.Neon, "head", u0)
		for i = 0, n - 1 do
			local k = (i + 0.5) / n
			local u = u0 + (u1 - u0) * k
			tube("Antler", bezier(p0, p1, p2, i / n), bezier(p0, p1, p2, (i + 1) / n), w0 + (w1 - w0) * k, auroraAt(palette, u), Enum.Material.Neon, "head", u)
		end
	end

	-- 胴体: 丸くて短い(胸 + 胴)
	local body = ell("Body", Vector3.new(1.3, 1.2, 1.8), palette.body, "body", CFrame.new(0, 1.7, 0.15))
	ell("Chest", Vector3.new(1.1, 1.15, 1.0), palette.body, "body", CFrame.new(0, 1.85, -0.55))

	-- 背中の白い斑点(子鹿の模様)
	for _, sp in ipairs({ { -0.3, 2.25, -0.1 }, { 0.3, 2.25, -0.1 }, { 0, 2.3, 0.35 }, { -0.35, 2.2, 0.6 }, { 0.35, 2.2, 0.6 }, { 0.15, 2.3, -0.4 } }) do
		ell("Spot", Vector3.new(0.2, 0.06, 0.2), palette.cream, "body", CFrame.new(sp[1], sp[2], sp[3]))
	end

	-- ふわふわの尾(上向き)
	ell("Tail", Vector3.new(0.32, 0.4, 0.3), palette.cream, "body", CFrame.new(0, 2.0, 1.05) * CFrame.Angles(math.rad(-40), 0, 0))

	-- 脚: 太さ一定のカプセル(段差なし)+ 後脚の太もも + 蹄
	for _, s in ipairs({ -1, 1 }) do
		tube("Leg", Vector3.new(s * 0.35, 1.4, -0.55), Vector3.new(s * 0.35, 0.22, -0.55), 0.28, palette.body, MAT, "body")
		tube("Leg", Vector3.new(s * 0.38, 1.5, 0.72), Vector3.new(s * 0.38, 0.22, 0.75), 0.28, palette.body, MAT, "body")
		ell("Thigh", Vector3.new(0.45, 0.75, 0.7), palette.body, "body", CFrame.new(s * 0.38, 1.45, 0.7))
		ell("Hoof", Vector3.new(0.3, 0.16, 0.34), palette.dark, "body", CFrame.new(s * 0.35, 0.1, -0.55))
		ell("Hoof", Vector3.new(0.3, 0.16, 0.34), palette.dark, "body", CFrame.new(s * 0.38, 0.1, 0.75))
	end

	-- 首: 短く太い
	tube("Neck", Vector3.new(0, 2.0, -0.75), Vector3.new(0, 2.55, -0.95), 0.45, palette.body, MAT, "body")

	-- 頭: 大きく丸い頭 + 短い鼻先 + 小さな鼻
	ell("Head", Vector3.new(1.1, 1.0, 1.0), palette.body, "head", CFrame.new(0, 2.95, -1.15))
	ell("Muzzle", Vector3.new(0.5, 0.4, 0.45), palette.cream, "head", CFrame.new(0, 2.75, -1.6))
	ell("Nose", Vector3.new(0.14, 0.1, 0.08), palette.dark, "head", CFrame.new(0, 2.82, -1.83))

	for _, s in ipairs({ -1, 1 }) do
		-- 大きな目 + ハイライト
		ell("Eye", Vector3.new(0.26, 0.3, 0.12), palette.dark, "head", CFrame.new(s * 0.28, 3.05, -1.58) * CFrame.Angles(0, s * math.rad(-20), 0))
		ell("EyeShine", Vector3.new(0.08, 0.08, 0.04), Color3.new(1, 1, 1), "head", CFrame.new(s * 0.24, 3.12, -1.65), Enum.Material.Neon)
		-- 頬の赤み
		ell("Cheek", Vector3.new(0.2, 0.12, 0.06), palette.pink, "head", CFrame.new(s * 0.4, 2.85, -1.5) * CFrame.Angles(0, s * math.rad(-30), 0), MAT, 0.25)
		-- 大きな耳(外側へ寝かせる)+ 内側のピンク
		local earCf = CFrame.new(s * 0.6, 3.25, -1.0) * CFrame.Angles(0, 0, s * math.rad(-60))
		ell("Ear", Vector3.new(0.22, 0.65, 0.4), palette.body, "head", earCf)
		ell("EarInner", Vector3.new(0.12, 0.45, 0.25), palette.pink, "head", earCf * CFrame.new(0, 0, -0.08))
	end

	-- 角(第2版の形を頭に合わせて縮小)と帯の端点
	local ribbonEnds = {}
	for _, s in ipairs({ -1, 1 }) do
		local p0, p1, p2 = Vector3.new(s * 0.25, 3.4, -1.15), Vector3.new(s * 0.75, 4.0, -1.1), Vector3.new(s * 0.7, 4.9, -0.5)
		antler(p0, p1, p2, 8, 0.14, 0.06, 0, 1)
		local b1 = bezier(p0, p1, p2, 0.35)
		antler(b1, b1 + Vector3.new(0, 0.4, -0.4), b1 + Vector3.new(s * -0.08, 0.64, -0.6), 3, 0.09, 0.045, 0.35, 0.6)
		local b2 = bezier(p0, p1, p2, 0.65)
		antler(b2, b2 + Vector3.new(s * 0.32, 0.24, -0.16), b2 + Vector3.new(s * 0.56, 0.48, -0.08), 3, 0.08, 0.04, 0.65, 0.9)

		local a = add(basePart("RibbonStart", Vector3.new(0.1, 0.1, 0.1), palette.body, MAT, 1, model), "head", CFrame.new(p2))
		local b = add(basePart("RibbonEnd", Vector3.new(0.1, 0.1, 0.1), palette.body, MAT, 1, model), "body", CFrame.new(s * 1.2, 3.6, 2.8))
		table.insert(ribbonEnds, { a = a, b = b, phase = s > 0 and 0 or 1.7, w0 = 0.6 })
	end
	local maneA = add(basePart("RibbonStart", Vector3.new(0.1, 0.1, 0.1), palette.body, MAT, 1, model), "body", CFrame.new(0, 2.6, -0.8))
	local maneB = add(basePart("RibbonEnd", Vector3.new(0.1, 0.1, 0.1), palette.body, MAT, 1, model), "body", CFrame.new(0, 2.4, 2.6))
	table.insert(ribbonEnds, { a = maneA, b = maneB, phase = 0.9, w0 = 0.45 })

	-- オーロラの帯(Beam)。CurveSize を時間で揺らして波打たせる
	local beams = {}
	for _, r in ipairs(ribbonEnds) do
		local a0 = Instance.new("Attachment")
		a0.Parent = r.a
		local a1 = Instance.new("Attachment")
		a1.Parent = r.b
		local beam = Instance.new("Beam")
		beam.Attachment0 = a0
		beam.Attachment1 = a1
		beam.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, palette.aurora[1]),
			ColorSequenceKeypoint.new(0.5, palette.aurora[2]),
			ColorSequenceKeypoint.new(1, palette.aurora[3]),
		})
		beam.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.25),
			NumberSequenceKeypoint.new(1, 1),
		})
		beam.LightEmission = 1
		beam.LightInfluence = 0
		beam.Width0 = r.w0
		beam.Width1 = 0.1
		beam.FaceCamera = true
		beam.Segments = 24
		beam.Parent = r.a
		table.insert(beams, { beam = beam, phase = r.phase })
	end

	-- 体から立ちのぼる光の粒
	local pe = Instance.new("ParticleEmitter")
	pe.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	pe.LightEmission = 1
	pe.LightInfluence = 0
	pe.Color = ColorSequence.new(palette.aurora[1], palette.aurora[3])
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 0) })
	pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1) })
	pe.Lifetime = NumberRange.new(1.5, 2.5)
	pe.Rate = 8
	pe.Speed = NumberRange.new(0.2, 0.5)
	pe.SpreadAngle = Vector2.new(180, 180)
	pe.Acceleration = Vector3.new(0, 0.3, 0)
	pe.Parent = body

	local light = Instance.new("PointLight")
	light.Range = 16
	light.Brightness = 1.5
	light.Shadows = false
	light.Parent = body

	model.PrimaryPart = body
	model.Parent = parent

	-- アニメーション: わずかに浮遊・見上げたままゆっくり首をかしげる・角の色が流れる・帯が波打つ
	local t0 = os.clock()
	local conn
	conn = RunService.Heartbeat:Connect(function()
		if not model.Parent then
			conn:Disconnect()
			return
		end
		local t = os.clock() - t0
		local root = origin * CFrame.new(0, 0.12 * math.sin(t * 1.2), 0)
		local nod = LOOK_UP + math.rad(4) * math.sin(t * 0.8)
		local tilt = math.rad(6) * math.sin(t * 0.5)
		local headRoot = root * HEAD_PIVOT * CFrame.Angles(nod, 0, tilt) * HEAD_PIVOT:Inverse()

		local flow = (t * 0.15) % 1
		for _, it in ipairs(items) do
			it.part.CFrame = (it.group == "head" and headRoot or root) * it.cf
			if it.antlerU then
				-- 三角波で 緑→紫→緑 と循環させる
				local u = (it.antlerU + flow) % 1
				it.part.Color = auroraAt(palette, u < 0.5 and u * 2 or (1 - u) * 2)
			end
		end
		for _, b in ipairs(beams) do
			b.beam.CurveSize0 = 1.2 * math.sin(t * 1.3 + b.phase)
			b.beam.CurveSize1 = -1.0 * math.sin(t * 1.1 + b.phase)
		end
		light.Color = auroraAt(palette, 0.5 + 0.5 * math.sin(t * 0.6))
	end)

	local function destroy()
		conn:Disconnect()
		model:Destroy()
	end
	return model, destroy
end

AuroraStag.DEFAULT_PALETTE = DEFAULT_PALETTE

return AuroraStag
