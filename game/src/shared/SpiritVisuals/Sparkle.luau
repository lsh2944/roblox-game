-- 光の精霊「반짝이(sparkle)」★1 の見た目をコードだけで組み立てる試作モジュール
-- 3D モデルを使わず、Neon パーツ・パーティクル・ライトの組み合わせで表現する
-- 試作のため全パーツを Anchored にして Heartbeat で毎フレーム CFrame を更新する
-- (本番ではクライアント側で動かし、workspace:BulkMoveTo などで最適化する想定)

local RunService = game:GetService("RunService")

local Sparkle = {}

-- 配色(外見スキン商品はこの値の差し替えで作れる)
local DEFAULT_PALETTE = {
	core = Color3.fromRGB(255, 244, 194), -- 本体: 暖かい白
	halo = Color3.fromRGB(255, 226, 122), -- 光輪: 金色
	wing = Color3.fromRGB(143, 233, 255), -- 羽: 水色
	eye = Color3.fromRGB(40, 32, 48), -- 目: 濃い紫
}

-- 当たり判定・影なしの装飾パーツを作る
local function makePart(name, shape, size, color, material, transparency, parent)
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = shape
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

-- きらきらの粒子(既定のスパークルテクスチャを使用)
local function addSparkles(parent, palette)
	local pe = Instance.new("ParticleEmitter")
	pe.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	pe.LightEmission = 1
	pe.LightInfluence = 0
	pe.Color = ColorSequence.new(palette.halo, palette.wing)
	pe.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.25),
		NumberSequenceKeypoint.new(1, 0),
	})
	pe.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	pe.Lifetime = NumberRange.new(0.6, 1.2)
	pe.Rate = 14
	pe.Speed = NumberRange.new(0.4, 1.0)
	pe.SpreadAngle = Vector2.new(180, 180)
	pe.Acceleration = Vector3.new(0, -0.6, 0) -- 粉がふわっと落ちる
	pe.Parent = parent
	return pe
end

-- 精霊を生成する。戻り値: model, destroy関数
-- palette を渡すと配色を差し替えられる(スキン用)
function Sparkle.create(parent, origin, palette)
	palette = palette or DEFAULT_PALETTE

	local model = Instance.new("Model")
	model.Name = "Sparkle"

	-- 本体(光る球)と、薄い光輪
	local core = makePart("Core", Enum.PartType.Ball, Vector3.new(1, 1, 1), palette.core, Enum.Material.Neon, 0, model)
	local halo = makePart("Halo", Enum.PartType.Ball, Vector3.new(1.8, 1.8, 1.8), palette.halo, Enum.Material.Neon, 0.85, model)

	-- 目(前方 = -Z 側)
	local eyeL = makePart("EyeL", Enum.PartType.Ball, Vector3.new(0.13, 0.13, 0.13), palette.eye, Enum.Material.SmoothPlastic, 0, model)
	local eyeR = makePart("EyeR", Enum.PartType.Ball, Vector3.new(0.13, 0.13, 0.13), palette.eye, Enum.Material.SmoothPlastic, 0, model)

	-- 羽: 薄い円柱 = 円盤。上の大きい羽と下の小さい羽を左右に1枚ずつ
	local wings = {}
	local wingDefs = {
		{ diameter = 0.75, tilt = math.rad(15), y = 0.1 },
		{ diameter = 0.45, tilt = math.rad(-30), y = -0.12 },
	}
	for _, def in ipairs(wingDefs) do
		for _, side in ipairs({ -1, 1 }) do
			local w = makePart(
				"Wing",
				Enum.PartType.Cylinder,
				Vector3.new(0.04, def.diameter, def.diameter),
				palette.wing,
				Enum.Material.Neon,
				0.4,
				model
			)
			table.insert(wings, { part = w, side = side, def = def })
		end
	end

	-- 周囲を照らす光
	local light = Instance.new("PointLight")
	light.Color = palette.halo
	light.Range = 12
	light.Brightness = 2
	light.Shadows = false
	light.Parent = core

	addSparkles(core, palette)

	model.PrimaryPart = core
	model.Parent = parent

	-- アニメーション: ふわふわ上下・ゆっくり左右を向く・羽ばたき・明滅・まばたき
	local t0 = os.clock()
	local conn
	conn = RunService.Heartbeat:Connect(function()
		if not model.Parent then
			conn:Disconnect()
			return
		end
		local t = os.clock() - t0
		local bob = math.sin(t * 2) * 0.25
		local root = origin * CFrame.new(0, bob, 0) * CFrame.Angles(0, math.sin(t * 0.5) * 0.6, 0)

		core.CFrame = root
		halo.CFrame = root
		halo.Transparency = 0.82 + 0.06 * math.sin(t * 3)
		light.Brightness = 1.8 + 0.6 * math.sin(t * 3)

		eyeL.CFrame = root * CFrame.new(-0.17, 0.08, -0.45)
		eyeR.CFrame = root * CFrame.new(0.17, 0.08, -0.45)
		-- 約3秒ごとに 0.12 秒だけ目を閉じる
		local blink = (t % 3.2) < 0.12
		eyeL.Transparency = blink and 1 or 0
		eyeR.Transparency = blink and 1 or 0

		local flap = math.rad(25) * math.sin(t * 14)
		for _, w in ipairs(wings) do
			local s = w.side
			-- 背中(+Z)の付け根を軸に羽ばたき → 上下に傾け → 外側へずらし → 円盤面を前後方向に向ける
			w.part.CFrame = root
				* CFrame.new(0, w.def.y, 0.3)
				* CFrame.Angles(0, s * flap, 0)
				* CFrame.Angles(0, 0, s * w.def.tilt)
				* CFrame.new(s * (w.def.diameter / 2 + 0.05), 0, 0)
				* CFrame.Angles(0, math.rad(90), 0)
		end
	end)

	local function destroy()
		conn:Disconnect()
		model:Destroy()
	end
	return model, destroy
end

Sparkle.DEFAULT_PALETTE = DEFAULT_PALETTE

return Sparkle
