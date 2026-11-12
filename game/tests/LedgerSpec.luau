--!strict
-- LedgerSpec: 財布の原子性（全部払うか何もしない）・合算・付与・atomic 品目フック
-- 配置: ServerStorage.Tests.LedgerSpec（Rojo: game/tests/LedgerSpec.luau）
-- 依存: deps.Ledger、deps.gd、deps.Net
-- 期待値の出典: 要求（計画書 4.1 Ledger「spend(전부 되거나 전부 안 되거나)」）と milli 規約（1 個 = 1000 milli）

return {
	name = "Ledger",
	run = function(t: any, deps: any)
		local L = deps.Ledger.new(deps.gd)

		t:test("부족하면 지갑을 전혀 바꾸지 않는다", function()
			local w = { dew = 50000, bloom = 19999 }
			local ok, code = L:spend(w, { { resource = "dew", amount = 40 }, { resource = "bloom", amount = 20 } })
			t:eq(ok, false)
			t:eq(code, deps.Net.ErrorCode.INSUFFICIENT)
			t:eq(w, { dew = 50000, bloom = 19999 })
			t:eq(L:canAfford(w, { { resource = "dew", amount = 40 } }), true)
		end)

		t:test("충분하면 전부 차감(milli)", function()
			local w = { dew = 50000, bloom = 20000 }
			local ok = L:spend(w, { { resource = "dew", amount = 40 }, { resource = "bloom", amount = 20 } })
			t:eq(ok, true)
			t:eq(w, { dew = 10000, bloom = 0 })
		end)

		t:test("같은 자원이 여러 행이면 합산해서 판정", function()
			local w = { dew = 50000 }
			t:eq(L:canAfford(w, { { resource = "dew", amount = 30 }, { resource = "dew", amount = 30 } }), false)
			t:eq((L:spend(w, { { resource = "dew", amount = 30 }, { resource = "dew", amount = 30 } })), false)
			t:eq(w.dew, 50000)
			t:eq(L:need({ { resource = "dew", amount = 30 }, { resource = "dew", amount = 20 } }), { dew = 50000 })
		end)

		t:test("없는 자원·0원 비용", function()
			local w = {}
			t:eq((L:spend(w, {})), true)
			t:eq(L:canAfford(w, { { resource = "wick", amount = 0 } }), true)
			t:throws(function()
				L:spend(w, { { resource = "gold", amount = 1 } })
			end, "알 수 없는 자원")
		end)

		t:test("지급: 개 단위·milli 단위, 잘못된 행이 있으면 아무것도 지급하지 않음", function()
			local w = { wick = 1000 }
			L:grant(w, { { resource = "wick", amount = 40 }, { resource = "hunt_meadow", amount = 3 } })
			t:eq(w, { wick = 41000, hunt_meadow = 3000 })
			L:grantMilli(w, "dew", 7594)
			t:eq(w.dew, 7594)
			t:throws(function()
				L:grant(w, { { resource = "wick", amount = 1 }, { resource = "gold", amount = 1 } })
			end, "알 수 없는 자원")
			t:eq(w.wick, 41000, "앞 행도 지급되지 않음")
			t:throws(function()
				L:grantMilli(w, "dew", -1)
			end, "음수")
		end)

		t:test("atomic 품목은 hook 없이는 오류, hook이 있으면 전개해서 차감", function()
			t:throws(function()
				L:spend({ hunt_meadow = 99000 }, { { resource = "key_meadow", amount = 1 } })
			end, "hook")
			local L2 = deps.Ledger.new(deps.gd, function(costs)
				local out = {}
				for _, c in costs do
					if c.resource == "key_meadow" then
						table.insert(out, { resource = "hunt_meadow", amount = 2 * c.amount })
					else
						table.insert(out, c)
					end
				end
				return out
			end)
			local w = { hunt_meadow = 5000 }
			t:eq((L2:spend(w, { { resource = "key_meadow", amount = 2 } })), true)
			t:eq(w.hunt_meadow, 1000)
		end)
	end,
}
