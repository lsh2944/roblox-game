--!strict
-- Migrations: 保存スキーマの版上げ（[n] = fn(save) -> save で n → n+1 を順に適用）
-- 配置: ServerScriptService.Server.Data.Migrations（Rojo: game/src/server/Data/Migrations.luau）
-- 依存: なし。Roblox API 不使用（Lune の単体テストも読む）
--
-- 計画書 4.4 節: 保存の save_schema がコードより低ければ順に上げる。コードより高ければ読み込まず追放する
-- （更新中に旧版サーバーが新しい形式を上書きしないため。追放は呼び出し側 PlayerDataService が行う）。

local Migrations = {}

Migrations.CURRENT = 1

export type Step = (save: any) -> any
export type Code = "corrupt" | "newer_schema" | "no_migration"

-- v1 が最初の版なので段はまだない。v2 を作るときは Migrations.STEPS[1] = function(save) ... return save end を足し、
-- CURRENT と SaveSchema.VERSION を 2 に上げる（SaveSchema.newSave は常に最新版を作る）。
Migrations.STEPS = table.freeze({} :: { [number]: Step })

-- 戻り値 (save | nil, 失敗コード | nil)。save は引数のテーブルをそのまま変更して返すことがある
function Migrations.migrate(save: any, current: number?, steps: { [number]: Step }?): (any, Code?)
	local cur = current or Migrations.CURRENT
	local st = steps or Migrations.STEPS
	if type(save) ~= "table" then
		return nil, "corrupt"
	end
	local v = save.save_schema
	if type(v) ~= "number" or v ~= v or v < 1 or math.floor(v) ~= v then
		return nil, "corrupt"
	end
	if v > cur then
		return nil, "newer_schema"
	end
	while v < cur do
		local step = st[v]
		if step == nil then
			return nil, "no_migration"
		end
		save = step(save)
		if type(save) ~= "table" then
			return nil, "corrupt"
		end
		v += 1
		save.save_schema = v
	end
	return save, nil
end

return table.freeze(Migrations)
