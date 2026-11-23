--!strict
-- Main（クライアント）: 複製の待ち合わせ → 状態（State）と HUD の起動 → StateChanged の受信 → GetSnapshot の初回取得
-- 配置: StarterPlayer.StarterPlayerScripts.Client.Main（LocalScript。Rojo: game/src/client/Main.client.luau）
-- 依存: ReplicatedStorage.Shared の Net・Text・HudFormat・Data.GameData、ReplicatedStorage.GameData、ReplicatedStorage.Remotes の
--   GetSnapshot・StateChanged、同じフォルダの Controllers.{State, Hud}
--
-- S1〜S3 進行記録の繰り越し Minor 1: game:IsLoaded() を待ってから require する（初期複製が揃う前に Shared の
-- require-by-string（"./Formulas" など）や GameData の ModuleScript を探して失敗しないように）。
-- クライアントは表示だけを行う。状態はサーバーのスナップショットからだけ作り、要求は Remote（サーバーがレート・検証する）で送る。
-- S5 の範囲: 財布と日次の HUD。帰還収穫の要約は State に 1 回分だけ保持する（画面は S8）。パネル・Prompt は S6〜S9。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

if not game:IsLoaded() then
	game.Loaded:Wait()
end

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local Net = require(Shared:WaitForChild("Net")) :: any
local Text = require(Shared:WaitForChild("Text")) :: any
local HudFormat = require(Shared:WaitForChild("HudFormat")) :: any
local GameData = require(Shared:WaitForChild("Data"):WaitForChild("GameData")) :: any

-- data の複製確認（S6 以降のパネルが使う。S5 の HUD は使わないので、失敗しても HUD は動かす）
local okGd, gdOrErr = pcall(GameData.load, ReplicatedStorage:WaitForChild("GameData"))
if okGd then
	print(`[Client] GameData OK ({gdOrErr.fileCount} files)`)
else
	warn(`[Client] GameData 불러오기 실패: {tostring(gdOrErr)}`)
end

local Controllers = script.Parent:WaitForChild("Controllers")
local State = require(Controllers:WaitForChild("State")) :: any
local Hud = require(Controllers:WaitForChild("Hud")) :: any

local player = Players.LocalPlayer
local state = State.new(os.clock, HudFormat)
local hud = Hud.new(player:WaitForChild("PlayerGui"), state, Text, HudFormat)
hud:start()

-- StateChanged を先に繋ぐ（GetSnapshot が NOT_READY の間に読み込みが終わっても、サーバーが送る最初の状態を受け取れる）
local stateChanged = Remotes:WaitForChild(Net.Remotes.StateChanged) :: RemoteEvent
stateChanged.OnClientEvent:Connect(function(snap: any)
	state:apply(snap)
end)

-- 初回の GetSnapshot（帰還収穫の要約はこの応答にだけ入る）。NOT_READY・RATE_LIMITED は 1 秒おきに再試行（レート 2/s 以内）
local getSnapshot = Remotes:WaitForChild(Net.Remotes.GetSnapshot) :: RemoteFunction
task.spawn(function()
	for _ = 1, 60 do
		local ok, res = pcall(function()
			return getSnapshot:InvokeServer()
		end)
		if ok and type(res) == "table" and res.ok == true then
			state:apply(res.data)
			local report = state:takeReturnReport()
			if report ~= nil and report.show then
				-- 画面は S8。S5 では出力だけ（Studio 確認用）
				print(`[Client] 귀환 수확 요약: 오프라인 {report.offlineMinutes}분, 인정 {report.creditedMinutes}분, 정령 {#report.spirits}`)
			end
			return
		end
		local code = if ok and type(res) == "table" then tostring(res.code) else tostring(res)
		if code ~= Net.ErrorCode.NOT_READY and code ~= Net.ErrorCode.RATE_LIMITED then
			warn(`[Client] GetSnapshot 실패: {code}`)
		end
		task.wait(1)
	end
	warn("[Client] GetSnapshot 재시도 한도 초과")
end)
