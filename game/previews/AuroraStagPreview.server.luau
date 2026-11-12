-- 試作確認用: ゲーム開始時に「오로라 사슴」を1体スポーンさせる
-- 置き場所: Rojo では同期しない（game/previews/ は default.project.json に写像していない）。
--   使うときだけ Studio で ServerScriptService 直下（Server フォルダの外）に Script として手で置く。
--   ServerScriptService.Server は Rojo の $path 管理下なので、そこに置くと同期で消える。
-- モジュール: Rojo 配置の ReplicatedStorage.Shared.SpiritVisuals.AuroraStag を使う
-- 注意: 確認用に Lighting.ClockTime を夜(21)に変える。確認が終わったら Script を消すこと。

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")

local AuroraStag = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SpiritVisuals"):WaitForChild("AuroraStag"))

-- 光り方が分かりやすいように夜にする(確認用)
Lighting.ClockTime = 21

-- 原点は足元。スポーン地点の 12 スタッド前方・地面すれすれに出し、顔(前方 = -Z)を原点(スポーン地点)へ向ける
AuroraStag.create(workspace, CFrame.lookAt(Vector3.new(0, 0.3, -12), Vector3.new(0, 0.3, 0)))
