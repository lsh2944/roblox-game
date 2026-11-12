--!strict
-- SaveSchema: 保存スキーマ v1 の新規状態の生成・形の検査・uid の文字列⇔数値変換（純粋関数）
-- 配置: ServerScriptService.Server.Data.SaveSchema（Rojo: game/src/server/Data/SaveSchema.luau）
-- 依存: なし（gd・開始精霊・単位定数は引数で受け取る）。Roblox API 不使用（Lune の単体テストも読む）
--
-- スキーマは計画書 docs/game_mvp1_impl_plan.md 4.4 節（型は ReplicatedStorage.Shared.Types の PlayerSaveV1）。
-- 時刻の単位: *_at・caught_at・dex・first_capture・field_unlock_time は秒（ゲーム時計 Clock.now()）、
--   settled_min・vigor_min は分（秒 // 60）。ただし session.locked_at・updated_at はセッション判定用に実時間 os.time()。
-- 灯籠（capture.lantern）は永続・開始付与・強化なしなので保存しない（data から導く: hasLantern）。

local SaveSchema = {}

SaveSchema.VERSION = 1

-- 新規状態の生成に必要な値（呼び出し側が data・Config から渡す）
export type NewSaveCtx = {
	gd: any, -- GameData.build の結果
	startSpirits: { { species: string, level: number } }, -- Config.START_SPIRITS
	milli: number, -- Formulas.MILLI（1 個 = 1000 milli）
	vigorTick: number, -- CaptureLogic.VIGOR_TICK（活力 1 点 = 60 tick）
}

-- uid（数値）→ roster のキー文字列。正の安全整数のみ
function SaveSchema.uidKey(uid: number): string
	if type(uid) ~= "number" or uid ~= uid or uid < 1 or uid > 9007199254740991 or math.floor(uid) ~= uid then
		error(`SaveSchema.uidKey: uid는 양의 정수: {tostring(uid)}`)
	end
	return string.format("%d", uid)
end

-- roster のキー文字列 → uid（数値）。CaptureLogic.pickAttacker は数値 uid で同点を比較するので、境界でここを必ず通す
-- 先頭ゼロ・符号・小数・空文字は拒否（"01" と "1" が別キーになるのを防ぐ）
function SaveSchema.uidNum(key: string): number
	if type(key) ~= "string" or string.match(key, "^[1-9]%d*$") == nil or #key > 16 then
		error(`SaveSchema.uidNum: uid 키는 10진 양의 정수 문자열: {tostring(key)}`)
	end
	local n = tonumber(key) :: number
	if n > 9007199254740991 then
		error(`SaveSchema.uidNum: 2^53-1 초과: {key}`)
	end
	return n
end

-- 次の uid を払い出して roster のキーを返す（save.next_uid を進める）
function SaveSchema.allocUid(save: any): string
	local key = SaveSchema.uidKey(save.next_uid)
	save.next_uid += 1
	return key
end

-- 灯籠は開始付与・永続（capture.json lantern）。保存項目なしで常に所持とみなせる条件
function SaveSchema.hasLantern(gd: any): boolean
	local l = gd.capture.lantern
	return l.start_granted == true and l.permanent == true
end

-- 前提条件のないフィールド（開始時に解禁、sim の開始状態と同じ。data では meadow）
local function startFields(gd: any): { string }
	local out = {}
	for _, fid in gd.fieldOrder do
		local u = gd.fields[fid].unlock
		if #u.requires_fields == 0 and #u.costs == 0 then
			table.insert(out, fid)
		end
	end
	return out
end

-- 新規プレイヤーの状態（session は transformLoad が付ける）
-- sim の開始状態（assumptions「시작 상태」・sim.py _open_facilities/_add_spirit）に合わせる:
--   前提なしフィールドだけ解禁、その施設 Lv1・基本枠、開始精霊（個体値 start_spirit_bps、活力満タン、図鑑登録）、
--   開始支給 capture.supply.start（芯 21）、オフライン上限は hub.offline_cap.base_hours。
-- 配置・同行は空（どこに置くかはプレイヤーが決める。計画書 Q3: 同行と施設は排他）。
function SaveSchema.newSave(ctx: NewSaveCtx, nowSec: number): any
	local gd = ctx.gd
	assert(type(nowSec) == "number" and nowSec >= 0 and math.floor(nowSec) == nowSec, "SaveSchema.newSave: nowSec는 0 이상 정수")
	if not SaveSchema.hasLantern(gd) then
		-- 灯籠を保存項目にする設計に変わったらスキーマ改訂が必要
		error("SaveSchema.newSave: capture.lantern 이 시작 지급·영구가 아니면 저장 항목이 필요(미구현)")
	end
	local ind = gd.rules.individual_stats
	if ind.roll_start_spirits then
		-- 開始精霊の個体値抽選は S4 では扱わない（サーバー乱数ストリームは S7）
		error("SaveSchema.newSave: rules.individual_stats.roll_start_spirits=true 는 미구현")
	end
	local nowMin = nowSec // 60
	local wallet: { [string]: number } = {}
	for _, c in gd.capture.supply.start do
		wallet[c.resource] = (wallet[c.resource] or 0) + c.amount * ctx.milli
	end
	local unlocked = startFields(gd)
	local unlockedSet: { [string]: boolean } = {}
	local fieldUnlockTime: { [string]: number } = {}
	for _, fid in unlocked do
		unlockedSet[fid] = true
		fieldUnlockTime[fid] = nowSec
	end
	local facilities = {}
	for _, fid in gd.facilityOrder do
		local fac = gd.facilities[fid]
		if unlockedSet[fac.unlock_field] then
			facilities[fid] = { level = 1, slots = fac.slots.base, assigned = {} }
		end
	end
	local save: any = {
		save_schema = SaveSchema.VERSION,
		created_at = nowSec,
		updated_at = nowSec,
		last_online_at = nowSec,
		wallet = wallet,
		carry = {},
		settled_min = nowMin,
		unlocked = unlocked,
		field_unlock_time = fieldUnlockTime,
		facilities = facilities,
		tool_level = 1,
		offline_cap_hours = gd.hub.offline_cap.base_hours,
		hub_rank = 1,
		storage_bonus = 0,
		roster = {},
		next_uid = 1,
		party = {},
		dex = {},
		first_capture = {},
		quest_day = -1, -- まだ一度も受け取っていない（UTC 日 = os.time() // 86400 は常に 0 以上）
		next_spawn_at = 0,
		stats = { encounters = 0, attempts = 0, captures = 0, releases = 0 },
	}
	local vigorMax = gd.capture.vigor.max * ctx.vigorTick
	for _, s in ctx.startSpirits do
		if gd.spirits[s.species] == nil then
			error(`SaveSchema.newSave: 시작 정령 종이 data에 없음: {s.species}`)
		end
		local key = SaveSchema.allocUid(save)
		save.roster[key] = {
			species = s.species,
			level = s.level,
			gather_bps = ind.start_spirit_bps,
			combat_bps = ind.start_spirit_bps,
			vigor_ticks = vigorMax,
			vigor_min = nowMin,
			origin = "start",
			caught_at = nowSec,
		}
		if save.dex[s.species] == nil then
			save.dex[s.species] = nowSec
		end
	end
	return save
end

-- 形の検査（読み込み時。壊れたセーブを上書きしないための最低限）。戻り値 (ok, 理由)
local function isInt(v: any): boolean
	return type(v) == "number" and v == v and math.floor(v) == v and math.abs(v) <= 9007199254740991
end

local function isMapOf(v: any, valueCheck: (any) -> boolean): boolean
	if type(v) ~= "table" then
		return false
	end
	for k, x in v do
		if type(k) ~= "string" or not valueCheck(x) then
			return false
		end
	end
	return true
end

local function isStringArray(v: any): boolean
	if type(v) ~= "table" then
		return false
	end
	local n = 0
	for k, x in v do
		n += 1
		if type(k) ~= "number" or type(x) ~= "string" then
			return false
		end
	end
	return n == #v
end

local INT_FIELDS = {
	"save_schema", "created_at", "updated_at", "last_online_at", "settled_min", "tool_level", "offline_cap_hours",
	"hub_rank", "storage_bonus", "next_uid", "quest_day", "next_spawn_at",
}

function SaveSchema.check(save: any): (boolean, string?)
	if type(save) ~= "table" then
		return false, "save가 테이블이 아님"
	end
	for _, k in INT_FIELDS do
		if not isInt(save[k]) then
			return false, `정수 필드 이상: {k}`
		end
	end
	if save.session ~= nil then
		local s = save.session
		-- token は錠を作ったセッションの GUID（S4 修正で追加。無い錠は持ち主不明として保存側が lost_lock 扱い）
		if type(s) ~= "table" or type(s.server_id) ~= "string" or not isInt(s.locked_at) or (s.token ~= nil and type(s.token) ~= "string") then
			return false, "session 이상"
		end
	end
	if not isMapOf(save.wallet, isInt) or not isMapOf(save.carry, isInt) then
		return false, "wallet/carry 이상"
	end
	if not isStringArray(save.unlocked) or not isStringArray(save.party) then
		return false, "unlocked/party 이상"
	end
	if not isMapOf(save.field_unlock_time, isInt) or not isMapOf(save.dex, isInt) or not isMapOf(save.first_capture, isInt) then
		return false, "field_unlock_time/dex/first_capture 이상"
	end
	if type(save.stats) ~= "table" then
		return false, "stats 이상"
	end
	if type(save.facilities) ~= "table" then
		return false, "facilities 이상"
	end
	for fid, f in save.facilities do
		if type(fid) ~= "string" or type(f) ~= "table" or not isInt(f.level) or not isInt(f.slots) or not isStringArray(f.assigned) then
			return false, `facilities 이상: {tostring(fid)}`
		end
	end
	if type(save.roster) ~= "table" then
		return false, "roster 이상"
	end
	for key, s in save.roster do
		local okKey = type(key) == "string" and pcall(SaveSchema.uidNum, key)
		if not okKey or type(s) ~= "table" or type(s.species) ~= "string" then
			return false, `roster 이상: {tostring(key)}`
		end
		for _, k in { "level", "gather_bps", "combat_bps", "vigor_ticks", "vigor_min", "caught_at" } do
			if not isInt(s[k]) then
				return false, `roster 이상: {key}.{k}`
			end
		end
		if SaveSchema.uidNum(key) >= save.next_uid then
			return false, `roster uid가 next_uid 이상: {key}`
		end
	end
	return true, nil
end

return table.freeze(SaveSchema)
