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

-- ---- 帰還収穫の要約（2026-11-13 ユーザー決定、表示専用で経済契約ではない） ----
-- オフライン経過（読み込み時のゲーム時刻 − last_online_at、分）がこれ以上なら帰還画面に出す（1 時間）
Config.RETURN_REPORT_MIN_OFFLINE_MINUTES = 60

-- ---- Remote（S5、計画書 4.3 の Remote 表。ゲーム専用の運用値で経済契約ではない） ----
-- プレイヤーごと・Remote ごとのトークンバケット（毎秒の補充数 = 容量）。超過は捨てて回数を記録する（追放しない）。
-- C→S の Remote は全部ここに載せる（RemotingSpec が Net.Directions と突き合わせる）。MoveSlot は 2026-11-12 メイン確認で AssignSlot と同じ 4/s
Config.REMOTE_RATES = table.freeze({
	GetSnapshot = 2,
	GatherStart = 2,
	GatherStop = 2,
	CaptureEngage = 1,
	SetParty = 2,
	AssignSlot = 4,
	UpgradeFacility = 2,
	Craft = 2,
	ClaimDaily = 1,
	ReleaseSpirit = 2,
	LevelUpSpirit = 4,
	MoveSlot = 4,
})
-- 引数の上限（型・形の検証用。実在するか・範囲の本当の上限はサービスが data で判定する）
Config.REMOTE_ID_MAX_LEN = 32 -- nodeId・wildId・facilityId・recipeId（Remote 表: string(≤32)）
Config.REMOTE_UID_MAX_LEN = 16 -- 精霊 uid（10 進文字列、SaveSchema.uidNum と同じ上限）
Config.REMOTE_SLOT_MAX = 64 -- slotIndex・toSlot の形の上限（実際の枠数はサービスが施設の slots で判定）
-- StateChanged（S→C）の送信間隔の下限（秒）。変更の印を付けてまとめて送る = 最大 4 回/秒（Remote 表「서버 스로틀 4/s」）
Config.PUSH_MIN_INTERVAL_SECONDS = 0.25
Config.PUSH_LOOP_SECONDS = 0.25 -- 送信ループの周期（分が変わったら全員に印を付けて財布のプレビューを送り直す。補間の上限秒は Shared.HudFormat）

-- ---- ワールド（S5、docs/world_hud_design_20261112.md 1 節。studs、Y 上、-Z = 北（フィールド側）。仮値: Studio で歩いて調整） ----
-- 部地 = 8（W1 決定: サーバー 8 人 = 部地 8 個。Experience の最大人数 8 は Studio の Game Settings で設定する）
-- 部地の中心は広場（原点）を中心に南側の半円（半径 185）、各部地は広場を向く（前 = 広場側）。
-- 座標は PlotSpec が「8 個・部地どうし／広場／フィールドと重ならない」を確かめる。ノード ID は fields.json gather_nodes[].id と一致させる
Config.WORLD = table.freeze({
	folderName = "MeadowWorld", -- Workspace 直下に実行時に作る（Rojo の管理外）
	groundY = 1, -- 地面の上面の高さ（テンプレートの Baseplate 上面 0 と重ならないよう少し上）
	plaza = table.freeze({ x = 0, z = 0, radius = 28 }),
	board = table.freeze({ x = 18, z = -14 }), -- 日次依頼の掲示板（S9 で使う）
	field = table.freeze({ id = "meadow", x = 0, z = -160, sizeX = 280, sizeZ = 170 }),
	path = table.freeze({ width = 14 }), -- 広場の北端からフィールドの南端までの道
	nodes = table.freeze({
		meadow_dew = table.freeze({ x = -85, z = -160, radius = 7 }), -- 見た目の半径（判定は Config.GATHER_RADIUS）
		meadow_bloom = table.freeze({ x = 85, z = -160, radius = 7 }),
	}),
	wildZone = table.freeze({ x = 0, z = -160, radius = 40 }), -- 野生の出現区域（S7）
	-- 野生の出現地点（S7 の WildSpawnService.pointCount が数を使う。出現区域の中）
	wildPoints = table.freeze({
		table.freeze({ x = 0, z = -135 }),
		table.freeze({ x = 22, z = -147 }),
		table.freeze({ x = 22, z = -173 }),
		table.freeze({ x = 0, z = -185 }),
		table.freeze({ x = -22, z = -173 }),
		table.freeze({ x = -22, z = -147 }),
	}),
	gate = table.freeze({ x = 0, z = -255 }), -- 森の関門（未解禁、"Coming soon"）
	plotSize = 64,
	plots = table.freeze({
		table.freeze({ x = -185, z = 0 }),
		table.freeze({ x = -167, z = 80 }),
		table.freeze({ x = -115, z = 145 }),
		table.freeze({ x = -41, z = 180 }),
		table.freeze({ x = 41, z = 180 }),
		table.freeze({ x = 115, z = 145 }),
		table.freeze({ x = 167, z = 80 }),
		table.freeze({ x = 185, z = 0 }),
	}),
	-- 部地の中の配置（部地ローカル。-Z = 前 = 広場側、+Z = 奥）。施設の台座は facilities.json の ID
	plotLayout = table.freeze({
		house = table.freeze({ x = 0, z = 20 }),
		pedestals = table.freeze({
			dew_spring = table.freeze({ x = -16, z = 4 }),
			bloom_garden = table.freeze({ x = 16, z = 4 }),
		}),
		-- forest の施設の予約地（MVP1 範囲外）。家の右奥に置く（2026-11-24: 中央 z=-4 だと出現位置の正面で看板がキャラクターを隠した）
		reserved = table.freeze({ id = "crystal_forge", x = 22, z = 22 }),
		showcase = table.freeze({ table.freeze({ x = -12, z = -20 }), table.freeze({ x = 0, z = -20 }), table.freeze({ x = 12, z = -20 }) }),
		sign = table.freeze({ x = 0, z = -29 }), -- 名札（前の端）
		spawn = table.freeze({ x = 0, z = -12 }), -- 出現位置（奥 = 家・台座の方を向く）
	}),
})

-- プレイヤー向けの文言（追放の案内など）は ReplicatedStorage.Shared.Text にキーで置く（Config には持たない）

return table.freeze(Config)
