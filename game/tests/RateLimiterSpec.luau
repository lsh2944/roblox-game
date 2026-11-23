--!strict
-- RateLimiterSpec: プレイヤー・Remote 別のトークンバケットと StateChanged のまとめ送信（PushThrottle）
-- 配置: ServerStorage.Tests.RateLimiterSpec（Rojo: game/tests/RateLimiterSpec.luau）
-- 依存: deps.RateLimiter・deps.PushThrottle・deps.Config・deps.Net
-- 期待値の出典: 計画書 4.3 Remote 表の「레이트(플레이어별)」列（GetSnapshot 2/s、GatherStart 2/s、GatherStop 2/s、CaptureEngage 1/s、
--   SetParty 2/s、AssignSlot 4/s、UpgradeFacility 2/s、Craft 2/s、ClaimDaily 1/s、ReleaseSpirit 2/s、LevelUpSpirit 4/s）、
--   MoveSlot 4/s（2026-11-12 メイン確認）、「초과는 버리고 횟수 기록, 추방 없음」、StateChanged「서버 스로틀 4/s」

return {
	name = "RateLimiter",
	run = function(t: any, deps: any)
		local RL = deps.RateLimiter
		local PT = deps.PushThrottle

		t:test("Config 레이트 = 계획서 Remote 표, C→S Remote 전부", function()
			t:eq(deps.Config.REMOTE_RATES, {
				GetSnapshot = 2,
				GatherStart = 2,
				GatherStop = 2,
				CaptureEngage = 1,
				SetParty = 2,
				AssignSlot = 4,
				UpgradeFacility = 2,
				Craft = 2,
				ClaimDaily = 1,
				ReleaseSpirit = 2,
				LevelUpSpirit = 4,
				MoveSlot = 4,
			})
			for name, dir in deps.Net.Directions do
				t:eq(deps.Config.REMOTE_RATES[name] ~= nil, dir == "C2S", name)
			end
		end)

		t:test("2/s: 연속 2회 통과 후 버림, 0.5초 뒤 1회 회복, 버린 횟수 기록", function()
			local now = 0
			local rl = RL.new(deps.Config.REMOTE_RATES, function()
				return now
			end)
			t:eq((rl:take(1, "GetSnapshot")), true)
			t:eq((rl:take(1, "GetSnapshot")), true)
			local ok, drops = rl:take(1, "GetSnapshot")
			t:eq(ok, false)
			t:eq(drops, 1)
			now = 0.5
			t:eq((rl:take(1, "GetSnapshot")), true)
			t:eq((rl:take(1, "GetSnapshot")), false)
			t:eq(rl:dropCount(1, "GetSnapshot"), 2)
		end)

		t:test("1/s 와 4/s, Remote·플레이어별로 독립", function()
			local now = 0
			local rl = RL.new(deps.Config.REMOTE_RATES, function()
				return now
			end)
			t:eq((rl:take(1, "CaptureEngage")), true)
			t:eq((rl:take(1, "CaptureEngage")), false)
			t:eq((rl:take(2, "CaptureEngage")), true, "다른 플레이어")
			for i = 1, 4 do
				t:eq((rl:take(1, "AssignSlot")), true, `AssignSlot {i}`)
			end
			t:eq((rl:take(1, "AssignSlot")), false)
			now = 0.9
			t:eq((rl:take(1, "CaptureEngage")), false, "0.9초")
			now = 1.0
			t:eq((rl:take(1, "CaptureEngage")), true, "1초")
		end)

		t:test("오래 쉬어도 용량 이상 쌓이지 않음, 시계가 돌아가면 회복 없음", function()
			local now = 0
			local rl = RL.new(deps.Config.REMOTE_RATES, function()
				return now
			end)
			t:eq((rl:take(1, "Craft")), true)
			now = 100
			t:eq((rl:take(1, "Craft")), true)
			t:eq((rl:take(1, "Craft")), true)
			t:eq((rl:take(1, "Craft")), false, "용량 2")
			now = 50 -- 巻き戻り
			t:eq((rl:take(1, "Craft")), false, "역행으로 회복하지 않음")
		end)

		t:test("1초 동안 연타: 레이트만큼만 통과", function()
			local now = 0
			local rl = RL.new(deps.Config.REMOTE_RATES, function()
				return now
			end)
			local passed = 0
			for i = 0, 99 do
				now = i * 0.01
				if rl:take(7, "GatherStart") then
					passed += 1
				end
			end
			-- 初期 2 + 0.99 秒の補充 1.98 → 3 回（4 回目は 1 秒ちょうどで補充）
			t:eq(passed, 3)
		end)

		t:test("정의 없는 Remote·잘못된 레이트는 오류, forget 으로 초기화", function()
			local now = 0
			local rl = RL.new(deps.Config.REMOTE_RATES, function()
				return now
			end)
			t:throws(function()
				rl:take(1, "NoSuchRemote")
			end, "레이트 미정의")
			t:throws(function()
				RL.new({ X = 0 }, function()
					return 0
				end)
			end)
			t:throws(function()
				RL.new({ X = 0 / 0 }, function()
					return 0
				end)
			end)
			rl:take(1, "ClaimDaily")
			rl:take(1, "ClaimDaily")
			t:eq(rl:dropCount(1, "ClaimDaily"), 1)
			rl:forget(1)
			t:eq(rl:dropCount(1, "ClaimDaily"), 0)
			t:eq((rl:take(1, "ClaimDaily")), true, "forget 후 가득 참")
		end)

		t:test("StateChanged 스로틀: 표시를 묶어 최대 4회/초", function()
			local pt = PT.new(deps.Config.PUSH_MIN_INTERVAL_SECONDS)
			local sends = 0
			-- 0.05 秒ごとに変更の印と送信確認（[0, 1) 秒）
			for i = 0, 19 do
				local now = i * 0.05
				pt:mark(5)
				pt:mark(5)
				sends += #pt:due(now)
			end
			t:eq(sends, 4)
		end)

		t:test("스로틀: 표시 없으면 안 보냄, 간격 미달이면 다음으로, 시계 역행·forget", function()
			local pt = PT.new(0.25)
			t:eq(pt:due(0), {})
			pt:mark(2)
			pt:mark(1)
			t:eq(pt:due(0), { 1, 2 })
			t:eq(pt:due(0.1), {}, "표시 소비됨")
			pt:mark(1)
			t:eq(pt:due(0.1), {}, "간격 미달")
			t:eq(pt:isDirty(1), true, "표시 유지")
			t:eq(pt:due(0.25), { 1 })
			pt:mark(1)
			t:eq(pt:due(0.0), { 1 }, "시계 역행")
			pt:mark(1)
			pt:forget(1)
			t:eq(pt:due(10), {})
		end)
	end,
}
