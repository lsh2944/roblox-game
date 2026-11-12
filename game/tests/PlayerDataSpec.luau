--!strict
-- PlayerDataSpec: セッション錠と保存の変換（純粋関数）、MockStore と同期 deps でのサービス全体（読み込み・再試行・追放・
--   自動保存・退出と BindToClose の 1 回保存・錠喪失）、保存先の選択規則
-- 配置: ServerStorage.Tests.PlayerDataSpec（Rojo: game/tests/PlayerDataSpec.luau）
-- 依存: deps.PlayerDataService・deps.DataStoreAdapter・deps.TestKit・deps.SaveSchema・deps.Formulas・deps.CaptureLogic・deps.Config・
--   deps.Text・deps.gd
-- 期待値の出典: 計画書 4.4 節「세션 잠금」「Studio와 라이브 분리」の規則（TTL 内は取り消し・TTL 切れは奪う・
--   持ち主だけ書く・退出で session=nil・重複保存 1 回・上位版は追放・UserId ≤ 0 は Mock）、
--   S4 リビュー修正（2026-11-11 進行記録）: セッション token で同じサーバーの前セッションを区別し、前セッションは書かず追放もしない、
--   TTL を超えて未来の locked_at は壊れた錠として奪う。ユーザー決定: TTL 300 秒

local SERVER = "server-A"
local OTHER = "server-B"
local T0 = 1762819200

return {
	name = "PlayerData",
	run = function(t: any, deps: any)
		local P = deps.PlayerDataService
		local A = deps.DataStoreAdapter
		local S = deps.SaveSchema
		local Config = deps.Config
		local newCtx = {
			gd = deps.gd,
			startSpirits = Config.START_SPIRITS,
			milli = deps.Formulas.MILLI,
			vigorTick = deps.CaptureLogic.VIGOR_TICK,
		}
		local function makeNew(now: number): any
			return S.newSave(newCtx, now)
		end
		local TTL = Config.LOCK_TTL_SECONDS
		local copy = deps.TestKit.deepCopy
		local txt = deps.Text.get
		local TOK = "tok-A"

		-- 同期 deps（wait は時計を進めるだけ、spawn は即実行）。
		-- 割り込みの再現: h.onWait（次の wait の後に 1 回だけ呼ぶ）、h.beforeUpdate（次の update の直前に 1 回だけ呼ぶ）
		local function harness(opts: any?): any
			local o = opts or {}
			local h: any = {
				store = A.newMock(),
				now = T0,
				present = {} :: { [number]: boolean },
				kicks = {} :: { any },
				logs = {} :: { string },
				hookCalls = {} :: { string },
				tokens = 0,
			}
			local function once(field: string)
				local f = h[field]
				if f ~= nil then
					h[field] = nil
					f()
				end
			end
			-- update の直前に割り込める包み（中身は h.store）
			local wrapped = {
				label = "mock",
				update = function(_self: any, key: string, fn: any, ids: any): (boolean, any)
					once("beforeUpdate")
					return h.store:update(key, fn, ids)
				end,
			}
			h.svc = P.new({
				serverId = SERVER,
				newToken = function()
					h.tokens += 1
					return `tok-{h.tokens}`
				end,
				storeFor = function(_userId: number)
					return wrapped
				end,
				lockNow = function()
					return h.now
				end,
				gameNow = function()
					return h.now
				end,
				makeNew = makeNew,
				wait = function(s: number)
					h.now += math.ceil(s)
					once("onWait")
				end,
				spawn = function(fn: () -> ())
					fn()
				end,
				random = function()
					return 0.5
				end,
				kick = function(userId: number, msg: string)
					table.insert(h.kicks, { userId, msg })
					h.present[userId] = nil
				end,
				isPresent = function(userId: number)
					return h.present[userId] == true
				end,
				text = txt,
				log = function(msg: string)
					table.insert(h.logs, msg)
				end,
				onLoaded = o.onLoaded or function(_userId: number, _save: any, decision: string, _now: number)
					table.insert(h.hookCalls, "loaded:" .. decision)
				end,
				beforeSave = function(save: any, now: number)
					table.insert(h.hookCalls, "beforeSave")
					save.last_online_at = now
				end,
				config = Config,
			})
			return h
		end

		t:test("transformLoad: 없음→신규, 같은 서버·만료 잠금은 가져옴, TTL 안 다른 서버는 취소", function()
			local base = { serverId = SERVER, token = TOK, lockNow = T0, ttl = TTL, makeNew = function()
				return makeNew(T0 - 5)
			end }
			local s, d = P.transformLoad(nil, base)
			t:eq(d, "new")
			t:eq(s.session, { server_id = SERVER, token = TOK, locked_at = T0 })
			t:eq(s.created_at, T0 - 5)
			t:eq(s.updated_at, T0)

			local old = makeNew(T0 - 100)
			t:eq(select(2, P.transformLoad(copy(old), base)), "loaded")
			old.session = { server_id = SERVER, locked_at = T0 - 1 }
			t:eq(select(2, P.transformLoad(copy(old), base)), "loaded")
			-- 同じサーバーの前セッション（token 違い）は読み込み、新しい token に置き換える
			old.session = { server_id = SERVER, token = "tok-old", locked_at = T0 - 1 }
			local s1, d1 = P.transformLoad(copy(old), base)
			t:eq(d1, "loaded")
			t:eq(s1.session, { server_id = SERVER, token = TOK, locked_at = T0 })
			old.session = { server_id = OTHER, token = "x", locked_at = T0 - TTL + 1 }
			t:eq({ P.transformLoad(copy(old), base) }, { nil, "locked" })
			old.session = { server_id = OTHER, locked_at = T0 + 60 } -- 時計差で少し未来
			t:eq({ P.transformLoad(copy(old), base) }, { nil, "locked" })
			old.session = { server_id = OTHER, locked_at = T0 - TTL }
			local s2, d2 = P.transformLoad(copy(old), base)
			t:eq(d2, "taken")
			t:eq(s2.session, { server_id = SERVER, token = TOK, locked_at = T0 })

			local newer = copy(old)
			newer.save_schema = 2
			t:eq({ P.transformLoad(newer, base) }, { nil, "newer_schema" })
			local broken = copy(old)
			broken.wallet = "x"
			t:eq({ P.transformLoad(broken, base) }, { nil, "corrupt" })
		end)

		t:test("transformLoad: 미래 locked_at은 TTL까지 잠금, TTL 초과면 손상 잠금으로 가져옴(TTL 300초)", function()
			t:eq(TTL, 300)
			local base = { serverId = SERVER, token = TOK, lockNow = T0, ttl = TTL, makeNew = function()
				return makeNew(T0)
			end }
			local old = makeNew(T0 - 100)
			old.session = { server_id = OTHER, token = "x", locked_at = T0 + TTL }
			t:eq({ P.transformLoad(copy(old), base) }, { nil, "locked" })
			old.session = { server_id = OTHER, token = "x", locked_at = T0 + TTL + 1 }
			local s, d = P.transformLoad(copy(old), base)
			t:eq(d, "taken")
			t:eq(s.session, { server_id = SERVER, token = TOK, locked_at = T0 })
			-- 過去側の境界（既存規則）: TTL − 1 秒前は錠、ちょうど TTL 秒前は奪う
			old.session = { server_id = OTHER, token = "x", locked_at = T0 - TTL + 1 }
			t:eq(select(2, P.transformLoad(copy(old), base)), "locked")
			old.session = { server_id = OTHER, token = "x", locked_at = T0 - TTL }
			t:eq(select(2, P.transformLoad(copy(old), base)), "taken")
		end)

		t:test("Config: 잠금 TTL은 자동 저장 2회 연속 실패를 견딤(TTL > 3 × 주기)", function()
			t:eq(Config.LOCK_TTL_SECONDS, 300)
			t:eq(Config.LOCK_TTL_SECONDS > 3 * Config.AUTOSAVE_SECONDS, true)
		end)

		t:test("transformSave: 소유자(server_id·token 일치)만 쓰고 locked_at 갱신, release면 session=nil", function()
			local data = makeNew(T0)
			data.wallet.dew = 5
			local old = makeNew(T0)
			old.session = { server_id = SERVER, token = TOK, locked_at = T0 - 90 }
			local ctx = { serverId = SERVER, token = TOK, lockNow = T0, data = data, release = false }
			local s, d = P.transformSave(old, ctx)
			t:eq(d, "saved")
			t:eq(s.session, { server_id = SERVER, token = TOK, locked_at = T0 })
			t:eq(s.wallet.dew, 5)
			s.wallet.dew = 99
			t:eq(data.wallet.dew, 5) -- 書く値は手元の状態のコピー
			local r, d2 = P.transformSave(old, { serverId = SERVER, token = TOK, lockNow = T0, data = data, release = true })
			t:eq(d2, "released")
			t:eq(r.session, nil)
			old.session = { server_id = OTHER, token = TOK, locked_at = T0 }
			t:eq({ P.transformSave(old, ctx) }, { nil, "lost_lock" })
			-- 同じサーバーでも別セッション（再入室後の新しい token）・token の無い錠には書かない
			old.session = { server_id = SERVER, token = "tok-new", locked_at = T0 }
			t:eq({ P.transformSave(old, ctx) }, { nil, "lost_lock" })
			t:eq({ P.transformSave(old, { serverId = SERVER, token = TOK, lockNow = T0, data = data, release = true }) }, { nil, "lost_lock" })
			old.session = { server_id = SERVER, locked_at = T0 }
			t:eq({ P.transformSave(old, ctx) }, { nil, "lost_lock" })
			old.session = nil
			t:eq({ P.transformSave(old, ctx) }, { nil, "lost_lock" })
			t:eq({ P.transformSave(nil, ctx) }, { nil, "missing" })
			old.session = { server_id = SERVER, token = TOK, locked_at = T0 }
			old.save_schema = 2
			t:eq({ P.transformSave(old, ctx) }, { nil, "newer_schema" })
		end)

		t:test("backoff: 지수 증가·상한·지터 0.5~1.0배", function()
			t:eq(P.backoffSeconds(1, 1, 8, 0), 0.5)
			t:eq(P.backoffSeconds(3, 1, 8, 1), 4)
			t:eq(P.backoffSeconds(4, 1, 8, 0.5), 6)
			t:eq(P.backoffSeconds(10, 1, 8, 0), 4)
		end)

		t:test("저장소 선택: UserId≤0·Studio 기본은 Mock, 라이브는 항상 실제", function()
			t:eq(A.decide(true, false, true, 123), "mock")
			t:eq(A.decide(true, true, false, 123), "mock")
			t:eq(A.decide(true, true, true, 123), "real")
			t:eq(A.decide(true, true, true, -1), "mock")
			t:eq(A.decide(false, false, false, 123), "real")
			t:eq(A.decide(false, false, false, 0), "mock")
			t:eq(A.key(123), "u_123")
			t:eq(A.storeName("PlayerSave_", true), "PlayerSave_dev")
			t:eq(A.storeName("PlayerSave_", false), "PlayerSave_live")
			t:eq(Config.STUDIO_USE_REAL_DATASTORE, false)
		end)

		t:test("서비스: 신규 불러오기 → 잠금 기록, 자동 저장, 퇴장 시 1회만 저장·해제", function()
			local h = harness()
			h.present[7] = true
			t:eq({ h.svc:loadAsync(7) }, { true, "new" })
			local stored = h.store:peek("u_7")
			t:eq(stored.session, { server_id = SERVER, token = "tok-1", locked_at = T0 })
			t:eq(h.store.userIds["u_7"], { 7 })
			t:eq(h.svc:get(7).wallet, { wick = 21000 })
			t:eq(h.hookCalls, { "loaded:new" })
			-- 自動保存: 初回は AUTOSAVE の 1/2〜1 倍後（random=0.5 → 0.75 倍）
			local due = h.svc:profile(7).nextAutosaveAt
			t:eq(due, T0 + math.floor(Config.AUTOSAVE_SECONDS * 0.75))
			h.now = due - 1
			local calls = h.store.calls
			h.svc:autosaveTick()
			t:eq(h.store.calls, calls)
			h.now = due
			h.svc:get(7).wallet.dew = 1234
			h.svc:autosaveTick()
			t:eq(h.store.calls, calls + 1)
			t:eq(h.store:peek("u_7").session.locked_at, due)
			t:eq(h.store:peek("u_7").wallet.dew, 1234)
			t:eq(h.store:peek("u_7").last_online_at, due)
			t:eq(h.svc:profile(7).nextAutosaveAt, due + Config.AUTOSAVE_SECONDS)
			-- 退出 + BindToClose の重複
			h.present[7] = nil
			calls = h.store.calls
			t:eq(h.svc:releaseAsync(7), true)
			h.svc:closeAll()
			t:eq(h.svc:releaseAsync(7), true)
			t:eq(h.store.calls, calls + 1)
			t:eq(h.store:peek("u_7").session, nil)
			t:eq(h.svc:get(7), nil)
		end)

		t:test("서비스: 다른 서버 잠금(TTL 안)이면 재시도 후 추방, 저장 내용은 그대로", function()
			local h = harness()
			local old = makeNew(T0 - 1000)
			old.session = { server_id = OTHER, locked_at = T0 }
			h.store:poke("u_8", old)
			h.present[8] = true
			t:eq({ h.svc:loadAsync(8) }, { false, "load_failed" })
			t:eq(h.store.calls, Config.LOAD_MAX_ATTEMPTS)
			t:eq(h.kicks, { { 8, txt("Kick.LoadFailed") } })
			t:eq(h.store:peek("u_8"), old)
			t:eq(h.svc:get(8), nil)
		end)

		t:test("서비스: 만료 잠금은 가져오고 오프라인 정산 훅에 'taken' 전달", function()
			local h = harness()
			local old = makeNew(T0 - 5000)
			old.session = { server_id = OTHER, locked_at = T0 - TTL - 1 }
			h.store:poke("u_9", old)
			h.present[9] = true
			t:eq({ h.svc:loadAsync(9) }, { true, "taken" })
			t:eq(h.store:peek("u_9").session.server_id, SERVER)
			t:eq(h.hookCalls, { "loaded:taken" })
		end)

		t:test("서비스: 상위 버전 저장은 1회 만에 추방하고 덮어쓰지 않음", function()
			local h = harness()
			local old = makeNew(T0)
			old.save_schema = 2
			h.store:poke("u_10", old)
			h.present[10] = true
			t:eq({ h.svc:loadAsync(10) }, { false, "newer_schema" })
			t:eq(h.store.calls, 1)
			t:eq(h.kicks, { { 10, txt("Kick.NewerSchema") } })
			t:eq(h.store:peek("u_10"), old)
		end)

		t:test("서비스: 요청 실패 2회 뒤 성공, 불러오는 중 퇴장하면 쓰지 않음", function()
			local h = harness()
			h.present[11] = true
			h.store:failNext(2)
			t:eq({ h.svc:loadAsync(11) }, { true, "new" })
			t:eq(h.store.calls, 3)
			local h2 = harness()
			t:eq({ h2.svc:loadAsync(12) }, { false, "left" })
			t:eq(h2.store.calls, 0)
		end)

		t:test("서비스: 잠금을 잃으면 저장을 멈추고 추방, 퇴장 때도 쓰지 않음", function()
			local h = harness()
			h.present[13] = true
			h.svc:loadAsync(13)
			local stolen = h.store:peek("u_13")
			stolen.session = { server_id = OTHER, locked_at = T0 + 1 }
			stolen.wallet.wick = 1
			h.store:poke("u_13", stolen)
			t:eq({ h.svc:saveAsync(13) }, { false, "lost_lock" })
			t:eq(h.kicks, { { 13, txt("Kick.LostLock") } })
			local calls = h.store.calls
			t:eq(h.svc:releaseAsync(13), false)
			t:eq(h.store.calls, calls)
			t:eq(h.store:peek("u_13"), stolen)
		end)

		t:test("서비스: 불러온 뒤 정산 실패면 원래 내용으로 잠금만 해제하고 추방", function()
			local h = harness({
				onLoaded = function(_u: number, save: any, _d: string, _n: number)
					save.wallet.wick = 999999
					error("정산 실패 흉내")
				end,
			})
			local old = makeNew(T0 - 100)
			h.store:poke("u_14", old)
			h.present[14] = true
			t:eq({ h.svc:loadAsync(14) }, { false, "corrupt" })
			local stored = h.store:peek("u_14")
			t:eq(stored.session, nil)
			t:eq(stored.wallet, old.wallet)
			t:eq(h.kicks, { { 14, txt("Kick.Corrupt") } })
			t:eq(h.hookCalls, {}) -- beforeSave を呼ばない
		end)

		-- 同じサーバーへの再入室: 前セッションの「退出 → 錠外し → 再入室 → 新しい読み込み」を、前セッションの自動保存の途中に割り込ませる
		local function rejoin(h: any, userId: number, newDew: number)
			t:eq(h.svc:releaseAsync(userId), true) -- 前セッションの退出（自動保存中なので待ってから錠外し）
			t:eq({ h.svc:loadAsync(userId) }, { true, "loaded" })
			h.svc:get(userId).wallet.dew = newDew
			t:eq({ h.svc:saveAsync(userId) }, { true, "saved" })
		end

		t:test("서비스: 같은 서버 재입장 — 이전 세션의 늦은 저장(요청 진행 중)은 토큰 불일치로 쓰지 않고 새 Player도 추방하지 않음", function()
			local h = harness()
			h.present[30] = true
			t:eq({ h.svc:loadAsync(30) }, { true, "new" })
			local oldP = h.svc:profile(30)
			oldP.save.wallet.dew = 111
			-- 前セッションの自動保存の UpdateAsync が届く直前に、退出・再入室・新セッションの保存が済む
			h.beforeUpdate = function()
				rejoin(h, 30, 222)
			end
			t:eq({ h.svc:saveAsync(30) }, { false, "stale" })
			local stored = h.store:peek("u_30")
			t:eq(stored.wallet.dew, 222)
			t:eq(stored.session.token, "tok-2")
			t:eq(h.kicks, {})
			t:eq(h.svc:profile(30) ~= oldP, true)
			t:eq(h.svc:profile(30).state, "active")
			t:eq(h.svc:get(30).wallet.dew, 222)
		end)

		t:test("서비스: 같은 서버 재입장 — 이전 세션의 재시도 회차는 프로필이 바뀌었으면 요청 없이 중단", function()
			local h = harness()
			h.present[31] = true
			t:eq({ h.svc:loadAsync(31) }, { true, "new" })
			local oldP = h.svc:profile(31)
			oldP.save.wallet.dew = 111
			h.store:failNext(1) -- 前セッションの自動保存 1 回目が失敗 → 再試行待ちの間に再入室
			h.onWait = function()
				rejoin(h, 31, 222)
			end
			local calls = h.store.calls
			t:eq({ h.svc:saveAsync(31) }, { false, "stale" })
			-- 失敗した 1 回 + 再入室側（錠外し・読み込み・保存）の 3 回だけ。前セッションの 2 回目は送らない
			t:eq(h.store.calls, calls + 4)
			t:eq(h.store:peek("u_31").wallet.dew, 222)
			t:eq(h.store:peek("u_31").session.token, "tok-2")
			t:eq(h.kicks, {})
			t:eq(h.svc:get(31).wallet.dew, 222)
		end)

		t:test("서비스: closeAll은 전원을 저장·해제", function()
			local h = harness()
			h.present[21] = true
			h.present[22] = true
			h.svc:loadAsync(21)
			h.svc:loadAsync(22)
			h.svc:closeAll()
			t:eq(h.store:peek("u_21").session, nil)
			t:eq(h.store:peek("u_22").session, nil)
			t:eq(next(h.svc.profiles), nil)
			-- 終了処理中の自動保存は何もしない
			local calls = h.store.calls
			h.svc:autosaveTick()
			t:eq(h.store.calls, calls)
		end)
	end,
}
