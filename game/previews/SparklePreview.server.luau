-- 試作確認用: ゲーム開始時に「반짝이」を1体スポーンさせる
-- 置き場所: Rojo では同期しない（game/previews/ は default.project.json に写像していない）。
--   使うときだけ Studio で ServerScriptService 直下（Server フォルダの外）に Script として手で置く。
--   ServerScriptService.Server は Rojo の $path 管理下なので、そこに置くと同期で消える。
-- モジュール: Rojo 配置の ReplicatedStorage.Shared.SpiritVisuals.Sparkle を使う
-- 注意: 確認用に Lighting.ClockTime を夜(21)に変える。確認が終わったら Script を消すこと。

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")

local Sparkle = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SpiritVisuals"):WaitForChild("Sparkle"))

-- 光り方が分かりやすいように夜にする(確認用)
Lighting.ClockTime = 21

-- スポーン地点の少し前方・空中に出す
Sparkle.create(workspace, CFrame.new(0, 5, -10))
