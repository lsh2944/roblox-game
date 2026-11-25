--!strict
-- Snapshot: 保存データ + サーバーの計算値 → クライアント用の状態テーブル（純粋関数。GetSnapshot の応答と StateChanged の中身）
-- 配置: ServerScriptService.Server.Net.Snapshot（Rojo: game/src/server/Net/Snapshot.luau）
-- 依存（build の ctx で注入）: GameData.build の結果・Economy インスタンス、ReplicatedStorage.Shared の IdleCalc・CaptureLogic・
--   RosterRules・QuestRules・FacilityRules、Services.IdleService（モジュール。input だけ使う）。Roblox API 不使用（Lune でも動く）
--
-- 方針（S5 決定）:
-- - 保存データを一切変えない（精算のプレビューは IdleService.input の写しで計算して捨てる。保存・自動保存と競合しない）
-- - 財布 wallet = 今の分まで精算したプレビュー（milli のまま。表示整数は HudFormat.units = milli // 1000）。
--   walletAt = プレビューの時刻（秒、分の頭）。クライアントは idle.perHour・idle.homePerDay で walletAt からの経過を補間する
--   （表示専用。サーバーは毎分と変更時にスナップショットを送り直すので、補間の誤差は次の送信で消える）
-- - 入れないもの（隠す情報・内部状態）: 遭遇の結果・試行数・乱数ブロック（遭遇中の状態は CaptureService にあり、ここには渡さない）、
--   session（錠）、carry（端数）、next_uid、next_spawn_at、stats、settled_min、last_online_at、created_at/updated_at、first_capture
-- - 採集 gather（S6）は extras で渡されたセッションがあるときだけ入れる: nodeId・resource・rate（milli/時）・accruedAt
--   （財布へ積算済みの時刻 = 秒）。クライアントは accruedAt からの経過を rate で補間する（表示専用）
-- - 帰還収穫の要約 returnReport は extras で渡されたときだけ入れる（Remoting は GetSnapshot の応答にだけ渡し、StateChanged には入れない）
-- - seq = プレイヤーごとの送信番号（クライアントは古い seq を捨てる。GetSnapshot の応答と StateChanged の到着順が入れ替わっても戻らない）

local Snapshot = {}

Snapshot.VERSION = 1

export type Ctx = {
	gd: any,
	econ: any,
	IdleService: any,
	IdleCalc: any,
	CaptureLogic: any,
	RosterRules: any,
	QuestRules: any,
	FacilityRules: any,
}

export type Extras = {
	seq: number,
	plot: number?, -- 部地の番号（PlotService。満員で無ければ nil）
	returnReport: any?, -- IdleCalc.ReturnReport（GetSnapshot の応答だけ）
	gather: any?, -- GatherService.Session（採集中だけ。写しを作って入れる）
}

-- 最上位のキー（SnapshotSpec がこれ以外のキーが無いことを確かめる。足すときはここと Spec を同時に直す）
Snapshot.KEYS = table.freeze({
	"v",
	"seq",
	"serverNow",
	"wallet",
	"walletAt",
	"idle",
	"facilities",
	"roster",
	"vigorMax",
	"party",
	"dex",
	"unlocked",
	"toolLevel",
	"storage",
	"daily",
	"plot",
	"returnReport",
	"gather",
})

local function copyArray(a: { any }): { any }
	local out = {}
	for i, v in a do
		out[i] = v
	end
	return out
end

function Snapshot.build(ctx: Ctx, save: any, nowSec: number, extras: Extras): any
	local gd, econ = ctx.gd, ctx.econ
	local nowMin = nowSec // 60
	local vt = ctx.CaptureLogic.VIGOR_TICK

	-- 精算のプレビュー（写しだけを進める）
	local input = ctx.IdleService.input(save, false)
	local r = ctx.IdleCalc.settle(econ, input, nowMin)
	local night = ctx.CaptureLogic.isNight(nowMin, gd.rules.night)
	local perHour = ctx.IdleCalc.idleRates(econ, input, night)
	local homePerDay: { [string]: number } = {}
	for _, row in ctx.IdleCalc.homeDetail(econ, input) do
		homePerDay[row.resource] = (homePerDay[row.resource] or 0) + row.milli
	end

	-- 施設（Home 画面・生産の表示用。施設ごとの率の合計 = perHour、SnapshotSpec が確かめる）
	local dexRes = econ:dexMap(save.dex).resource_output
	local facilities: { [string]: any } = {}
	for _, fid in gd.facilityOrder do
		local fac = save.facilities[fid]
		if fac ~= nil then
			local members = {}
			for _, uid in fac.assigned do
				local s = save.roster[uid]
				if s == nil then
					error(`Snapshot: 배치된 정령이 보관함에 없음 uid={uid}`)
				end
				table.insert(members, { species = s.species, level = s.level, gatherBps = s.gather_bps, combatBps = s.combat_bps })
			end
			local produces = gd.facilities[fid].produces
			facilities[fid] = {
				level = fac.level,
				slots = fac.slots,
				assigned = copyArray(fac.assigned),
				produces = produces,
				ratePerHour = econ:facilityRate(fid, fac.level, members, night, dexRes[produces] or 0),
				levelCap = ctx.FacilityRules.levelCap(gd, save, fid),
			}
		end
	end

	local roster: { [string]: any } = {}
	for uid, s in save.roster do
		roster[uid] = {
			species = s.species,
			level = s.level,
			gatherBps = s.gather_bps,
			combatBps = s.combat_bps,
			vigor = ctx.CaptureLogic.vigorAt(s.vigor_ticks, s.vigor_min, nowMin, gd.capture) // vt, -- 今の活力（点、切り捨て）
			origin = s.origin,
			caughtAt = s.caught_at,
		}
	end

	local dex: { [string]: number } = {}
	for species, at in save.dex do
		dex[species] = at
	end

	local g = extras.gather
	local gather = if g ~= nil
		then { nodeId = g.nodeId, resource = g.resource, rate = g.rate, accruedAt = g.lastSec }
		else nil

	local day = ctx.QuestRules.utcDay(nowSec)
	return {
		v = Snapshot.VERSION,
		seq = extras.seq,
		serverNow = nowSec,
		wallet = input.wallet,
		walletAt = r.newSettledMin * 60,
		idle = { night = night, perHour = perHour, homePerDay = homePerDay },
		facilities = facilities,
		roster = roster,
		vigorMax = gd.capture.vigor.max,
		party = copyArray(save.party),
		dex = dex,
		unlocked = copyArray(save.unlocked),
		toolLevel = save.tool_level,
		storage = { count = ctx.RosterRules.count(save), capacity = ctx.RosterRules.capacity(gd, save) },
		daily = {
			claimed = save.quest_day >= day,
			day = day,
			nextResetAt = (day + 1) * ctx.QuestRules.SECONDS_PER_DAY,
		},
		plot = extras.plot,
		returnReport = extras.returnReport,
		gather = gather,
	}
end

return table.freeze(Snapshot)
