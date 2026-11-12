--!strict
-- PlayerDataService: 読み込み・セッション錠・自動保存・退出・終了時保存（計画書 4.4 節、Q7 決定: UpdateAsync で自前実装）
-- 配置: ServerScriptService.Server.Data.PlayerDataService（Rojo: game/src/server/Data/PlayerDataService.luau）
-- 依存: 同じフォルダの SaveSchema・Migrations・DataStoreAdapter（require-by-string）。
--   Roblox API はすべて new の deps で受け取る（Main が task.wait・task.spawn・Players・DataStore・GUID 生成を渡す）。
--   追放の文言は deps.text（Main が ReplicatedStorage.Shared.Text.get を渡す）でキーから引く。
--   錠・版上げの判定は純粋関数 transformLoad / transformSave に分け、サービス本体も MockStore と同期 deps で Lune から試せる。
--
-- 規則:
-- - 錠 = session { server_id, token, locked_at }。token は読み込みのたびに作るセッション固有の GUID
--   （同じサーバーへの再入室で、前のセッションの遅れた書き込みが新しいセッションの内容を上書きしないため）
-- - 読み込み = UpdateAsync。他サーバーの錠が TTL 内なら書き込みを取り消して再試行（指数バックオフ + ジッター、上限回数）、
--   尽きたら案内つきで追放。TTL 切れの錠と、locked_at が TTL を超えて未来の錠（壊れた錠）は奪う（"taken"）。
--   同じサーバーの錠は token が違っても読み込む（このサーバーに同じプレイヤーの有効なプロフィールが無いことは loadAsync が確かめる）。
--   保存の版がコードより新しい・形が壊れていれば読み込まず追放
-- - 保存 = UpdateAsync。錠の server_id と token が自分のセッションと一致するときだけ書き、locked_at を更新する。
--   一致しなければ保存をやめて追放。ただし書き込みの各試行と追放の前に、自分のプロフィールがまだ登録中（profiles[userId] が同じ
--   オブジェクト）かを確かめ、外れていれば何も書かず追放もしない（"stale"。再入室した新しいセッションを壊さない）
-- - 退出・終了: session=nil で書いて錠を外す。PlayerRemoving と BindToClose が重なっても書くのは 1 回（state="releasing"）
-- - 自動保存: プレイヤーごとに初回をずらす（AUTOSAVE_SECONDS の 1/2〜1 倍）

local SaveSchema = require("./SaveSchema")
local Migrations = require("./Migrations")
local DataStoreAdapter = require("./DataStoreAdapter")

local deepCopy = DataStoreAdapter.deepCopy

local PlayerDataService = {}
PlayerDataService.__index = PlayerDataService

export type LoadDecision = "new" | "loaded" | "taken" | "locked" | "newer_schema" | "corrupt"
export type SaveDecision = "saved" | "released" | "lost_lock" | "newer_schema" | "missing"

-- ---- 純粋関数 ----

export type LoadCtx = { serverId: string, token: string, lockNow: number, ttl: number, makeNew: () -> any }

-- 読み込みの変換。戻り値 (書く値 | nil = 取り消し, 判定)
function PlayerDataService.transformLoad(old: any, ctx: LoadCtx): (any, LoadDecision)
	if old == nil then
		local s = ctx.makeNew()
		s.session = { server_id = ctx.serverId, token = ctx.token, locked_at = ctx.lockNow }
		s.updated_at = ctx.lockNow
		return s, "new"
	end
	local save, code = Migrations.migrate(old)
	if save == nil then
		return nil, if code == "newer_schema" then "newer_schema" else "corrupt"
	end
	local okShape = SaveSchema.check(save)
	if not okShape then
		return nil, "corrupt"
	end
	local decision: LoadDecision = "loaded"
	local sess = save.session
	if sess ~= nil and sess.server_id ~= ctx.serverId then
		-- 時計差で locked_at が少し未来でも TTL 内とみなす（錠を守る側に倒す）。ただし TTL を超えて未来なら
		-- 自動保存の更新で説明できないので壊れた錠とみなして奪う（そうしないと時計が追いつくまで永久に入れない）
		local age = ctx.lockNow - sess.locked_at
		if age < ctx.ttl and -age <= ctx.ttl then
			return nil, "locked"
		end
		decision = "taken"
	end
	save.session = { server_id = ctx.serverId, token = ctx.token, locked_at = ctx.lockNow }
	save.updated_at = ctx.lockNow
	return save, decision
end

export type SaveCtx = { serverId: string, token: string, lockNow: number, data: any, release: boolean }

-- 保存の変換。自分のセッション（server_id と token の両方が一致）が錠の持ち主のときだけ data を書く。release=true なら錠を外す
function PlayerDataService.transformSave(old: any, ctx: SaveCtx): (any, SaveDecision)
	if type(old) ~= "table" then
		return nil, "missing"
	end
	local v = old.save_schema
	if type(v) == "number" and v > Migrations.CURRENT then
		return nil, "newer_schema"
	end
	local s = old.session
	if type(s) ~= "table" or s.server_id ~= ctx.serverId or s.token ~= ctx.token then
		return nil, "lost_lock"
	end
	local new = deepCopy(ctx.data)
	new.save_schema = Migrations.CURRENT
	new.session = if ctx.release then nil else { server_id = ctx.serverId, token = ctx.token, locked_at = ctx.lockNow }
	new.updated_at = ctx.lockNow
	return new, if ctx.release then "released" else "saved"
end

-- 再試行の待ち秒（指数バックオフ + ジッター、上限つき）。r は [0,1) の一様乱数
function PlayerDataService.backoffSeconds(attempt: number, base: number, cap: number, r: number): number
	local raw = math.min(cap, base * 2 ^ (attempt - 1))
	return raw * (0.5 + 0.5 * r)
end

-- ---- サービス ----

export type Deps = {
	serverId: string, -- HttpService:GenerateGUID()（Studio では JobId が空のことがあるので使わない）
	newToken: () -> string, -- セッション token（HttpService:GenerateGUID()。読み込みのたびに呼ぶ）
	storeFor: (userId: number) -> any, -- DataStoreAdapter.Store
	lockNow: () -> number, -- 実時間 os.time()（錠・updated_at・自動保存の予定）
	gameNow: () -> number, -- ゲーム時計 Clock:now()（新規状態・精算・last_online_at）
	makeNew: (nowSec: number) -> any, -- SaveSchema.newSave を包んだもの
	wait: (seconds: number) -> (),
	spawn: (fn: () -> ()) -> (),
	random: () -> number,
	kick: (userId: number, message: string) -> (),
	text: (key: string) -> string, -- プレイヤー向け文言（Shared.Text.get）
	isPresent: (userId: number) -> boolean,
	log: (msg: string) -> (),
	onLoaded: ((userId: number, save: any, decision: string, nowSec: number) -> ())?,
	beforeSave: ((save: any, nowSec: number) -> ())?,
	config: any, -- Config（LOCK_TTL_SECONDS など）
}

export type Profile = {
	userId: number,
	key: string,
	token: string, -- このセッションの錠 token
	store: any,
	save: any,
	state: "active" | "releasing" | "released" | "lost" | "failed",
	saving: boolean,
	noHooks: boolean, -- 読み込み後フックが失敗した（精算できない）ので、保存前フックを呼ばずに錠だけ外す
	nextAutosaveAt: number,
	lastSavedAt: number?,
}

export type Service = typeof(setmetatable(
	{} :: {
		deps: Deps,
		profiles: { [number]: Profile },
		loading: { [number]: boolean },
		closing: boolean,
	},
	PlayerDataService
))

function PlayerDataService.new(deps: Deps): Service
	return setmetatable({ deps = deps, profiles = {}, loading = {}, closing = false }, PlayerDataService)
end

local function cfg(self: Service): any
	return self.deps.config
end

-- 条件が偽になるか上限秒に達するまで POLL 秒ずつ待つ（同期 deps のテストでも必ず終わる）
local function waitWhile(self: Service, cond: () -> boolean, maxSeconds: number)
	local poll = cfg(self).POLL_SECONDS
	local waited = 0
	while cond() and waited < maxSeconds do
		self.deps.wait(poll)
		waited += poll
	end
end

function PlayerDataService.get(self: Service, userId: number): any
	local p = self.profiles[userId]
	if p ~= nil and p.state == "active" then
		return p.save
	end
	return nil
end

function PlayerDataService.profile(self: Service, userId: number): Profile?
	return self.profiles[userId]
end

-- 読み込み（PlayerAdded から task.spawn で呼ぶ）。戻り値 (成功, 判定・理由)
function PlayerDataService.loadAsync(self: Service, userId: number): (boolean, string)
	local d, c = self.deps, cfg(self)
	if self.loading[userId] then
		return false, "busy"
	end
	self.loading[userId] = true
	-- 同じサーバーへの再入室: 前回の錠外し（releasing）が終わるのを待ってから読む（古い内容を読まないため）
	waitWhile(self, function()
		return self.profiles[userId] ~= nil
	end, c.CLOSE_WAIT_SECONDS)
	if self.profiles[userId] ~= nil then
		self.loading[userId] = nil
		d.kick(userId, d.text("Kick.LoadFailed"))
		return false, "busy"
	end
	local store = d.storeFor(userId)
	local key = DataStoreAdapter.key(userId)
	local token = d.newToken() -- 再試行の間は同じ token（書けた回の token がこのセッションのもの）
	for attempt = 1, c.LOAD_MAX_ATTEMPTS do
		if not d.isPresent(userId) then
			self.loading[userId] = nil
			return false, "left"
		end
		local decision: string? = nil
		local ok, res = store:update(key, function(old: any): any
			local new, dec = PlayerDataService.transformLoad(old, {
				serverId = d.serverId,
				token = token,
				lockNow = d.lockNow(),
				ttl = c.LOCK_TTL_SECONDS,
				makeNew = function()
					return d.makeNew(d.gameNow())
				end,
			})
			decision = dec
			return new
		end, { userId })
		if ok and type(res) == "table" and (decision == "new" or decision == "loaded" or decision == "taken") then
			return self:_activate(userId, key, token, store, res, decision :: string)
		end
		if ok and (decision == "newer_schema" or decision == "corrupt") then
			self.loading[userId] = nil
			d.log(`[PlayerData] {key} 불러오기 중단({decision}, {store.label})`)
			d.kick(userId, d.text(if decision == "newer_schema" then "Kick.NewerSchema" else "Kick.Corrupt"))
			return false, decision :: string
		end
		local why = if ok then tostring(decision) else tostring(res)
		d.log(`[PlayerData] {key} 불러오기 재시도 {attempt}/{c.LOAD_MAX_ATTEMPTS}: {why}`)
		if attempt < c.LOAD_MAX_ATTEMPTS then
			d.wait(PlayerDataService.backoffSeconds(attempt, c.RETRY_BASE_SECONDS, c.RETRY_CAP_SECONDS, d.random()))
		end
	end
	self.loading[userId] = nil
	d.kick(userId, d.text("Kick.LoadFailed"))
	return false, "load_failed"
end

function PlayerDataService._activate(
	self: Service,
	userId: number,
	key: string,
	token: string,
	store: any,
	save: any,
	decision: string
): (boolean, string)
	local d, c = self.deps, cfg(self)
	local now = d.lockNow()
	local p: Profile = {
		userId = userId,
		key = key,
		token = token,
		store = store,
		save = save,
		state = "active",
		saving = false,
		noHooks = false,
		nextAutosaveAt = now + math.floor(c.AUTOSAVE_SECONDS * (0.5 + 0.5 * d.random())),
		lastSavedAt = nil,
	}
	self.profiles[userId] = p
	self.loading[userId] = nil
	d.log(`[PlayerData] {key} 불러오기 성공({store.label}, {decision})`)
	local hook = d.onLoaded
	if hook ~= nil then
		local original = deepCopy(save)
		local okH, err = pcall(hook, userId, save, decision, d.gameNow())
		if not okH then
			-- 精算できない保存（配置 uid の欠落など）。読み込んだままの内容で錠だけ外し、上書きしない
			d.log(`[PlayerData] {key} 불러온 뒤 처리 실패: {tostring(err)}`)
			p.save = original
			p.noHooks = true
			d.kick(userId, d.text("Kick.Corrupt"))
			self:releaseAsync(userId)
			return false, "corrupt"
		end
	end
	if self.closing or not d.isPresent(userId) then
		self:releaseAsync(userId)
		return false, "left"
	end
	return true, decision
end

-- p がまだこのプレイヤーの登録中のプロフィールか（退出後に同じサーバーへ再入室すると別のオブジェクトに置き換わる）
local function isCurrent(self: Service, p: Profile): boolean
	return self.profiles[p.userId] == p
end

-- 1 回の書き込み（再試行つき）。戻り値 (成功, 判定・理由)。"stale" = プロフィールが登録から外れたので書かずにやめた
function PlayerDataService._write(self: Service, p: Profile, release: boolean): (boolean, string)
	local d, c = self.deps, cfg(self)
	if not p.noHooks and d.beforeSave ~= nil then
		local okH, err = pcall(d.beforeSave :: any, p.save, d.gameNow())
		if not okH then
			d.log(`[PlayerData] {p.key} 저장 전 정산 실패(정산 없이 저장): {tostring(err)}`)
		end
	end
	local maxAttempts = if release then c.RELEASE_MAX_ATTEMPTS else c.SAVE_MAX_ATTEMPTS
	for attempt = 1, maxAttempts do
		if not isCurrent(self, p) then
			d.log(`[PlayerData] {p.key} 이전 세션의 저장 중단(stale)`)
			return false, "stale"
		end
		local decision: string? = nil
		local lockNow = d.lockNow()
		local ok, res = p.store:update(p.key, function(old: any): any
			local new, dec = PlayerDataService.transformSave(old, {
				serverId = d.serverId,
				token = p.token,
				lockNow = d.lockNow(),
				data = p.save,
				release = release,
			})
			decision = dec
			return new
		end, { p.userId })
		if ok and (decision == "saved" or decision == "released") then
			p.lastSavedAt = lockNow
			p.save.session = if release then nil else { server_id = d.serverId, token = p.token, locked_at = lockNow }
			d.log(`[PlayerData] {p.key} {if release then "저장·잠금 해제" else "저장"} 성공({p.store.label})`)
			return true, decision :: string
		end
		if ok and (decision == "lost_lock" or decision == "newer_schema" or decision == "missing") then
			-- 他サーバー・別セッションが錠を取った（TTL 切れ・再入室）・新しい版が書いた: この内容で上書きしない
			if not isCurrent(self, p) then
				-- 再入室した新しいセッションが錠を持っている。新しい Player を追放しない
				d.log(`[PlayerData] {p.key} 이전 세션의 저장 중단(stale, {decision})`)
				return false, "stale"
			end
			p.state = "lost"
			d.log(`[PlayerData] {p.key} 저장 중단({decision}, {p.store.label})`)
			d.kick(p.userId, d.text("Kick.LostLock"))
			return false, decision :: string
		end
		d.log(`[PlayerData] {p.key} 저장 재시도 {attempt}/{maxAttempts}: {if ok then tostring(decision) else tostring(res)}`)
		if attempt < maxAttempts then
			d.wait(PlayerDataService.backoffSeconds(attempt, c.RETRY_BASE_SECONDS, c.RETRY_CAP_SECONDS, d.random()))
		end
	end
	return false, "error"
end

-- 保存（自動保存など）。保存中なら飛ばす
function PlayerDataService.saveAsync(self: Service, userId: number): (boolean, string)
	local p = self.profiles[userId]
	if p == nil or p.state ~= "active" then
		return false, "inactive"
	end
	if p.saving then
		return false, "busy"
	end
	p.saving = true
	local ok, code = self:_write(p, false)
	p.saving = false
	return ok, code
end

-- 退出・終了時の保存と錠外し。二重に呼ばれても書くのは 1 回で、後の呼び出しは先行の完了を待つ
function PlayerDataService.releaseAsync(self: Service, userId: number): boolean
	local c = cfg(self)
	local p = self.profiles[userId]
	if p == nil then
		return true
	end
	if p.state == "releasing" then
		waitWhile(self, function()
			return p.state == "releasing"
		end, c.CLOSE_WAIT_SECONDS)
		return p.state == "released"
	end
	if p.state ~= "active" then
		self.profiles[userId] = nil
		return false
	end
	p.state = "releasing"
	waitWhile(self, function()
		return p.saving
	end, c.CLOSE_WAIT_SECONDS)
	local ok = self:_write(p, true)
	if p.state == "releasing" then
		p.state = if ok then "released" else "failed"
	end
	if self.profiles[userId] == p then
		self.profiles[userId] = nil
	end
	return ok
end

-- 自動保存の予定（Main が 1 秒ごとに呼ぶ）。期限の来たプレイヤーだけ spawn で保存する
function PlayerDataService.autosaveTick(self: Service)
	local d, c = self.deps, cfg(self)
	if self.closing then
		return
	end
	local now = d.lockNow()
	local due = {}
	for userId, p in self.profiles do
		if p.state == "active" and not p.saving and p.nextAutosaveAt <= now then
			p.nextAutosaveAt = now + c.AUTOSAVE_SECONDS
			table.insert(due, userId)
		end
	end
	for _, userId in due do
		d.spawn(function()
			self:saveAsync(userId)
		end)
	end
end

-- BindToClose: 全員を並列に保存・錠外しし、読み込み中のものも含めて終わるか上限秒まで待つ
function PlayerDataService.closeAll(self: Service)
	local d, c = self.deps, cfg(self)
	self.closing = true
	local ids = {}
	for userId in self.profiles do
		table.insert(ids, userId)
	end
	local pending = #ids
	for _, userId in ids do
		d.spawn(function()
			self:releaseAsync(userId)
			pending -= 1
		end)
	end
	waitWhile(self, function()
		return pending > 0 or next(self.loading) ~= nil or next(self.profiles) ~= nil
	end, c.CLOSE_WAIT_SECONDS)
end

return PlayerDataService
