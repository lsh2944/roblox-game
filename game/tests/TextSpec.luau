--!strict
-- TextSpec: プレイヤー向け文言の表（キーの形・英語原文・無いキーは error・凍結）
-- 配置: ServerStorage.Tests.TextSpec（Rojo: game/tests/TextSpec.luau）
-- 依存: deps.Text
-- 期待値の出典: 2026-11-11 ユーザー決定（プレイヤー向け文言は英語が既定、後で Roblox Localization へ移す）と
--   計画書の S4 追放案内（読み込み失敗・新しい版・壊れた保存・錠喪失の 4 種）

return {
	name = "Text",
	run = function(t: any, deps: any)
		local Text = deps.Text

		t:test("문구: 키는 '구분.이름', 원문은 비어 있지 않은 인쇄 가능 ASCII(영어 기본)", function()
			t:eq(Text.SOURCE_LOCALE, "en")
			local n = 0
			for key, s in Text.STRINGS do
				n += 1
				t:eq(string.match(key, "^%u%w*%.%u%w*$") ~= nil, true, `키 형식: {key}`)
				t:eq(type(s) == "string" and #s > 0, true, `빈 문구: {key}`)
				t:eq(string.find(s, "[^\32-\126]") == nil, true, `ASCII 밖 문자: {key}`)
			end
			t:eq(n >= 4, true)
		end)

		t:test("문구: S4 추방 안내 4종이 있고, 없는 키는 오류, 표는 고정", function()
			for _, key in { "Kick.LoadFailed", "Kick.NewerSchema", "Kick.Corrupt", "Kick.LostLock" } do
				t:eq(Text.get(key), Text.STRINGS[key], key)
			end
			t:eq((pcall(Text.get, "Kick.NoSuchKey")), false)
			t:eq(table.isfrozen(Text.STRINGS), true)
			t:eq((pcall(function()
				(Text.STRINGS :: any)["Kick.LoadFailed"] = "x"
			end)), false)
		end)

		t:test("format: {이름} 자리 바꾸기, 값 없음·남는 값은 오류", function()
			t:eq(Text.format("Hud.DailyReset", { time = "01:02:03" }), "Resets in 01:02:03")
			t:eq(Text.format("World.PlotOwner", { name = "Mia{x}" }), "Mia{x}'s Garden", "값 안의 중괄호는 그대로")
			t:eq(Text.format("Hud.Dew", {}), "Dew")
			t:eq((pcall(Text.format, "Hud.DailyReset", {})), false)
			t:eq((pcall(Text.format, "Hud.Dew", { extra = 1 })), false)
			t:eq((pcall(Text.format, "Hud.NoSuchKey", {})), false)
		end)

		t:test("이동 버튼·이동 실패 문구 키(2026-11-24 Travel)", function()
			t:eq(Text.get("Hud.TravelMeadow"), "Meadow")
			t:eq(Text.get("Hud.TravelHome"), "Home")
			t:ok(#Text.get("Travel.Busy") > 0)
			t:ok(#Text.get("Travel.Failed") > 0)
		end)

		t:test("S5 HUD·월드·미구현 문구 키", function()
			for _, key in {
				"Error.NotImplemented",
				"Hud.Loading",
				"Hud.Dew",
				"Hud.Bloom",
				"Hud.Wick",
				"Hud.Materials",
				"Hud.DailyClaimed",
				"Hud.DailyReady",
				"Hud.DailyReset",
				"World.PlotEmpty",
				"World.PlotOwner",
				"World.Board",
				"World.ForestGate",
				"World.Reserved",
				"World.Showcase",
			} do
				t:ok(Text.STRINGS[key] ~= nil, key)
			end
		end)
	end,
}
