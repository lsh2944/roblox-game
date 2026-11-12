--!strict
-- Types: サーバー・クライアント共通の型定義（実行時の値は持たない）
-- 配置: ReplicatedStorage.Shared.Types（Rojo: game/src/shared/Types.luau）
-- 依存: なし
-- 保存スキーマ v1 は計画書 docs/game_mvp1_impl_plan.md 4.4 節。数値はすべて整数、roster のキーは文字列 uid。
-- 生産率など計算で出る値は保存しない（placeholder 数値が変わってもセーブが壊れないように）。

export type Cost = { resource: string, amount: number } -- amount は「個」
export type Wallet = { [string]: number } -- 資源 ID → milli

-- locked_at は実時間 os.time()（Clock のオフセットを使わない）。token は読み込みごとのセッション GUID（同じサーバーへの再入室を区別）
export type SessionLock = { server_id: string, token: string?, locked_at: number }

export type SpiritRecord = {
	species: string,
	level: number,
	gather_bps: number, -- 個体値（採集）10000..12000、開始精霊は start_spirit_bps
	combat_bps: number, -- 個体値（戦闘）
	vigor_ticks: number, -- 活力（1 点 = 60 tick）
	vigor_min: number, -- 活力の基準時刻（分）
	origin: string, -- "start" | "capture"
	caught_at: number, -- os.time()
}

export type FacilityState = {
	level: number,
	slots: number,
	assigned: { string }, -- uid 文字列（同行とは排他: 計画書 Q3）
}

export type SaveStats = { encounters: number, attempts: number, captures: number, releases: number }

export type PlayerSaveV1 = {
	save_schema: number, -- 1
	created_at: number, -- 秒（ゲーム時計 Clock:now()。以下 *_at・dex・first_capture・field_unlock_time も同じ）
	updated_at: number, -- 秒（実時間 os.time()、最後に書いた時刻）
	last_online_at: number, -- 秒（最後に保存・退出した時のゲーム時刻。オフライン上限の起点）
	session: SessionLock?,
	wallet: Wallet,
	carry: { [string]: number },
	settled_min: number, -- os.time() // 60
	unlocked: { string },
	field_unlock_time: { [string]: number },
	facilities: { [string]: FacilityState },
	tool_level: number,
	offline_cap_hours: number,
	hub_rank: number,
	storage_bonus: number,
	roster: { [string]: SpiritRecord },
	next_uid: number,
	party: { string },
	dex: { [string]: number }, -- 種 → 初登録時刻
	first_capture: { [string]: number }, -- 種 → 初捕獲時刻（直接捕獲の履歴。開始精霊は含まない）
	quest_day: number, -- 最後に受け取った UTC 日（os.time() // 86400）。未受領は -1
	next_spawn_at: number,
	stats: SaveStats,
}

-- RemoteFunction の応答
export type RemoteResult = { ok: boolean, code: string?, data: any? }

-- 遭遇の再生イベント（サーバー → クライアント）
-- CaptureLogic.encounterEvents が作る。順: reveal → weaken（弱体化するときだけ）→ attempt × 試行数 → result
export type EncounterEvent = {
	phase: string, -- "reveal" | "weaken" | "attempt" | "result"
	at: number, -- 遭遇開始からの秒（クライアントの再生時刻）
	species: string?, -- reveal: 種（Q2 決定: 灯籠を使ったときに公開）
	grade: number?, -- reveal
	seconds: number?, -- weaken: 弱体化の秒
	assist: boolean?, -- weaken: true = 灯籠の補助弱体化（同行なし・全員疲労・同行が遅い）
	attempt: number?, -- attempt: 何回目か / result: 試行数
	light: number?,
	bps: number?, -- その試行の成功率
	fleeBps: number?, -- その試行が失敗したときの逃走確率
	result: string?, -- "success" | "flee" | "wick_out"
}

return {}
