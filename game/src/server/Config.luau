--!strict
-- Config: ゲーム専用の定数（経済契約ではない値）
-- 配置: ServerScriptService.Server.Config（Rojo: game/src/server/Config.luau）
-- 依存: なし。現時点では Roblox API を使わない（Lune の単体テストも読む）。
-- Studio 判定などの Roblox API は Config では呼ばない（Main・各サービスが関数の中で game:GetService を呼ぶ）。

local Config = {}

-- 開始精霊（計画書 Q1 決定: Luau Config に複製）
-- 出典: tools/econ_sim/config/personas.json の "start".spirits（2026-11-11 時点、placeholder: ★1 3 種 Lv1）。
-- 値を変えるときは personas.json と同時に直す（data へ移す案 Q1-b は後続課題）。
-- 個体値は rules.json individual_stats.start_spirit_bps（roll_start_spirits=false）を使うので、ここには持たない。
Config.START_SPIRITS = table.freeze({
	table.freeze({ species = "sparkle", level = 1 }),
	table.freeze({ species = "dewdrop", level = 1 }),
	table.freeze({ species = "flower_lamp", level = 1 }),
})

-- MVP1（meadow スライス）が参照する data の ID。GameData.assertRefs で起動時に確認する（計画書 5 節）
Config.SLICE_REFS = table.freeze({
	spirits = { "sparkle", "dewdrop", "flower_lamp" },
	nodes = { "meadow_dew", "meadow_bloom" },
	facilities = { "dew_spring", "bloom_garden" },
	recipes = { "wick_from_meadow" },
	quests = { "daily_login" },
	questFields = { "meadow" },
	resources = { "dew", "bloom", "hunt_meadow", "wick" },
})

-- ---- 保存（S4、計画書 4.4 節。ゲーム専用の運用値で経済契約ではない） ----
-- Studio で実 DataStore（PlayerSave_dev）を使うか。既定 false = MockStore（メモリ、Play を止めると消える）。
-- true にしても「Enable Studio Access to API Services」が無効なら API 接続確認で失敗して Mock に戻る。
-- 実ストアを試すのはライブと別のテスト用 Experience だけにすること（計画書 Q9 決定）。
Config.STUDIO_USE_REAL_DATASTORE = false
Config.DATASTORE_PREFIX = "PlayerSave_" -- ストア名 = PlayerSave_dev（Studio）/ PlayerSave_live（ライブ）
-- 他サーバーの錠をこの秒数を過ぎたら奪う（自動保存が locked_at を更新する）。2026-11-11 ユーザー決定で 600 → 300 秒。
-- 自動保存の周期（AUTOSAVE_SECONDS）より十分長くする: 自動保存が 2 回続けて失敗しても錠が切れない程度（90 × 3 = 270 < 300）。
-- locked_at が lockNow よりこの秒数を超えて未来なら、時計差ではなく壊れた錠とみなして奪う。
Config.LOCK_TTL_SECONDS = 300
Config.AUTOSAVE_SECONDS = 90 -- 自動保存の周期（60〜120 秒の範囲、初回はプレイヤーごとに 1/2〜1 倍へずらす）
Config.LOAD_MAX_ATTEMPTS = 5 -- 読み込みの試行回数（錠待ち・要求失敗。尽きたら追放）
Config.SAVE_MAX_ATTEMPTS = 3 -- 自動保存 1 回あたりの試行回数（失敗しても次の周期で再び保存する）
Config.RELEASE_MAX_ATTEMPTS = 3 -- 退出・終了時の保存の試行回数
Config.RETRY_BASE_SECONDS = 1 -- 再試行の待ち = min(上限, 基準 × 2^(n−1)) × (0.5〜1.0 のジッター)
Config.RETRY_CAP_SECONDS = 8
Config.BUDGET_WAIT_SECONDS = 5 -- DataStore 要求予算が尽きているときに待つ上限
Config.CLOSE_WAIT_SECONDS = 25 -- BindToClose・錠外し待ちの上限（30 秒制限の記述は公式で未確認なので余裕を取る）
Config.POLL_SECONDS = 0.25 -- 待ち合わせの間隔
Config.AUTOSAVE_TICK_SECONDS = 1 -- 自動保存の予定を確かめる間隔
Config.DEBUG_CLOCK_ATTRIBUTE = "DebugClockOffsetSeconds" -- Studio 専用: ServerStorage のこの属性（秒）をゲーム時計に足す

-- ---- 採集・捕獲・制作（S6〜S9、ゲーム専用の運用値で経済契約ではない。半径は仮値: World 作成時に調整） ----
Config.GATHER_RADIUS = 12 -- 採集ノードからの距離の上限（studs、開始時と 1 秒ごとの再確認）
Config.GATHER_CHECK_SECONDS = 1 -- 採集の再確認の間隔
Config.GATHER_MAX_CREDIT_SECONDS = 3 -- 1 回の確認で認定する秒の上限（ループが止まっていた間を認定しすぎない）
Config.CAPTURE_RADIUS = 20 -- 野生精霊に灯籠を使える距離（studs）
-- 制作の許可リスト（計画書 4.2: スライスは wick_from_meadow だけ）と 1 回の回数上限（Remote 表 times 1..100）
Config.CRAFT_ALLOWED = table.freeze({ "wick_from_meadow" })
Config.CRAFT_MAX_TIMES = 100

-- プレイヤー向けの文言（追放の案内など）は ReplicatedStorage.Shared.Text にキーで置く（Config には持たない）

return table.freeze(Config)
