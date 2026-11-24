--!strict
-- HudFormatSpec: HUD の表示用純粋関数（縮約表記・milli → 表示整数・財布の補間・残り時間）とクライアントの State（seq・補間・帰還要約 1 回）
-- 配置: ServerStorage.Tests.HudFormatSpec（Rojo: game/tests/HudFormatSpec.luau）
-- 依存: deps.HudFormat・deps.Net・deps.Text・deps.ClientState（StarterPlayer.StarterPlayerScripts.Client.Controllers.State）
-- 期待値の出典: world_hud_design 3 節（左上の財布は縮約表記 1.2K）、表示整数は milli // 1000（Ledger・サーバーログと同じ切り捨て）、
--   S5 決定（縮約は切り捨て、補間は表示専用で上限あり、古い seq は捨てる、帰還要約は 1 回だけ渡す）

return {
	name = "HudFormat",
	run = function(t: any, deps: any)
		local HF = deps.HudFormat

		t:test("축약 표기: 1000 미만 그대로, K·M·B·T, 소수 1자리 버림, .0 생략", function()
			local cases: { { any } } = {
				{ 0, "0" },
				{ 860, "860" },
				{ 999, "999" },
				{ 1000, "1K" },
				{ 1234, "1.2K" },
				{ 1999, "1.9K" },
				{ 12345, "12.3K" },
				{ 999999, "999.9K" },
				{ 1000000, "1M" },
				{ 1250000, "1.2M" },
				{ 2000000000, "2B" },
				{ 3500000000000, "3.5T" },
				{ 1000000000000000, "1000T" },
				{ -1500, "-1.5K" },
				{ 12.7, "12" },
			}
			for _, c in cases do
				t:eq(HF.abbreviate(c[1]), c[2], tostring(c[1]))
			end
			t:eq(HF.abbreviate(0 / 0), "?")
			t:eq(HF.abbreviate(math.huge), "?")
		end)

		t:test("milli → 표시 정수는 버림", function()
			t:eq(HF.units(1999), 1)
			t:eq(HF.units(1000), 1)
			t:eq(HF.units(999), 0)
			t:eq(HF.units(21000), 21)
			t:eq(HF.units(0 / 0), 0)
		end)

		t:test("보간: 시간당·일당 비례, 경과는 0..상한", function()
			t:eq(HF.projectMilli(1000, 3600000, nil, 1, 120), 2000)
			t:eq(HF.projectMilli(1000, nil, 86400000, 1, 120), 2000)
			t:eq(HF.projectMilli(1000, 3600000, nil, -5, 120), 1000, "음수 경과")
			t:eq(HF.projectMilli(1000, 3600000, nil, 500, 120), 1000 + 120000, "상한")
			t:eq(HF.projectMilli(1000, 3600000, nil, 0 / 0, 120), 1000, "NaN 경과")
			t:eq(HF.projectMilli(1000, nil, nil, 30, 120), 1000)
		end)

		t:test("남은 시간 HH:MM:SS", function()
			t:eq(HF.countdown(0), "00:00:00")
			t:eq(HF.countdown(3661), "01:01:01")
			t:eq(HF.countdown(86399), "23:59:59")
			t:eq(HF.countdown(90000), "25:00:00")
			t:eq(HF.countdown(-5), "00:00:00")
			t:eq(HF.countdown(59.9), "00:00:59")
		end)

		local function snap(seq: number, extra: any?): any
			local s: any = {
				seq = seq,
				serverNow = 1000,
				walletAt = 960,
				wallet = { dew = 5000 },
				idle = { perHour = { dew = 3600000 }, homePerDay = {} },
				daily = { claimed = true, nextResetAt = 86400 },
			}
			if extra ~= nil then
				for k, v in extra do
					s[k] = v
				end
			end
			return s
		end

		t:test("State: 보간한 표시 정수, 서버 시각 추정, 보간 상한", function()
			local clock = 0
			local st = deps.ClientState.new(function()
				return clock
			end, HF)
			t:eq(st:units("dew"), nil, "스냅샷 전")
			t:eq(st:apply(snap(1)), true)
			-- walletAt から 40 秒（serverNow − walletAt）: 5000 + 1000 × 40
			t:eq(st:units("dew"), 45)
			clock = 10
			t:eq(st:units("dew"), 55)
			t:eq(st:serverNow(), 1010)
			clock = 500
			t:eq(st:units("dew"), 125, "120초 상한")
			t:eq(st:units("bloom"), 0)
		end)

		t:test("State(S6): 채집 중이면 그 자원만 accruedAt 이후를 채집률로 보간, 상한 동일, 채집 노드", function()
			local clock = 0
			local st = deps.ClientState.new(function()
				return clock
			end, HF)
			t:eq(st:gatherNode(), nil, "스냅샷 전")
			-- 財布 bloom 2000 milli は accruedAt = 990 まで積算済み。serverNow 1000 → 経過 10 秒 × 360000/時 = +1000
			t:eq(st:apply(snap(1, {
				wallet = { dew = 5000, bloom = 2000 },
				gather = { nodeId = "meadow_bloom", resource = "bloom", rate = 360000, accruedAt = 990 },
			})), true)
			t:eq(st:units("bloom"), 3)
			t:eq(st:units("dew"), 45, "다른 자원은 방치 보간만")
			t:eq(st:gatherNode(), "meadow_bloom")
			clock = 10
			t:eq(st:units("bloom"), 4)
			clock = 1000
			t:eq(st:units("bloom"), 2 + 12, "120초 상한(360000 × 120 / 3600 = 12000)")
			t:eq(st:apply(snap(2)), true)
			t:eq(st:gatherNode(), nil, "채집이 끝난 스냅샷")
			t:eq(st:units("bloom"), 0)
		end)

		t:test("오류 코드 → 토스트 문구 키(없는 코드는 Error.Generic, Notify TOO_FAR 는 채집 정지)", function()
			local E = deps.Net.ErrorCode
			t:eq(HF.errorTextKey(E.TOO_FAR), "Error.TooFar")
			t:eq(HF.errorTextKey(E.BUSY), "Error.Busy")
			t:eq(HF.errorTextKey(E.NOT_UNLOCKED), "Error.NotUnlocked")
			t:eq(HF.errorTextKey(E.RATE_LIMITED), "Error.RateLimited")
			t:eq(HF.errorTextKey(E.NOT_IMPLEMENTED), "Error.NotImplemented")
			t:eq(HF.errorTextKey(E.INTERNAL), "Error.Generic")
			t:eq(HF.errorTextKey(nil), "Error.Generic")
			t:eq(HF.errorTextKey(42), "Error.Generic")
			t:eq(HF.noticeTextKey(E.TOO_FAR), "Notice.GatherStopped")
			t:eq(HF.noticeTextKey(E.STORAGE_FULL), "Notice.StorageFull")
			t:eq(HF.noticeTextKey(E.BUSY), "Error.Busy", "Notify 전용이 아니면 RF 와 같은 문구")
			-- 対応先の文言キーは全部 Text にある（表示時に Text.get が error にならない）
			for _, key in HF.ERROR_TEXT_KEYS do
				t:ok(deps.Text.STRINGS[key] ~= nil, key)
			end
			for _, key in HF.NOTICE_TEXT_KEYS do
				t:ok(deps.Text.STRINGS[key] ~= nil, key)
			end
			t:ok(deps.Text.STRINGS[HF.GENERIC_ERROR_KEY] ~= nil)
		end)

		t:test("State: 오래된·같은 seq 와 형식 틀린 것은 버림, 듣는 쪽 오류는 다른 쪽을 막지 않음", function()
			local clock = 0
			local st = deps.ClientState.new(function()
				return clock
			end, HF)
			local got = {}
			st:onChanged(function(_s: any)
				error("listener boom")
			end)
			st:onChanged(function(s: any)
				table.insert(got, s.seq)
			end)
			t:eq(st:apply(snap(2)), true)
			t:eq(st:apply(snap(1)), false)
			t:eq(st:apply(snap(2)), false)
			t:eq(st:apply({ seq = "3" }), false)
			t:eq(st:apply(nil), false)
			t:eq(st:apply(snap(3)), true)
			t:eq(got, { 2, 3 })
			t:eq(st:get().seq, 3)
		end)

		t:test("State: 귀환 요약은 seq 와 무관하게 처음 1번만, 꺼내면 다시 안 줌", function()
			local st = deps.ClientState.new(function()
				return 0
			end, HF)
			local report = { show = true, offlineMinutes = 120, creditedMinutes = 120, spirits = {} }
			t:eq(st:apply(snap(5)), true)
			-- 応答が push より遅れて届いた（seq は古い）が、要約は受け取る
			t:eq(st:apply(snap(4, { returnReport = report })), false)
			t:eq(st:takeReturnReport(), report)
			t:eq(st:takeReturnReport(), nil)
			t:eq(st:apply(snap(6, { returnReport = { show = true } })), true)
			t:eq(st:takeReturnReport(), nil, "한 세션에 1번")
		end)
	end,
}
