--!strict
-- NetSpec: Net の Remote 名・種別が実際の Remotes 定義（default.project.json / Studio の ReplicatedStorage.Remotes）と一致するか
-- 配置: ServerStorage.Tests.NetSpec（Rojo: game/tests/NetSpec.luau）
-- 依存: deps.Net、deps.remoteClasses（名前 → ClassName。Lune は default.project.json から、Studio は実インスタンスから作る）
-- 期待値の出典: 計画書 docs/game_mvp1_impl_plan.md 4.3 節の Remote 表（選択の ReleaseSpirit・LevelUpSpirit は Q6 で採用、MoveSlot は 2026-11-12 決定、Travel は 2026-11-24 決定。
--   方向は表の「RE S→C」行、NOT_IMPLEMENTED は S5 指示: 未結線の S6〜S9 Remote の応答）

local CLASS = { RF = "RemoteFunction", RE = "RemoteEvent" }

return {
	name = "Net",
	run = function(t: any, deps: any)
		local Net = deps.Net

		t:test("Remotes 이름 = 키, 종류 정의가 빠짐없이 있음", function()
			local n = 0
			for k, v in Net.Remotes do
				n += 1
				t:eq(v, k)
				t:ok(Net.RemoteKinds[k] ~= nil, k)
			end
			t:eq(n, 16)
		end)

		t:test("방향: 계획서 표의 S→C 는 StateChanged·EncounterEvent·Notify 뿐, RF 는 모두 C→S", function()
			local s2c = {}
			for name in Net.Remotes do
				local dir = Net.Directions[name]
				t:ok(dir == "C2S" or dir == "S2C", `방향 없음: {name}`)
				if dir == "S2C" then
					table.insert(s2c, name)
				end
				if Net.RemoteKinds[name] == "RF" then
					t:eq(dir, "C2S", name)
				end
			end
			table.sort(s2c)
			t:eq(s2c, { "EncounterEvent", "Notify", "StateChanged" })
			for name in Net.Directions do
				t:ok(Net.Remotes[name] ~= nil, `Remotes 에 없는 방향 정의: {name}`)
			end
		end)

		t:test("ErrorCode: 키 = 값, 미구현 코드(NOT_IMPLEMENTED) 있음", function()
			for k, v in Net.ErrorCode do
				t:eq(v, k)
			end
			t:eq(Net.ErrorCode.NOT_IMPLEMENTED, "NOT_IMPLEMENTED")
		end)

		t:test("Travel: C→S RF, 목적지 이름은 meadow·home 둘(키 → 값)", function()
			t:eq(Net.Remotes.Travel, "Travel")
			t:eq(Net.RemoteKinds.Travel, "RF")
			t:eq(Net.Directions.Travel, "C2S")
			t:eq(Net.TravelDest, { Meadow = "meadow", Home = "home" })
			t:eq(table.isfrozen(Net.TravelDest), true)
		end)

		t:test("실제 Remotes 정의와 일치", function()
			local classes = deps.remoteClasses
			t:ok(classes ~= nil, "remoteClasses 없음")
			for name, kind in Net.RemoteKinds do
				t:eq(classes[name], CLASS[kind], name)
			end
			for name in classes do
				t:ok(Net.Remotes[name] ~= nil, `Net에 없는 Remote: {name}`)
			end
		end)
	end,
}
