--!strict
-- SnapshotSpec: 保存データ + 計算値 → クライアント用の状態（保存データ不変・精算プレビュー・生産率・隠す情報・帰還要約の出し分け）
-- 配置: ServerStorage.Tests.SnapshotSpec（Rojo: game/tests/SnapshotSpec.luau）
-- 依存: deps.Snapshot・deps.IdleService・deps.IdleCalc・deps.CaptureLogic・deps.RosterRules・deps.QuestRules・deps.FacilityRules・
--   deps.econ・deps.gd・deps.SaveSchema・deps.Config・deps.Formulas・deps.TestKit
-- 期待値の出典（IdleServiceSpec と同じ Python 由来の値、cwd tools/econ_sim の python3 -c、シミュ実行なし）:
--   開始 3 種を dew_spring に配置 → Economy.facility_rate = 63516 milli/時、家の素材 hunt_meadow ★1 500/日 × 3 = 1500 milli/日。
--   オンライン 13 時間（780 分、上限なし）: accrue_milli(63516, 780, 0) = 825708、divmod(1500 × 780, 1440) = 812。
--   夜の効果は data で 0。meadow の施設上限 Lv10（facilities.json level_cap_by_field）、保管箱 100（hub.json）、
--   活力 max 100・休息回復 20/時（capture.json vigor）

local T = 1762819200 -- 秒（60 の倍数、UTC 日の途中）

return {
	name = "Snapshot",
	run = function(t: any, deps: any)
		local S = deps.Snapshot
		local ctx = {
			gd = deps.gd,
			econ = deps.econ,
			IdleService = deps.IdleService,
			IdleCalc = deps.IdleCalc,
			CaptureLogic = deps.CaptureLogic,
			RosterRules = deps.RosterRules,
			QuestRules = deps.QuestRules,
			FacilityRules = deps.FacilityRules,
		}
		local newCtx = {
			gd = deps.gd,
			startSpirits = deps.Config.START_SPIRITS,
			milli = deps.Formulas.MILLI,
			vigorTick = deps.CaptureLogic.VIGOR_TICK,
		}
		local function placed(): any
			local s = deps.SaveSchema.newSave(newCtx, T)
			s.facilities.dew_spring.assigned = { "1", "2", "3" }
			return s
		end

		t:test("저장 데이터를 바꾸지 않음(정산은 사본 미리보기)", function()
			local s = placed()
			local before = deps.TestKit.deepCopy(s)
			local snap = S.build(ctx, s, T + 13 * 3600, { seq = 1 })
			t:eq(s, before)
			snap.wallet.dew = 0
			snap.facilities.dew_spring.assigned[1] = "9"
			snap.party[1] = "x"
			t:eq(s, before, "스냅샷 수정이 저장 데이터에 번지지 않음")
		end)

		t:test("지갑 = 지금 분까지의 온라인 정산 미리보기(milli), walletAt = 분의 시작", function()
			local s = placed()
			local snap = S.build(ctx, s, T + 13 * 3600 + 59, { seq = 1 })
			t:eq(snap.wallet, { wick = 21000, dew = 825708, hunt_meadow = 812 })
			t:eq(snap.walletAt, T + 13 * 3600)
			t:eq(snap.serverNow, T + 13 * 3600 + 59)
		end)

		t:test("생산률: 자원별 milli/시·집 재료 milli/일, 시설별 합 = 자원별", function()
			local s = placed()
			local snap = S.build(ctx, s, T + 600, { seq = 1 })
			t:eq(snap.idle.perHour.dew, 63516)
			t:eq(snap.idle.perHour.bloom, 0)
			t:eq(snap.idle.homePerDay, { hunt_meadow = 1500 })
			t:eq(snap.idle.night, deps.CaptureLogic.isNight((T + 600) // 60, deps.gd.rules.night))
			local f = snap.facilities.dew_spring
			t:eq(f.level, 1)
			t:eq(f.slots, s.facilities.dew_spring.slots)
			t:eq(f.assigned, { "1", "2", "3" })
			t:eq(f.produces, "dew")
			t:eq(f.ratePerHour, 63516)
			t:eq(f.levelCap, 10)
			local sum: { [string]: number } = {}
			for _, fac in snap.facilities do
				sum[fac.produces] = (sum[fac.produces] or 0) + fac.ratePerHour
			end
			t:eq(sum, snap.idle.perHour)
		end)

		t:test("정령·동행·도감·보관함·해금", function()
			local s = placed()
			s.roster["1"].vigor_ticks = 0
			s.roster["1"].vigor_min = T // 60
			local snap = S.build(ctx, s, T + 3600, { seq = 1 })
			t:eq(snap.roster["1"].vigor, 20, "1시간 휴식 회복 20")
			t:eq(snap.roster["2"].vigor, 100)
			t:eq(snap.vigorMax, 100)
			t:eq(snap.roster["1"].species, "sparkle")
			t:eq(snap.roster["1"].gatherBps, deps.gd.rules.individual_stats.start_spirit_bps)
			t:eq(snap.roster["1"].origin, "start")
			t:eq(snap.roster["1"].caughtAt, T)
			t:eq(snap.party, {})
			t:eq(snap.dex, { sparkle = T, dewdrop = T, flower_lamp = T })
			t:eq(snap.storage, { count = 3, capacity = 100 })
			t:eq(snap.unlocked, { "meadow" })
			t:eq(snap.toolLevel, 1)
		end)

		t:test("일일: 오늘 받음 여부와 다음 UTC 0시", function()
			local s = placed()
			local day = (T + 100) // 86400
			local snap = S.build(ctx, s, T + 100, { seq = 1 })
			t:eq(snap.daily, { claimed = false, day = day, nextResetAt = (day + 1) * 86400 })
			s.quest_day = day
			t:eq(S.build(ctx, s, T + 100, { seq = 2 }).daily.claimed, true)
		end)

		t:test("숨길 정보·내부 상태는 없음(최상위 키 허용 목록, 전체 키 검사)", function()
			local s = placed()
			s.session = { server_id = "x", token = "secret", locked_at = T }
			s.carry["idle:dew"] = 12
			s.next_spawn_at = T + 60
			local report = { show = true, offlineMinutes = 90, creditedMinutes = 90, lostMinutes = 0, offlineCapHours = 12, gained = { dew = 1 }, spirits = {} }
			local session = { nodeId = "meadow_dew", resource = "dew", rate = 160800, lastSec = T + 99 }
			local snap = S.build(ctx, s, T + 100, { seq = 3, plot = 2, returnReport = report, gather = session })
			local allowed: { [string]: boolean } = {}
			for _, k in S.KEYS do
				allowed[k] = true
			end
			for k in snap do
				t:ok(allowed[k], `허용 목록 밖 키: {k}`)
			end
			local FORBIDDEN = {
				"session",
				"token",
				"carry",
				"next_uid",
				"next_spawn_at",
				"stats",
				"settled_min",
				"last_online_at",
				"first_capture",
				"pending",
				"block",
				"uniforms",
				"attempts",
				"result",
				"endsAt",
			}
			local function walk(v: any, path: string)
				if type(v) ~= "table" then
					return
				end
				for k, x in v do
					for _, bad in FORBIDDEN do
						t:ok(k ~= bad, `숨길 키 '{bad}' 가 {path} 에 있음`)
					end
					walk(x, `{path}.{tostring(k)}`)
				end
			end
			walk(snap, "snap")
			t:eq(snap.seq, 3)
			t:eq(snap.plot, 2)
			t:eq(snap.v, S.VERSION)
			t:eq(snap.returnReport, report)
			t:ok(snap.gather ~= nil, "채집 상태가 실제로 검사 대상에 들어감")
		end)

		t:test("귀환 요약·채집은 extras 로 줄 때만, 부지 없으면 plot = nil", function()
			local s = placed()
			local snap = S.build(ctx, s, T + 100, { seq = 1 })
			t:eq(snap.returnReport, nil)
			t:eq(snap.plot, nil)
			t:eq(snap.gather, nil)
		end)

		t:test("채집(S6): nodeId·resource·rate(milli/시)·accruedAt 만, 세션의 사본", function()
			local s = placed()
			local session = { nodeId = "meadow_bloom", resource = "bloom", rate = 123456, lastSec = T + 42 }
			local snap = S.build(ctx, s, T + 43, { seq = 1, gather = session })
			t:eq(snap.gather, { nodeId = "meadow_bloom", resource = "bloom", rate = 123456, accruedAt = T + 42 })
			snap.gather.rate = 0
			t:eq(session.rate, 123456, "스냅샷 수정이 세션에 번지지 않음")
		end)

		t:test("now < settled_min(시계 역행)이면 적립 없이 지갑 그대로, walletAt = settled_min", function()
			local s = placed()
			s.settled_min = T // 60 + 100
			local snap = S.build(ctx, s, T + 600, { seq = 1 })
			t:eq(snap.wallet, { wick = 21000 })
			t:eq(snap.walletAt, (T // 60 + 100) * 60)
		end)
	end,
}
