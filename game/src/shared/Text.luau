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
} :: { [string]: string })

-- キーの文言を返す。無いキーは誤り（黙って空文字を出さない）
function Text.get(key: string): string
	local s = Text.STRINGS[key]
	if s == nil then
		error(`Text.get: 없는 키: {tostring(key)}`)
	end
	return s
end

return table.freeze(Text)
