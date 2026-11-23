--!strict
-- ValidateSpec: Remote 引数の型・形の検証（NaN・無限・小数・範囲・文字列長・配列の形・引数の個数）と Remote ごとのスキーマ
-- 配置: ServerStorage.Tests.ValidateSpec（Rojo: game/tests/ValidateSpec.luau）
-- 依存: deps.Validate・deps.Net・deps.Config・deps.gd・deps.GameData・deps.loadDocs
-- 期待値の出典: 計画書 4.3「검증 공통」（typeof、x == x、有限、整数、範囲、文字列の長さ上限、テーブルの長さ上限と要素の型）と
--   Remote 表の引数（nodeId: string(≤32)、uids ≤ companion_slots、slotIndex: int、uid または ""、times: int 1..100）。
--   S5 完了基準「숫자 대신 문자열, NaN 을 보내면 거부」

return {
	name = "Validate",
	run = function(t: any, deps: any)
		local V = deps.Validate
		local Net = deps.Net
		local schemas = V.schemas(deps.gd, deps.Config)
		local function okArgs(name: string, ...: any): boolean
			return (V.args(schemas[name], select("#", ...), ...))
		end
		local NAN = 0 / 0

		t:test("정수: NaN·무한·소수·문자열·범위 밖 거부", function()
			local s = V.int(1, 100)
			t:eq((V.check(s, 1)), true)
			t:eq((V.check(s, 100)), true)
			for _, bad in { NAN, math.huge, -math.huge, 1.5, 0, 101, -1, "5", true, {} :: any } do
				t:eq((V.check(s, bad)), false, `거부되어야 함: {tostring(bad)}`)
			end
			t:eq((V.check(s, nil)), false, "nil")
		end)

		t:test("문자열: 숫자·빈 문자열·길이 초과·형식 밖 문자 거부", function()
			local s = V.str(1, 32, V.ID_PATTERN)
			t:eq((V.check(s, "meadow_dew")), true)
			t:eq((V.check(s, string.rep("a", 32))), true)
			for _, bad in { 5, "", string.rep("a", 33), "a b", "a\0b", "meadow-dew", "이슬", {} :: any } do
				t:eq((V.check(s, bad)), false, `거부되어야 함: {tostring(bad)}`)
			end
		end)

		t:test("uid: 앞자리 0·부호·소수·17자리 거부, uid 또는 빈 문자열", function()
			local uid = V.str(1, 16, V.UID_PATTERN)
			t:eq((V.check(uid, "1")), true)
			t:eq((V.check(uid, "120")), true)
			for _, bad in { "0", "01", "-1", "1.0", "abc", "", string.rep("1", 17), 1 :: any } do
				t:eq((V.check(uid, bad)), false, `거부되어야 함: {tostring(bad)}`)
			end
			local orEmpty = V.str(1, 16, V.UID_PATTERN, true)
			t:eq((V.check(orEmpty, "")), true)
			t:eq((V.check(orEmpty, "7")), true)
			t:eq((V.check(orEmpty, "05")), false)
		end)

		t:test("배열: 길이 상한·원소 타입·빈 칸·사전 키 거부", function()
			local s = V.array(3, V.str(1, 16, V.UID_PATTERN))
			t:eq((V.check(s, {})), true)
			t:eq((V.check(s, { "1", "2", "3" })), true)
			t:eq((V.check(s, { "1", "2", "3", "4" })), false, "길이 4")
			t:eq((V.check(s, { "1", 2 } :: any)), false, "숫자 원소")
			t:eq((V.check(s, { [1] = "1", [3] = "3" } :: any)), false, "빈 칸")
			t:eq((V.check(s, { a = "1" } :: any)), false, "사전 키")
			t:eq((V.check(s, { [0] = "1" } :: any)), false, "0 키")
			t:eq((V.check(s, { [1.5] = "1" } :: any)), false, "소수 키")
			t:eq((V.check(s, { "1", NAN } :: any)), false, "NaN 원소")
			t:eq((V.check(s, "1")), false, "문자열")
		end)

		t:test("인자 개수: 모자람·남는 인자 거부(끝의 nil 포함)", function()
			t:eq(okArgs("GetSnapshot"), true)
			t:eq(okArgs("GetSnapshot", "x"), false)
			t:eq(okArgs("GatherStart"), false)
			t:eq(okArgs("GatherStart", "meadow_dew"), true)
			t:eq(okArgs("GatherStart", "meadow_dew", "extra"), false)
			t:eq(okArgs("GatherStart", "meadow_dew", nil), false)
		end)

		t:test("Remote 표 인자: 문자열 자리에 숫자, 숫자 자리에 문자열·NaN 거부", function()
			t:eq(okArgs("GatherStart", 123), false)
			t:eq(okArgs("CaptureEngage", NAN), false)
			t:eq(okArgs("Craft", "wick_from_meadow", 1), true)
			t:eq(okArgs("Craft", "wick_from_meadow", 100), true)
			t:eq(okArgs("Craft", "wick_from_meadow", "5"), false)
			t:eq(okArgs("Craft", "wick_from_meadow", NAN), false)
			t:eq(okArgs("Craft", "wick_from_meadow", 0), false)
			t:eq(okArgs("Craft", "wick_from_meadow", 101), false)
			t:eq(okArgs("Craft", "wick_from_meadow", math.huge), false)
			t:eq(okArgs("AssignSlot", "dew_spring", 1, "3"), true)
			t:eq(okArgs("AssignSlot", "dew_spring", 1, ""), true)
			t:eq(okArgs("AssignSlot", "dew_spring", 1.5, "3"), false)
			t:eq(okArgs("AssignSlot", "dew_spring", "1", "3"), false)
			t:eq(okArgs("AssignSlot", "dew_spring", 1, 3), false)
			t:eq(okArgs("MoveSlot", "3", "bloom_garden", 2), true)
			t:eq(okArgs("MoveSlot", "3", "bloom_garden", NAN), false)
			t:eq(okArgs("SetParty", { "1", "2", "3" }), true)
			t:eq(okArgs("SetParty", { "1", "2", "3", "4" }), false)
			t:eq(okArgs("SetParty", "1"), false)
			t:eq(okArgs("ReleaseSpirit", "1"), true)
			t:eq(okArgs("LevelUpSpirit", 1), false)
			t:eq(okArgs("UpgradeFacility", "dew_spring"), true)
			t:eq(okArgs("ClaimDaily"), true)
			t:eq(okArgs("GatherStop"), true)
		end)

		t:test("스키마는 C→S Remote 전부에만 있음", function()
			for name, dir in Net.Directions do
				if dir == "C2S" then
					t:ok(schemas[name] ~= nil, `스키마 없음: {name}`)
				else
					t:eq(schemas[name], nil, `S→C 인데 스키마 있음: {name}`)
				end
			end
			for name in schemas do
				t:eq(Net.Directions[name], "C2S", name)
			end
		end)

		t:test("SetParty 길이 상한은 data(companion_slots)에서 옴", function()
			local docs = deps.loadDocs()
			docs.rules.constants.companion_slots = 2
			local gd2 = deps.GameData.build(docs)
			local s2 = V.schemas(gd2, deps.Config)
			t:eq((V.args(s2.SetParty, 1, { "1", "2" })), true)
			t:eq((V.args(s2.SetParty, 1, { "1", "2", "3" })), false)
		end)
	end,
}
