--!strict
-- Text: プレイヤーに見える文言の一覧（キー → 英語の原文）。開発者向けの print・warn・error の文言はここに入れない
-- 配置: ReplicatedStorage.Shared.Text（Rojo: game/src/shared/Text.luau）
-- 依存: なし。Roblox API 不使用（サーバー・クライアント・Lune の単体テストが読む）
--
-- 規則（2026-11-11 ユーザー決定: プレイヤー向け文言は英語が既定、他言語は後で Roblox Localization の翻訳で付ける）:
-- - 文言は必ずキーで引く（Text.get）。コードに直接書かない
-- - キーは「区分.名前」（例 "Kick.LoadFailed"）。後で LocalizationTable へ移すときに Key 列へそのまま使う想定
-- - 原文は英語（ASCII）。翻訳はこの表ではなく LocalizationTable 側に置く予定
-- - 追放文言（Player:Kick）はサーバーで組み立てるので、翻訳するときは LocalizationService:GetTranslatorForPlayerAsync で
--   プレイヤーの言語の Translator を取り、FormatByKey で引く形に置き換える（未実装、Studio 未確認）

local Text = {}

Text.SOURCE_LOCALE = "en"

Text.STRINGS = table.freeze({
	-- 保存データの読み込み・セッション錠（PlayerDataService の追放）
	["Kick.LoadFailed"] = "We couldn't load your save data. Please rejoin in a moment.",
	["Kick.NewerSchema"] = "The game has been updated. Please rejoin.",
	["Kick.Corrupt"] = "Your save data couldn't be read. Please contact the developer.",
	["Kick.LostLock"] = "Your account joined from another server, so this session has ended.",
	-- 捕獲開始の拒否（Q4 決定: 保管箱が満杯なら捕獲を止めて手動の放出を案内する。Net.ErrorCode.STORAGE_FULL に対応）
	["Notice.StorageFull"] = "Your spirit storage is full. Release a spirit to make room before using the lantern.",
	-- Remote の応答コード（Net.ErrorCode.NOT_IMPLEMENTED: S5 時点で処理が未結線の Remote）
	["Error.NotImplemented"] = "This feature is coming soon.",
	-- HUD（S5: 左上の財布・右上の日次状態。{name} 形式の差し込みは Text.format）
	["Hud.Loading"] = "Loading...",
	["Hud.Dew"] = "Dew",
	["Hud.Bloom"] = "Bloom",
	["Hud.Wick"] = "Wick",
	["Hud.Materials"] = "Meadow Materials",
	["Hud.DailyClaimed"] = "Daily claimed",
	["Hud.DailyReady"] = "Daily ready",
	["Hud.DailyReset"] = "Resets in {time}",
	-- 移動ボタン（2026-11-24 決定: Travel Remote）と失敗の案内（HudFormat.travelErrorKey が応答コードから選ぶ）
	["Hud.TravelMeadow"] = "Meadow",
	["Hud.TravelHome"] = "Home",
	["Travel.Busy"] = "You can't travel during a capture.",
	["Travel.Failed"] = "You can't travel right now. Please try again.",
	-- ワールドの看板（S5 MeadowBuilder。サーバーが組み立てて複製する）
	["World.PlotEmpty"] = "Empty Garden",
	["World.PlotOwner"] = "{name}'s Garden",
	["World.Board"] = "Daily Requests",
	["World.ForestGate"] = "Forest - Coming soon",
	["World.Reserved"] = "Coming soon",
	["World.Showcase"] = "Showcase - Coming soon",
} :: { [string]: string })

-- キーの文言を返す。無いキーは誤り（黙って空文字を出さない）
function Text.get(key: string): string
	local s = Text.STRINGS[key]
	if s == nil then
		error(`Text.get: 없는 키: {tostring(key)}`)
	end
	return s
end

-- キーの文言の {名前} を args の値で置き換える。args に無い名前・余った args は誤り（黙って欠けた文言を出さない）
-- 置き換える値は文字列化してそのまま入れる（値の中の { } は再解釈しない）
function Text.format(key: string, args: { [string]: any }): string
	local s = Text.get(key)
	local used: { [string]: boolean } = {}
	local out = string.gsub(s, "{(%w+)}", function(name: string): string
		local v = args[name]
		if v == nil then
			error(`Text.format: '{key}' 의 자리 '{name}' 값 없음`)
		end
		used[name] = true
		return tostring(v)
	end)
	for name in args do
		if not used[name] then
			error(`Text.format: '{key}' 에 없는 자리 '{tostring(name)}'`)
		end
	end
	return out
end

return table.freeze(Text)
