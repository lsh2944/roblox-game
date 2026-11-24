--!strict
-- Gather（クライアント）: 採集ノードの ProximityPrompt（画面ボタン）と、GatherStart / GatherStop の送信・失敗のトースト
-- 配置: StarterPlayer.StarterPlayerScripts.Client.Controllers.Gather（ModuleScript。Rojo: game/src/client/Controllers/Gather.luau）
-- 依存（new の deps で注入）: Controllers.State・Controllers.Hud インスタンス、ReplicatedStorage.Shared の Text・HudFormat、
--   ReplicatedStorage.Remotes の GatherStart（RF）・GatherStop（RE）、ノードを探す根（Main は Workspace）
--
-- 規則（docs/world_hud_design_20261112.md W3、2026-11-24 S6 承認範囲）:
-- - Prompt はクライアントが作る画面ボタンだけ。押したら既存の Remote を呼ぶ（サーバーの入口は Net/Remoting だけ）
-- - ノード = 属性 NodeId（文字列）を持つ BasePart（サーバーの MeadowBuilder が作る。Workspace の外から複製されてくるので
--   DescendantAdded でも拾う）。届く距離 MaxActivationDistance は属性 GatherRadius（クライアントはサーバーの Config を読めない）
-- - 表示: 採集中のノードは "Stop"、他は "Gather"（State.gatherNode = サーバーのスナップショットが正）
-- - 要求中は次の押下を送らない（同じ RF の重複送信を減らす表示側の都合。サーバーのレート・検証はそのまま）
-- - 失敗コードは HudFormat.errorTextKey → Text でトースト

local Gather = {}
Gather.__index = Gather

type Deps = {
	state: any,
	hud: any,
	Text: any,
	HudFormat: any,
	gatherStart: any, -- RemoteFunction
	gatherStop: any, -- RemoteEvent
	root: Instance,
}

export type Gather = typeof(setmetatable(
	{} :: {
		deps: Deps,
		prompts: { [string]: ProximityPrompt },
		pending: boolean,
	},
	Gather
))

function Gather.new(deps: Deps): Gather
	return setmetatable({ deps = deps, prompts = {}, pending = false }, Gather)
end

-- Prompt の文言（採集中のノードだけ "Stop"）
function Gather.actionKey(gatheringNode: string?, nodeId: string): string
	return if gatheringNode == nodeId then "Prompt.Stop" else "Prompt.Gather"
end

function Gather._refreshPrompts(self: Gather)
	local cur = self.deps.state:gatherNode()
	for nodeId, prompt in self.prompts do
		prompt.ActionText = self.deps.Text.get(Gather.actionKey(cur, nodeId))
	end
end

function Gather._toast(self: Gather, code: any)
	local d = self.deps
	d.hud:toast(d.Text.get(d.HudFormat.errorTextKey(code)))
end

function Gather._onTriggered(self: Gather, nodeId: string)
	local d = self.deps
	if d.state:gatherNode() == nodeId then
		d.gatherStop:FireServer()
		return
	end
	if self.pending then
		return
	end
	self.pending = true
	local ok, res = pcall(function()
		return d.gatherStart:InvokeServer(nodeId)
	end)
	self.pending = false
	if not ok then
		warn(`[Gather] GatherStart 호출 실패: {tostring(res)}`)
		self:_toast(nil)
	elseif type(res) ~= "table" or res.ok ~= true then
		self:_toast(if type(res) == "table" then res.code else nil)
	end
	-- 成功時の表示（チップ・"Stop"）はサーバーの StateChanged で切り替わる
end

function Gather._attach(self: Gather, part: Instance)
	if not part:IsA("BasePart") then
		return
	end
	local nodeId = part:GetAttribute("NodeId")
	if type(nodeId) ~= "string" or self.prompts[nodeId] ~= nil then
		return
	end
	local d = self.deps
	-- 同じ Part が外れて戻ってきた（作った Prompt が残っている）ときは作り直さずに登録だけ戻す
	local existing = part:FindFirstChild("GatherPrompt")
	if existing ~= nil and existing:IsA("ProximityPrompt") then
		self.prompts[nodeId] = existing
		existing.ActionText = d.Text.get(Gather.actionKey(d.state:gatherNode(), nodeId))
		return
	end
	local radius = part:GetAttribute("GatherRadius")
	local res = part:GetAttribute("Resource")
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "GatherPrompt"
	prompt.ActionText = d.Text.get(Gather.actionKey(d.state:gatherNode(), nodeId))
	prompt.ObjectText = if type(res) == "string" then d.hud:resourceName(res) else ""
	prompt.HoldDuration = 0
	prompt.RequiresLineOfSight = false -- ノードは地面の円盤なので、視線の判定で隠れないようにする
	if type(radius) == "number" and radius > 0 then
		prompt.MaxActivationDistance = radius
	end
	prompt.Triggered:Connect(function()
		self:_onTriggered(nodeId)
	end)
	prompt.Parent = part
	self.prompts[nodeId] = prompt
	-- ノードが消えたら（ワールドの作り直し・ストリーミング）登録を外す
	part.AncestryChanged:Connect(function()
		if part.Parent == nil and self.prompts[nodeId] == prompt then
			self.prompts[nodeId] = nil
		end
	end)
end

function Gather.start(self: Gather)
	local root = self.deps.root
	for _, inst in root:GetDescendants() do
		self:_attach(inst)
	end
	root.DescendantAdded:Connect(function(inst)
		self:_attach(inst)
	end)
	self.deps.state:onChanged(function()
		self:_refreshPrompts()
	end)
end

return Gather
