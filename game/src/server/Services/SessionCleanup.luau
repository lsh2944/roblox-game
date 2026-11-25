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
-- 呼び出し位置（S6 で Main に結線。順番は leave・closeAll が固定し、GatherLoopSpec が確かめる）:
-- - PlayerRemoving: SessionCleanup.leave = run(deps, userId, playerData:get(userId), now) → playerData:releaseAsync(userId)
-- - BindToClose: SessionCleanup.closeAll = 残っている全員に run → playerData:closeAll()
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

-- 退出: 後始末してから保存・錠外し（Main の PlayerRemoving が task.spawn の中で呼ぶ）。戻り値 = releaseAsync の結果
function SessionCleanup.leave(deps: Deps, playerData: any, userId: number, nowSec: number): boolean
	SessionCleanup.run(deps, userId, playerData:get(userId), nowSec)
	return playerData:releaseAsync(userId)
end

-- サーバー終了: userIds の全員を後始末してから closeAll（Main の BindToClose）
function SessionCleanup.closeAll(deps: Deps, playerData: any, userIds: { number }, nowSec: number)
	for _, userId in userIds do
		SessionCleanup.run(deps, userId, playerData:get(userId), nowSec)
	end
	playerData:closeAll()
end

return table.freeze(SessionCleanup)
