--!strict
-- SessionCleanup: 退出・サーバー終了で保存する前の、実行時だけの状態の後始末（S6〜S9 レビュー Minor 3、2026-11-12）
-- 配置: ServerScriptService.Server.Services.SessionCleanup（Rojo: game/src/server/Services/SessionCleanup.luau）
-- 依存（run の deps で注入）: Services の CaptureService・GatherService・WildSpawnService・Activity インスタンス、log（任意）。
--   Roblox API 不使用（Lune でも動く）
--
-- 順番（変えない。CaptureServiceSpec が固定する）:
-- 1. capture:finish — 遭遇中なら今すぐ確定・反映する（捕獲した精霊・図鑑・統計を保存に入れる。精算フックもここで走る）
-- 2. gather:stop — 採集をその時点まで積算して閉じる
-- 3. wild:clear — 野生精霊（保存しない）を消す
-- 4. activity:clear — 活動の残りを消す（1・2 で消えているはずの防御）
-- 各段は pcall で包み、1 つが失敗しても残りの段と、その後の保存（releaseAsync）を止めない（失敗は log と戻り値の errors）。
--
-- 呼び出し位置（Main の結線は Studio 段階。Main.server.luau の TODO 参照）:
-- - PlayerRemoving: playerData:releaseAsync(userId) の前に SessionCleanup.run(deps, userId, playerData:get(userId), clock:now())
-- - BindToClose: playerData:closeAll() の前に、読み込み済みの全員へ同じ呼び出し
-- 保存データが無い（読み込み前・失敗）ときは save = nil で呼んでよい: 保存に触れる 1・2 を飛ばし、3・4 だけ行う。

local SessionCleanup = {}

export type Deps = {
	capture: any,
	gather: any,
	wild: any,
	activity: any,
	log: ((msg: string) -> ())?,
}

export type Result = {
	capture: any?, -- capture:finish の反映結果（遭遇中でなければ nil）
	gathered: number, -- 採集の積算（milli）
	errors: { string }, -- 失敗した段（"capture: …" など）
}

function SessionCleanup.run(deps: Deps, userId: number, save: any?, nowSec: number): Result
	local out: Result = { capture = nil, gathered = 0, errors = {} }
	local function step(name: string, fn: () -> ())
		local ok, err = pcall(fn)
		if not ok then
			local msg = `{name}: {tostring(err)}`
			table.insert(out.errors, msg)
			local f = deps.log
			if f ~= nil then
				f(`[Session] u_{userId} 정리 실패 {msg}`)
			end
		end
	end
	if save ~= nil then
		step("capture", function()
			out.capture = deps.capture:finish(userId, save, nowSec)
		end)
		step("gather", function()
			out.gathered = deps.gather:stop(userId, save, nowSec)
		end)
	end
	step("wild", function()
		deps.wild:clear(userId)
	end)
	step("activity", function()
		deps.activity:clear(userId)
	end)
	return out
end

return table.freeze(SessionCleanup)
