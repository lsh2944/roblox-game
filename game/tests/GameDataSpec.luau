--!strict
-- GameDataSpec: manifest 確認・索引・freeze・欠落ファイルの検出・参照 ID 確認
-- 配置: ServerStorage.Tests.GameDataSpec（Rojo: game/tests/GameDataSpec.luau）
-- 依存: deps.GameData、deps.gd、deps.loadDocs、deps.Config
-- 期待値の出典: data/manifest.json（source 15 + generated 2 = 17、計画書 6 節 S1「GameData OK (17 files)」）、
--   data/generated/upgrade_tables.json（fac_cost_dew_spring Lv1→2 = dew 40·bloom 20、facility_output Lv10 = 38000）

return {
	name = "GameData",
	run = function(t: any, deps: any)
		local G = deps.GameData
		local gd = deps.gd

		t:test("17개 파일 로드·색인", function()
			t:eq(gd.fileCount, 17)
			t:eq(gd.fieldOrder[1], "meadow")
			t:eq(gd.nodes.meadow_dew.fieldId, "meadow")
			t:eq(gd.cost.fac_cost_dew_spring[1], { { resource = "dew", amount = 40 }, { resource = "bloom", amount = 20 } })
			t:eq(gd.bonus.facility_output[10], 38000)
			t:eq(gd.costMax.fac_cost_dew_spring, 30)
			t:eq(gd.aptBps.A, 12000)
			t:eq(gd.recipes.wick_from_meadow.output, { resource = "wick", amount = 25 })
		end)

		t:test("깊게 freeze됨", function()
			t:ok(table.isfrozen(gd), "gd")
			t:ok(table.isfrozen(gd.spirits.sparkle), "spirit")
			t:ok(table.isfrozen(gd.docs.capture.light.bands), "docs")
			t:throws(function()
				(gd.spirits.sparkle :: any).grade = 9
			end)
		end)

		t:test("파일 누락·스키마 버전 불일치는 오류", function()
			local docs = deps.loadDocs()
			docs.sink_tables = nil
			t:throws(function()
				G.build(docs)
			end, "sink_tables")
			local docs2 = deps.loadDocs()
			docs2.manifest.schema_version = 2
			t:throws(function()
				G.build(docs2)
			end, "schema_version")
		end)

		t:test("manifest path → 인스턴스 이름", function()
			t:eq(G.pathSegments("generated/upgrade_tables.json"), { "generated", "upgrade_tables" })
			t:eq(G.pathSegments("daily_quests.json"), { "daily_quests" })
		end)

		t:test("슬라이스 참조 id 확인", function()
			G.assertRefs(gd, deps.Config.SLICE_REFS)
			t:throws(function()
				G.assertRefs(gd, { spirits = { "nope" }, questFields = { "nowhere" }, quests = { "daily_login" } })
			end, "spirit:nope")
			t:throws(function()
				G.assertRefs(gd, { quests = { "daily_login" }, questFields = { "nowhere" } })
			end, "quest_row:daily_login/nowhere")
		end)

		t:test("시작 정령은 data에 있는 ★1 3종(personas.json start 복사)", function()
			local start = deps.Config.START_SPIRITS
			t:eq(#start, 3)
			for _, s in start do
				t:ok(gd.spirits[s.species] ~= nil, s.species)
				t:eq(s.level, 1)
			end
		end)
	end,
}
