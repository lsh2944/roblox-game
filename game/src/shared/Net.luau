--!strict
-- Net: Remote 名の定数とエラーコード列挙（計画書 docs/game_mvp1_impl_plan.md 4.3 節の表）
-- 配置: ReplicatedStorage.Shared.Net（Rojo: game/src/shared/Net.luau）
-- 依存: なし（Roblox API 不使用）。Remote 実体は default.project.json の ReplicatedStorage.Remotes に定義する
--
-- RemoteFunction は { ok: boolean, code: string?, data: any? } を返す。サーバー→クライアントの InvokeClient は使わない。
-- Remote 名を増減したら default.project.json の Remotes も同時に直す（Lune テスト NetSpec が両者の一致を確認する）

local Net = {}

-- 種別: "RF" = RemoteFunction（C→S、応答あり）、"RE" = RemoteEvent
export type RemoteKind = "RF" | "RE"

Net.Remotes = table.freeze({
	GetSnapshot = "GetSnapshot", -- RF
	StateChanged = "StateChanged", -- RE S→C
	GatherStart = "GatherStart", -- RF
	GatherStop = "GatherStop", -- RE C→S
	CaptureEngage = "CaptureEngage", -- RF
	EncounterEvent = "EncounterEvent", -- RE S→C
	SetParty = "SetParty", -- RF
	AssignSlot = "AssignSlot", -- RF
	UpgradeFacility = "UpgradeFacility", -- RF
	Craft = "Craft", -- RF
	ClaimDaily = "ClaimDaily", -- RF
	Notify = "Notify", -- RE S→C
	ReleaseSpirit = "ReleaseSpirit", -- RF（Q6: 手動の放出）
	LevelUpSpirit = "LevelUpSpirit", -- RF（Q6: 精霊レベルアップ）
	MoveSlot = "MoveSlot", -- RF（2026-11-12 決定: 配置の一括移動・入れ替え）
	Travel = "Travel", -- RF（2026-11-24 決定: HUD の "Meadow"・"Home" 移動ボタン。行き先の座標はサーバーが決める）
})

Net.RemoteKinds = table.freeze({
	GetSnapshot = "RF",
	StateChanged = "RE",
	GatherStart = "RF",
	GatherStop = "RE",
	CaptureEngage = "RF",
	EncounterEvent = "RE",
	SetParty = "RF",
	AssignSlot = "RF",
	UpgradeFacility = "RF",
	Craft = "RF",
	ClaimDaily = "RF",
	Notify = "RE",
	ReleaseSpirit = "RF",
	LevelUpSpirit = "RF",
	MoveSlot = "RF",
	Travel = "RF",
} :: { [string]: RemoteKind })

-- 方向: "C2S" = クライアント→サーバー（Net/Remoting がレート → 検証 → 処理の順で受ける）、"S2C" = サーバー→クライアントだけ
-- （S2C の RemoteEvent はサーバーが OnServerEvent を受けない。クライアントから送られても誰も処理しない）
export type Direction = "C2S" | "S2C"

Net.Directions = table.freeze({
	GetSnapshot = "C2S",
	StateChanged = "S2C",
	GatherStart = "C2S",
	GatherStop = "C2S",
	CaptureEngage = "C2S",
	EncounterEvent = "S2C",
	SetParty = "C2S",
	AssignSlot = "C2S",
	UpgradeFacility = "C2S",
	Craft = "C2S",
	ClaimDaily = "C2S",
	Notify = "S2C",
	ReleaseSpirit = "C2S",
	LevelUpSpirit = "C2S",
	MoveSlot = "C2S",
	Travel = "C2S",
} :: { [string]: Direction })

-- Travel の行き先（クライアントが送るのはこの文字列だけ。座標はサーバーの Config.WORLD が決める。Net/Validate が列挙で検証する）
-- meadow = 草原の入口、home = 自分の部地の出現位置（部地が無いときは広場、出現時と同じ規則）
Net.TravelDest = table.freeze({
	Meadow = "meadow",
	Home = "home",
})

-- 応答・通知のエラーコード（クライアントは表示文言をこのコードから引く）
Net.ErrorCode = table.freeze({
	BAD_ARG = "BAD_ARG", -- 型・範囲・長さの検証に失敗
	RATE_LIMITED = "RATE_LIMITED", -- レート超過（破棄）
	NOT_FOUND = "NOT_FOUND", -- ID が存在しない・所有していない
	NOT_UNLOCKED = "NOT_UNLOCKED", -- フィールド・施設が未解禁
	TOO_FAR = "TOO_FAR", -- 距離検査に失敗
	BUSY = "BUSY", -- 別の活動中（採集 ⟂ 捕獲。Travel は遭遇中なら BUSY）
	IN_ENCOUNTER = "IN_ENCOUNTER", -- 遭遇中は変更できない
	INSUFFICIENT = "INSUFFICIENT", -- 資源不足
	NO_WICK = "NO_WICK", -- 芯が 1 個未満
	STORAGE_FULL = "STORAGE_FULL", -- 保管箱が満杯（Q4: 捕獲開始を止める）
	PARTY_FULL = "PARTY_FULL", -- 同行枠を超える
	DUPLICATE = "DUPLICATE", -- 同じ精霊の重複指定
	ASSIGNED_ELSEWHERE = "ASSIGNED_ELSEWHERE", -- 同行と施設配置は排他（Q3）
	LEVEL_CAP = "LEVEL_CAP", -- レベル上限
	NOT_ALLOWED = "NOT_ALLOWED", -- 許可リスト外（制作レシピ等）
	ALREADY_CLAIMED = "ALREADY_CLAIMED", -- 日次依頼の受取済み
	NOT_READY = "NOT_READY", -- データ読み込み前など（Travel はキャラクター・HumanoidRootPart が無いときも）
	NOT_IMPLEMENTED = "NOT_IMPLEMENTED", -- Remote は結線済みだが処理が未実装（S5 時点の S6〜S9 Remote。検証・レートは通した後に返す）
	INTERNAL = "INTERNAL", -- サーバー内部エラー
})

return table.freeze(Net)
