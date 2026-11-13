--!strict
-- CaptureLogic: 簡易モード捕獲の純粋ロジック（自動攻撃者の選択・活力の遅延評価・種の抽選・遭遇結果の確定）
-- 配置: ReplicatedStorage.Shared.CaptureLogic（Rojo: game/src/shared/CaptureLogic.luau）
-- 依存: Formulas（同じフォルダ）。Roblox API 不使用（乱数ブロックは呼び出し側 ServerRng が作って渡す）
-- S7 で遭遇の計画（planEncounter）・再生イベント列（encounterEvents）・夜判定（isNight）を追加。状態の変更は
-- ServerScriptService.Server.Services.CaptureService が行う。
--
-- sim.py との対応: pick_attacker（:774-806）、vigor_at / use_vigor（:721-741）、_start_encounter の種抽選と
-- resolve（:283-312）。活力は整数 tick（1 点 = 60 tick、sim.py:26 VIGOR_TICK）、時刻は分（os.time() // 60）。
-- 乱数ブロック = 1 + 2·K_max 個の一様 [0,1)：block[1] が種、block[2..] が resolve の uniforms（sim.py:288-312）。

local Formulas = require("./Formulas")

local CaptureLogic = {}

CaptureLogic.VIGOR_TICK = 60

export type AttackerInput = {
	uid: number, -- 同点時の最終キー（sim と同じく数値で比較する。保存の文字列 uid は tonumber して渡す）
	grade: number,
	level: number,
	vigorTicks: number, -- 遭遇開始時刻で評価済みの活力（vigorAt の結果）
}

type Key = { number }

-- 辞書式比較 a < b（sim の tuple 比較）
local function keyLess(a: Key, b: Key): boolean
	for i = 1, #a do
		if a[i] ~= b[i] then
			return a[i] < b[i]
		end
	end
	return false
end

-- 簡易モードの自動攻撃者。戻り値 (uid | nil = 灯籠の補助弱体化, 秒, 活力消費 tick)
-- 候補: 活力 > vigor_above かつ 秒 ≤ max_seconds → (活力消費, 秒, −活力, uid) の最小。
-- 候補なし → 行動可能（活力 > 0）な同行の (秒, 消費, −活力, uid) 最小。それが assist_seconds より速くなければ灯籠
function CaptureLogic.pickAttacker(party: { AttackerInput }, targetGrade: number, rule: any): (number?, number, number)
	local VT = CaptureLogic.VIGOR_TICK
	local wk = rule.weaken
	local aa = wk.auto_attacker
	local bestKey: Key? = nil
	local best: AttackerInput? = nil
	local bestSec, bestCost = 0, 0
	local fbKey: Key? = nil
	local fb: AttackerInput? = nil
	local fbSec, fbCost = 0, 0
	for _, a in party do
		-- uid が数値でないとタプル比較の最終キーが消え、順序依存になる（レビュー Minor 3）
		assert(type(a.uid) == "number", "pickAttacker: uid は数値であること")
		local v = a.vigorTicks
		if v <= 0 then
			continue
		end
		local sec = Formulas.weakenSecondsTicks(a.grade, a.level, targetGrade, v, VT, rule)
		if sec < 0 then
			continue
		end
		local cost = Formulas.weakenVigorCost(a.grade, targetGrade, rule) * VT
		if v > aa.vigor_above * VT and sec <= aa.max_seconds then
			local key = { cost, sec, -v, a.uid }
			if bestKey == nil or keyLess(key, bestKey) then
				bestKey, best, bestSec, bestCost = key, a, sec, cost
			end
		end
		local key2 = { sec, cost, -v, a.uid }
		if fbKey == nil or keyLess(key2, fbKey) then
			fbKey, fb, fbSec, fbCost = key2, a, sec, cost
		end
	end
	if best ~= nil then
		return best.uid, bestSec, bestCost
	end
	if fb ~= nil and fbSec < wk.assist_seconds then
		return fb.uid, fbSec, fbCost
	end
	return nil, wk.assist_seconds, 0
end

-- ---- 活力（整数 tick、分単位で遅延評価） ----

-- 時刻 tMin の活力（tick）。最後の更新 vigorMin 以降の非活動時間ぶん回復（上限 max）。状態は変えない
function CaptureLogic.vigorAt(vigorTicks: number, vigorMin: number, tMin: number, rule: any): number
	local VT = CaptureLogic.VIGOR_TICK
	local vg = rule.vigor
	local maxTicks = vg.max * VT
	local recPerMin = Formulas.idiv(vg.rest_recovery_per_hour * VT, 60)
	if tMin > vigorMin then
		return math.min(maxTicks, vigorTicks + recPerMin * (tMin - vigorMin))
	end
	return vigorTicks
end

-- tMin 時点で ticks を消費し、busyUntilMin までは回復しない。戻り値 (新しい tick, 新しい基準分)（sim.py use_vigor）
function CaptureLogic.useVigor(vigorTicks: number, vigorMin: number, tMin: number, ticks: number, busyUntilMin: number, rule: any): (number, number)
	local v = CaptureLogic.vigorAt(vigorTicks, vigorMin, tMin, rule)
	local vt = math.max(vigorMin, tMin)
	return math.max(0, v - ticks), math.max(vt, busyUntilMin)
end

-- ---- 遭遇 ----

-- 1 遭遇で引く一様乱数の個数 = 1（種）+ 2·K_max（試行成功・逃走）
function CaptureLogic.blockSize(rule: any): number
	return 1 + 2 * Formulas.captureKMax(rule)
end

-- その時点の出現表（weight > 0、always か夜の night_only。event は MVP1 では扱わない）
function CaptureLogic.captureTable(field: any, night: boolean): { any }
	local out = {}
	for _, e in field.capture.table do
		if e.weight > 0 and (e.availability == "always" or (night and e.availability == "night_only")) then
			table.insert(out, e)
		end
	end
	return out
end

-- 種の抽選（sim.py:289-295）: x = u × Σweight を先頭から weight で削り、x < weight の種。端数は末尾
function CaptureLogic.pickSpecies(captureTable: { any }, u: number): string?
	local wsum = 0
	for _, e in captureTable do
		wsum += e.weight
	end
	if wsum <= 0 then
		return nil
	end
	local x = u * wsum
	for _, e in captureTable do
		if x < e.weight then
			return e.spirit_id
		end
		x -= e.weight
	end
	return captureTable[#captureTable].spirit_id
end

-- 遭遇の結果を開始時に確定する（道具なし = resolveEncounterTool(..., 0)）。block は 1 + 2·K_max 個の全体。
-- captureBonusBps（省略 = 0）は図鑑の捕獲確率ボーナス（2026-11-12 決定、dexCaptureBps の値）
function CaptureLogic.resolveEasy(
	grade: number,
	rule: any,
	block: { number },
	wicksAvailable: number,
	weakenS: number,
	captureBonusBps: number?
): Formulas.EncounterResult
	local need = CaptureLogic.blockSize(rule)
	if #block < need then
		error(`CaptureLogic: 난수 블록은 {need}개 필요(받은 수 {#block})`)
	end
	local uniforms = table.move(block, 2, need, 1, {})
	return Formulas.resolveEncounterTool(grade, rule, uniforms, wicksAvailable, weakenS, 0, captureBonusBps)
end

-- 図鑑（save.dex = { [種] = 初登録時刻 }）の捕獲確率ボーナス（bps）。遭遇開始時点の図鑑で決める（sim._start_encounter と同じ）。
-- 「成功率は等級別固定」原則の 2 つ目の例外（1 つ目は捕獲補助道具）。精霊は販売しないので有料の経路はない
function CaptureLogic.dexCaptureBps(dexSet: { [string]: any }, spirits: { [string]: any }, dexRule: any): number
	return Formulas.dexBonusMapForSet(dexSet, spirits, dexRule).capture_attempt_up
end

-- 試行の成功率（bps、表示用の最終値）: 等級 × 光の区間（簡易モードの試行の光）→ 図鑑の捕獲確率ボーナス
function CaptureLogic.attemptBps(grade: number, rule: any, captureBonusBps: number?): number
	local light = Formulas.easyAttemptLight(grade, rule)
	return Formulas.captureBonusAttemptBps(Formulas.captureAttemptBps(grade, light, rule), captureBonusBps or 0)
end

-- ---- 遭遇の計画（S7、計画書 4.3「조우(간편 모드)」2〜5） ----

-- ゲーム内時計の夜判定（rules.night、UTC 通算分）。IdleCalc・sim.is_night と同じ nightSegments の 1 分区間
function CaptureLogic.isNight(nowMin: number, night: any): boolean
	local seg = Formulas.nightSegments(nowMin, nowMin + 1, night.cycle_minutes, night.night_start_offset_minutes, night.night_minutes)
	return seg[1][3] :: boolean
end

export type EncounterPlan = {
	species: string,
	grade: number,
	weakened: boolean, -- 弱体化した（★1 など成功率が上がらない等級は false）
	attackerUid: number?, -- 弱体化した同行の uid（nil で weakened = 灯籠の補助弱体化）
	weakenSeconds: number,
	vigorCostTicks: number, -- 攻撃者の活力消費（tick）。灯籠・弱体化なしは 0
	captureBonusBps: number, -- 図鑑の捕獲確率ボーナス（結果の確定と表示の bps に使った値）
	result: Formulas.EncounterResult,
	durationSeconds: number, -- 実時間 = 弱体化秒 + 試行秒 × 試行数（基本 60 秒は探索時間 = 次の出現待ちに使う）
}

export type PlanInput = {
	field: any, -- fields.json の 1 フィールド
	night: boolean, -- 遭遇開始時刻の夜判定
	block: { number }, -- 1 + 2·K_max 個の一様 [0,1)（block[1] = 種、block[2..] = resolve の uniforms）
	rule: any, -- capture.json
	spirits: { [string]: any }, -- gd.spirits
	party: { AttackerInput }, -- 同行（活力は開始時刻で評価済み）
	wicksAvailable: number, -- 芯の個数（milli ではない）
	captureBonusBps: number?, -- 図鑑の捕獲確率ボーナス（dexCaptureBps、省略 = 0）
}

-- 遭遇開始時に種・攻撃者・結果をすべて確定する（sim.py _start_encounter と同じ順）。出現表が空なら nil
function CaptureLogic.planEncounter(input: PlanInput): EncounterPlan?
	local rule = input.rule
	local need = CaptureLogic.blockSize(rule)
	if #input.block < need then
		error(`CaptureLogic: 난수 블록은 {need}개 필요(받은 수 {#input.block})`)
	end
	local species = CaptureLogic.pickSpecies(CaptureLogic.captureTable(input.field, input.night), input.block[1])
	if species == nil then
		return nil
	end
	local sp = input.spirits[species]
	if sp == nil then
		error(`CaptureLogic: 출현 표의 종이 data에 없음 '{species}'`)
	end
	local grade = sp.grade
	local weakened = Formulas.weakenNeeded(grade, rule)
	local attacker: number? = nil
	local wsec, cost = 0, 0
	if weakened then
		attacker, wsec, cost = CaptureLogic.pickAttacker(input.party, grade, rule)
	end
	local bonus = input.captureBonusBps or 0
	local res = CaptureLogic.resolveEasy(grade, rule, input.block, input.wicksAvailable, wsec, bonus)
	return {
		species = species,
		grade = grade,
		weakened = weakened,
		attackerUid = attacker,
		weakenSeconds = wsec,
		vigorCostTicks = cost,
		captureBonusBps = bonus,
		result = res,
		durationSeconds = wsec + rule.time.attempt_seconds * res.attempts,
	}
end

-- クライアントへ再生させるイベント列（サーバー → クライアント EncounterEvent）。at = 遭遇開始からの秒。
-- 順: reveal（種の公開、Q2 決定: 灯籠を使ったときに公開）→ weaken（弱体化するときだけ）→ attempt i（試行間隔ごと）→ result。
-- attempt の bps = その試行の成功率（図鑑の捕獲確率ボーナス込みの最終値、2026-11-12 決定）、fleeBps = その試行が失敗したときの
-- 逃走確率（確率表の常時公開、決定 I1）。
-- 乱数ブロックはクライアントへ送らない（ここにも入れない）。
function CaptureLogic.encounterEvents(plan: EncounterPlan, rule: any): { any }
	local step = rule.time.attempt_seconds
	local light = Formulas.easyAttemptLight(plan.grade, rule)
	local bps = CaptureLogic.attemptBps(plan.grade, rule, plan.captureBonusBps)
	local ev: { any } = {
		{ phase = "reveal", at = 0, species = plan.species, grade = plan.grade },
	}
	if plan.weakened then
		table.insert(ev, {
			phase = "weaken",
			at = 0,
			seconds = plan.weakenSeconds,
			assist = plan.attackerUid == nil, -- 灯籠の補助弱体化
		})
	end
	local w = plan.weakenSeconds
	for i = 1, plan.result.attempts do
		table.insert(ev, {
			phase = "attempt",
			at = w + step * (i - 1),
			attempt = i,
			light = light,
			bps = bps,
			fleeBps = Formulas.fleeBps(i, rule),
		})
	end
	table.insert(ev, {
		phase = "result",
		at = w + step * plan.result.attempts,
		attempt = plan.result.attempts,
		result = plan.result.result,
	})
	return ev
end

-- ---- 未来の時刻の上限（2026-11-12 決定: 上限を超えて未来なら壊れた値として今へ切り詰める。S4 の未来 locked_at と同じ考え方） ----
-- 上限は data から計算する: 1 遭遇の最長実時間 = 弱体化の最長 + 試行秒 × K_max。
-- 弱体化の最長 = max(weaken.max_seconds（weakenSecondsTicks の上限 clamp）, weaken.assist_seconds（灯籠の補助）)。
-- 正しく書かれた値は次を超えない（遭遇開始時刻 ≤ 今 なので）:
--   next_spawn_at ≤ 今 + encounter_base_seconds + 最長実時間（CaptureService が 開始 + res.seconds を書く）
--   vigor_min ≤ (今 + 最長実時間) // 60（useVigor の busyUntilMin = (開始 + 実時間) // 60）
--   pending.endsAt ≤ 今 + 最長実時間
-- 超えるのは保存の破損か、ゲーム時計の巻き戻り（Studio のオフセット戻し・サーバー間の大きな時計差）だけ。

function CaptureLogic.maxEncounterSeconds(rule: any): number
	local wk = rule.weaken
	return math.max(wk.max_seconds, wk.assist_seconds) + rule.time.attempt_seconds * Formulas.captureKMax(rule)
end

function CaptureLogic.maxSpawnAheadSeconds(rule: any): number
	return rule.time.encounter_base_seconds + CaptureLogic.maxEncounterSeconds(rule)
end

-- value が now + maxAhead を超えて未来なら now を返す。戻り値 (値, 切り詰めたか)。上限ちょうどは正しい値として残す
function CaptureLogic.clampFuture(value: number, now: number, maxAhead: number): (number, boolean)
	if value - now > maxAhead then
		return now, true
	end
	return value, false
end

-- 活力の基準分 vigor_min（分）の切り詰め。nowSec は秒。戻り値 (分, 切り詰めたか)
function CaptureLogic.clampVigorMin(vigorMin: number, nowSec: number, rule: any): (number, boolean)
	local nowMin = nowSec // 60
	return CaptureLogic.clampFuture(vigorMin, nowMin, (nowSec + CaptureLogic.maxEncounterSeconds(rule)) // 60 - nowMin)
end

return table.freeze(CaptureLogic)
