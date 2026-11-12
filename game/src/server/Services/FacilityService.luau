--!strict
-- FacilityService: 施設の枠配置・移動と強化（S8。保存データ PlayerSaveV1 の facilities・wallet を更新する）
-- 配置: ServerScriptService.Server.Services.FacilityService（Rojo: game/src/server/Services/FacilityService.luau）
-- 依存（new の deps で注入）: ReplicatedStorage.Shared の FacilityRules・Ledger インスタンス・Economy インスタンス・GameData.build の結果、
--   フック beforeChange（変更前の精算 = IdleService.settle + GatherService.settle）・afterChange。Roblox API 不使用（Lune でも動く）
--
-- 規則は FacilityRules の頭書き（Q3 排他、詰めた配列の枠、強化上限 = 解禁済み最高フィールドの level_cap_by_field、
-- 費用 = 生成表 + hunt_gates）。配置・強化は生産率を変えるので、変更の前に必ず精算する（強化は費用を差し引く前）。
-- 生産の演出（クライアント）と 4 番目の枠の解禁（Q6 で後続）は範囲外。戻り値は RemoteResult { ok, code?, data? }。

local FacilityService = {}
FacilityService.__index = FacilityService

type Deps = {
	gd: any,
	econ: any,
	FacilityRules: any,
	ledger: any,
	beforeChange: ((userId: number, save: any, nowSec: number) -> ())?,
	afterChange: ((userId: number, save: any, nowSec: number) -> ())?,
}

export type FacilityService = typeof(setmetatable({} :: { deps: Deps }, FacilityService))

function FacilityService.new(deps: Deps): FacilityService
	return setmetatable({ deps = deps }, FacilityService)
end

local function hook(f: ((number, any, number) -> ())?, userId: number, save: any, nowSec: number)
	if f ~= nil then
		f(userId, save, nowSec)
	end
end

-- AssignSlot(facilityId, slotIndex, uid | "")
function FacilityService.assign(self: FacilityService, userId: number, save: any, fid: any, slotIndex: any, uid: any, nowSec: number): any
	local d = self.deps
	local idx, code = d.FacilityRules.checkAssign(d.gd, save, fid, slotIndex, uid)
	if code ~= nil then
		return { ok = false, code = code }
	end
	local f = save.facilities[fid]
	hook(d.beforeChange, userId, save, nowSec)
	if uid == "" then
		table.remove(f.assigned, idx)
	else
		f.assigned[idx :: number] = uid
	end
	hook(d.afterChange, userId, save, nowSec)
	return { ok = true, data = { facilityId = fid, assigned = table.clone(f.assigned) } }
end

-- MoveSlot(uid, toFacilityId, toSlot): 配置中の精霊を一度に移動（埋まった枠なら入れ替え）。
-- 枠の計算と検証は FacilityRules.planMove で済ませ、失敗なら精算も含めて何も変えない。成功時だけ精算 → 配列の差し替え → afterChange
function FacilityService.move(self: FacilityService, userId: number, save: any, uid: any, toFid: any, toSlot: any, nowSec: number): any
	local d = self.deps
	local plan, code = d.FacilityRules.planMove(d.gd, save, uid, toFid, toSlot)
	if code ~= nil then
		return { ok = false, code = code }
	end
	hook(d.beforeChange, userId, save, nowSec)
	local out: { [string]: { string } } = {}
	for fid, arr in plan :: { [string]: { string } } do
		save.facilities[fid].assigned = arr
		out[fid] = table.clone(arr)
	end
	hook(d.afterChange, userId, save, nowSec)
	return { ok = true, data = { facilities = out } }
end

-- UpgradeFacility(facilityId)
function FacilityService.upgrade(self: FacilityService, userId: number, save: any, fid: any, nowSec: number): any
	local d = self.deps
	local cost, code = d.FacilityRules.checkUpgrade(d.gd, d.econ, save, fid)
	if code ~= nil then
		return { ok = false, code = code }
	end
	-- 差し引く前に精算する（旧レベルでの生産を確定し、その分も支払いに使える）
	hook(d.beforeChange, userId, save, nowSec)
	local ok, err = d.ledger:spend(save.wallet, cost)
	if not ok then
		return { ok = false, code = err }
	end
	local f = save.facilities[fid]
	f.level += 1
	hook(d.afterChange, userId, save, nowSec)
	return { ok = true, data = { facilityId = fid, level = f.level } }
end

return FacilityService
