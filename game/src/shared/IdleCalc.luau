--!strict
-- IdleCalc: 放置生産の精算（IdleService の純粋な計算部）
-- 配置: ReplicatedStorage.Shared.IdleCalc（Rojo: game/src/shared/IdleCalc.luau）
-- 依存: Formulas（同じフォルダ）、Economy インスタンス（引数）。Roblox API 不使用（Lune でも動く）
-- サーバーの Services/IdleService（S4 以降）がこのモジュールを呼び、保存データの wallet・carry・settled_min を更新する。
--
-- sim.py _advance（:504-543）と同じ規則:
-- - オンライン中は [settled, now] をそのまま認定。オフラインは [settled, min(now, 退出 + 上限時間)] を認定し、超過は失効
-- - 認定区間を夜/昼境界（rules.night のゲーム内時計、UTC の通算分）で分け、区間ごとの生産率で accrue_milli（carry は資源別に持ち越す）
-- - 施設で働く精霊の固有狩り素材は milli/日 を divmod(per_day × 分 + carry, 1440) で積む（(資源, 等級) 別の carry）
-- - 図鑑ボーナス（2026-11-12 改編）は資源別: 施設はその生産資源の bps、家の素材はその狩り素材の bps（Economy.dexMap）
-- - 研究倍率は資源別 bps のフック（MVP1 は 0）。図鑑ボーナス込みの資源別合計に 1 回だけ掛ける
-- - 日境界での分割は行わない（carry 付き積算は区間を分けても合計が同じ。sim の日分割は日別集計のため）
-- - 同行と施設配置は排他（計画書 Q3 決定）なので、sim の exclude（同行中の除外）は扱わない
--
-- 帰還収穫の要約（2026-11-13 ユーザー決定、表示専用・経済影響 0）:
-- - settle(..., withBreakdown=true) のときだけ、実際の獲得量を (昼/夜, 資源) 別・家の素材の行別に result.parts へ記録する
--   （wallet・carry・gained・newSettledMin の計算は withBreakdown に関係なく同じ）
-- - spiritBreakdown が parts を精霊（uid）別に配る。returnReport が表示用の要約を組む
-- - 配分は精算と分けて呼ぶ（要約の失敗で精算を巻き戻さないため。IdleService が pcall で包む）

local Formulas = require("./Formulas")

local MINUTES_PER_DAY = Formulas.MINUTES_PER_DAY

local IdleCalc = {}

export type SpiritRec = {
	species: string,
	level: number,
	gather_bps: number,
	combat_bps: number,
}

export type FacilityRec = {
	level: number,
	assigned: { string }, -- roster の uid 文字列
}

export type SettleInput = {
	wallet: { [string]: number }, -- milli（更新される）
	carry: { [string]: number }, -- 端数（更新される）
	settledMin: number, -- 精算済みの時刻（分）
	offlineSinceMin: number?, -- オフラインなら退出時刻（分）。オンライン中は nil
	offlineCapHours: number,
	facilities: { [string]: FacilityRec },
	roster: { [string]: SpiritRec },
	dex: { [string]: any }, -- 図鑑（save.dex = { [種] = 初登録時刻 }、開始精霊を含む）
	researchIdleBps: { [string]: number }?, -- 資源別の研究倍率（MVP1 は nil = 0）
}

export type SettleResult = {
	fromMin: number,
	toMin: number, -- 認定区間の終わり
	creditedMinutes: number,
	lostMinutes: number, -- オフライン上限を超えて失効した分
	gained: { [string]: number }, -- 資源別の獲得 milli
	newSettledMin: number,
	parts: SettleParts?, -- withBreakdown=true のときだけ（精霊別配分の元データ）
}

-- 精霊別配分の元データ（実際の獲得 milli。昼夜それぞれの区間を合計した値）
export type SettleParts = {
	idle: { [boolean]: { [string]: number } }, -- [夜か] = { [資源] = milli }
	home: { [string]: { resource: string, grade: number, milli: number } }, -- [homeCarryKey] = 行
}

-- 精霊 uid → { [資源] = milli }
export type SpiritBreakdown = { [string]: { [string]: number } }

export type ReturnReportSpirit = {
	uid: string,
	species: string,
	resources: { [string]: number }, -- milli（0 の資源は入れない）
	total: number, -- 並べ替え用の資源合計 milli（資源の種類をまたいだ単純合計）
}

export type ReturnReport = {
	show: boolean, -- 帰還画面に出すか（オフライン経過 >= minOfflineMinutes）
	offlineMinutes: number, -- オフライン経過（分）= (今 − last_online_at) // 60
	creditedMinutes: number,
	lostMinutes: number, -- 上限超過で失効した分（表示用）
	offlineCapHours: number,
	gained: { [string]: number }, -- 資源別 milli（精算結果の写し）
	spirits: { ReturnReportSpirit }, -- 寄与の大きい順（total 降順、同点は uid 昇順）。寄与 0 の精霊は入れない
}

-- carry のキー（保存スキーマ carry={[key]=int}）
function IdleCalc.idleCarryKey(res: string): string
	return "idle:" .. res
end

function IdleCalc.homeCarryKey(res: string, grade: number): string
	return `home:g{grade}:{res}`
end

-- 認定区間。戻り値 (from, to, lost)。now < settled（サーバー間の時計差）なら何も認定しない
function IdleCalc.creditRange(settledMin: number, nowMin: number, offlineSinceMin: number?, capHours: number): (number, number, number)
	Formulas.assertSafe(settledMin, nowMin, capHours)
	if nowMin <= settledMin then
		return settledMin, settledMin, 0
	end
	if offlineSinceMin == nil then
		return settledMin, nowMin, 0
	end
	Formulas.assertSafe(offlineSinceMin)
	local capEnd = offlineSinceMin + capHours * 60
	local toMin = math.max(settledMin, math.min(nowMin, capEnd))
	local lost = if nowMin > capEnd then nowMin - math.max(settledMin, capEnd) else 0
	return settledMin, toMin, lost
end

-- 施設で働く精霊（Economy.Member の配列）
local function facilityMembers(input: SettleInput, fac: FacilityRec): { any }
	local members = {}
	for _, uid in fac.assigned do
		local s = input.roster[uid]
		if s == nil then
			error(`IdleCalc: 배치된 정령이 보관함에 없음 uid={uid}`)
		end
		table.insert(members, { species = s.species, level = s.level, gatherBps = s.gather_bps, combatBps = s.combat_bps })
	end
	return members
end

-- 資源別の放置生産率（milli/時）。研究倍率を資源別合計に 1 回だけ掛ける（sim.py idle_rates）
function IdleCalc.idleRates(econ: any, input: SettleInput, night: boolean): { [string]: number }
	local gd = econ.gd
	local dexRes = econ:dexMap(input.dex).resource_output
	local rates: { [string]: number } = {}
	for _, fid in gd.facilityOrder do
		local fac = input.facilities[fid]
		if fac ~= nil then
			local res = gd.facilities[fid].produces
			local r = econ:facilityRate(fid, fac.level, facilityMembers(input, fac), night, dexRes[res] or 0)
			rates[res] = (rates[res] or 0) + r
		end
	end
	local research = input.researchIdleBps
	if research ~= nil then
		for res, v in rates do
			rates[res] = Formulas.researchScaledMilli(v, research[res] or 0)
		end
	end
	return rates
end

-- 施設で働く全精霊の固有狩り素材（(資源, 等級) 別の milli/日）
function IdleCalc.homeDetail(econ: any, input: SettleInput): { any }
	local members = {}
	for _, fid in econ.gd.facilityOrder do
		local fac = input.facilities[fid]
		if fac ~= nil then
			for _, m in facilityMembers(input, fac) do
				table.insert(members, m)
			end
		end
	end
	return econ:homeMaterialDetail(members, econ:dexMap(input.dex).resource_output)
end

local function addGain(input: SettleInput, gained: { [string]: number }, res: string, milli: number)
	if milli > 0 then
		local total = (input.wallet[res] or 0) + milli
		Formulas.assertSafe(total)
		input.wallet[res] = total
		gained[res] = (gained[res] or 0) + milli
	end
end

-- 精算: nowMin まで進め、input.wallet・input.carry を更新して結果を返す（呼び出し側は settledMin を newSettledMin に更新する）
-- withBreakdown=true なら result.parts に配分の元データを記録する（帰還要約用。通常の精算では渡さない）
function IdleCalc.settle(econ: any, input: SettleInput, nowMin: number, withBreakdown: boolean?): SettleResult
	local fromMin, toMin, lost = IdleCalc.creditRange(input.settledMin, nowMin, input.offlineSinceMin, input.offlineCapHours)
	local gained: { [string]: number } = {}
	local parts: SettleParts? = if withBreakdown then { idle = { [true] = {}, [false] = {} }, home = {} } else nil
	if toMin > fromMin then
		local night = econ.gd.rules.night
		local home = IdleCalc.homeDetail(econ, input)
		local rateCache: { [boolean]: { [string]: number } } = {}
		for _, seg in Formulas.nightSegments(fromMin, toMin, night.cycle_minutes, night.night_start_offset_minutes, night.night_minutes) do
			local s, e, isNight = seg[1] :: number, seg[2] :: number, seg[3] :: boolean
			local mins = e - s
			local rates = rateCache[isNight]
			if rates == nil then
				rates = IdleCalc.idleRates(econ, input, isNight)
				rateCache[isNight] = rates
			end
			for res, rate in rates :: { [string]: number } do
				local key = IdleCalc.idleCarryKey(res)
				local g, c = Formulas.accrueMilli(rate, mins, input.carry[key] or 0)
				input.carry[key] = c
				addGain(input, gained, res, g)
				if parts ~= nil and g > 0 then
					local ph = parts.idle[isNight]
					ph[res] = (ph[res] or 0) + g
				end
			end
			for _, row in home do
				local key = IdleCalc.homeCarryKey(row.resource, row.grade)
				local total = row.milli * mins + (input.carry[key] or 0)
				Formulas.assertSafe(total)
				local g = Formulas.idiv(total, MINUTES_PER_DAY)
				input.carry[key] = total - g * MINUTES_PER_DAY
				addGain(input, gained, row.resource, g)
				if parts ~= nil and g > 0 then
					local hr = parts.home[key]
					if hr == nil then
						hr = { resource = row.resource, grade = row.grade, milli = 0 }
						parts.home[key] = hr
					end
					hr.milli += g
				end
			end
		end
	end
	return {
		fromMin = fromMin,
		toMin = toMin,
		creditedMinutes = toMin - fromMin,
		lostMinutes = lost,
		gained = gained,
		newSettledMin = math.max(input.settledMin, nowMin),
		parts = parts,
	}
end

-- ---- 帰還収穫の要約（表示専用） ----

-- uid の並び順: 10 進の正整数文字列（保存の roster キー）は数値順で先、それ以外は文字列順で後（全順序）
function IdleCalc.uidLess(a: string, b: string): boolean
	local da = string.match(a, "^[1-9]%d*$") ~= nil
	local db = string.match(b, "^[1-9]%d*$") ~= nil
	if da ~= db then
		return da
	end
	if da and #a ~= #b then
		return #a < #b
	end
	return a < b
end

-- 最大剰余法: total を weights の比で整数に配る（合計 = total ちょうど）。
-- 端数の +1 は剰余の大きい順、同点は添字の小さい順（呼び出し側が uid 昇順などに並べて渡す）。
-- 重み 0 の項目には配らない（剰余の合計 = 残り × 重み合計 で、剰余 > 0 の項目数は残りより多い）
function IdleCalc.apportion(total: number, weights: { number }): { number }
	local out = table.create(#weights, 0)
	if total == 0 then
		return out
	end
	if total < 0 then
		error(`IdleCalc.apportion: 음수 total {total}`)
	end
	local sum = 0
	for _, w in weights do
		if w < 0 then
			error(`IdleCalc.apportion: 음수 가중치 {w}`)
		end
		sum += w
	end
	Formulas.assertSafe(sum)
	if sum == 0 then
		error(`IdleCalc.apportion: 가중치 합 0인데 배분량 {total}`)
	end
	local rems = table.create(#weights, 0)
	local given = 0
	for i, w in weights do
		local x = total * w
		Formulas.assertSafe(x)
		local q = Formulas.idiv(x, sum)
		out[i] = q
		rems[i] = x - q * sum
		given += q
	end
	local left = total - given
	if left > 0 then
		local idx = table.create(#weights, 0)
		for i in weights do
			idx[i] = i
		end
		table.sort(idx, function(i: number, j: number): boolean
			if rems[i] ~= rems[j] then
				return rems[i] > rems[j]
			end
			return i < j
		end)
		for k = 1, left do
			out[idx[k]] += 1
		end
	end
	return out
end

local function addTo(out: SpiritBreakdown, uid: string, res: string, milli: number)
	if milli > 0 then
		local m = out[uid]
		if m == nil then
			m = {}
			out[uid] = m
		end
		m[res] = (m[res] or 0) + milli
	end
end

local function sortedUids(list: { string }): { string }
	local u = table.clone(list)
	table.sort(u, IdleCalc.uidLess)
	return u
end

-- settle(..., true) の parts を精霊別に配る（純粋関数。input は settle に渡したものと同じ配置・保管箱・図鑑）。
-- 施設の放置生産（(昼/夜, 資源) ごと）:
--   1 段目: その資源を作る施設どうしで、施設の生産率（混合・図鑑込み、Economy.facilityRate）の比で配る（同点は facilityOrder 順）
--   2 段目: 施設の取り分を、配置精霊の枠寄与（Economy.slotPower、夜は夜特性込み）の比で配る（同点は uid 昇順）
--   施設の生産率は Formulas.idleRateMilliPerHour で枠寄与の合計に比例し、混合・図鑑は施設単位の共通倍率なので
--   精霊 i の取り分 ∝ 施設の率 × power_i / Σpower。研究倍率は資源単位の共通倍率なので比に影響しない（ここでは見ない）。
--   夜特性で power が昼夜で変わるため、昼と夜は別々に配る。同じ (昼/夜, 資源) の区間は重みが同じなので合計してから配る
--   （区間ごとに配るより端数の誤差が小さい。合計は gained と一致）。
-- 家の素材（(資源, 等級) の行ごと）: 精霊ごとの milli/日（個体値込み、図鑑前）の比で配る（図鑑は行単位の共通倍率）。同点は uid 昇順。
-- 戻り値の資源別合計は result.gained と一致する（各段の配分が合計を保つ）
function IdleCalc.spiritBreakdown(econ: any, input: SettleInput, parts: SettleParts): SpiritBreakdown
	local gd = econ.gd
	local out: SpiritBreakdown = {}
	local dexRes = econ:dexMap(input.dex).resource_output
	for _, isNight in { false, true } do
		for res, g in parts.idle[isNight] do
			if g > 0 then
				-- 1 段目: この資源を作る施設（facilityOrder 順）
				local fids: { string } = {}
				local facW: { number } = {}
				for _, fid in gd.facilityOrder do
					local fac = input.facilities[fid]
					if fac ~= nil and gd.facilities[fid].produces == res then
						table.insert(fids, fid)
						table.insert(facW, econ:facilityRate(fid, fac.level, facilityMembers(input, fac), isNight, dexRes[res] or 0))
					end
				end
				local facShare = IdleCalc.apportion(g, facW)
				-- 2 段目: 施設の中で枠寄与の比
				for fi, fid in fids do
					local share = facShare[fi]
					if share > 0 then
						local fac = input.facilities[fid]
						local uids = sortedUids(fac.assigned)
						local w: { number } = {}
						for _, uid in uids do
							local sp = input.roster[uid]
							if sp == nil then
								error(`IdleCalc: 배치된 정령이 보관함에 없음 uid={uid}`)
							end
							table.insert(w, econ:slotPower(sp.species, sp.level, res, isNight, sp.gather_bps))
						end
						for i, v in IdleCalc.apportion(share, w) do
							addTo(out, uids[i], res, v)
						end
					end
				end
			end
		end
	end
	-- 家の素材: 施設で働く全精霊（uid 昇順）の行ごとの milli/日
	local all: { string } = {}
	for _, fid in gd.facilityOrder do
		local fac = input.facilities[fid]
		if fac ~= nil then
			for _, uid in fac.assigned do
				table.insert(all, uid)
			end
		end
	end
	all = sortedUids(all)
	for key, row in parts.home do
		if row.milli > 0 then
			local uids: { string } = {}
			local w: { number } = {}
			for _, uid in all do
				local sp = input.roster[uid]
				if sp == nil then
					error(`IdleCalc: 배치된 정령이 보관함에 없음 uid={uid}`)
				end
				local m = { species = sp.species, level = sp.level, gatherBps = sp.gather_bps, combatBps = sp.combat_bps }
				local one = econ:homeMaterialDetail({ m }, nil) -- 図鑑前の 1 体分
				local r1 = one[1]
				if r1 ~= nil and IdleCalc.homeCarryKey(r1.resource, r1.grade) == key then
					table.insert(uids, uid)
					table.insert(w, r1.milli)
				end
			end
			for i, v in IdleCalc.apportion(row.milli, w) do
				addTo(out, uids[i], row.resource, v)
			end
		end
	end
	return out
end

-- 帰還収穫の要約を組む（純粋関数）。
-- show の基準は「オフライン経過時間」= (読み込み時のゲーム時刻 − last_online_at) を分に切り捨てた値 >= minOfflineMinutes
-- （2026-11-13 ユーザー決定「オフライン 1 時間以上」。認定分 + 失効分ではない: settled_min が last_online_at より前後しても経過で判定する）
function IdleCalc.returnReport(
	roster: { [string]: SpiritRec },
	result: SettleResult,
	bySpirit: SpiritBreakdown,
	offlineMinutes: number,
	minOfflineMinutes: number,
	offlineCapHours: number
): ReturnReport
	local spirits: { ReturnReportSpirit } = {}
	for uid, resMap in bySpirit do
		local total = 0
		local resources: { [string]: number } = {}
		for res, v in resMap do
			if v > 0 then
				resources[res] = v
				total += v
			end
		end
		if total > 0 then
			local sp = roster[uid]
			table.insert(spirits, {
				uid = uid,
				species = if sp ~= nil then sp.species else "",
				resources = resources,
				total = total,
			})
		end
	end
	table.sort(spirits, function(a: ReturnReportSpirit, b: ReturnReportSpirit): boolean
		if a.total ~= b.total then
			return a.total > b.total
		end
		return IdleCalc.uidLess(a.uid, b.uid)
	end)
	local off = math.max(0, offlineMinutes)
	return {
		show = off >= minOfflineMinutes,
		offlineMinutes = off,
		creditedMinutes = result.creditedMinutes,
		lostMinutes = result.lostMinutes,
		offlineCapHours = offlineCapHours,
		gained = table.clone(result.gained),
		spirits = spirits,
	}
end

return table.freeze(IdleCalc)
