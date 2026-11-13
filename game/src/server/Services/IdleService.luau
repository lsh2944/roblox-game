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

local IdleService = {}
IdleService.__index = IdleService

export type IdleService = typeof(setmetatable({} :: { IdleCalc: any, econ: any }, IdleService))

function IdleService.new(IdleCalc: any, econ: any): IdleService
	return setmetatable({ IdleCalc = IdleCalc, econ = econ }, IdleService)
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
function IdleService.settle(self: IdleService, save: any, nowSec: number, offline: boolean): any
	local input = IdleService.input(save, offline)
	local r = self.IdleCalc.settle(self.econ, input, nowSec // 60)
	-- ここまで来たら成功。wallet・carry・settled_min を一度に反映する（error なら上で抜けて保存データは不変）
	replaceContents(save.wallet, input.wallet)
	replaceContents(save.carry, input.carry)
	save.settled_min = r.newSettledMin
	return r
end

-- 保存直前の処理: オンライン精算して最終オンライン時刻を記録する（PlayerDataService の beforeSave フック）
function IdleService.beforeSave(self: IdleService, save: any, nowSec: number): any
	local r = self:settle(save, nowSec, false)
	save.last_online_at = math.max(save.last_online_at, nowSec)
	return r
end

return IdleService
