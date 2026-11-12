--!strict
-- DataStoreAdapter: 実 DataStore とメモリ上の MockStore の切り替え（計画書 4.4 節「Studio とライブの分離」）
-- 配置: ServerScriptService.Server.Data.DataStoreAdapter（Rojo: game/src/server/Data/DataStoreAdapter.luau）
-- 依存: なし。実ストアは呼び出し側（Main）が DataStoreService を渡して作る。モジュール読み込み時に Roblox API を呼ばない
--   （Mock・decide は Lune の単体テストでも動く）
--
-- 選択規則（decide）:
-- - UserId ≤ 0（Studio のローカルテストプレイヤー）→ Mock
-- - Studio 以外（ライブサーバー）→ 実ストア（env "live"）。ライブでは Mock に落とさない（黙ってデータを失わないため）
-- - Studio → 既定 Mock。Config.STUDIO_USE_REAL_DATASTORE=true かつ API 接続確認（probe）が通ったときだけ実ストア（env "dev"）
-- 実ストアの書き込みは UpdateAsync だけ。変換関数の戻り値に userIds を付ける（公式文書: 内容・IP の追跡と削除のため）。

local DataStoreAdapter = {}

export type Transform = (old: any) -> any -- nil を返すと書き込みを取り消す
export type Store = {
	kind: "mock" | "real",
	label: string, -- ログ表示用（"Mock" / ストア名）
	-- 戻り値 (成功, 新しい値 | nil(取り消し) | エラーメッセージ)
	update: (self: Store, key: string, transform: Transform, userIds: { number }) -> (boolean, any),
}

local function deepCopy(v: any): any
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, x in v do
		out[k] = deepCopy(x)
	end
	return out
end
DataStoreAdapter.deepCopy = deepCopy

-- ストア名・キー（計画書 4.4: PlayerSave_<env>、u_<UserId>、どちらも 50 字以内）
function DataStoreAdapter.storeName(prefix: string, isStudio: boolean): string
	return prefix .. (if isStudio then "dev" else "live")
end

function DataStoreAdapter.key(userId: number): string
	return "u_" .. string.format("%d", userId)
end

-- 選択（純粋関数）。realAvailable は Studio で実ストアの API 接続確認が通ったか（ライブでは無視）
function DataStoreAdapter.decide(isStudio: boolean, useRealInStudio: boolean, realAvailable: boolean, userId: number): "mock" | "real"
	if userId <= 0 then
		return "mock"
	end
	if not isStudio then
		return "real"
	end
	if useRealInStudio and realAvailable then
		return "real"
	end
	return "mock"
end

-- ---- MockStore（メモリ。サーバー終了で消える） ----
-- 実ストアと同じく値はコピーで出し入れする（呼び出し側が手元のテーブルを変えても保存値は変わらない）。
-- テスト用: failNext(n) で次の n 回の update を失敗させる、peek/poke で中身を直接見る・置く。
export type MockStore = Store & {
	data: { [string]: any },
	userIds: { [string]: { number } },
	calls: number,
	failCount: number,
	failNext: (self: MockStore, n: number) -> (),
	peek: (self: MockStore, key: string) -> any,
	poke: (self: MockStore, key: string, value: any) -> (),
}

local function mockUpdate(self: any, key: string, transform: Transform, userIds: { number }): (boolean, any)
	self.calls += 1
	if self.failCount > 0 then
		self.failCount -= 1
		return false, "MockStore: 주입된 실패"
	end
	local okT, new = pcall(transform, deepCopy(self.data[key]))
	if not okT then
		return false, `MockStore: transform 오류: {tostring(new)}`
	end
	if new == nil then
		return true, nil
	end
	self.data[key] = deepCopy(new)
	self.userIds[key] = table.clone(userIds)
	return true, deepCopy(new)
end

function DataStoreAdapter.newMock(): MockStore
	local m = {
		kind = "mock",
		label = "Mock",
		data = {},
		userIds = {},
		calls = 0,
		failCount = 0,
	}
	function m.update(self: any, key: string, transform: Transform, userIds: { number }): (boolean, any)
		return mockUpdate(self, key, transform, userIds)
	end
	function m.failNext(self: any, n: number)
		self.failCount = n
	end
	function m.peek(self: any, key: string): any
		return deepCopy(self.data[key])
	end
	function m.poke(self: any, key: string, value: any)
		self.data[key] = deepCopy(value)
	end
	return (m :: any) :: MockStore
end

-- ---- 実ストア（Studio 未検証） ----
-- dataStoreService: game:GetService("DataStoreService")、name: storeName(...)、wait: task.wait、budgetWaitSeconds: 予算待ちの上限
function DataStoreAdapter.newReal(dataStoreService: any, name: string, wait: (number) -> (), budgetWaitSeconds: number): Store
	local ds = dataStoreService:GetDataStore(name)
	local s = { kind = "real", label = name }
	function s.update(_self: any, key: string, transform: Transform, userIds: { number }): (boolean, any)
		-- 要求予算が尽きていれば少し待つ（公式 best practices。待っても尽きていれば投げて呼び出し側の再試行に任せる）
		local waited = 0
		while waited < budgetWaitSeconds do
			local okB, budget = pcall(function()
				return dataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync)
			end)
			if not okB or budget >= 1 then
				break
			end
			wait(1)
			waited += 1
		end
		return pcall(function()
			return (ds :: any):UpdateAsync(key, function(old: any, _keyInfo: any)
				local new = transform(old)
				if new == nil then
					return nil
				end
				return new, userIds
			end)
		end)
	end
	return (s :: any) :: Store
end

-- Studio で実ストアを使えるか（API 接続確認）。書き込みはせず GetAsync だけを呼ぶ。
-- 「Enable Studio Access to API Services」が無効・未公開の place などはここで失敗し、呼び出し側は Mock を使う
function DataStoreAdapter.probeReal(dataStoreService: any, name: string): (boolean, string?)
	local ok, err = pcall(function()
		local ds = dataStoreService:GetDataStore(name)
		ds:GetAsync("probe_studio_access")
	end)
	if ok then
		return true, nil
	end
	return false, tostring(err)
end

return table.freeze(DataStoreAdapter)
