--!strict
-- NetSpec: Net の Remote 名・種別が実際の Remotes 定義（default.project.json / Studio の ReplicatedStorage.Remotes）と一致するか
-- 配置: ServerStorage.Tests.NetSpec（Rojo: game/tests/NetSpec.luau）
-- 依存: deps.Net、deps.remoteClasses（名前 → ClassName。Lune は default.project.json から、Studio は実インスタンスから作る）
-- 期待値の出典: 計画書 docs/game_mvp1_impl_plan.md 4.3 節の Remote 表（選択の ReleaseSpirit・LevelUpSpirit は Q6 で採用、MoveSlot は 2026-11-12 決定）

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
			t:eq(n, 15)
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
