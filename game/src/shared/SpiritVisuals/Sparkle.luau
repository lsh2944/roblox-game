-- 光の精霊「반짝이(sparkle)」★1 の見た目をコードだけで組み立てる試作モジュール
-- 3D モデルを使わず、Neon パーツ・パーティクル・ライトの組み合わせで表現する
-- 試作のため全パーツを Anchored にして Heartbeat で毎フレーム CFrame を更新する
-- (本番ではクライアント側で動かし、workspace:BulkMoveTo などで最適化する想定)
-- 顔は meadow 4 種(Dewdrop 等)と同じ方式: 縦長の目 + 白いハイライト + 半透明の頬の赤み、
--   まばたきは目を線につぶして表す(2026-11-12 決定)
-- 配置: ReplicatedStorage.Shared.SpiritVisuals.Sparkle(Rojo: game/src/shared/SpiritVisuals/Sparkle.luau)
-- 利用: クライアント専用の見た目(判定・報酬には使わない)。依存モジュール: なし(RunService のみ)
-- 構成: パーツ 12 / ParticleEmitter 1 / PointLight 1

local RunService = game:GetService("RunService")

local Sparkle = {}

-- 配色(外見スキン商品はこの値の差し替えで作れる)
-- shine・cheek は 2026-11-12 追加。省いた palette を渡されたら既定色を使う
local DEFAULT_PALETTE = {
	core = Color3.fromRGB(255, 244, 194), -- 本体: 暖かい白
	halo = Color3.fromRGB(255, 226, 122), -- 光輪: 金色
	wing = Color3.fromRGB(143, 233, 255), -- 羽: 水色
	eye = Color3.fromRGB(40, 32, 48), -- 目: 濃い紫
	shine = Color3.fromRGB(255, 255, 255), -- 目のハイライト
	cheek = Color3.fromRGB(255, 160, 180), -- 頬の赤み
}

local CORE_RADII = Vector3.new(0.5, 0.5, 0.5)
local BLINK_PERIOD = 3.2
local BLINK_TIME = 0.12
local BLINK_SCALE = Vector3.new(1, 0.15, 1) -- まばたき中は目を細い線にする

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

-- 楕円体(SpecialMesh Sphere)。メッシュの Scale でまばたきを表す
local function makeEllipsoid(name, size, color, material, transparency, parent)
	local p = makePart(name, Enum.PartType.Block, size, color, material, transparency, parent)
	local m = Instance.new("SpecialMesh")
	m.MeshType = Enum.MeshType.Sphere
	m.Parent = p
	return p, m
end

-- 楕円体(半径 radii)の前面(-Z 側)の点 (x, y) に、表面の向きへ沿わせて置く CFrame を返す
-- 返す CFrame の -Z が表面の外向き。lift だけ外へ浮かせる
local function onSurface(radii, x, y, lift)
	local k = 1 - (x / radii.X) ^ 2 - (y / radii.Y) ^ 2
	local z = -radii.Z * math.sqrt(math.max(k, 0))
	local p = Vector3.new(x, y, z)
	local n = Vector3.new(x / radii.X ^ 2, y / radii.Y ^ 2, z / radii.Z ^ 2).Unit
	return CFrame.lookAt(p + n * lift, p + n * (lift + 1))
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
	-- 追加キー(shine・cheek)が無い古い palette でも動くよう既定色で補う
	local shineColor = palette.shine or DEFAULT_PALETTE.shine
	local cheekColor = palette.cheek or DEFAULT_PALETTE.cheek
	-- 多数が同時に出ても動きがそろわないよう、開始位相とまばたき位相をずらす(見た目だけの乱数)
	local rng = Random.new()
	local timeOffset = rng:NextNumber(0, 10)
	local blinkOffset = rng:NextNumber(0, BLINK_PERIOD)

	local model = Instance.new("Model")
	model.Name = "Sparkle"

	-- 本体(光る球)と、薄い光輪
	local core = makePart("Core", Enum.PartType.Ball, Vector3.new(1, 1, 1), palette.core, Enum.Material.Neon, 0, model)
	local halo = makePart("Halo", Enum.PartType.Ball, Vector3.new(1.8, 1.8, 1.8), palette.halo, Enum.Material.Neon, 0.85, model)

	-- 顔(前方 = -Z 側): 縦長の目 + ハイライト + 頬の赤み。cf は本体中心からの相対
	local faceItems = {}
	local eyeMeshes = {}
	local shines = {}
	for _, s in ipairs({ -1, 1 }) do
		local eye, eyeMesh = makeEllipsoid(s < 0 and "EyeL" or "EyeR", Vector3.new(0.15, 0.2, 0.08), palette.eye, Enum.Material.SmoothPlastic, 0, model)
		table.insert(faceItems, { part = eye, cf = onSurface(CORE_RADII, s * 0.17, 0.06, 0) })
		table.insert(eyeMeshes, eyeMesh)
		local shine = makeEllipsoid("EyeShine", Vector3.new(0.06, 0.06, 0.03), shineColor, Enum.Material.Neon, 0, model)
		table.insert(faceItems, { part = shine, cf = onSurface(CORE_RADII, s * 0.17 - 0.03, 0.11, 0.04) })
		table.insert(shines, shine)
		local cheek = makeEllipsoid("Cheek", Vector3.new(0.15, 0.08, 0.04), cheekColor, Enum.Material.SmoothPlastic, 0.25, model)
		table.insert(faceItems, { part = cheek, cf = onSurface(CORE_RADII, s * 0.3, -0.1, 0) })
	end

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
	local t0 = os.clock() - timeOffset
	local lastBlink = false
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

		for _, it in ipairs(faceItems) do
			it.part.CFrame = root * it.cf
		end
		-- 約3秒ごとに 0.12 秒だけ目を閉じる(目を線につぶし、ハイライトを消す)
		local blink = ((t + blinkOffset) % BLINK_PERIOD) < BLINK_TIME
		if blink ~= lastBlink then
			lastBlink = blink
			for _, m in ipairs(eyeMeshes) do
				m.Scale = blink and BLINK_SCALE or Vector3.one
			end
			for _, sh in ipairs(shines) do
				sh.Transparency = blink and 1 or 0
			end
		end

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
