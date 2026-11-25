--!strict
-- HudFormat: HUD の表示用の純粋関数（数の縮約表記・milli → 表示整数・財布の補間・残り時間の表記・Travel の失敗文言キー）
-- 配置: ReplicatedStorage.Shared.HudFormat（Rojo: game/src/shared/HudFormat.luau）
-- 依存: Formulas（同じフォルダ、MILLI だけ）・Net（同じフォルダ、ErrorCode だけ）。Roblox API 不使用（クライアント HUD と Lune の単体テストが読む）
--
-- 規則:
-- - 表示整数 = milli // 1000（切り捨て。サーバーの Ledger・ログと同じ。持っていない量を見せない）
-- - 縮約は 1 桁の小数を「切り捨て」（1999 → 1.9K。四捨五入で 2K と見せると、2K の費用を払えそうに見えるため）。
--   1000 未満はそのまま、".0" は付けない（1000 → 1K）。K・M・B・T の順、それ以上は T のまま大きくする
-- - 財布の補間（S5 決定: サーバーは毎分の精算プレビューを送り、クライアントは生産率で 1 分の間を補う。表示専用で、
--   次のスナップショットで必ずサーバーの値に戻る）: milli + 率(milli/時) × 経過秒 / 3600 + 家の素材(milli/日) × 経過秒 / 86400。
--   経過は 0 以上・maxSeconds 以下に丸める（push が止まっても数字が増え続けないように）

local Formulas = require("./Formulas")
local Net = require("./Net")

local HudFormat = {}

local SUFFIXES = { "K", "M", "B", "T" }

-- 財布を補間する上限秒（サーバーは毎分送り直すので、2 回続けて届かなければ補間を止める）
HudFormat.PROJECT_MAX_SECONDS = 120

-- milli（整数）→ 表示整数（切り捨て）
function HudFormat.units(milli: number): number
	if type(milli) ~= "number" or milli ~= milli or milli == math.huge or milli == -math.huge then
		return 0
	end
	return milli // Formulas.MILLI
end

-- 表示整数 → 縮約表記（"860"・"1.2K"・"3M"）。非数・無限は "?"
function HudFormat.abbreviate(n: number): string
	if type(n) ~= "number" or n ~= n or n == math.huge or n == -math.huge then
		return "?"
	end
	local neg = n < 0
	local v = math.floor(math.abs(n))
	local text: string
	if v < 1000 then
		text = string.format("%d", v)
	else
		-- 10 分の 1 単位の整数で切り捨てる（浮動小数の丸めで 1.9999K が 2K にならないように整数で数える）
		local idx = 1
		local scaled = v
		local tenths = v // 100 -- K 単位の 10 分の 1
		while tenths >= 10000 and idx < #SUFFIXES do
			idx += 1
			scaled = scaled // 1000
			tenths = scaled // 100
		end
		local whole = tenths // 10
		local frac = tenths % 10
		if frac == 0 then
			text = string.format("%d%s", whole, SUFFIXES[idx])
		else
			text = string.format("%d.%d%s", whole, frac, SUFFIXES[idx])
		end
	end
	return if neg then "-" .. text else text
end

-- 補間した milli（小数を含む。表示は units で切り捨てる）
function HudFormat.projectMilli(
	milli: number,
	perHourMilli: number?,
	perDayMilli: number?,
	elapsedSeconds: number,
	maxSeconds: number
): number
	local e = elapsedSeconds
	if e ~= e or e < 0 then
		e = 0
	elseif e > maxSeconds then
		e = maxSeconds
	end
	local add = (perHourMilli or 0) * e / 3600 + (perDayMilli or 0) * e / 86400
	if add ~= add or add < 0 then
		add = 0
	end
	return milli + add
end

-- 応答コード（RF の失敗）→ トーストの文言キー（Shared.Text）。対応が無いコードは汎用の文言
local ERROR_TEXT_KEYS: { [string]: string } = {
	[Net.ErrorCode.TOO_FAR] = "Error.TooFar",
	[Net.ErrorCode.BUSY] = "Error.Busy",
	[Net.ErrorCode.NOT_UNLOCKED] = "Error.NotUnlocked",
	[Net.ErrorCode.RATE_LIMITED] = "Error.RateLimited",
	[Net.ErrorCode.NOT_IMPLEMENTED] = "Error.NotImplemented",
	[Net.ErrorCode.STORAGE_FULL] = "Notice.StorageFull",
}
HudFormat.ERROR_TEXT_KEYS = table.freeze(ERROR_TEXT_KEYS)
HudFormat.GENERIC_ERROR_KEY = "Error.Generic"

-- Notify（S→C）のコード → 文言キー。サーバーからの自発的な通知なので RF の失敗と文言を分けるもの（TOO_FAR = 範囲外で採集が
-- 止まった）だけここに置き、他は RF と同じ対応を使う
local NOTICE_TEXT_KEYS: { [string]: string } = {
	[Net.ErrorCode.TOO_FAR] = "Notice.GatherStopped",
}
HudFormat.NOTICE_TEXT_KEYS = table.freeze(NOTICE_TEXT_KEYS)

function HudFormat.errorTextKey(code: any): string
	return if type(code) == "string" then ERROR_TEXT_KEYS[code] or HudFormat.GENERIC_ERROR_KEY else HudFormat.GENERIC_ERROR_KEY
end

function HudFormat.noticeTextKey(code: any): string
	if type(code) == "string" and NOTICE_TEXT_KEYS[code] ~= nil then
		return NOTICE_TEXT_KEYS[code]
	end
	return HudFormat.errorTextKey(code)
end

-- 残り秒 → "HH:MM:SS"（負は 0、24 時間以上も時の桁を伸ばす）
function HudFormat.countdown(seconds: number): string
	local s = if seconds ~= seconds or seconds < 0 then 0 else math.floor(seconds)
	return string.format("%02d:%02d:%02d", s // 3600, (s // 60) % 60, s % 60)
end

-- Travel の失敗応答コード → 表示する文言キー（Shared.Text）。遭遇中（BUSY）だけ専用の案内、それ以外は共通の「今は移動できない」
function HudFormat.travelErrorKey(code: any): string
	if code == Net.ErrorCode.BUSY then
		return "Travel.Busy"
	elseif code == Net.ErrorCode.NOT_IMPLEMENTED then
		return "Error.NotImplemented"
	end
	return "Travel.Failed"
end

return table.freeze(HudFormat)
