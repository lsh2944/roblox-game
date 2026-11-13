--!strict
-- CaptureService: 簡易モードの遭遇の状態機械（S7、計画書 4.3「조우(간편 모드)」）。保存データ PlayerSaveV1 を更新する
-- 配置: ServerScriptService.Server.Services.CaptureService（Rojo: game/src/server/Services/CaptureService.luau）
-- 依存（new の deps で注入）: ReplicatedStorage.Shared の CaptureLogic・RosterRules・Net・Ledger インスタンス・GameData.build の結果、
--   ServerRng インスタンス、Services の Activity・WildSpawnService・GatherService・RosterService インスタンス、
--   Data.SaveSchema.uidNum、Config.CAPTURE_RADIUS、フック beforeChange（変更前の精算）、log（任意、壊れた値の切り詰めの記録）。
--   Roblox API 不使用（Lune でも動く）
--
-- 流れ（sim.py _start_encounter / _complete_encounter と同じ契約）:
-- 1. engage の検証順: 自分の野生精霊か → 距離 → 芯 ≥ 1 回分 → 遊休（遭遇中でない）→ 保管箱が満杯でない（Q4）
--    → 今の出現表が空でない。ここまでは状態を変えない（精算・採集終了・乱数・野生の消費は検証の後）
-- 2. 採集中なら採集を閉じる。capture ストリームから固定ブロック 1 + 2·K_max 個を引き、種（block[1]・出現表）を決める
-- 3. 弱体化が要る等級なら pickAttacker → 攻撃者の活力を差し引く（同行なし・全員疲労なら灯籠の補助弱体化）
-- 4. resolveEasy で結果を開始時に確定し、使った芯をすぐ差し引く。統計（遭遇・試行）と next_spawn_at もここで書く
-- 5. 再生イベント列（reveal → weaken → attempt i → result）を作る。実時間 = 弱体化秒 + 試行秒 × 試行数。
--    クライアントへはイベントの時刻（開始 + at）が来たものだけを渡す（2026-11-12 決定、RF 応答に結果を入れない）:
--    engage の応答 = 時刻 0 のイベント（reveal・weaken など）だけ。以後はサーバーの 1 秒ループが dueEvents で取り出して
--    EncounterEvent（RE）で送る。結果を先に推測できないよう、応答に実時間・終了時刻も入れない（試行数が分かるため）
-- 6. 完了時刻（complete）に反映: 捕獲・first_capture・個体値（individual ストリーム intInclusive(min, max)）・図鑑。
--    まだ渡していないイベントは反映結果の events に入れて返す（ループの呼び順に依らず result を落とさない）。
--    退出・サーバー終了で途中なら finish ですぐ確定・反映する（引き直す手段はない）
-- 7. 未来の時刻の切り詰め（2026-11-12 決定、上限は CaptureLogic.maxEncounterSeconds の頭書き）: 使う時点で確かめる。
--    同行の vigor_min は engage の入力を作るとき、pending.endsAt は complete のとき（時計が巻き戻っても遭遇が終わるように）
-- 芯は capture.attempt_cost の 1 種だけ対応（sim と同じ制約）。遭遇中の状態は実行時だけ（保存しない）。
-- 遭遇の結果に有料の材料は入らない（芯・灯籠は非売、捕獲補助道具は MVP1 で使わない）。
-- 図鑑の捕獲確率ボーナス（2026-11-12 決定、オーロラ鹿 +0.5%p・上限 +3%p）は engage 時点の save.dex で決め、結果の確定と
-- EncounterEvent の attempt.bps（表示する最終値）に同じ値を使う。精霊は販売しないので有料の経路はない（PolicyService 対象外）。

local CaptureService = {}
CaptureService.__index = CaptureService

type Deps = {
	gd: any,
	CaptureLogic: any,
	RosterRules: any,
	Net: any,
	ledger: any,
	rng: any,
	activity: any,
	wild: any,
	gather: any?,
	roster: any,
	uidNum: (key: string) -> number,
	radius: number,
	beforeChange: ((userId: number, save: any, nowSec: number) -> ())?,
	log: ((msg: string) -> ())?,
}

export type Pending = {
	plan: any,
	fieldId: string,
	startSec: number,
	endsAt: number,
	events: { any },
	sent: number, -- クライアントへ渡したイベントの数（events の先頭から）
}

export type CaptureService = typeof(setmetatable(
	{} :: { deps: Deps, pending: { [number]: Pending }, maxEncounterSeconds: number },
	CaptureService
))

function CaptureService.new(deps: Deps): CaptureService
	local cost = deps.gd.capture.attempt_cost
	if #cost ~= 1 then
		error("CaptureService: capture.attempt_cost 는 자원 1종만 지원")
	end
	return setmetatable(
		{ deps = deps, pending = {}, maxEncounterSeconds = deps.CaptureLogic.maxEncounterSeconds(deps.gd.capture) },
		CaptureService
	)
end

local function log(self: CaptureService, msg: string)
	local f = self.deps.log
	if f ~= nil then
		f(msg)
	end
end

function CaptureService.getPending(self: CaptureService, userId: number): Pending?
	return self.pending[userId]
end

local function before(self: CaptureService, userId: number, save: any, nowSec: number)
	local f = self.deps.beforeChange
	if f ~= nil then
		f(userId, save, nowSec)
	end
end

local function fail(self: CaptureService, code: string): any
	return { ok = false, code = self.deps.Net.ErrorCode[code] }
end

-- 同行 → pickAttacker の入力（活力は nowMin で遅延評価、uid は数値）。戻り値 (入力, 数値 uid → キー文字列)
-- 上限を超えて未来の vigor_min は今の分へ切り詰めて保存データにも書き戻す（回復が永久に止まらないように）
local function partyInputs(self: CaptureService, userId: number, save: any, nowSec: number): ({ any }, { [number]: string })
	local d = self.deps
	local nowMin = nowSec // 60
	local out = {}
	local keys: { [number]: string } = {}
	for _, key in save.party do
		local rec = save.roster[key]
		if rec ~= nil then
			local vm, bad = d.CaptureLogic.clampVigorMin(rec.vigor_min, nowSec, d.gd.capture)
			if bad then
				log(self, `[Capture] u_{userId} 정령 {key} vigor_min {rec.vigor_min} 이 미래 상한 초과 → {vm}`)
				rec.vigor_min = vm
			end
			local n = d.uidNum(key)
			keys[n] = key
			table.insert(out, {
				uid = n,
				grade = d.gd.spirits[rec.species].grade,
				level = rec.level,
				vigorTicks = d.CaptureLogic.vigorAt(rec.vigor_ticks, rec.vigor_min, nowMin, d.gd.capture),
			})
		end
	end
	return out, keys
end

-- 開始からの経過秒 elapsed までに時刻（at）が来たイベントを先頭から取り出す（渡した数 sent を進める）
local function takeDue(p: Pending, elapsed: number): { any }
	local out = {}
	while p.sent < #p.events and p.events[p.sent + 1].at <= elapsed do
		p.sent += 1
		table.insert(out, p.events[p.sent])
	end
	return out
end

-- 時刻の来たイベント（まだ渡していないもの）。サーバーの 1 秒ループが complete の前に呼び、EncounterEvent で送る。
-- 遭遇中でなければ空。状態は送信カーソルだけ変わる
function CaptureService.dueEvents(self: CaptureService, userId: number, nowSec: number): { any }
	local p = self.pending[userId]
	if p == nil then
		return {}
	end
	return takeDue(p, nowSec - p.startSec)
end

-- 灯籠を使う。戻り値 RemoteResult（data = { events = 時刻 0 のイベントだけ }。結果・実時間・終了時刻は入れない）
function CaptureService.engage(self: CaptureService, userId: number, save: any, wildId: any, distance: any, nowSec: number): any
	local d = self.deps
	local gd = d.gd
	local rule = gd.capture
	local CL = d.CaptureLogic
	if type(wildId) ~= "string" or type(distance) ~= "number" or distance ~= distance or distance < 0 or distance == math.huge then
		return fail(self, "BAD_ARG")
	end
	local wild = d.wild:get(userId)
	if wild == nil or wild.id ~= wildId then
		return fail(self, "NOT_FOUND")
	end
	if distance > d.radius then
		return fail(self, "TOO_FAR")
	end
	local wickCost = rule.attempt_cost[1]
	local wickMilli = save.wallet[wickCost.resource] or 0
	if wickMilli < wickCost.amount * 1000 then
		return fail(self, "NO_WICK")
	end
	if self.pending[userId] ~= nil or d.activity:get(userId) == "encounter" then
		return fail(self, "BUSY")
	end
	if d.RosterRules.isFull(gd, save) then
		return fail(self, "STORAGE_FULL")
	end
	local nowMin = nowSec // 60
	local field = gd.fields[wild.fieldId]
	local night = CL.isNight(nowMin, gd.rules.night)
	if #CL.captureTable(field, night) == 0 then
		-- 出現表が空（昼夜で表が変わった等）。副作用（精算・採集終了・乱数・野生の消費）の前に断る
		return fail(self, "NOT_FOUND")
	end

	before(self, userId, save, nowSec)
	if d.gather ~= nil and d.activity:get(userId) == "gather" then
		d.gather:stop(userId, save, nowSec)
	end
	local block = d.rng:block("capture", CL.blockSize(rule))
	local party, keyOf = partyInputs(self, userId, save, nowSec)
	local plan = CL.planEncounter({
		field = field,
		night = night,
		block = block,
		rule = rule,
		spirits = gd.spirits,
		party = party,
		wicksAvailable = wickMilli // 1000,
		captureBonusBps = CL.dexCaptureBps(save.dex, gd.spirits, gd.rules.dex_bonus),
	})
	if plan == nil then
		error("CaptureService: 출현 표를 확인한 뒤 종 추첨 실패") -- 上で空でないことを確かめているので起きない
	end
	d.wild:clear(userId)
	local res = plan.result
	if res.wicksUsed > 0 then
		local ok, err = d.ledger:spend(save.wallet, { { resource = wickCost.resource, amount = res.wicksUsed } })
		if not ok then
			error(`CaptureService: 심지 차감 실패 {tostring(err)}`) -- wicksAvailable の範囲で確定しているので起きない
		end
	end
	if plan.attackerUid ~= nil then
		local key = keyOf[plan.attackerUid]
		local rec = save.roster[key]
		local busyUntilMin = (nowSec + plan.durationSeconds) // 60
		rec.vigor_ticks, rec.vigor_min = CL.useVigor(rec.vigor_ticks, rec.vigor_min, nowMin, plan.vigorCostTicks, busyUntilMin, rule)
	end
	save.stats.encounters += 1
	save.stats.attempts += res.attempts
	save.next_spawn_at = nowSec + res.seconds
	local p: Pending = {
		plan = plan,
		fieldId = wild.fieldId,
		startSec = nowSec,
		endsAt = nowSec + plan.durationSeconds,
		events = CL.encounterEvents(plan, rule),
		sent = 0,
	}
	self.pending[userId] = p
	d.activity:set(userId, "encounter")
	return { ok = true, data = { events = takeDue(p, 0) } }
end

-- 遭遇の反映（atSec = 反映時刻）。戻り値 { result, species, uid?, gatherBps?, combatBps?, events = まだ渡していないイベント }
local function apply(self: CaptureService, userId: number, save: any, atSec: number): any
	local d = self.deps
	local p = self.pending[userId] :: Pending
	-- 図鑑が増えると放置生産が変わるので、反映の前に精算する
	before(self, userId, save, atSec)
	self.pending[userId] = nil
	d.activity:clear(userId, "encounter")
	local plan = p.plan
	local out: any = { result = plan.result.result, species = plan.species, events = takeDue(p, math.huge) }
	if plan.result.result == "success" then
		local ind = d.gd.rules.individual_stats
		-- sim と同じ順（採集 → 戦闘、独立な一様の整数 bps）
		local g = d.rng:intInclusive("individual", ind.gather_bps_min, ind.gather_bps_max)
		local c = d.rng:intInclusive("individual", ind.combat_bps_min, ind.combat_bps_max)
		local key = d.roster:addCaptured(save, plan.species, g, c, atSec)
		if save.first_capture[plan.species] == nil then
			save.first_capture[plan.species] = atSec
		end
		save.stats.captures += 1
		out.uid, out.gatherBps, out.combatBps = key, g, c
	end
	return out
end

-- 完了時刻を過ぎていれば反映する（サーバーのループが dueEvents の後に呼ぶ）。戻り値 反映結果 | nil
-- endsAt が上限（最長実時間）を超えて未来なら時計の巻き戻りとみなし、今の時刻で反映する（遭遇中のまま止まらないように）
function CaptureService.complete(self: CaptureService, userId: number, save: any, nowSec: number): any
	local p = self.pending[userId]
	if p == nil then
		return nil
	end
	local endsAt, bad = self.deps.CaptureLogic.clampFuture(p.endsAt, nowSec, self.maxEncounterSeconds)
	if bad then
		log(self, `[Capture] u_{userId} 조우 종료 시각 {p.endsAt} 이 미래 상한 초과 → {endsAt}에 반영`)
	elseif nowSec < endsAt then
		return nil
	end
	return apply(self, userId, save, endsAt)
end

-- 退出・サーバー終了: 途中でもすぐ確定・反映する。戻り値 反映結果 | nil
function CaptureService.finish(self: CaptureService, userId: number, save: any, nowSec: number): any
	local p = self.pending[userId]
	if p == nil then
		return nil
	end
	return apply(self, userId, save, math.min(nowSec, p.endsAt))
end

return CaptureService
