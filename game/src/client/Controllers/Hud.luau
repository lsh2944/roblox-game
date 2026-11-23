--!strict
-- Hud: 最小 HUD（左上 = 財布 Dew・Bloom・Wick・Meadow Materials、右上 = 日次の状態と UTC 0 時までの残り）
-- 配置: StarterPlayer.StarterPlayerScripts.Client.Controllers.Hud（ModuleScript。Rojo: game/src/client/Controllers/Hud.luau）
-- 依存: new の引数で受け取る Controllers.State、ReplicatedStorage.Shared の Text・HudFormat、LocalPlayer（PlayerGui）
--
-- 配置の規則（docs/world_hud_design_20261112.md 3 節）:
-- - ScreenInsets = CoreUISafeInsets（ノッチ・Roblox の上部メニューと重ならない）。左下（移動スティック）・右下（ジャンプ）・
--   上中央（Roblox メニュー）には置かない。左の縦メニュー・下中央の状態チップ・遭遇カード・パネルは S6〜S9
-- - 文言は Text のキー（英語）、数は HudFormat（切り捨ての縮約表記）。値はサーバーのスナップショットだけから作る（表示専用）
-- - 0.2 秒ごとに書き換える（財布の補間・残り時間のカウントダウン）

local Hud = {}
Hud.__index = Hud

-- 財布の並び（資源 ID・文言キー・色。色は docs/previews/meadow_layout_hud_mock.html の --dew 等）
local WALLET = {
	{ res = "dew", key = "Hud.Dew", rgb = { 143, 216, 255 } },
	{ res = "bloom", key = "Hud.Bloom", rgb = { 255, 179, 209 } },
	{ res = "wick", key = "Hud.Wick", rgb = { 255, 215, 122 } },
	{ res = "hunt_meadow", key = "Hud.Materials", rgb = { 183, 227, 161 } },
}

local INK = Color3.fromRGB(43, 37, 64)
local PILL_HEIGHT = 32
local TEXT_SIZE = 18

export type Hud = typeof(setmetatable(
	{} :: {
		gui: ScreenGui,
		state: any,
		Text: any,
		HudFormat: any,
		walletLabels: { [string]: TextLabel },
		walletNames: { [string]: string },
		dailyStatus: TextLabel,
		dailyReset: TextLabel,
		dailyResetPill: Frame,
		running: boolean,
	},
	Hud
))

local function pill(parent: Instance, order: number, dotColor: Color3?): (Frame, TextLabel)
	local f = Instance.new("Frame")
	f.Name = "Pill"
	f.LayoutOrder = order
	f.BackgroundColor3 = Color3.new(1, 1, 1)
	f.BackgroundTransparency = 0.08
	f.AutomaticSize = Enum.AutomaticSize.X
	f.Size = UDim2.fromOffset(0, PILL_HEIGHT)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = f
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(217, 211, 234)
	stroke.Thickness = 1
	stroke.Parent = f
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 12)
	pad.Parent = f
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.Padding = UDim.new(0, 6)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = f
	if dotColor ~= nil then
		local dot = Instance.new("Frame")
		dot.Name = "Dot"
		dot.LayoutOrder = 1
		dot.Size = UDim2.fromOffset(14, 14)
		dot.BackgroundColor3 = dotColor
		local dc = Instance.new("UICorner")
		dc.CornerRadius = UDim.new(1, 0)
		dc.Parent = dot
		dot.Parent = f
	end
	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.LayoutOrder = 2
	label.BackgroundTransparency = 1
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Size = UDim2.fromOffset(0, PILL_HEIGHT)
	label.Font = Enum.Font.FredokaOne
	label.TextSize = TEXT_SIZE
	label.TextColor3 = INK
	label.Text = ""
	label.Parent = f
	f.Parent = parent
	return f, label
end

local function column(parent: Instance, name: string, rightSide: boolean): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.BackgroundTransparency = 1
	f.AutomaticSize = Enum.AutomaticSize.XY
	f.Size = UDim2.fromOffset(0, 0)
	f.AnchorPoint = Vector2.new(if rightSide then 1 else 0, 0)
	f.Position = if rightSide then UDim2.new(1, -12, 0, 8) else UDim2.new(0, 12, 0, 8)
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical
	list.HorizontalAlignment = if rightSide then Enum.HorizontalAlignment.Right else Enum.HorizontalAlignment.Left
	list.Padding = UDim.new(0, 6)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = f
	f.Parent = parent
	return f
end

function Hud.new(playerGui: Instance, state: any, Text: any, HudFormat: any): Hud
	local gui = Instance.new("ScreenGui")
	gui.Name = "GlimmerHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local walletCol = column(gui, "Wallet", false)
	local labels: { [string]: TextLabel } = {}
	local names: { [string]: string } = {}
	for i, w in WALLET do
		local _, label = pill(walletCol, i, Color3.fromRGB(w.rgb[1], w.rgb[2], w.rgb[3]))
		labels[w.res] = label
		names[w.res] = Text.get(w.key)
		label.Text = `{names[w.res]} -`
	end

	local dailyCol = column(gui, "Daily", true)
	local _, status = pill(dailyCol, 1, nil)
	local resetPill, reset = pill(dailyCol, 2, nil)
	status.Text = Text.get("Hud.Loading")
	resetPill.Visible = false

	gui.Parent = playerGui
	local self = setmetatable({
		gui = gui,
		state = state,
		Text = Text,
		HudFormat = HudFormat,
		walletLabels = labels,
		walletNames = names,
		dailyStatus = status,
		dailyReset = reset,
		dailyResetPill = resetPill,
		running = false,
	}, Hud)
	return self
end

-- 表示の書き換え（スナップショットが無いあいだは "-" と Loading のまま）
function Hud.refresh(self: Hud)
	local snap = self.state:get()
	if snap == nil then
		return
	end
	local HF = self.HudFormat
	for res, label in self.walletLabels do
		local n = self.state:units(res)
		label.Text = `{self.walletNames[res]} {if n ~= nil then HF.abbreviate(n) else "-"}`
	end
	local daily = snap.daily
	if type(daily) == "table" then
		self.dailyStatus.Text = self.Text.get(if daily.claimed then "Hud.DailyClaimed" else "Hud.DailyReady")
		local now = self.state:serverNow()
		if daily.claimed and now ~= nil then
			self.dailyReset.Text = self.Text.format("Hud.DailyReset", { time = HF.countdown(daily.nextResetAt - now) })
			self.dailyResetPill.Visible = true
		else
			self.dailyResetPill.Visible = false
		end
	end
end

-- 書き換えループ（0.2 秒ごと、HUD が消えたら止まる）
function Hud.start(self: Hud)
	if self.running then
		return
	end
	self.running = true
	task.spawn(function()
		while self.gui.Parent ~= nil do
			local ok, err = pcall(self.refresh, self)
			if not ok then
				warn(`[Hud] 갱신 오류: {tostring(err)}`)
			end
			task.wait(0.2)
		end
		self.running = false
	end)
end

return Hud
