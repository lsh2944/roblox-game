--!strict
-- RosterService: 精霊の追加（捕獲）・同行の編成・手動の放出・レベルアップ（保存データ PlayerSaveV1 を更新する）
-- 配置: ServerScriptService.Server.Services.RosterService（Rojo: game/src/server/Services/RosterService.luau）
-- 依存（new の deps で注入）: ReplicatedStorage.Shared の RosterRules・Net・Ledger インスタンス・GameData.build の結果、
--   Services.Activity インスタンス、Data.SaveSchema.allocUid、活力 tick（CaptureLogic.VIGOR_TICK）、
--   フック beforeChange（変更前の精算 = IdleService.settle + GatherService.settle）・afterChange（GatherService.refresh）。
--   Roblox API 不使用（Lune でも動く）
--
-- 規則は RosterRules の頭書き（Q3 排他・Q4 満杯・Q6 レベルアップと放出）。遭遇中は同行を変えられない（計画書 Remote 表）。
-- 戻り値は RemoteResult { ok, code?, data? }。

local RosterService = {}
RosterService.__index = RosterService

type Deps = {
	gd: any,
	RosterRules: any,
	Net: any,
	ledger: any,
	activity: any,
	allocUid: (save: any) -> string,
	vigorTick: number,
	beforeChange: ((userId: number, save: any, nowSec: number) -> ())?,
	afterChange: ((userId: number, save: any, nowSec: number) -> ())?,
}

export type RosterService = typeof(setmetatable({} :: { deps: Deps }, RosterService))

function RosterService.new(deps: Deps): RosterService
	return setmetatable({ deps = deps }, RosterService)
end

local function before(self: RosterService, userId: number, save: any, nowSec: number)
	local f = self.deps.beforeChange
	if f ~= nil then
		f(userId, save, nowSec)
	end
end

local function after(self: RosterService, userId: number, save: any, nowSec: number)
	local f = self.deps.afterChange
	if f ~= nil then
		f(userId, save, nowSec)
	end
end

-- 捕獲した精霊を加える（Lv1・活力満タン・図鑑登録、sim.py _add_spirit）。atSec = 捕獲時刻（ゲーム時計の秒）。戻り値 uid 文字列
-- 保有上限は遭遇開始時に確かめ済み（Q4）。ここでは上限で止めない（確定済みの結果を捨てない）
function RosterService.addCaptured(self: RosterService, save: any, species: string, gatherBps: number, combatBps: number, atSec: number): string
	local gd = self.deps.gd
	if gd.spirits[species] == nil then
		error(`RosterService: 정령 없음 '{species}'`)
	end
	local key = self.deps.allocUid(save)
	save.roster[key] = {
		species = species,
		level = 1,
		gather_bps = gatherBps,
		combat_bps = combatBps,
		vigor_ticks = gd.capture.vigor.max * self.deps.vigorTick,
		vigor_min = atSec // 60,
		origin = "capture",
		caught_at = atSec,
	}
	if save.dex[species] == nil then
		save.dex[species] = atSec
	end
	return key
end

function RosterService.setParty(self: RosterService, userId: number, save: any, uids: any, nowSec: number): any
	local d = self.deps
	if d.activity:get(userId) == "encounter" then
		return { ok = false, code = d.Net.ErrorCode.IN_ENCOUNTER }
	end
	local code = d.RosterRules.checkParty(d.gd, save, uids)
	if code ~= nil then
		return { ok = false, code = code }
	end
	before(self, userId, save, nowSec)
	save.party = table.clone(uids)
	after(self, userId, save, nowSec)
	return { ok = true, data = { party = table.clone(save.party) } }
end

-- 手動の放出（Q6）。研究ポイント = release_research_by_grade（kind=research の資源が無ければ付与なし）
function RosterService.release(self: RosterService, userId: number, save: any, uid: any, nowSec: number): any
	local d = self.deps
	local code = d.RosterRules.checkRelease(save, uid)
	if code ~= nil then
		return { ok = false, code = code }
	end
	before(self, userId, save, nowSec)
	local rec = save.roster[uid]
	local res = d.RosterRules.researchResource(d.gd)
	local amount = 0
	if res ~= nil then
		amount = d.RosterRules.releaseResearch(d.gd, d.gd.spirits[rec.species].grade)
		d.ledger:grant(save.wallet, { { resource = res, amount = amount } })
	end
	save.roster[uid] = nil
	save.stats.releases += 1
	after(self, userId, save, nowSec)
	return { ok = true, data = { uid = uid, research = amount } }
end

-- 精霊レベルアップ（Q6）。費用は生成表、上限は表の max_level。払えなければ何も変えない
function RosterService.levelUp(self: RosterService, userId: number, save: any, uid: any, nowSec: number): any
	local d = self.deps
	if type(uid) ~= "string" then
		return { ok = false, code = d.Net.ErrorCode.BAD_ARG }
	end
	local rec = save.roster[uid]
	if rec == nil then
		return { ok = false, code = d.Net.ErrorCode.NOT_FOUND }
	end
	local cost, code = d.RosterRules.levelUpCost(d.gd, rec.species, rec.level)
	if code ~= nil then
		return { ok = false, code = code }
	end
	-- 費用を差し引く前に精算する（その時点までの生産を旧レベルで確定し、払える額にも含める）
	before(self, userId, save, nowSec)
	local ok, err = d.ledger:spend(save.wallet, cost)
	if not ok then
		return { ok = false, code = err }
	end
	rec.level += 1
	after(self, userId, save, nowSec)
	return { ok = true, data = { uid = uid, level = rec.level } }
end

return RosterService
