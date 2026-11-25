--!strict
-- Validate: Remote 引数の型・形の検証（純粋関数）と、Remote ごとの引数スキーマ
-- 配置: ServerScriptService.Server.Net.Validate（Rojo: game/src/server/Net/Validate.luau）
-- 依存: なし（gd・Config は schemas の引数）。Roblox API 不使用（Lune の単体テストも読む）
--
-- 計画書 4.3「검증 공통」: typeof を確かめ、数は x == x（NaN 拒否）・有限・整数・範囲、文字列は長さ上限、
-- テーブルは長さ上限と要素の型。ここは「形」だけを見る。ID が実在するか・所有しているか・本当の枠数などは各サービスが data で判定する
-- （クライアントが送るのは ID と意図だけ。数量・費用・確率・時刻は受け取らない）。
-- 引数の個数も確かめる: 多すぎる引数（余分な値）は拒否する（受け取る値の形を一つに固定する）。
-- 戻り値は (true, nil) か (false, 理由)。理由は開発者向けのログ用（プレイヤーには Net.ErrorCode.BAD_ARG だけ返す）。

local Validate = {}

export type Spec =
	{ kind: "int", min: number, max: number }
	| { kind: "string", min: number, max: number, pattern: string?, allowEmpty: boolean? }
	| { kind: "array", max: number, elem: Spec }
	| { kind: "oneOf", values: { [string]: boolean } }

-- 整数（min..max の両端を含む）
function Validate.int(min: number, max: number): Spec
	return table.freeze({ kind = "int", min = min, max = max }) :: any
end

-- 文字列（バイト長 min..max、pattern があれば全体が一致すること）。allowEmpty = 空文字 "" も認める（長さ・形の検査の例外）
function Validate.str(min: number, max: number, pattern: string?, allowEmpty: boolean?): Spec
	return table.freeze({ kind = "string", min = min, max = max, pattern = pattern, allowEmpty = allowEmpty }) :: any
end

-- 配列（長さ 0..max、各要素は elem）。キーは 1..n の連番だけ（辞書・穴・余分なキーは拒否）
function Validate.array(max: number, elem: Spec): Spec
	return table.freeze({ kind = "array", max = max, elem = elem }) :: any
end

-- 列挙（values のどれかと完全に一致する文字列だけ。大文字小文字・前後の空白も区別する）
function Validate.oneOf(values: { string }): Spec
	assert(#values >= 1, "Validate.oneOf: 값이 비어 있음")
	local set: { [string]: boolean } = {}
	for _, v in values do
		assert(type(v) == "string", "Validate.oneOf: 문자열이 아닌 값")
		set[v] = true
	end
	return table.freeze({ kind = "oneOf", values = table.freeze(set) }) :: any
end

-- data の ID（英小文字・数字・下線。fields・facilities・recipes の id がこの形）
Validate.ID_PATTERN = "^[%w_]+$"
-- 精霊 uid（保存の roster キー = 先頭ゼロなしの 10 進正整数、SaveSchema.uidNum と同じ形）
Validate.UID_PATTERN = "^[1-9]%d*$"

function Validate.check(spec: Spec, v: any): (boolean, string?)
	local s = spec :: any
	local t = typeof(v)
	if s.kind == "int" then
		if t ~= "number" then
			return false, `number 가 아님({t})`
		end
		if v ~= v then
			return false, "NaN"
		end
		if v == math.huge or v == -math.huge then
			return false, "무한"
		end
		if math.floor(v) ~= v then
			return false, "정수가 아님"
		end
		if v < s.min or v > s.max then
			return false, `범위 밖({v}, {s.min}..{s.max})`
		end
		return true, nil
	elseif s.kind == "string" then
		if t ~= "string" then
			return false, `string 이 아님({t})`
		end
		if v == "" and s.allowEmpty == true then
			return true, nil
		end
		local n = #v
		if n < s.min or n > s.max then
			return false, `길이 범위 밖({n}, {s.min}..{s.max})`
		end
		if s.pattern ~= nil and string.match(v, s.pattern) == nil then
			return false, "형식 불일치"
		end
		return true, nil
	elseif s.kind == "array" then
		if t ~= "table" then
			return false, `table 이 아님({t})`
		end
		-- 上限を超えたら数えるのをやめる（巨大なテーブルを最後まで回さない）
		local count = 0
		for k in v do
			count += 1
			if count > s.max then
				return false, `길이 초과(>{s.max})`
			end
			if type(k) ~= "number" or k ~= k or math.floor(k) ~= k or k < 1 then
				return false, "배열이 아닌 키"
			end
		end
		for i = 1, count do
			local e = v[i]
			if e == nil then
				return false, "배열에 빈 칸"
			end
			local ok, why = Validate.check(s.elem, e)
			if not ok then
				return false, `[{i}] {why}`
			end
		end
		return true, nil
	elseif s.kind == "oneOf" then
		if t ~= "string" then
			return false, `string 이 아님({t})`
		end
		if s.values[v] ~= true then
			return false, "허용 목록 밖"
		end
		return true, nil
	end
	error(`Validate.check: 알 수 없는 spec kind {tostring(s.kind)}`)
end

-- 引数の並び。n = select("#", ...)（末尾の nil も数える）
function Validate.args(specs: { Spec }, n: number, ...: any): (boolean, string?)
	if n ~= #specs then
		return false, `인자 개수 {n} (기대 {#specs})`
	end
	local args = table.pack(...)
	for i, spec in specs do
		local ok, why = Validate.check(spec, args[i])
		if not ok then
			return false, `인자 {i}: {why}`
		end
	end
	return true, nil
end

-- C→S Remote の引数スキーマ（計画書 4.3 の Remote 表）。gd = GameData.build の結果、config = Config、
-- net = ReplicatedStorage.Shared.Net（Travel の行き先の列挙 Net.TravelDest。2026-11-24 決定）
function Validate.schemas(gd: any, config: any, net: any): { [string]: { Spec } }
	local id = Validate.str(1, config.REMOTE_ID_MAX_LEN, Validate.ID_PATTERN)
	local uid = Validate.str(1, config.REMOTE_UID_MAX_LEN, Validate.UID_PATTERN)
	local slot = Validate.int(1, config.REMOTE_SLOT_MAX)
	-- AssignSlot の uid は空文字 "" = 外す（FacilityService の契約）
	local uidOrEmpty = Validate.str(1, config.REMOTE_UID_MAX_LEN, Validate.UID_PATTERN, true)
	local dests: { string } = {}
	for _, v in net.TravelDest do
		table.insert(dests, v)
	end
	table.sort(dests)
	local s = {
		GetSnapshot = {},
		GatherStart = { id }, -- nodeId
		GatherStop = {},
		CaptureEngage = { id }, -- wildId
		SetParty = { Validate.array(gd.constants.companion_slots, uid) }, -- uids（≤ companion_slots）
		AssignSlot = { id, slot, uidOrEmpty }, -- facilityId, slotIndex, uid | ""
		UpgradeFacility = { id }, -- facilityId
		Craft = { id, Validate.int(1, config.CRAFT_MAX_TIMES) }, -- recipeId, times
		ClaimDaily = {},
		ReleaseSpirit = { uid },
		LevelUpSpirit = { uid },
		MoveSlot = { uid, id, slot }, -- uid, toFacilityId, toSlot
		Travel = { Validate.oneOf(dests) }, -- dest（"meadow" | "home"）
	}
	for k, v in s do
		s[k] = table.freeze(v)
	end
	return table.freeze(s) :: any
end

return table.freeze(Validate)
