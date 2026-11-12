--!strict
-- SaveSchemaSpec: 新規状態（芯 21・開始精霊 3・施設 Lv1）、uid 文字列⇔数値の境界、形の検査、版上げ（Migrations）
-- 配置: ServerStorage.Tests.SaveSchemaSpec（Rojo: game/tests/SaveSchemaSpec.luau）
-- 依存: deps.SaveSchema・deps.Migrations・deps.CaptureLogic・deps.Formulas・deps.Config・deps.gd
-- 期待値の出典: 計画書 2 節・4.4 節と data（capture.json supply.start 芯 21・vigor.max 100、hub.json offline_cap.base_hours 12、
--   facilities.json の meadow 施設 2 つ slots.base 3、rules.json individual_stats.start_spirit_bps 10000、
--   Config.START_SPIRITS 3 種）、milli 規約（1 個 = 1000）、活力 tick（1 点 = 60、sim.py:26）

local NOW = 1762819200 -- 秒（60 の倍数）

return {
	name = "SaveSchema",
	run = function(t: any, deps: any)
		local S = deps.SaveSchema
		local M = deps.Migrations
		local ctx = {
			gd = deps.gd,
			startSpirits = deps.Config.START_SPIRITS,
			milli = deps.Formulas.MILLI,
			vigorTick = deps.CaptureLogic.VIGOR_TICK,
		}

		t:test("신규 상태: 심지 21·시작 정령 3·meadow 시설 Lv1·오프라인 상한 12시간", function()
			local s = S.newSave(ctx, NOW)
			t:eq(s.save_schema, 1)
			t:eq(s.wallet, { wick = 21000 })
			t:eq(s.unlocked, { "meadow" })
			t:eq(s.field_unlock_time, { meadow = NOW })
			t:eq(s.facilities, {
				dew_spring = { level = 1, slots = 3, assigned = {} },
				bloom_garden = { level = 1, slots = 3, assigned = {} },
			})
			t:eq(s.offline_cap_hours, 12)
			t:eq(s.settled_min, NOW // 60)
			t:eq(s.next_uid, 4)
			t:eq(s.party, {})
			t:eq(s.quest_day, -1)
			t:eq(s.session, nil)
			t:eq(s.roster["1"], {
				species = "sparkle",
				level = 1,
				gather_bps = 10000,
				combat_bps = 10000,
				vigor_ticks = 6000,
				vigor_min = NOW // 60,
				origin = "start",
				caught_at = NOW,
			})
			t:eq(s.roster["2"].species, "dewdrop")
			t:eq(s.roster["3"].species, "flower_lamp")
			t:eq(s.dex, { sparkle = NOW, dewdrop = NOW, flower_lamp = NOW })
			t:eq(S.hasLantern(deps.gd), true)
			t:eq({ S.check(s) }, { true, nil })
		end)

		t:test("uid 경계: 저장 키는 문자열, pickAttacker에 넘길 값은 숫자", function()
			t:eq(S.uidNum("1"), 1)
			t:eq(type(S.uidNum("42")), "number")
			t:eq(S.uidNum("9007199254740991"), 9007199254740991)
			t:eq(S.uidKey(42), "42")
			t:eq(S.uidKey(9007199254740991), "9007199254740991")
			for _, bad in { "0", "01", "-1", "1.5", "", "abc", " 1", "9007199254740992", "1e3" } do
				t:throws(function()
					S.uidNum(bad)
				end, nil, `uidNum({bad})`)
			end
			for _, bad in { 0, -1, 1.5, 0 / 0, 2 ^ 53 } do
				t:throws(function()
					S.uidKey(bad)
				end, nil, `uidKey({bad})`)
			end
			local s = { next_uid = 7 }
			t:eq(S.allocUid(s), "7")
			t:eq(s.next_uid, 8)
		end)

		t:test("형태 검사: 깨진 저장을 거부", function()
			local function broken(mut: (any) -> ()): (boolean, string?)
				local s = S.newSave(ctx, NOW)
				mut(s)
				return S.check(s)
			end
			t:eq((broken(function(s)
				s.wallet.wick = 1.5
			end)), false)
			t:eq((broken(function(s)
				s.roster["01"] = s.roster["1"]
			end)), false)
			t:eq((broken(function(s)
				s.next_uid = 3 -- uid "3" が next_uid 以上
			end)), false)
			t:eq((broken(function(s)
				s.session = { server_id = 5, locked_at = 1 }
			end)), false)
			t:eq((broken(function(s)
				s.facilities.dew_spring.assigned = { 1 }
			end)), false)
			t:eq((broken(function(s)
				s.settled_min = nil
			end)), false)
			t:eq((broken(function(s)
				s.session = { server_id = "x", locked_at = 1 }
			end)), true)
			t:eq((broken(function(s)
				s.session = { server_id = "x", token = "t", locked_at = 1 }
			end)), true)
			t:eq((broken(function(s)
				s.session = { server_id = "x", token = 7, locked_at = 1 }
			end)), false)
		end)

		t:test("마이그레이션: 같은 버전 통과, 상위 버전·깨진 값 거부, 단계 순서", function()
			local s = { save_schema = 1, x = 1 }
			t:eq({ M.migrate(s) }, { s, nil })
			t:eq({ M.migrate({ save_schema = 2 }) }, { nil, "newer_schema" })
			for _, bad in { {}, { save_schema = 0 }, { save_schema = 1.5 }, { save_schema = "1" } } do
				t:eq({ M.migrate(bad) }, { nil, "corrupt" })
			end
			t:eq({ M.migrate("x") }, { nil, "corrupt" })
			local order = {}
			local steps = {
				[1] = function(v: any)
					table.insert(order, 1)
					v.a = true
					return v
				end,
				[2] = function(v: any)
					table.insert(order, 2)
					v.b = v.a
					return v
				end,
			}
			local out = M.migrate({ save_schema = 1 }, 3, steps)
			t:eq(out, { save_schema = 3, a = true, b = true })
			t:eq(order, { 1, 2 })
			t:eq({ M.migrate({ save_schema = 1 }, 3, { [1] = steps[1] }) }, { nil, "no_migration" })
			t:eq(M.CURRENT, S.VERSION)
		end)
	end,
}
