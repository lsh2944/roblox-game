--!strict
-- Hud: 最小 HUD（左上 = 財布 Dew・Bloom・Wick・Meadow Materials、右上 = 日次の状態と UTC 0 時までの残り、
--   その下 = 移動ボタン "Meadow"・"Home"（2026-11-24 決定: Travel Remote）と失敗の短い案内、
--   下中央 = 採集の状態チップ「Gathering Dew +N/h」（S6）、上 = トースト 3 秒（S6 最小実装、Notify・RF の失敗））
-- 配置: StarterPlayer.StarterPlayerScripts.Client.Controllers.Hud（ModuleScript。Rojo: game/src/client/Controllers/Hud.luau）
-- 依存: new の引数で受け取る Controllers.State、ReplicatedStorage.Shared の Text・HudFormat、LocalPlayer（PlayerGui）、
--   opts.travelDests（Shared.Net.TravelDest）と opts.onTravel（ボタンを押したときの要求。Main が Travel RF を呼ぶ）
--
-- 配置の規則（docs/world_hud_design_20261112.md 3 節）:
-- - ScreenInsets = CoreUISafeInsets（ノッチ・Roblox の上部メニューと重ならない）。左下（移動スティック）・右下（ジャンプ）・
--   上中央（Roblox メニュー）には置かない。左の縦メニュー・遭遇カード・パネルは S7〜S9
-- - 文言は Text のキー（英語）、数は HudFormat（切り捨ての縮約表記）。値はサーバーのスナップショットだけから作る（表示専用）
-- - 0.2 秒ごとに書き換える（財布の補間・残り時間のカウントダウン・採集チップ）
-- - 移動ボタンは右上の日次の列の下（日次の 2 段目が出たり消えたりしても動かないよう、別の列で位置を固定）。右下（ジャンプ）とは離す。
--   ボタンは行き先の名前を onTravel に渡すだけ（座標・可否はサーバーが決める）。案内は TRAVEL_MESSAGE_SECONDS 秒で消える。
--   上中央のトースト・下中央の採集チップとは別の場所（右端の列）なので重ならない
-- - 採集チップの率は「表示整数/時」（2026-11-24 S6: 開始時の採集率は 160〜212/時 ≒ 0.04〜0.06/秒で、/s では小数 2 桁でも
--   倍率の差が見えにくい。完了基準「160/시 × 배율」と同じ単位で Studio 照合できる。設計文書 3 節の "+N/s" から変更）。
--   遭遇中に隠すのは S7
-- - トーストは画面上部（Roblox のトップバーより下）に 1 件だけ 3 秒出す。新しいものが来たら置き換える

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
-- 移動ボタン（タッチしやすい高さ 44）。列の上端 = 日次の列の 2 段分（32 × 2 + 間 6）+ 余白
local TRAVEL_TOP = 8 + PILL_HEIGHT * 2 + 6 + 14
local TRAVEL_BUTTON_SIZE = Vector2.new(116, 44)
local TRAVEL_MESSAGE_SECONDS = 3
local TOAST_SECONDS = 3 -- 設計文書 3 節「화면 위쪽에서 3초」
local TOAST_TOP = 64 -- 上端からの位置（Roblox のトップバーと重ならない高さ。Studio で確認して調整）
local CHIP_BOTTOM = 24 -- 下端からの位置（左下の移動スティック・右下のジャンプの間）

export type HudOpts = {
	travelDests: { Meadow: string, Home: string }?, -- Shared.Net.TravelDest
	onTravel: ((dest: string) -> ())?,
}

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
		messagePill: Frame?,
		messageLabel: TextLabel?,
		messageToken: number,
		gatherChip: Frame,
		gatherText: TextLabel,
		toastFrame: Frame,
		toastText: TextLabel,
		toastSeq: number,
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

-- 移動ボタン 1 個（角丸・枠線つき TextButton）
local function travelButton(parent: Instance, order: number, text: string, onClick: () -> ()): TextButton
	local b = Instance.new("TextButton")
	b.Name = "Travel"
	b.LayoutOrder = order
	b.Size = UDim2.fromOffset(TRAVEL_BUTTON_SIZE.X, TRAVEL_BUTTON_SIZE.Y)
	b.BackgroundColor3 = Color3.fromRGB(246, 241, 255)
	b.BackgroundTransparency = 0.05
	b.AutoButtonColor = true
	b.Font = Enum.Font.FredokaOne
	b.TextSize = TEXT_SIZE
	b.TextColor3 = INK
	b.Text = text
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = b
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(196, 172, 255)
	stroke.Thickness = 2
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = b
	b.Activated:Connect(onClick)
	b.Parent = parent
	return b
end

function Hud.new(playerGui: Instance, state: any, Text: any, HudFormat: any, opts: HudOpts?): Hud
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

	-- 移動ボタン（opts.onTravel が無ければ作らない）
	local messagePill: Frame? = nil
	local messageLabel: TextLabel? = nil
	local dests = if opts ~= nil then opts.travelDests else nil
	local onTravel = if opts ~= nil then opts.onTravel else nil
	if dests ~= nil and onTravel ~= nil then
		local meadow, home, request = dests.Meadow, dests.Home, onTravel
		local travelCol = column(gui, "Travel", true)
		travelCol.Position = UDim2.new(1, -12, 0, TRAVEL_TOP)
		travelButton(travelCol, 1, Text.get("Hud.TravelMeadow"), function()
			request(meadow)
		end)
		travelButton(travelCol, 2, Text.get("Hud.TravelHome"), function()
			request(home)
		end)
		local mp, ml = pill(travelCol, 3, nil)
		mp.Visible = false
		messagePill, messageLabel = mp, ml
	end

	-- 下中央: 採集の状態チップ（採集中だけ表示）
	local chipHolder = Instance.new("Frame")
	chipHolder.Name = "GatherChip"
	chipHolder.BackgroundTransparency = 1
	chipHolder.AutomaticSize = Enum.AutomaticSize.XY
	chipHolder.Size = UDim2.fromOffset(0, 0)
	chipHolder.AnchorPoint = Vector2.new(0.5, 1)
	chipHolder.Position = UDim2.new(0.5, 0, 1, -CHIP_BOTTOM)
	chipHolder.Visible = false
	chipHolder.Parent = gui
	local _, chipText = pill(chipHolder, 1, nil)

	-- 上: トースト（1 件、3 秒）
	local toastHolder = Instance.new("Frame")
	toastHolder.Name = "Toast"
	toastHolder.BackgroundTransparency = 1
	toastHolder.AutomaticSize = Enum.AutomaticSize.XY
	toastHolder.Size = UDim2.fromOffset(0, 0)
	toastHolder.AnchorPoint = Vector2.new(0.5, 0)
	toastHolder.Position = UDim2.new(0.5, 0, 0, TOAST_TOP)
	toastHolder.Visible = false
	toastHolder.Parent = gui
	local _, toastText = pill(toastHolder, 1, nil)

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
		messagePill = messagePill,
		messageLabel = messageLabel,
		messageToken = 0,
		gatherChip = chipHolder,
		gatherText = chipText,
		toastFrame = toastHolder,
		toastText = toastText,
		toastSeq = 0,
		running = false,
	}, Hud)
	return self
end

-- 資源の表示名（財布と同じ文言キー。無い資源は ID のまま）
function Hud.resourceName(self: Hud, res: string): string
	return self.walletNames[res] or res
end

-- トーストを 3 秒出す（新しいものが来たら置き換え、古い方の消去予約は無効になる）
function Hud.toast(self: Hud, text: string)
	self.toastSeq += 1
	local mySeq = self.toastSeq
	self.toastText.Text = text
	self.toastFrame.Visible = true
	task.delay(TOAST_SECONDS, function()
		if self.toastSeq == mySeq then
			self.toastFrame.Visible = false
		end
	end)
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
	local g = snap.gather
	if type(g) == "table" and type(g.rate) == "number" and type(g.resource) == "string" then
		self.gatherText.Text = self.Text.format("Hud.Gathering", {
			resource = self:resourceName(g.resource),
			rate = HF.abbreviate(HF.units(g.rate)),
		})
		self.gatherChip.Visible = true
	else
		self.gatherChip.Visible = false
	end
end

-- 移動ボタンの下に短い案内を出す（TRAVEL_MESSAGE_SECONDS 秒で消える。続けて出したら新しい方の時間で消える）
function Hud.showMessage(self: Hud, text: string)
	local p, l = self.messagePill, self.messageLabel
	if p == nil or l == nil then
		return
	end
	self.messageToken += 1
	local token = self.messageToken
	l.Text = text
	p.Visible = true
	task.delay(TRAVEL_MESSAGE_SECONDS, function()
		if self.messageToken == token then
			p.Visible = false
		end
	end)
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
