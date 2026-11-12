--!strict
-- QuestCraftSpec: 日次依頼（UTC 日・1 日 1 回・解禁済み最高フィールドの行）と在庫制作（許可リスト・回数 1..100・原子的な差し引きと付与）
-- 配置: ServerStorage.Tests.QuestCraftSpec（Rojo: game/tests/QuestCraftSpec.luau）
-- 依存: deps.QuestService・QuestRules・CraftService・CraftRules・Net・Ledger・SaveSchema・Config・Formulas・CaptureLogic・gd
-- 期待値の出典: daily_quests.json（meadow = hunt_meadow 3・wick 40、forest = hunt_forest 3・wick 20）、Q12 決定（UTC 0 時）、
--   crafting.json（wick_from_meadow = hunt_meadow 5 → wick 25、food_from_meadow は stock だが許可リスト外、key_meadow は atomic）、
--   計画書 S9 完了基準（日付が変わったら 1 回だけ、hunt_meadow 5 → 芯 25）。開始状態の芯 21

local T = 1762819200 -- 2025-11-11 00:00 UTC（86400 の倍数）

return {
	name = "QuestCraft",
	run = function(t: any, deps: any)
		local E = deps.Net.ErrorCode

		local function newSave(): any
			return deps.SaveSchema.newSave({
				gd = deps.gd,
				startSpirits = deps.Config.START_SPIRITS,
				milli = deps.Formulas.MILLI,
				vigorTick = deps.CaptureLogic.VIGOR_TICK,
			}, T)
		end
		local ledger = deps.Ledger.new(deps.gd)
		local quest = deps.QuestService.new({ gd = deps.gd, QuestRules = deps.QuestRules, ledger = ledger })
		local craft = deps.CraftService.new({
			gd = deps.gd,
			CraftRules = deps.CraftRules,
			ledger = ledger,
			allowed = deps.Config.CRAFT_ALLOWED,
			maxTimes = deps.Config.CRAFT_MAX_TIMES,
		})

		t:test("UTC 날짜 = floor(초/86400)", function()
			t:eq({ deps.QuestRules.utcDay(T - 1), deps.QuestRules.utcDay(T), deps.QuestRules.utcDay(T + 86399) }, { T // 86400 - 1, T // 86400, T // 86400 })
		end)

		t:test("일일 의뢰: 하루 1회, 날짜가 바뀌면 다시, 시계가 되돌아가도 두 번 받지 않음", function()
			local s = newSave()
			local day = T // 86400
			local r = quest:claim(1, s, T + 100)
			t:eq(r, { ok = true, data = { day = day, rewards = { { resource = "hunt_meadow", amount = 3 }, { resource = "wick", amount = 40 } } } })
			t:eq({ s.wallet.wick, s.wallet.hunt_meadow, s.quest_day }, { 61000, 3000, day })
			t:eq(quest:claim(1, s, T + 86399).code, E.ALREADY_CLAIMED)
			t:eq(quest:claim(1, s, T - 5).code, E.ALREADY_CLAIMED, "전날로 역행")
			t:eq(quest:claim(1, s, T + 86400).ok, true)
			t:eq({ s.wallet.wick, s.quest_day }, { 101000, day + 1 })
		end)

		t:test("일일 의뢰: 해금한 최고 필드의 보상만", function()
			local s = newSave()
			s.unlocked = { "meadow", "forest" }
			local r = quest:claim(1, s, T)
			t:eq(r.data.rewards, { { resource = "hunt_forest", amount = 3 }, { resource = "wick", amount = 20 } })
			t:eq({ s.wallet.hunt_meadow, s.wallet.hunt_forest, s.wallet.wick }, { nil, 3000, 41000 })
		end)

		t:test("제작: hunt_meadow 5 → 심지 25, 부족하면 변경 없음", function()
			local s = newSave()
			s.wallet.hunt_meadow = 5000
			t:eq(craft:craft(1, s, "wick_from_meadow", 2, T).code, E.INSUFFICIENT)
			t:eq(s.wallet, { wick = 21000, hunt_meadow = 5000 })
			local r = craft:craft(1, s, "wick_from_meadow", 1, T)
			t:eq(r, { ok = true, data = { recipeId = "wick_from_meadow", times = 1, output = { resource = "wick", amount = 25 } } })
			t:eq(s.wallet, { wick = 46000, hunt_meadow = 0 })
			s.wallet.hunt_meadow = 500000
			t:eq(craft:craft(1, s, "wick_from_meadow", 100, T).ok, true, "100회")
			t:eq(s.wallet, { wick = 2546000, hunt_meadow = 0 })
		end)

		t:test("제작 거부: 횟수 범위·정수, 허용 목록 밖(stock·atomic), 없는 레시피", function()
			local s = newSave()
			s.wallet.hunt_meadow = 1000000
			for _, n in { 0, 101, 1.5, 0 / 0, "1" } do
				t:eq(craft:craft(1, s, "wick_from_meadow", n, T).code, E.BAD_ARG, tostring(n))
			end
			t:eq(craft:craft(1, s, "food_from_meadow", 1, T).code, E.NOT_ALLOWED)
			t:eq(craft:craft(1, s, "key_meadow", 1, T).code, E.NOT_ALLOWED)
			t:eq(craft:craft(1, s, "nope", 1, T).code, E.NOT_FOUND)
			t:eq(craft:craft(1, s, 5, 1, T).code, E.BAD_ARG)
			t:eq(s.wallet, { wick = 21000, hunt_meadow = 1000000 })
		end)
	end,
}
