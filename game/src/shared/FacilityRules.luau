--!strict
-- FacilityRules: 施設の枠配置と強化の純粋な判定（状態は変えない）、フィールドの解禁順位
-- 配置: ReplicatedStorage.Shared.FacilityRules（Rojo: game/src/shared/FacilityRules.luau）
-- 依存: Net・RosterRules（同じフォルダ）、GameData.build の結果（引数）。Roblox API 不使用（Lune でも動く）
-- 状態の変更は ServerScriptService.Server.Services.FacilityService。
--
-- 規則の出典:
-- - Q3 決定: 同行と施設配置は排他（同行中の精霊は配置できない）
-- - 枠は開いている施設（save.facilities にある）の 1..slots。assigned は詰めた配列（保存スキーマ v1 の { uid 文字列 } を変えない）:
--   slotIndex が埋まっていれば入れ替え、空き（> #assigned）なら末尾に足す。"" は slotIndex の精霊を外して詰める
-- - 精霊は同時に 1 か所だけ。AssignSlot で別の施設・別の枠にいる精霊を指定したら ASSIGNED_ELSEWHERE（移動は MoveSlot）
-- - 移動（MoveSlot、2026-11-12 決定）: 配置中の精霊を (施設 A, 枠 i) → (施設 B, 枠 j) へ 1 回で動かす。A = B も可。
--   j が埋まっていれば 2 体の位置を入れ替え、空き（> #assigned）なら B の末尾へ（A からは外して詰める）。
--   枠番号の計算は planMove だけで行い、新しい配列を作って返す（検証が全部通るまで保存データに触れない）
-- - 強化の上限 = 解禁済みフィールドのうち最も順位が高いフィールドまでの level_cap_by_field の最大（model.py level_cap_at_field）
-- - 強化の費用 = 生成表 + hunt_gates（Economy.facilityLevelCost）

local Net = require("./Net")
local RosterRules = require("./RosterRules")

local E = Net.ErrorCode

local FacilityRules = {}

-- フィールドの順位（gd.fieldOrder の位置、1 始まり）。無いフィールドは nil
function FacilityRules.fieldRank(gd: any, fieldId: string): number?
	return table.find(gd.fieldOrder, fieldId)
end

-- 解禁済みのうち最も順位が高いフィールド
function FacilityRules.topUnlockedField(gd: any, unlocked: { string }): string
	local best: string? = nil
	local bestRank = 0
	for _, fid in unlocked do
		local r = FacilityRules.fieldRank(gd, fid)
		if r ~= nil and r > bestRank then
			best, bestRank = fid, r
		end
	end
	if best == nil then
		error("FacilityRules: 해금된 필드가 없음")
	end
	return best :: string
end

-- そのフィールドまで解禁したときの最大レベル（未定義なら 0）。entity は施設・道具
function FacilityRules.levelCapAtField(gd: any, entity: any, fieldId: string): number
	local rank = FacilityRules.fieldRank(gd, fieldId) or 0
	local best = 0
	for _, cap in entity.level_cap_by_field do
		local r = FacilityRules.fieldRank(gd, cap.field_id)
		if r ~= nil and r <= rank then
			best = math.max(best, cap.max_level)
		end
	end
	return math.min(best, entity.max_level)
end

function FacilityRules.levelCap(gd: any, save: any, fid: string): number
	return FacilityRules.levelCapAtField(gd, gd.facilities[fid], FacilityRules.topUnlockedField(gd, save.unlocked))
end

local function isInt(v: any): boolean
	return type(v) == "number" and v == v and math.floor(v) == v and math.abs(v) <= 9007199254740991
end

-- 枠配置の検証。戻り値 (正規化した slotIndex | nil, エラーコード | nil)
function FacilityRules.checkAssign(gd: any, save: any, fid: any, slotIndex: any, uid: any): (number?, string?)
	if type(fid) ~= "string" or not isInt(slotIndex) or type(uid) ~= "string" then
		return nil, E.BAD_ARG
	end
	if gd.facilities[fid] == nil then
		return nil, E.NOT_FOUND
	end
	local f = save.facilities[fid]
	if f == nil then
		return nil, E.NOT_UNLOCKED
	end
	if slotIndex < 1 or slotIndex > f.slots then
		return nil, E.BAD_ARG
	end
	local n = #f.assigned
	if uid == "" then
		if slotIndex > n then
			return nil, E.NOT_FOUND
		end
		return slotIndex, nil
	end
	if save.roster[uid] == nil then
		return nil, E.NOT_FOUND
	end
	if table.find(save.party, uid) ~= nil then
		return nil, E.ASSIGNED_ELSEWHERE
	end
	local idx = math.min(slotIndex, n + 1)
	local at = RosterRules.assignedFacility(save, uid)
	if at ~= nil and not (at == fid and f.assigned[idx] == uid) then
		return nil, E.ASSIGNED_ELSEWHERE
	end
	return idx, nil
end

-- uid が配置されている (施設 ID, 枠番号)。無ければ nil
function FacilityRules.locate(save: any, uid: string): (string?, number?)
	for fid, f in save.facilities do
		local i = table.find(f.assigned, uid)
		if i ~= nil then
			return fid, i
		end
	end
	return nil, nil
end

-- 移動の検証と移動後の配列。戻り値 ({ [施設 ID]: 新しい assigned（変わる施設だけ、新しいテーブル）} | nil, エラーコード | nil)
-- 検証: 引数の型 → 保有 → 同行中でない（Q3）→ 配置中 → 移動先の施設が存在・解禁済み → 枠 1..slots →
--   入れ替え相手が同行中でない（壊れた保存の防御）
function FacilityRules.planMove(gd: any, save: any, uid: any, toFid: any, toSlot: any): ({ [string]: { string } }?, string?)
	if type(uid) ~= "string" or type(toFid) ~= "string" or not isInt(toSlot) then
		return nil, E.BAD_ARG
	end
	if save.roster[uid] == nil then
		return nil, E.NOT_FOUND
	end
	if table.find(save.party, uid) ~= nil then
		return nil, E.ASSIGNED_ELSEWHERE
	end
	local fromFid, fromIdx = FacilityRules.locate(save, uid)
	if fromFid == nil or fromIdx == nil then
		return nil, E.NOT_FOUND -- 配置されていない（新しく置くのは AssignSlot）
	end
	if gd.facilities[toFid] == nil then
		return nil, E.NOT_FOUND
	end
	local dst = save.facilities[toFid]
	if dst == nil then
		return nil, E.NOT_UNLOCKED
	end
	if toSlot < 1 or toSlot > dst.slots then
		return nil, E.BAD_ARG
	end
	local src = table.clone(save.facilities[fromFid].assigned)
	if fromFid == toFid then
		if toSlot <= #src then
			-- 同じ施設の埋まった枠: 入れ替え（同じ枠なら変化なし）
			src[fromIdx], src[toSlot] = src[toSlot], src[fromIdx]
		else
			-- 同じ施設の空き枠: 外して末尾へ
			table.remove(src, fromIdx)
			table.insert(src, uid)
		end
		return { [fromFid] = src }, nil
	end
	local dstArr = table.clone(dst.assigned)
	if toSlot <= #dstArr then
		local other = dstArr[toSlot]
		if table.find(save.party, other) ~= nil then
			return nil, E.ASSIGNED_ELSEWHERE
		end
		dstArr[toSlot] = uid
		src[fromIdx] = other
	else
		table.remove(src, fromIdx)
		table.insert(dstArr, uid)
	end
	return { [fromFid] = src, [toFid] = dstArr }, nil
end

-- 強化の検証と費用。戻り値 (費用 | nil, エラーコード | nil)
function FacilityRules.checkUpgrade(gd: any, econ: any, save: any, fid: any): ({ { resource: string, amount: number } }?, string?)
	if type(fid) ~= "string" then
		return nil, E.BAD_ARG
	end
	if gd.facilities[fid] == nil then
		return nil, E.NOT_FOUND
	end
	local f = save.facilities[fid]
	if f == nil then
		return nil, E.NOT_UNLOCKED
	end
	if f.level >= FacilityRules.levelCap(gd, save, fid) then
		return nil, E.LEVEL_CAP
	end
	return econ:facilityLevelCost(fid, f.level), nil
end

return table.freeze(FacilityRules)
