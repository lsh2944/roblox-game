--!strict
-- IdleService: 保存データ（PlayerSaveV1）に対する放置生産の精算（IdleCalc の包み）
-- 配置: ServerScriptService.Server.Services.IdleService（Rojo: game/src/server/Services/IdleService.luau）
-- 依存: ReplicatedStorage.Shared.IdleCalc と Economy インスタンス（new の引数で受け取る）。Roblox API 不使用（Lune でも動く）
--
-- 計画書 4.4「오프라인 정산」:
-- - 読み込み直後（オフライン）: 認定区間 [settled_min, min(now, last_online_at + offline_cap_hours×60)]、超過は失効
-- - オンライン中（保存前・状態変更前）: [settled_min, now] をそのまま認定
-- - now < settled_min（サーバー間の時計差・Clock オフセットを戻した場合）は積算しない。settled_min は戻さない
-- - 精算は wallet・carry の写しで計算し、最後まで成功したときだけ settled_min と一緒に保存データへ反映する
--   （途中で失敗＝assertSafe などの error なら保存データは何も変わらない。部分的な積算を残さない）
-- 活力はオフライン中も遅延評価（vigor_ticks, vigor_min）で回復するのでここでは触らない。
--
-- 帰還収穫の要約（2026-11-13 ユーザー決定、表示専用・経済影響 0）:
-- - settleOnLoad（読み込み直後のオフライン精算）の結果から IdleCalc.spiritBreakdown・returnReport で要約を作り、
--   userId 別のセッションメモリ（self.reports）にだけ置く。保存しない。wallet・carry・settled_min・保存スキーマは変えない
-- - 要約の作成は精算の反映後に pcall で包む: 失敗しても精算・保存は変わらず、要約が nil になってログを出すだけ
-- - 読み出しは getReturnReport（S5 GetSnapshot で使う予定）、退出時は clearReturnReport（Main の PlayerRemoving）
-- - 表示の閾値（オフライン経過の分）は opts.reportMinOfflineMinutes（Main は Config.RETURN_REPORT_MIN_OFFLINE_MINUTES）。
--   opts が無ければ要約を作らない（既存の呼び出し・テストはそのまま）

local IdleService = {}
IdleService.__index = IdleService

export type Opts = {
	reportMinOfflineMinutes: number, -- 帰還要約を表示するオフライン経過（分）の下限
	log: ((msg: string) -> ())?,
}

export type IdleService = typeof(setmetatable(
	{} :: { IdleCalc: any, econ: any, opts: Opts?, reports: { [number]: any } },
	IdleService
))

function IdleService.new(IdleCalc: any, econ: any, opts: Opts?): IdleService
	return setmetatable({ IdleCalc = IdleCalc, econ = econ, opts = opts, reports = {} }, IdleService)
end

-- dst の中身を src と同じにする（テーブルの同一性は保つ: 他から save.wallet を参照していても新しい値が見える）
local function replaceContents(dst: { [any]: any }, src: { [any]: any })
	for k in dst do
		if src[k] == nil then
			dst[k] = nil
		end
	end
	for k, v in src do
		dst[k] = v
	end
end

-- 保存データ → IdleCalc.SettleInput。wallet・carry は写し（値は整数だけなので浅い写しで足りる）。
-- IdleCalc.settle は input.wallet・input.carry を書き換えるので、保存データへの反映は settle が担う
function IdleService.input(save: any, offline: boolean): any
	return {
		wallet = table.clone(save.wallet),
		carry = table.clone(save.carry),
		settledMin = save.settled_min,
		offlineSinceMin = if offline then save.last_online_at // 60 else nil,
		offlineCapHours = save.offline_cap_hours,
		facilities = save.facilities,
		roster = save.roster,
		dex = save.dex, -- 図鑑（資源別の図鑑ボーナスは IdleCalc が Economy.dexMap で求める）
		researchIdleBps = nil, -- 研究倍率のフック（MVP1 は 0）
	}
end

-- nowSec（ゲーム時計の秒）まで精算する。offline=true は読み込み直後の 1 回だけ（last_online_at から上限を数える）
-- 精算して反映する本体。戻り値 (結果, 精算に使った input)
local function settleInto(self: IdleService, save: any, nowSec: number, offline: boolean, withBreakdown: boolean): (any, any)
	local input = IdleService.input(save, offline)
	local r = if withBreakdown
		then self.IdleCalc.settle(self.econ, input, nowSec // 60, true)
		else self.IdleCalc.settle(self.econ, input, nowSec // 60)
	-- ここまで来たら成功。wallet・carry・settled_min を一度に反映する（error なら上で抜けて保存データは不変）
	replaceContents(save.wallet, input.wallet)
	replaceContents(save.carry, input.carry)
	save.settled_min = r.newSettledMin
	return r, input
end

function IdleService.settle(self: IdleService, save: any, nowSec: number, offline: boolean): any
	local r = settleInto(self, save, nowSec, offline, false)
	return r
end

-- 読み込み直後のオフライン精算 + 帰還要約（Main の onLoaded から 1 回だけ）。精算の結果を返す（settle(save, nowSec, true) と同じ反映）
function IdleService.settleOnLoad(self: IdleService, userId: number, save: any, nowSec: number): any
	self.reports[userId] = nil -- 前のセッションの要約を残さない
	local opts = self.opts
	-- オフライン経過は精算の前に読む（精算は last_online_at を変えないが、順序に依らないようにする）
	local lastOnline = save.last_online_at
	local r, input = settleInto(self, save, nowSec, true, opts ~= nil)
	if opts ~= nil then
		local o: Opts = opts
		-- 表示専用: ここから先の失敗は精算・保存に影響させない
		local ok, rep = pcall(function(): any
			local bySpirit = self.IdleCalc.spiritBreakdown(self.econ, input, r.parts)
			local offlineMinutes = math.max(0, nowSec - lastOnline) // 60
			return self.IdleCalc.returnReport(
				save.roster,
				r,
				bySpirit,
				offlineMinutes,
				o.reportMinOfflineMinutes,
				save.offline_cap_hours
			)
		end)
		if ok then
			self.reports[userId] = rep
		else
			local f = o.log
			if f ~= nil then
				f(`[Idle] u_{userId} 귀환 요약 생성 실패(정산은 반영됨): {tostring(rep)}`)
			end
		end
	end
	return r
end

-- 帰還要約（IdleCalc.ReturnReport）。無い・作成失敗・新規プレイヤーなら nil
function IdleService.getReturnReport(self: IdleService, userId: number): any
	return self.reports[userId]
end

-- 退出時・表示済みの破棄
function IdleService.clearReturnReport(self: IdleService, userId: number)
	self.reports[userId] = nil
end

-- 保存直前の処理: オンライン精算して最終オンライン時刻を記録する（PlayerDataService の beforeSave フック）
function IdleService.beforeSave(self: IdleService, save: any, nowSec: number): any
	local r = self:settle(save, nowSec, false)
	save.last_online_at = math.max(save.last_online_at, nowSec)
	return r
end

return IdleService
