--!strict
-- TestKit: 依存なしの最小テスト枠組み（Studio の Dev/TestRunner と Lune の lune_run.luau が共用）
-- 配置: ServerStorage.Tests.TestKit（Rojo: game/tests/TestKit.luau）
-- 依存: なし（Roblox API 不使用）
--
-- テストモジュール（名前が "Spec" で終わる）は次の形を返す:
--   return { name = "Ledger", run = function(t: TestKit.Ctx, deps) t:test("名前", function() t:eq(実際, 期待) end) end }
-- deps は実行側が渡す依存（Formulas・Economy・GameData の build 結果など）。Spec 自身は何も require しない。

local TestKit = {}

export type Result = { pass: number, fail: number, failures: { string } }

local function deepEqual(a: any, b: any): boolean
	if type(a) ~= type(b) then
		return false
	end
	if type(a) ~= "table" then
		return a == b
	end
	for k, v in a do
		if not deepEqual(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end
TestKit.deepEqual = deepEqual

local function show(v: any, depth: number?): string
	local d = depth or 0
	if type(v) == "string" then
		return string.format("%q", v)
	end
	if type(v) ~= "table" then
		return tostring(v)
	end
	if d > 4 then
		return "{...}"
	end
	local keys = {}
	for k in v do
		table.insert(keys, k)
	end
	table.sort(keys, function(x, y)
		return tostring(x) < tostring(y)
	end)
	local parts = {}
	for _, k in keys do
		table.insert(parts, `{tostring(k)}={show(v[k], d + 1)}`)
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end
TestKit.show = show

-- 凍結されていない深いコピー（凍結済み data を書き換えて壊れたケースを作るため）
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
TestKit.deepCopy = deepCopy

local Ctx = {}
Ctx.__index = Ctx

type CtxData = { suite: string, tests: { { name: string, fn: () -> () } } }
export type Ctx = typeof(setmetatable({} :: CtxData, Ctx))

function Ctx.test(self: Ctx, name: string, fn: () -> ())
	table.insert(self.tests, { name = name, fn = fn })
end

function Ctx.eq(_self: Ctx, actual: any, expected: any, label: string?)
	if not deepEqual(actual, expected) then
		error(`{label or "eq"}: got {show(actual)} expected {show(expected)}`, 2)
	end
end

function Ctx.ok(_self: Ctx, cond: any, label: string?)
	if not cond then
		error(`{label or "ok"}: 조건 불성립`, 2)
	end
end

-- fn が error を投げること（pattern を渡したらメッセージに含まれること）
function Ctx.throws(_self: Ctx, fn: () -> (), pattern: string?, label: string?)
	local ok, err = pcall(fn)
	if ok then
		error(`{label or "throws"}: 오류가 나지 않음`, 2)
	end
	if pattern ~= nil and not string.find(tostring(err), pattern, 1, true) then
		error(`{label or "throws"}: 오류 메시지에 '{pattern}' 없음: {tostring(err)}`, 2)
	end
end

-- suites = { { name, run } }。log は 1 行ずつ出力する関数（print など）
function TestKit.runSuites(suites: { any }, deps: any, log: (string) -> ()): Result
	local res: Result = { pass = 0, fail = 0, failures = {} }
	for _, suite in suites do
		local ctx = setmetatable({ suite = suite.name, tests = {} } :: CtxData, Ctx)
		local okCollect, errCollect = pcall(suite.run, ctx, deps)
		if not okCollect then
			res.fail += 1
			local msg = `[{suite.name}] 수집 실패: {tostring(errCollect)}`
			table.insert(res.failures, msg)
			log("FAIL " .. msg)
			continue
		end
		for _, tc in ctx.tests do
			local ok, err = pcall(tc.fn)
			if ok then
				res.pass += 1
			else
				res.fail += 1
				local msg = `[{suite.name}] {tc.name}: {tostring(err)}`
				table.insert(res.failures, msg)
				log("FAIL " .. msg)
			end
		end
	end
	return res
end

-- 乱数源（ServerRng.Provider 互換）: 決まった数列を順に返す。尽きたら error（引く回数の検査にもなる）
function TestKit.seqProvider(numbers: { number }?, integers: { number }?): any
	local ni, ii = 0, 0
	return {
		number = function(): number
			ni += 1
			local v = numbers and numbers[ni]
			if v == nil then
				error(`seqProvider: number 수열이 다 떨어짐({ni})`)
			end
			return v
		end,
		integer = function(_a: number, _b: number): number
			ii += 1
			local v = integers and integers[ii]
			if v == nil then
				error(`seqProvider: integer 수열이 다 떨어짐({ii})`)
			end
			return v
		end,
	}
end

-- 乱数源の工場（標本検査用、Lune）: xorshift32。シードとストリーム名からストリームごとに別の初期値を作る
-- Studio の TestRunner は代わりに Roblox Random を使う工場を deps.sampleRngFactory に渡す
function TestKit.xorshiftFactory(seed: number): (stream: string) -> any
	return function(stream: string): any
		local x = bit32.band(seed, 0xFFFFFFFF)
		for i = 1, #stream do
			x = bit32.bxor(bit32.lrotate(x, 5), string.byte(stream, i))
		end
		if x == 0 then
			x = 2463534242
		end
		local function nextU32(): number
			x = bit32.bxor(x, bit32.lshift(x, 13))
			x = bit32.bxor(x, bit32.rshift(x, 17))
			x = bit32.bxor(x, bit32.lshift(x, 5))
			return x
		end
		return {
			number = function(): number
				return nextU32() / 4294967296
			end,
			integer = function(a: number, b: number): number
				return a + math.floor(nextU32() / 4294967296 * (b - a + 1))
			end,
		}
	end
end

function TestKit.format(r: Result): string
	return `UNIT PASS {r.pass} / FAIL {r.fail}`
end

return TestKit
