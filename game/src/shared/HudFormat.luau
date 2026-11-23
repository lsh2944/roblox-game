--!strict
-- HudFormat: HUD の表示用の純粋関数（数の縮約表記・milli → 表示整数・財布の補間・残り時間の表記）
-- 配置: ReplicatedStorage.Shared.HudFormat（Rojo: game/src/shared/HudFormat.luau）
-- 依存: Formulas（同じフォルダ、MILLI だけ）。Roblox API 不使用（クライアント HUD と Lune の単体テストが読む）
--
-- 規則:
-- - 表示整数 = milli // 1000（切り捨て。サーバーの Ledger・ログと同じ。持っていない量を見せない）
-- - 縮約は 1 桁の小数を「切り捨て」（1999 → 1.9K。四捨五入で 2K と見せると、2K の費用を払えそうに見えるため）。
--   1000 未満はそのまま、".0" は付けない（1000 → 1K）。K・M・B・T の順、それ以上は T のまま大きくする
-- - 財布の補間（S5 決定: サーバーは毎分の精算プレビューを送り、クライアントは生産率で 1 分の間を補う。表示専用で、
--   次のスナップショットで必ずサーバーの値に戻る）: milli + 率(milli/時) × 経過秒 / 3600 + 家の素材(milli/日) × 経過秒 / 86400。
--   経過は 0 以上・maxSeconds 以下に丸める（push が止まっても数字が増え続けないように）

local Formulas = require("./Formulas")

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

-- 残り秒 → "HH:MM:SS"（負は 0、24 時間以上も時の桁を伸ばす）
function HudFormat.countdown(seconds: number): string
	local s = if seconds ~= seconds or seconds < 0 then 0 else math.floor(seconds)
	return string.format("%02d:%02d:%02d", s // 3600, (s // 60) % 60, s % 60)
end

return table.freeze(HudFormat)
