# 게임 본체 MVP1 "meadow 수직 슬라이스" 구현 계획서

- 대상: `/Users/leeseunghak/project/roblox-game`. Git을 쓰지 않는 폴더라 브랜치·커밋은 없다. 2026-11-11에 읽기 전용으로 확인했다.
- 현재 Luau 파일은 3개다: `game/src/server/SparklePreview.server.luau`(13줄), `game/src/shared/SpiritVisuals/Sparkle.luau`(156줄), `AuroraStag.luau`(255줄).
- 근거로 삼은 것: 각 토론 문서 끝의 "사용자 결정", `docs/sinks_capture_impl_plan.md` 3·12·13절, `data/*.json`, `tools/econ_sim/econ_sim/{formulas,sim,economy,rng}.py`.
- 파일 수정과 시뮬 실행은 하지 않았다.

---

## 1. 요약
- meadow 필드 하나에서 다음 루프가 Studio에서 실제로 돌게 한다: 직접 채집 → 포획(심지·약화·도망) → 시설 배치와 방치 생산 → 심지 제작·일일 의뢰 → DataStore 저장.
- 판정과 경제 계산은 모두 서버가 한다. 공식은 `formulas.py`를 그대로 옮기고 `data/test_vectors.json`으로 같은 값이 나오는지 검증한다.
- 경제 수치는 `data/*.json`을 Rojo의 JSON→ModuleScript 변환으로 읽어서만 가져온다. 코드에 수치를 박지 않는다.
- **데이터 계약 변경은 필요 없다**(7절).

## 2. 원하는 동작과 범위

### 플레이어 흐름
1. 접속하면 저장 데이터를 불러온다. 신규 플레이어는 시작 상태로 만든다: 심지 21개(`capture.json:25`), 등롱(`:4`), 시작 정령.
2. 오프라인 동안의 방치 생산을 정산한다. 상한은 12시간이다(`hub.json:10-11`).
3. 오늘 일일 의뢰를 아직 받지 않았다면 meadow 보상(심지 40, hunt_meadow 3)을 자동 지급한다(`daily_quests.json:7`).
4. 채집 노드(meadow_dew, meadow_bloom, `fields.json:7-9`) 근처에서 채집을 시작한다. 서버 시간 기준으로 이슬·꽃빛이 쌓인다. 동행 정령과 채집 도구 Lv가 배율에 들어간다.
5. 야생 정령에게 등롱을 쓰면 다음이 순서대로 진행된다.
   - 동행 정령 중 하나가 자동으로 약화한다. 걸리는 시간은 `weaken_seconds`가 정한다.
   - 4초마다 시도한다. 시도마다 심지 1개를 쓴다.
   - 결과는 성공, 도망, 심지 부족 중 하나다.
   - 성공하면 개체값(채집·전투 10000~12000 bps)이 붙은 정령이 보관함과 도감에 들어간다.
   - 화면에는 시도 성공률과 다음 도망 확률을 항상 보여준다(`weaken_hunger_debate` 결정 I1의 "확률표 상시 공개").
6. 집 부지의 이슬 샘과 꽃빛 정원(둘 다 `unlock_field: meadow`, `facilities.json:5,26`)에 정령을 배치하면 방치 생산이 시작된다. 일하는 정령은 hunt_meadow도 조금씩 만든다(`rules.json:47-70`). 생산 연출은 클라이언트에서만 재생한다(late_sinks 결정).
7. 시설을 강화한다. meadow에서는 Lv10까지이고, Lv4·7·10은 hunt_meadow 9가 추가로 든다(`facilities.json:7,11-14`). 심지는 hunt_meadow 5개로 25개를 만든다(`crafting.json:5`).
8. 자동 저장, 퇴장, 서버 종료 때 저장한다.

### 범위 판단 (데이터 의존성 근거)

| 항목 | 판단 | 근거 |
|---|---|---|
| 직접 채집, 포획(간편 모드), 시설 배치·방치·오프라인, 저장 | **필수** | 사용자가 정한 범위 |
| 시설 강화(dew_spring·bloom_garden, meadow 상한 Lv10) | **필수** | 이게 없으면 채집으로 모은 이슬·꽃빛을 쓸 곳이 없다. 비용은 `generated/upgrade_tables.json`에 있고, 사냥 재료 관문은 `facilities.json:11-14` |
| 일일 의뢰(접속 보상) | **필수** | 시작 심지 21개는 약 20번 조우하면 바닥난다(`capture.json:3`). meadow 단계의 주된 심지 공급원이 일일 의뢰다(`daily_quests.json:7`) |
| 심지 제작(wick_from_meadow) | **필수(가벼움)** | hunt_meadow → 심지로 루프가 닫힌다. 같은 Craft 서비스를 먹이·유인 도구가 나중에 재사용한다 |
| 활력(vigor)·자동 공격자 선택 | **필수** | 약화 시간이 활력에 따라 달라진다(`formulas.py:398-422`, `sim.py:774-806`) |
| 개체값, 도감 등록(+생산 보너스) | **필수** | `rules.json:71-86`. 저장 스키마에 영향을 주므로 처음부터 넣는다 |
| 먹이 제작·자동 급식 | 선택 | 시간당 20 회복과 등롱 보조 약화 12초가 있어 막히지 않는다(`capture.json:36,47`) |
| 정령 레벨업, 채집 도구 강화, 시설 4번째 칸, 오프라인 상한 강화 | 선택 | 같은 비용 차감 경로를 쓰므로 추가가 쉽다 |
| 수동 놓아주기(연구 포인트 지급) | 선택 | 보관함 100칸(`hub.json:4`)은 슬라이스 안에서 거의 차지 않는다. 가득 찼을 때 동작은 질문 Q4 |
| 포획 도구 공식(Formulas에만 구현) | 선택(권장) | 벡터 20건이 이미 있다. 게임에서 쓰는 것은 범위 밖 |
| 사냥 | 범위 밖(Q5) | 사용자가 정한 루프에 없다. hunt_meadow는 집 생산과 일일 의뢰로 공급된다 |
| 연구 | 범위 밖 | 연구 포인트·도감 3종이 필요하고(`research.json:16-17`) 효과가 생산 bps뿐이다. 연구 배율 0을 넣을 자리(hook)만 둔다 |
| 과금, PolicyService, 방문·전시·거래, 포획 도구 사용, 필드 해금, 밤 | 범위 밖 | 구조로 막지만 않는다: 플롯 배정, 보관함 보너스 필드, `unlocked` 목록, night 플래그를 둔다 |

---

## 3. 저장소 구조와 Rojo 프로젝트

### 디렉터리 (새로 만드는 것은 ★)
```
roblox-game/
  default.project.json          ★
  data/                          (변경 없음)
  game/src/shared/   → ReplicatedStorage.Shared
  game/src/server/   → ServerScriptService.Server
  game/src/client/   ★ → StarterPlayer.StarterPlayerScripts.Client
  game/tests/        ★ → ServerStorage.Tests   (실행되지 않는 ModuleScript)
  game/previews/     ★ (매핑하지 않음, 외형 미리보기 보관)
```

### `default.project.json` (요지)
```json
{
  "name": "light-spirits",
  "tree": {
    "$className": "DataModel",
    "ReplicatedStorage": {
      "Shared": { "$path": "game/src/shared" },
      "GameData": { "$className": "Folder",
        "manifest": { "$path": "data/manifest.json" },
        "resources": { "$path": "data/resources.json" },
        "...": "manifest의 role=source 15개를 같은 이름으로 하나씩",
        "generated": { "$className": "Folder",
          "upgrade_tables": { "$path": "data/generated/upgrade_tables.json" },
          "sink_tables": { "$path": "data/generated/sink_tables.json" } } },
      "Remotes": { "$className": "Folder",
        "GetSnapshot": { "$className": "RemoteFunction" },
        "StateChanged": { "$className": "RemoteEvent" },
        "...": "4.3절 표의 이름 전부" } },
    "ServerScriptService": { "Server": { "$path": "game/src/server" } },
    "ServerStorage": {
      "TestData": { "$className": "Folder", "test_vectors": { "$path": "data/test_vectors.json" } },
      "Tests": { "$path": "game/tests" } },
    "StarterPlayer": { "StarterPlayerScripts": { "Client": { "$path": "game/src/client" } } }
  }
}
```

### data/ 매핑 방식
- data는 manifest의 경로대로 **파일 하나씩 명시적으로 매핑**한다. 디렉터리 통째 `$path`를 쓰지 않는 이유는 둘이다.
  - `variants/`(manifest에 없는 패치)가 섞여 들어온다.
  - `test_vectors.json`(102KB)이 클라이언트로 복제된다.
- 로더는 manifest의 `path`에서 `.json`을 떼고 `/`로 나눠 GameData 아래 인스턴스를 찾는다. 하나라도 없으면 시작할 때 오류를 내고 멈춘다. 그래서 data 파일이 늘었는데 project 갱신을 빠뜨리면 바로 드러난다.

### Rojo에서 확인한 사실
- 확장자가 `.json`이고 `.model.json`·`.meta.json`·`.project.json`이 아닌 파일은 "JSON 구조를 그대로 담은 테이블을 반환하는 ModuleScript"가 된다(rojo.space sync-details). 6.0.0-rc.1부터 지원한다.
- `.luau`는 7.2.0부터 지원한다. 최신 릴리스는 7.7.1(2026-10-01)이다(CHANGELOG). **7.7.x 사용을 권장한다.**
- `$path`가 지정된 인스턴스는 `$ignoreUnknownInstances` 기본값이 `false`다. 그래서 **Studio에서 Shared/Server/Client 폴더 안에 직접 만든 인스턴스는 동기화할 때 지워질 수 있다.** 사용자에게 안내해야 한다.
- `emitLegacyScripts`는 기본값 `true`(Script/LocalScript)를 그대로 쓴다.
- JSON의 `[]`와 `{}`는 둘 다 빈 테이블이 되어 구분되지 않는다. 현재 코드에서 이 차이에 기대는 곳은 없다.
- JSON 실수(예: test_vectors의 `uniforms` 0.17)가 Rojo 변환 뒤에도 같은 double인지는 문서에 없다(미확인). resolve_encounter 벡터가 통과하면 함께 확인된다.

### 기존 파일 처리
- `SparklePreview.server.luau`는 `ReplicatedStorage:WaitForChild("Sparkle")`를 기다린다(`:7`). Rojo 배치에서는 경로가 달라져 무한 대기에 빠지고, 게임 안에서 조명도 밤으로 바꾼다(`:10`). `game/previews/`로 옮기고 require 경로 주석을 고친다.
- 작업 전에 `baselines/20261111_pre_mvp1/`에 `game/`을 복사한다(CLAUDE.md 규칙).

---

## 4. 모듈, 서버 권위, Remote 계약

### 4.1 shared (`game/src/shared/`, Roblox API에 기대지 않는 순수 모듈은 ◆)

| 파일 | 책임 | 의존 |
|---|---|---|
| `Data/GameData.luau` | manifest 확인(schema_version=1, 파일 존재), id 색인(spirits, fields, facilities, recipes, resources, quests), 생성 표 색인(`cost[curveId][level]`, `bonus[curveId][level]`), 깊은 `table.freeze` | GameData 폴더 |
| ◆`Formulas.luau` | `formulas.py`를 1:1로 옮긴다(5절의 100벡터 대상). 정수 bps, `//` 내림 나눗셈, `assertSafe`(절댓값 ≤ 2^53−1, Python `_safe` `formulas.py:26-31`과 같음). 포획 함수는 `rule` 인자를 받는다(벡터가 부분 rule을 넘기기 때문) | 없음 |
| ◆`Economy.luau` | `economy.py`의 필요한 부분만: abilityBps, slotPower(개체값 반영), facilityRate(혼합 → 도감 순서로 내림), dexMap·dexCosts(2026-11-13 도감 개편으로 dexBps 대체), homeMaterialDetail, facilityLevelCost(+hunt_gates), toolMult, companionPower, directRate | GameData, Formulas |
| ◆`CaptureLogic.luau` | `pickAttacker`(`sim.py:774-806` 동점 처리 순서 그대로: 비용 → 초 → −활력 → uid, 대체 경로 포함), 시작 시 결과를 확정하는 `resolveEasy`(=`resolveEncounterTool(..., tools=0)`). 활력은 tick 정수(1점=60tick, `sim.py:26`)로 다룬다 | Formulas |
| ◆`Ledger.luau` | milli 단위 지갑: canAfford, spend(전부 되거나 전부 안 되거나), grant. atomic 품목 전개 hook(길표는 나중에) | GameData |
| `SpiritVisuals/init.luau` + 종별 파일 | 종 id → builder 레지스트리. Sparkle은 재사용하고 dewdrop·flower_lamp·shard_light·sunset_bird는 같은 방식(Neon 파트·파티클·라이트)으로 새로 만든다. 전용 외형이 없는 종에는 등급 색 기반 Generic. `create(parent, cframe, palette) -> model, destroy` 시그니처를 유지한다(`Sparkle.luau:62`, 반환값 `:151`) | 클라이언트 전용 |
| `Net.luau` | Remote 이름 상수, 오류 코드 열거형 | 없음 |
| `Types.luau` | PlayerState 등 타입 | 없음 |

### 4.2 server (`game/src/server/`)

| 파일 | 책임 |
|---|---|
| `Main.server.luau` | GameData 로드(실패 시 멈춤) → 서비스 init 순서 고정 → PlayerAdded/Removing, BindToClose 연결 |
| `Config.luau` | 게임 전용 상수(경제 계약이 아님): 채집 반경, 자동 저장 주기, 잠금 TTL, 레이트 제한, 플롯 좌표, Studio 디버그 플래그, (Q1에 따라) 시작 정령 |
| `Clock.luau` | `now()`=os.time(). Studio 전용 오프셋 디버그로 오프라인·날짜 경계를 시험할 수 있게 한다 |
| `ServerRng.luau` | 스트림별 `Random` 인스턴스 3개(spawn·capture·individual). `uniform()`은 [0,1)이고 범위를 벗어나면 다시 뽑는다. `block(n)`, `intInclusive(a,b)`. 테스트에서는 공급자를 주입한다 |
| `Data/DataStoreAdapter.luau` | 실제 DataStore와 MockStore(메모리) 사이에서 고른다(4.4) |
| `Data/Migrations.luau` | `[n] = fn(save) -> save`를 차례로 적용 |
| `Data/PlayerDataService.luau` | 불러오기·세션 잠금·자동 저장·퇴장·종료 저장. 잠금 판정은 순수 함수 `transformLoad`/`transformSave`로 분리해 테스트한다 |
| `Services/IdleService.luau` | 정산: 온라인 구간, 오프라인 상한, 시설 생산 `accrue_milli`, 집 재료 일 단위 적립(`sim.py:485-490`의 divmod 1440). 연구 배율 hook(0) |
| `Services/GatherService.luau` | 채집 세션(4.3) |
| `Services/WildSpawnService.luau` | 플레이어별 야생 정령(위치는 서버 표 기준). 쿨다운은 `capture.time.encounter_base_seconds` |
| `Services/CaptureService.luau` | 조우 상태 기계(4.3) |
| `Services/RosterService.luau` | 정령 추가(개체값 추첨, 도감, `first_capture`), 동행 편성, 보관함 상한, (선택) 놓아주기·레벨업 |
| `Services/FacilityService.luau` | 칸 배정, 강화(필드 상한 = 해금한 필드 중 가장 높은 필드의 `level_cap_by_field`) |
| `Services/CraftService.luau` | stock 레시피만, 허용 목록(slice: `wick_from_meadow`) |
| `Services/QuestService.luau` | 일일 의뢰(UTC 날짜 = `os.time()//86400`, sim과 같은 UTC 기준) |
| `Services/PlotService.luau` | 플레이어별 집 부지 배정(나중의 방문 기능을 위한 구조) |
| `World/MeadowBuilder.luau` | 임시 도형 월드: 초원, 노드 2개, 출현 구역, 부지와 시설 받침대. 노드 id는 data의 `gather_nodes[].id`와 맞춘다 |
| `Net/Remoting.luau`, `Net/Validate.luau`, `Net/RateLimiter.luau` | Remote 바인딩, 입력 검증, 토큰 버킷, 스냅샷 복제(최대 초당 4회) |
| `Dev/TestRunner.server.luau` | `RunService:IsStudio()`일 때만 실행한다. ServerStorage.Tests와 벡터를 돌려 결과를 출력한다 |

### client (`game/src/client/`)
- `Main.client.luau`, `Controllers/{State,Hud,Gather,WildSpiritView,CaptureView,HomeView,Party,Craft,Quest}.luau`
- UI는 코드로 만든 임시 ScreenGui다.
- 클라이언트는 그리기만 한다: 정령 외형, 궤도 모션, 생산 연출.

### 4.3 서버 권위 원칙과 상태 기계

**클라이언트를 믿는 범위**
- 클라이언트가 보내는 것은 id와 의도뿐이다. 수량, 비용, 확률, 시간은 받지 않는다.
- 캐릭터 위치는 클라이언트가 소유하므로 거리 검사는 최선의 노력 수준이다. 그래서 산출을 **서버 시간에 묶어** 순간이동이나 스팸으로 생산량을 늘릴 수 없게 한다.
- 활동은 한 번에 하나만 한다(채집 ⟂ 포획). sim도 활동 분을 나눠 쓴다.

**채집 세션**
- `GatherStart(nodeId)`을 검증한다: 노드가 존재하는지, 노드가 속한 필드가 해금됐는지, 거리 ≤ R인지, 조우 중이 아닌지.
- 서버가 1초마다 거리를 다시 확인하고, 산출 = `directRate`(milli/시) × 경과 초를 carry와 함께 적립한다. 범위를 벗어나거나 조우를 시작하면 자동 종료한다.
- 초 단위 적립(`total = rate·sec + carry`, `gained = total // 3600`)은 Luau에만 있는 보조 함수다. 단위 테스트로 검증한다.

**조우(간편 모드)** — `sim.py:820-922`과 같은 계약이다.
1. `CaptureEngage(wildId)`를 검증한다: 본인 소유의 야생 정령인지, 거리, 심지 ≥ 1, 활동 중이 아닌지, 보관함 상태(Q4).
2. 종을 정한다. Q2 권장안(등롱을 쓸 때 공개)이면 이 시점에 블록을 **1 + 2·K_max(=21) 개** 뽑는다. sim과 같은 고정 블록이다(`sim.py:832`, 계획서 3절 "공통 난수"). 종은 u[1]과 출현 가중치로 정한다.
3. `weaken_needed`이면 `pickAttacker`를 실행하고 활력을 차감한다. 동행이 없거나 모두 지쳤으면 등롱 보조(12초)로 약화한다.
4. `resolveEncounterTool(grade, capture, u[2..], 심지 재고, wsec, 0)`로 **결과를 시작 시점에 확정**한다. 사용한 심지를 즉시 차감한다(sim과 같음).
5. 클라이언트에는 약화 → 시도 i(4초 간격) → 결과 순서로 `EncounterEvent`를 재생해 보낸다. 실제 시간은 `wsec + 4·attempts`초다. 기본 60초는 탐색 시간에 해당하므로 다음 출현 쿨다운으로 쓴다.
6. 완료 시점에 반영한다: 포획, 첫 포획 기록, 개체값 추첨(`individual` 스트림 `intInclusive(10000,12000)`), 도감 등록. 퇴장이나 종료로 중간에 끊기면 **즉시 확정해 반영**한다. 다시 뽑을 방법이 없다.

**서버 RNG 규약을 옮기는 방식**

옮기는 것:
- 조우마다 고정 블록을 쓰고, i번째 시도는 `u[i]`, i번째 실패 뒤 도망 판정은 `u[K+i]`를 쓴다.
- 비교는 `u * 10000 < p_bps`로 double끼리 한다. Python float도 IEEE double이라 결과가 같다.
- 용도별로 스트림을 나눈다. 포획 판정이 출현 횟수나 개체값 추첨 횟수에 영향을 받지 않는다.
- 블록은 클라이언트로 보내지 않는다.

옮기지 않는 것:
- sha256 시드 파생과 Mersenne Twister(`rng.py:18-36`)는 시뮬레이션 짝 비교용이다. 게임에서 재현할 필요가 없다.

**야생 출현**
- 플레이어마다 등롱을 쓸 수 있는 야생 정령을 최대 1마리 둔다.
- 다음 출현은 직전 조우가 끝난 시각 + `encounter_base_seconds`(60초) 뒤다.
- `next_spawn_at`을 저장해 재접속으로 쿨다운을 초기화할 수 없게 한다.
- 이 규칙은 sim의 조우 시간 가정(60 + 약화 + 4·시도)을 지키기 위한 것이다. 장식용 정령은 따로 둘 수 있다.

### Remote 계약
- RF는 `{ok: boolean, code?: string, data?: any}`를 반환한다.
- 서버 → 클라이언트 방향 InvokeClient는 쓰지 않는다.

| 이름 | 종류 | 인자 | 서버 검증 | 레이트(플레이어별) |
|---|---|---|---|---|
| GetSnapshot | RF | — | — | 2/s |
| StateChanged | RE S→C | snapshot | — | 서버 스로틀 4/s |
| GatherStart | RF | nodeId: string(≤32) | 노드·해금·거리·유휴 | 2/s |
| GatherStop | RE | — | — | 2/s |
| CaptureEngage | RF | wildId: string(≤32) | 소유·거리·심지 ≥ 1·유휴·보관함 | 1/s |
| EncounterEvent | RE S→C | {phase, attempt?, light?, bps?, fleeBps?, result?} | — | — |
| SetParty | RF | uids: {string} (≤ `companion_slots`=3, `rules.json:36`) | 보유, 중복 없음, 조우 중 변경 불가, Q3 규칙 | 2/s |
| AssignSlot | RF | facilityId, slotIndex: int, uid: string 또는 "" | 열린 시설, 1..slots, 보유, Q3 | 4/s |
| UpgradeFacility | RF | facilityId | 상한, 비용(정산을 먼저 한 뒤) | 2/s |
| Craft | RF | recipeId, times: int 1..100 | stock·허용 목록·재료 | 2/s |
| ClaimDaily | RF | — | 날짜(접속 시 자동 지급도 함) | 1/s |
| Notify | RE S→C | {code, args} | — | — |
| (선택) ReleaseSpirit / LevelUpSpirit | RF | uid | 배치 해제·상한·비용 | 2/s, 4/s |

- 검증 공통: `typeof`를 확인하고, 숫자는 `x == x`, 유한값, `math.floor(x) == x`, 범위를 본다. 문자열은 길이 상한을 둔다. 테이블은 길이 상한을 두고 원소 타입을 확인한다.
- 레이트를 넘긴 요청은 버리고 횟수를 기록한다. 슬라이스에서는 추방하지 않는다.
- 상태를 바꾸는 요청은 모두 처리 전에 `IdleService.settle`을 먼저 실행한다.

### 4.4 저장 스키마와 DataStore

**키**
- DataStore 이름은 `PlayerSave_<env>`, 키는 `u_<UserId>`다.
- env는 `Config`에서 정한다. Studio는 `dev`, 라이브는 `live`.
- 이름·키 제한 50자 안에 들어간다.

**값(v1)** — 모든 수치는 정수다.
```
{ save_schema=1, created_at, updated_at, last_online_at,
  session={server_id, locked_at} | nil,
  wallet={[resId]=milli}, carry={[key]=int},
  settled_min,                  -- os.time()//60, 분 단위로 정산
  unlocked={"meadow"}, field_unlock_time={meadow=...},
  facilities={[fid]={level, slots, assigned={uidStr...}}},
  tool_level=1, offline_cap_hours=12, hub_rank=1, storage_bonus=0,
  roster={[uidStr]={species, level, gather_bps, combat_bps, vigor_ticks, vigor_min, origin="start"|"capture", caught_at}},
  next_uid, party={uidStr...}, dex={[species]=first_at}, first_capture={[species]=t},
  quest_day, next_spawn_at, stats={encounters, attempts, captures, releases} }
```
- 배열과 사전을 섞지 않으려고 roster 키는 **문자열 uid**로 한다.
- 생산율처럼 계산으로 나오는 값은 저장하지 않는다. 그래야 placeholder 수치가 바뀌어도 세이브가 깨지지 않는다.
- 크기는 정령 200마리여도 수십 KB다. 키당 한도 4,194,304자에 비해 충분히 작다.

**마이그레이션**
- 저장된 `save_schema`가 코드보다 낮으면 순서대로 올린다.
- **코드보다 높으면 불러오지 않고 추방한다.** 업데이트 중 구버전 서버가 덮어쓰는 것을 막기 위해서다.

**세션 잠금(자체 구현 권장, Q7)**
- 불러오기는 `UpdateAsync`로 한다.
  - 다른 서버가 잠그고 있고 `now − locked_at < TTL`(예: 10분)이면 nil을 반환해 쓰기를 취소한다.
  - 재시도한다(지수 백오프 + 지터, 최대 N회).
  - 그래도 실패하면 안내 메시지와 함께 추방한다.
  - TTL이 지난 잠금은 가져온다.
- 저장은 `UpdateAsync`로 하되, 소유자가 나일 때만 쓴다. 자동 저장(60~120초, 플레이어별로 시차)이 `locked_at`을 갱신한다.
- 퇴장할 때 `session=nil`로 잠금을 해제한다.
- `server_id`에는 `HttpService:GenerateGUID()`를 쓴다. Studio에서는 JobId가 비어 있을 수 있어 JobId를 쓰지 않는다.
- PlayerRemoving과 BindToClose가 겹쳐도 한 번만 저장되도록 플레이어별 저장 진행 플래그를 둔다.
- UpdateAsync 변환 함수의 반환값에 userIds를 넣는다. 문서상 목적은 콘텐츠·IP 추적과 삭제다.
- 실패한 요청은 pcall로 감싸고 지수 백오프 + 지터 + 상한으로 재시도한다(공식 best-practices).

**한도(공식 문서 기준, 2026-11-11 조회)**
- 서버당 분당 Get/Set·Update 요청 한도는 `60 + 플레이어 수 × 40`이다. 자동 저장 1분 주기로 충분하다.
- 같은 키에 대한 6초 쿨다운 문구는 현행 페이지에 없었다(키당 쓰기 4MB/분으로 바뀐 것으로 보인다).
- BindToClose의 30초 제한은 공식 페이지에서 확인하지 못했다. 그래서 종료 저장은 병렬로 하고 최대한 짧게 끝내는 것으로 설계한다.

**오프라인 정산**
- 기간은 `[settled_min, min(now, last_online_at + offline_cap_hours×60)]`이다. 초과분은 버린다(`offline_credit_minutes`, `sim.py:513-517`과 같은 의미).
- `now < settled_min`이면(서버마다 시계가 다른 경우) 적립하지 않는다.
- 활력은 지연 계산 `min(max, v + rec·(t − vt))`로 오프라인 동안에도 회복된다.

**Studio와 라이브 분리**
- 사용자가 할 일:
  1. 라이브와 **별도인 테스트 Experience**를 만든다.
  2. 그 Experience에서만 File ⟩ Experience Settings ⟩ Security ⟩ "Enable Studio Access to API Services"를 켠다.
  - 공식 문서도 라이브 게임에서는 켜지 말고 별도 테스트 버전에서 켜라고 권한다.
- 코드 쪽 안전장치:
  - Studio에서는 기본으로 **MockStore**(메모리, 영속 없음)를 쓴다. `Config.STUDIO_USE_REAL_DATASTORE=true`이고 API 접근이 가능할 때만 실제 `dev` 스토어를 쓴다. API 접근이 없어서 생기는 오류는 pcall로 감지해 Mock으로 돌린다.
  - Studio의 로컬 테스트 플레이어(음수 UserId)도 Mock으로 처리된다.
- 라이브 DataStore 쓰기와 게시는 사용자가 한다.

---

## 5. 데이터 로더와 test_vectors 실행

**로더**
- `GameData.load()`는 manifest를 확인하고 색인을 만든 뒤 freeze한다.
- 전체 검증기를 Luau로 다시 만들지는 않는다. 동기화 전에 다음 두 명령을 통과시키는 것을 절차로 정한다(cwd `tools/econ_sim`).
  - `python3 -m econ_sim validate`
  - `python3 -m econ_sim gen-tables --check`
- 로더는 게임이 실제로 참조하는 id만 가볍게 확인한다: 시작 정령, meadow 노드·시설·레시피·의뢰 행.

**벡터 범위** — 전체 130건을 실제로 집계해 나눴다.

Luau 대상은 **100건**이며 Formulas에 구현한다.
- 함수: linear_milestone_bps, slot_power_bps, idle_rate, companion_bonus, direct_rate, research_scaled, idle_dex_research, party_power, hunt_rate, offline_credit, accrue_milli, night_segments, capture_attempt_bps, flee_bps, capture_k_max, weaken_needed, easy_attempt_light, weaken_seconds, weaken_vigor_cost, resolve_encounter, vigor_hunt_scaled, capture_tool_attempt_bps/mult/item, resolve_encounter_tool.
- 사냥·밤·도구 관련 함수는 구현만 하고 게임에 연결하지는 않는다.

Python 전용으로 건너뛰는 것은 **30건**이다.
- exp_ceil_cost(7), exp_ceil_capped(4), linear_ceil_capped(3): 유리수 거듭제곱이 2^53을 넘는다. 예: 1.15^8의 분자 115^8 ≈ 3.06e16. 게임에서는 계산하지 않고 `generated/*_tables.json`을 조회하므로 필요 없다.
- capture_success_per_encounter(1), geometric_quantile(6), g2_ratio(1), direct_share(1), encounter_expectation(7): 분석용 Fraction이다.

**러너(`Dev/TestRunner.server.luau`)**
- vector의 `fn`을 Luau 함수에 매핑한다. `capture_tool_item`은 nil을 ""로 바꾸고, 배열은 깊게 비교한다.
- 출력 예: `PASS 100 / SKIP 30 / FAIL 0`.
- **목록에 없는 fn이 나오면 FAIL로 처리한다.** 새 벡터가 조용히 빠지는 것을 막기 위해서다.
- 이어서 `ServerStorage.Tests`의 단위 테스트를 실행한다: Ledger 원자성, Idle 정산(상한·carry·일 단위 적립), 마이그레이션·잠금 변환, pickAttacker 동점 처리, Validate, RateLimiter, 초 단위 적립.

**대안(도구 도입은 사용자 승인 사항, Q8)**
- Lune(로컬 Luau 런타임)을 들이면 Claude가 순수 모듈과 벡터를 Studio 없이 직접 돌릴 수 있다.
- 이를 위해 Formulas, Economy, CaptureLogic, Ledger, IdleService의 계산부는 Roblox API를 쓰지 않게 만든다.
- selene과 stylua는 그다음 순위다.

---

## 6. 구현 순서
담당은 모두 `roblox-feature`, 리뷰는 `code-reviewer`(기준본 diff)가 맡는다.

| 단계 | 내용 | 완료 기준 / 사용자가 Studio에서 확인할 것 |
|---|---|---|
| S0 | 기준본 복사, Q1~Q12 결정, 사용자가 Rojo 7.7.x CLI·플러그인 설치 | `rojo --version` 출력 |
| S1 | `default.project.json`, GameData 로더, preview 이동, Remotes 정의 | `rojo serve` 연결. Explorer에 Shared/GameData/Remotes/Server/Client가 보임. 출력에 "GameData OK (17 files)" |
| S2 | Formulas, Dev 러너 | 출력 `PASS 100 / SKIP 30 / FAIL 0`. resolve_encounter 6건 통과로 Rojo 실수 변환도 확인됨 |
| S3 | Economy, Ledger, CaptureLogic(pickAttacker), IdleService 계산부, 단위 테스트 | 단위 테스트 전부 PASS. 시작 3종 배치 때 이슬 샘 생산율이 Python `Economy.facility_rate`와 같음. 기대값은 메인이 Python 함수 호출로 뽑아 고정한다(시뮬 실행 아님) |
| S4 | PlayerDataService(Mock 기본), 마이그레이션, 잠금, 자동 저장, BindToClose, Clock 디버그 | Play 시 신규 상태(심지 21, 정령 3) 생성. 상태가 "dev 스토어 저장 성공/Mock"으로 표시됨. 테스트 Experience에서 실제 스토어로 재접속하면 상태가 유지됨(사용자 실행) |
| S5 | MeadowBuilder, PlotService, Remoting, 스냅샷 복제, HUD | 초원·노드·부지·시설 받침대가 보임. HUD에 지갑 표시. Remote에 잘못된 인자(숫자 대신 문자열, NaN)를 보내면 거부됨 |
| S6 | 직접 채집 | 노드 옆에서 HUD 증가율이 "160/시 × 배율"과 맞음. 범위를 벗어나면 멈춤. 연타해도 산출이 늘지 않음 |
| S7 | SpiritVisuals 레지스트리와 meadow 5종 외형, 야생 출현, 파티·활력, 포획 | 등롱 → 약화 초 표시 → 4초 간격 시도 → 성공/도망/심지 부족. 심지 감소, 확률 표시, 개체값·도감 반영. Studio 전용 표본 검사(서버 RNG로 resolve 1만 회): ★2 조우당 획득 ≈ 0.979, ★1 = 1(`sinks_capture_impl_plan.md:197-205` 표). `intInclusive`가 10000과 12000을 모두 내는지 확인 |
| S8 | 시설 배치, 방치 생산, 강화, 클라이언트 생산 연출 | 배치하면 생산율 표시. Clock 오프셋으로 13시간 오프라인을 흉내 내면 12시간만 인정. dew_spring 1→2 비용이 이슬 40·꽃빛 20(생성 표). Lv3→4에 hunt_meadow 9 요구 |
| S9 | 일일 의뢰, 심지 제작, (선택 항목) | 날짜가 넘어가면 심지 40과 hunt_meadow 3을 한 번만 지급. hunt_meadow 5 → 심지 25 |
| S10 | 통합: 한 루프 전체, 실제 저장소 재접속, 2인 서버(Studio Start Server + 2 Players), 리뷰 | 체크리스트 전체 통과, 리뷰 Blocker 0 |

**필수 검증(완료 시)**
- Studio 러너: 벡터 100/0 FAIL, 단위 테스트 전부 PASS.
- 사용자 Studio 체크리스트 S1~S10.
- `python3 -m econ_sim validate`와 `gen-tables --check`를 시작과 끝에 실행해 data가 바뀌지 않았음을 확인. 전체 unittest는 Python을 고치지 않으면 생략해도 된다.
- 기준본 diff로 리뷰.
- 라이브 게시와 라이브 DataStore 검증은 하지 않은 상태로 보고하고, 실행 절차만 넘긴다.

---

## 7. 데이터 계약 변경
- **필수 변경은 없다.**
  - 게임에만 필요한 값은 `Config.luau`에 두고 "게임 전용"으로 표시한다: 좌표, 반경, 레이트, 저장 주기.
  - 출현 쿨다운은 기존 `capture.time`을, 채집 초 단위 적립은 기존 `base_per_hour`를 그대로 쓴다.
- 선택(후속):
  - 시작 상태를 data로 옮기는 경우(Q1-b): manifest, econ_sim `data_load`·`validate`, `sim_config.py:32,70`과 `personas*.json`의 `start` 전환, 테스트와 Luau 로더를 동시에 고쳐야 한다.
  - 초 단위 적립을 공식 벡터로 만드는 경우: `formulas.py`의 `VECTOR_FUNCS`(`:578-615`)와 test_vectors, test_formulas를 동시에 고쳐야 한다.

---

## 8. 위험과 미정 사항

### 기술 위험 (조치 포함)
- **Luau 수 정밀도**: 0 ≤ a < 2^53, 정수 b ≥ 1일 때 `a // b`가 올바르게 내림된다는 것은 추론이다. 모든 곱셈 결과에 `assertSafe`를 넣고, 벡터와 단위 테스트로 확인한다.
- **`Random`의 동작 미확인**: 공식 API 페이지에 NextNumber의 [0,1) 범위와 NextInteger의 경계 포함 여부가 적혀 있지 않았다. uniform은 범위를 벗어나면 다시 뽑게 하고, S7에서 표본으로 확인한다.
- **Rojo가 Studio 수동 편집을 지울 수 있음**(`$ignoreUnknownInstances=false`): 사용자 안내가 필요하다. 월드는 코드로 만든다.
- **조우율이 sim과 어긋남**: 출현 쿨다운이 sim 가정을 따르지만 이동 시간만큼 실제 조우율은 낮아질 수 있다(추측). 후속으로 조우·시도 통계(저장의 `stats`)를 sim과 비교한다.
- **위치 신뢰도**: 캐릭터 위치는 클라이언트 소유라 거리 검사는 근사치다. 산출을 서버 시간에 묶어 피해를 제한한다.
- **data 변경 동기화**: validate와 `gen-tables --check`가 통과하지 않은 data를 동기화하지 않는다.
- **CLAUDE.md 갱신**: "Rojo 프로젝트 파일은 아직 없으며…"(`roblox-game/CLAUDE.md` 구성 절)를 S1 뒤에 갱신해야 한다. 메인이 처리하며 사용자 확인이 필요하다.

### 사용자 질문 (권장안과 이유)
1. **Q1 시작 정령 정의 위치**: 지금은 econ_sim `config/personas.json`의 `start`에만 있다(★1 3종 Lv1, placeholder).
   - 권장: (a) 슬라이스는 Luau `Config`에 같은 값을 복사하고, 출처 주석을 단다.
   - 이유: 계약을 바꾸지 않는다. data로 옮기는 (b)는 후속 과제로 둔다.
2. **Q2 야생 정령의 종을 언제 공개하나**
   - 권장: (A) 등롱을 쓸 때 공개(평소에는 "빛 덩어리"로만 보임).
   - 이유: sim 계약(조우 시작 때 종 결정, 21개 블록)과 똑같다.
   - 대안 (B) 출현 때 공개: 원하는 종만 골라 심지를 아낄 수 있어 심지 소비 모델이 sim과 달라진다.
3. **Q3 동행 정령과 시설 배치를 겹칠 수 있나**
   - 권장: (A) 서로 배타.
   - 이유: 단순하고 서버 판정이 명확하다. 생산은 sim보다 조금 적어진다.
   - 대안 (B) sim처럼 활동 중일 때만 생산에서 제외(`sim.py:1013-1015`).
4. **Q4 보관함이 가득 찼을 때**
   - 권장: (A) 포획 시작을 막고 수동 놓아주기를 안내.
   - 이유: 보호 필터(C3 결정: 즐겨찾기·유용 개체 보호)가 슬라이스에 없다.
   - 대안 (B) sim처럼 자동 놓아주기.
5. **Q5 사냥**: 권장은 범위 밖(다음 마일스톤). 이유: 사용자가 정한 루프에 없고, 루프를 닫는 데 필요하지 않다. 단, hunt_meadow 공급이 sim보다 적어 Lv4 이후 강화 속도가 느려진다.
6. **Q6 선택 항목**: 권장은 정령 레벨업과 수동 놓아주기만 포함하고 먹이·도구 강화·4번째 칸·오프라인 상한 강화는 후속. 포획 도구 공식은 Formulas에만 넣는다.
7. **Q7 세션 잠금**
   - 권장: UpdateAsync로 자체 구현.
   - 이유: 외부 의존이 없고 스키마를 직접 통제한다.
   - 대안: ProfileStore 같은 외부 라이브러리. 검증된 구현이지만 코드 반입 승인이 필요하다.
8. **Q8 도구 도입**: 권장은 Lune만 우선 도입. 이유: Claude가 벡터와 순수 모듈을 직접 실행해 Studio 왕복을 줄인다. 미승인이어도 계획은 그대로 진행할 수 있다.
9. **Q9 테스트용 Experience 분리**(사용자 작업): 권장은 분리. 공식 권고와 같다.
10. **Q10 수동 약화 모드**
    - 권장: 슬라이스는 간편 모드만.
    - 이유: 약화 함수 B(`capture.json:27`)는 간편 모드 기준이고, 수동 모드의 피해와 흩어짐 판정은 결정 문서에 비어 있다. 결정이 필요하다.
11. **Q11 시도 진행 방식**: 권장은 자동 연속(sim과 같음). 시도마다 버튼을 누르게 하면 중간에 그만둘 수 있어 심지 소비가 sim과 달라진다.
12. **Q12 일일 초기화 기준**: 권장은 UTC 0시(sim과 같은 서버 UTC 기준).

### memory 기록 제안
승인 뒤 `project_roblox_idle_game.md`에 다음을 추가할 것을 제안한다: Rojo 매핑(manifest 기반 명시 매핑, test_vectors는 ServerStorage), 서버 RNG 규약(21개 블록, 스트림 분리, 시작 시 확정), 저장 스키마 v1과 잠금 방식, 벡터 범위(100 대상 / 30 Python 전용).

## 출처
- https://rojo.space/docs/v7/sync-details/ (JSON 모듈, 특수 json)
- https://rojo.space/docs/v7/project-format/ (`$path`, `$ignoreUnknownInstances`, `emitLegacyScripts`, `globIgnorePaths`)
- https://raw.githubusercontent.com/rojo-rbx/rojo/master/CHANGELOG.md (.luau 7.2.0, JSON 모듈 6.0.0-rc.1, 최신 7.7.1)
- https://create.roblox.com/docs/cloud-services/data-stores/error-codes-and-limits (요청·크기·저장 한도)
- https://create.roblox.com/docs/cloud-services/data-stores (Studio API 접근, 테스트 Experience 권고, UpdateAsync)
- https://create.roblox.com/docs/cloud-services/data-stores/best-practices (백오프·지터, 플레이어당 키 하나)
- https://create.roblox.com/docs/reference/engine/classes/DataModel (BindToClose: 시간 제한 문구 없음)
- https://create.roblox.com/docs/reference/engine/datatypes/Random (범위·알고리즘 명시 없음 → Studio 확인 항목)

## 사용자 결정 (2026-11-11)
- 첫 마일스톤 = meadow 수직 슬라이스, 동기화 = Rojo 도입(사용자 설치), 그래픽 = 임시 도형(정령은 코드 생성 외형).
- Q2 야생 정령 종 공개: **등롱 사용 시 공개**(평소 '빛 덩어리', sim 조우 계약과 동일).
- Q3 동행·시설 배치: **서로 배타**.
- Q8 도구: **Lune 도입**(사용자 설치). 순수 모듈·test_vectors를 로컬에서 검증한다. selene·stylua는 미도입.
- 나머지 권장안 일괄 승인: Q1 시작 정령은 Luau Config에 복사(출처 주석) / Q4 보관함 가득 → 포획 차단·수동 놓아주기 안내 / Q5 사냥은 다음 마일스톤 / Q6 선택 기능은 정령 레벨업·수동 놓아주기만(포획 도구 공식은 Formulas에만) / Q7 세션 잠금 자체 구현(UpdateAsync) / Q9 테스트용 Experience 분리 / Q10 간편 모드만 / Q11 시도 자동 연속 / Q12 일일 초기화 UTC 0시.
- 계획 승인. S0부터 진행.

## 진행 기록
- 2026-11-11 S1~S3 구현 완료(roblox-feature). 계획과 다른 점: Idle 계산부를 `shared/IdleCalc.luau`에 둠(Lune require), Main.server 최소판, require-by-string(`./X`), Spec은 deps 주입, `weakenSecondsTicks` 추가.
- 검증(cwd roblox-game): `.tools/bin/lune run game/tests/lune_run.luau` → 매핑 17/오류 0, vectors PASS 100/SKIP 30/FAIL 0, unit PASS 42/FAIL 0. `.tools/bin/rojo build` 성공. Studio 미실행(Studio 미설치).
- 코드 리뷰(code-reviewer): Blocker·Major 0. 메인 반영: Minor 2 벡터 건수 고정(`VectorRunner.EXPECTED_COUNTS` 총 130·SKIP 30), Minor 3 pickAttacker uid 숫자 단언. 재검증 동일 통과.
- 이월: Minor 1 클라이언트 require-by-string·GameData 복제 대기(S5 클라이언트 진입점에서 `WaitForChild`/`IsLoaded` 후 require), Minor 4 Rojo JSON 변환 경로는 Studio TestRunner로만 확인 → **S2 완료 판정은 Studio 실행 전까지 보류**. Nit(Economy apply_* 경로 assertSafe, Config SLICE_REFS 얕은 freeze)는 해당 경로 사용 시 처리.
- 미정: 밤 판정 기준(rules.json night placeholder, 현 구현 UTC 20~06) — S7(night_only 출현) 전 결정 필요.
- 사용자 결정(2026-11-11): S4는 Studio 설치와 병행해 진행(S5 이후는 Studio 확인 뒤). **밤 판정 = 게임 내 시계**: 현실 60분 = 게임 하루, 낮 30분·밤 30분, **전 세계 동기**(UTC 에폭 기준, 매시 정각~30분 낮, 30분~정각 밤). S4 앞에 먼저 반영(data rules.night 스키마·econ_sim night_segments·test_vectors·검증기·Luau Formulas/IdleCalc). Roblox Studio는 필수 도구로 사용자가 설치 예정.
- 2026-11-11 밤 판정 게임 내 시계 반영(roblox-feature, 기준본 `baselines/20261111_pre_night_clock/`): `rules.night` = `cycle_minutes` 60 / `night_start_offset_minutes` 30 / `night_minutes` 30(placeholder). `night_segments(start, end, cycle, offset, night_minutes)`로 Python·Luau 동시 변경, 새 검증 규칙 `RULE_NIGHT_CLOCK`(offset < cycle, night ≤ cycle, cycle은 1440의 약수 — 시뮬 분과 UTC 에폭 분의 위상 일치) + `broken_night_clock.json`. night_segments 벡터 4건 교체(건수 동일, 총 130·SKIP 30 유지). quick `outputs/20261111_night_clock_q`가 `20261111_tool_off_q2`와 daily/checks/capture_stats/spirit_daily/allocation/events 전부 일치(밤 효과 0).
- 2026-11-11 S4 구현(roblox-feature): `server/Clock`, `server/Data/{SaveSchema, Migrations, DataStoreAdapter, PlayerDataService}`, `server/Services/IdleService`, Main 결선(PlayerAdded/Removing·BindToClose·자동 저장). 계획과 다른 점: 신규 상태·형태 검사·uid 변환을 `Data/SaveSchema.luau`로 분리, 서버 모듈은 Roblox API를 deps 주입으로 받아 Lune에서 MockStore로 서비스 흐름까지 검증, 잠금(locked_at)·updated_at은 실시간 os.time(Clock 오프셋 미적용), Clock 오프셋은 ServerStorage 속성 `DebugClockOffsetSeconds`(Studio 전용), 등롱은 저장하지 않고 data(start_granted·permanent)에서 도출. 검증: Lune vectors PASS 100/SKIP 30, unit PASS 63/FAIL 0(10 suites), rojo build 성공. DataStore·Studio 동작은 미검증.
- 사용자 결정(2026-11-11, S4 후): 신규 플레이어 시작 정령 3마리는 **자동 배치하지 않는다**(배치·동행 비움). S8 배치 UI에서 튜토리얼처럼 직접 배치하도록 안내한다. sim은 시작 즉시 `policy.reassign`으로 배치하므로 첫 배치까지의 생산 차이는 수용(튜토리얼 동선 설계 시 첫 배치를 빠르게 유도).
- S4 리뷰(code-reviewer, 2026-11-11): Blocker·Major 0. Minor = 같은 서버 재입장 시 이전 세션의 늦은 쓰기·추방(세션 토큰·profile 동일성 확인으로 수정), 미래 locked_at 영구 잠금(오래된 잠금으로 취급). Nit = 저장 전 정산의 부분 적립(사본 계산 후 일괄 반영), 특성 params start_hour/end_hour의 실시각 의미(S7 전 정리).
- 사용자 결정(2026-11-11): 세션 잠금 TTL 600초 → **300초**. 플레이어에게 보이는 문구는 **지금부터 영어 기본**(한국어 등은 이후 Roblox Localization 번역으로). 코드 주석은 일본어, docs는 한국어 유지.
- 2026-11-11 S4 리뷰 반영(roblox-feature, 기준본 `baselines/20261111_pre_s4_fix/`): 잠금 `session`에 세션 토큰(`token`, 불러올 때마다 GUID) 추가, 저장은 server_id·token 일치 시만, `_write` 각 회차·lost_lock 추방 전 `profiles[userId] == p` 확인(아니면 `"stale"`로 쓰지 않고 추방 없음). `locked_at`이 TTL 초과 미래면 손상 잠금으로 가져옴. 정산은 wallet·carry 사본 계산 후 성공 시 일괄 반영. TTL 300초. 플레이어 노출 문구는 `shared/Text.luau`(키 기반 영어 원문, `Config.MESSAGES` 제거). 4.4절 스키마의 `session={server_id, locked_at}`은 `{server_id, token, locked_at}`으로 읽는다.
- 검증: Lune vectors PASS 100/SKIP 30/FAIL 0, unit PASS 70/FAIL 0(11 suites, 새 TextSpec 포함), rojo build 성공. 새 테스트는 수정 전 동작으로 되돌린 사본에서 실패함을 확인. DataStore·Studio 동작은 미검증.
- 2026-11-12 S6~S9 계산·판정 로직 선구현(roblox-feature, 기준본 `baselines/20261112_pre_s6_s9_logic/`, Studio 미설치라 Roblox API·Remote 바인딩·월드·UI 없음). shared 순수 모듈: `GatherCalc`(초 단위 적립·시작 검증·채집 배율), `CaptureLogic` 확장(`planEncounter`·`encounterEvents`·`isNight`), `RosterRules`·`FacilityRules`·`QuestRules`·`CraftRules`. server(deps 주입, Lune 실행 가능): `ServerRng`(스트림 3개·공급자 주입·범위 밖 재추첨), `Services/{Activity, GatherService, WildSpawnService, CaptureService, RosterService, FacilityService, QuestService, CraftService}`. 계획과 다른 점: 판정은 shared `*Rules`로 분리, 서비스는 `beforeChange`(정산)·`afterChange`(채집 배율 갱신) hook을 받음, 시설 `assigned`는 빈칸 없는 배열(빈 칸 지정 = 끝에 추가, `""` = 빼고 당김), 놓아주기는 동행·배치 중 거부, `quest_day ≥ 오늘`이면 수령 거부(시계 역행 대비), `EncounterEvent`에 `reveal` phase·`at`·`species`·`seconds`·`assist` 추가. `Text`에 `Notice.StorageFull`, `Config`에 채집·포획 반경·제작 허용 목록.
- 검증(cwd roblox-game): Lune vectors PASS 100/SKIP 30/FAIL 0, unit PASS 105/FAIL 0(18 suites, 새 Spec 7개: Gather·Encounter·CaptureService·CaptureSample·RosterService·FacilityService·QuestCraft), rojo build 성공. 표본(xorshift32 대체 공급자, 1만 회): ★1 Q=1, ★2 0.9788(기대 0.9787972), ★3 0.8018, ★4 0.4718, intInclusive(10000,12000) 양 끝 확인. 돌연변이 5종(강화 정산 순서·quest_day 비교·next_spawn_at·범위 밖 적립·배치 이동) 모두 검출. data·econ_sim 무변경. 특성 params `start_hour`/`end_hour` 정리는 결정 필요로 보류(사용자 질문).
- 사용자 결정(2026-11-12, S6~S9 순수 로직 후): ① 특성 params `start_hour`/`end_hour` **키 삭제**(밤은 rules.night 하나로만, validate·model 경고·test_sim_rules 함께 정리). ② 동행·배치 중인 정령의 놓아주기는 **거부**(먼저 빼야 함). ③ 배치 이동은 **서버에서 한 번에 이동**(새 Remote, 원자적 처리, 중간 상태 없음 — 빈칸 없는 assigned 배열의 칸 번호 밀림·부분 실패 위험 때문), 대상 칸이 차 있으면 **두 정령 자리 바꾸기**. ④ 채집·포획 반경·인정 간격(12·20 studs, 3초)은 월드 제작 시 결정.
- S6~S9 리뷰(code-reviewer, 2026-11-12): Blocker·Major 0, Python 대조 의미 차이 없음, 악용 경로 없음. 사용자 결정: ① 조우 이벤트는 **시각(at)에 맞춰 RE로 단계별 전송**(RF 응답에 result 미포함). ② 게임 시계 기준 미래 시각(next_spawn_at·vigor_min·pending.endsAt)이 상한(60초 + 최대 조우 시간 등)을 넘으면 **손상값으로 잘라냄**(S4 미래 locked_at 처리와 같은 방식). ③ 진행 중 조우는 저장하지 않는 **현행 유지** — 잔여 위험: 조우 중 자동 저장 직후 서버 다운 시 심지만 차감되고 결과 소실(수용).
- 2026-11-12 S6~S9 결정·리뷰 반영(roblox-feature, 기준본 `baselines/20261112_pre_s6_s9_fix/`, Studio 미검증). ① 배치 이동: Remote `MoveSlot(uid, toFacilityId, toSlot)`(RF, Net·default.project.json·NetSpec 15개) — `FacilityRules.planMove`가 검증(형식→보유→동행 아님→배치 중→시설 존재·해금→1..slots→교환 상대 동행 아님)과 새 배열 계산을 한 곳에서 하고, `FacilityService.move`는 통과 시에만 정산→배열 교체→afterChange. 찬 칸은 교환(같은/다른 시설), 빈 칸은 끝에 추가(원래 시설은 당김). 4.3 표에 MoveSlot 행(레이트 미정) 추가 필요. ② econ_sim 특성 params `start_hour`/`end_hour` 삭제(validate 스키마·model 경고·test_sim_rules), 들어오면 SCHEMA_UNKNOWN_KEY(test_validate). ③ 조우 이벤트 단계 전송: `engage` 응답 = 시각 0 이벤트만(result·durationSeconds·endsAt 제외 — 시도 수가 드러나므로), `CaptureService:dueEvents(userId, now)`가 시각이 된 이벤트를 한 번씩 반환(1초 루프 → EncounterEvent RE), `complete`/`finish` 결과의 `events`에 미전송분 포함. ④ 미래 시각 잘라내기: 상한 = data 계산(최장 조우 = max(weaken.max_seconds, assist_seconds) + attempt_seconds×K_max = 52초, next_spawn_at 112초, vigor_min ≤ (now+52)//60), 초과 시 now로 고치고 로그. **사용 시점**에 검사(WildSpawnService.ensure·engage의 동행 입력·complete) — 로드 시 손상과 플레이 중 시계 역행 둘 다 막고, pending.endsAt은 저장되지 않아 사용 시점만 가능. ⑤ `Services/SessionCleanup.run(deps, userId, save, now)`(capture:finish→gather:stop→wild:clear→activity:clear, 단계별 pcall). Main 결선은 Studio 단계: PlayerRemoving은 releaseAsync 전, BindToClose는 closeAll 전(Main에 TODO). ⑥ 테스트 보강(분 경계 조우의 vigor_min, 반영 시 정산이 도감 등록 전·atSec). ⑦ Nit: 출현표 빈 확인을 부수효과 전으로. 검증: Lune vectors 100/30/0, unit 119/0, rojo build 성공, econ_sim unittest 204 OK·validate ERROR 0·gen-tables 최신. 돌연변이 16종(Luau)+1종(Python) 모두 검출.
- 메인 확인(2026-11-12, S6~S9 리뷰 반영 후): Lune vectors 100/30/0·unit 119/0 재실행 확인. 결정 ①의 귀결로 engage RF 응답에서 durationSeconds·endsAt도 제외(시도 횟수를 드러내므로), MoveSlot 레이트는 AssignSlot과 같은 4/s, MoveSlot 인자는 (uid, toFacilityId, toSlot)(출발 위치는 서버가 uid로 탐색). 이 수정분은 S10 통합 리뷰 범위에 포함.
- 2026-11-12 S5 사전 설계(메인, 코드 변경 없음, Studio 미검증): `docs/world_hud_design_20261112.md`·목업 `docs/previews/meadow_layout_hud_mock.html`. 결정: 서버 8명=부지 8개, 야생 표시 하이브리드(장식 정령 무리 모두 표시·포획 대상은 플레이어별 1마리·Q2 유지·동행 따라다님), ProximityPrompt는 화면 버튼만 하고 요청은 기존 Remote 하나로, 시설 화면은 HUD Home과 받침대 Prompt 양쪽, 시작 위치는 자기 부지. 외형 방향: 귀엽게, 10~20대 타깃(사용자). S5·S7 착수 시 이 문서를 입력으로 쓴다.
- 2026-11-12 meadow 정령 4종 외형 선구현(roblox-feature, Studio 미검증): `shared/SpiritVisuals/{Dewdrop,FlowerLamp,ShardLight,SunsetBird}.luau`(Sparkle과 같은 시그니처, DEFAULT_PALETTE 분리, 파트 10~14), `game/previews/*Preview.server.luau`, `docs/previews/*_preview.{html,png}`(PNG는 설치된 Chrome headless로 촬영, three.js CDN 사용). 검증: Lune 매핑 오류 0·vectors 100/30/0·unit 119/0, rojo build 성공, luau.compile 구문 OK, @lune/roblox 스모크(생성→5프레임→palette 교체→destroy) OK. S7 이월: 레지스트리에서 Heartbeat 하나로 모든 정령 갱신 + BulkMoveTo·거리 컬링, 공통 함수(makePart 등 4파일 중복) 공용 모듈화, palette는 기본값 병합 또는 키 검증. 사용자 결정(11/12): Sparkle도 새 얼굴 방식(큰 눈·하이라이트·홍조·위상 어긋남)으로 맞춘다 → 같은 날 완료(파트 8→12, palette 키 shine·cheek 추가·옛 palette는 기본색으로 채움, preview 정면 수정, Lune·rojo·compile·스모크 통과, Studio 미검증. non-strict 유지 → S7 공용 모듈화 때 strict 전환), 이슬방울 눈은 작은 크기 유지.
- 2026-11-12~13 정령 20종 확장·도감 보너스 개편(roblox-feature, 설계·결정·구현 기록은 `docs/spirit_roster_expansion_20261112.md`). MVP1 영향: 도감 보너스가 "종 수 × 1% 전체 생산"에서 "종별 1개(자원·사냥 재료 생산 ★1 0.5/★2 1/★3 2%, ★4 특수: 오로라 사슴 포획 +0.5%p·그림자 등불 강화 −5%·별무리 고래 제작 −5%)"로 바뀌었다. 방치·직접 채집·집 사냥 재료·포획·강화·제작 경로에 반영(`Formulas.dexBonusMap` 등, `Economy.dexMap/dexCosts`, IdleCalc 입력이 save.dex). 벡터 총 153(PASS 123·SKIP 30). 검증(메인 재실행 2026-11-13): econ_sim unittest 229 OK·validate ERROR 0·gen-tables 최신, Lune 매핑 오류 0·vectors 123/30/0·unit 126/0, rojo build 성공. code-reviewer Blocker·Major 0(Minor 2·Nit 1 반영). Studio 미검증.
- 사용자 결정(2026-11-13, 인기 차별점·외형 토론 `docs/appeal_visuals_debate_20261113.md`): S7·S8 완료 기준에 다음을 추가한다(기존 범위 안, 새 저장·Remote·경제 계약 없음). ① **외형 수정** — 미리보기 A/B에서 사용자가 고른 얼굴·재질·접지 그림자 안을 meadow 종에 반영(S7, 실패 시 기존 외형 유지). ② **포획·배치 순간의 짧은 기쁨 반응**(S7 포획 결과·S8 배치 피드백, 클라이언트 연출만이며 결과·지급의 선행 조건이 아님). ③ **살아 있는 정원 최소 연출** — meadow 시설 2곳에서 배치 정령이 일하는 모습·생산 방향 표시(S8 생산 연출, 연출 수 상한, 생산량은 HUD 기준). 탭 반응·주인 바라보기·표정 controller 확장은 동결 예외 후보로 따로 결정. 메시 하이브리드 시험은 MVP1 직후 사용자가 집에서 진행(11/11 "그래픽 = 임시 도형" 변경은 그때 결정). S7 동행 이동 결선 시 이동 root 단일 소유(외부 PivotTo와 외형 내부 고정 origin 갱신 충돌 방지)를 함께 정리한다.
- 2026-11-13 반짝이 입 추가(메인, Studio 미검증): 사용자 결정(`docs/appeal_visuals_debate_20261113.md` 끝)에 따라 `shared/SpiritVisuals/Sparkle.luau`에 ω 입(눈과 같은 색 SmoothPlastic, 관 6·공 8 = 파츠 14개, 12→26)을 추가했다. palette 키는 바꾸지 않았다(입 색 = palette.eye). 외형 판단 기준은 밤 화면 우선(사용자). 검증: Lune vectors 123/30/0·unit 126/0, rojo build 성공, @lune/roblox 스모크(생성→Heartbeat 5회→옛 palette 생성→destroy, 파츠 26·입 14·NaN 없음) OK. `docs/previews/sparkle_preview.{html,png}`는 입 추가 전 그림이며, 입 모양은 `sparkle_ab_20261113`의 B1 칸과 같다. S7 이월: 파츠 증가분을 포함한 다수 표시 성능은 Studio에서 확인.
- 2026-11-13 귀환 수확 요약(서버·계산·세션 보관, roblox-feature, Studio 미검증, 화면 없음): 사용자 결정(오프라인 1시간 이상일 때 "자는 동안 정령들이 모은 것"을 정령별 기여 포함으로 표시, 요약은 저장하지 않음, 버려진 시간 포함, 경제 영향 0)에 따라 `IdleCalc.settle(..., withBreakdown)`이 (낮/밤, 자원)·집 재료 행별 실제 획득량을 `parts`로 기록하고, `IdleCalc.spiritBreakdown`이 정령(uid)별로 배분(시설: 같은 자원 시설끼리 시설률 → 시설 안 slotPower 비, 집 재료: 1마리 milli/일 비, 최대 나머지·동점 uid 오름차순, 정령별 합 = gained), `IdleCalc.returnReport`가 요약(show = 오프라인 경과 (now − last_online_at)//60 ≥ `Config.RETURN_REPORT_MIN_OFFLINE_MINUTES`(60), 인정·소실 분, 자원별, 기여 큰 순 정령 목록)을 만든다. `IdleService:settleOnLoad`(Main onLoaded)가 정산 반영 후 pcall로 요약을 만들어 userId별 메모리에 두고(`getReturnReport`/`clearReturnReport`, PlayerRemoving·퇴장 중 로드 종료 시 정리), 요약 실패는 로그만 남기고 정산·저장에 영향 없음. 지갑·carry·settled_min·저장 스키마·test_vectors 불변. 검증: Lune 매핑 오류 0·vectors 123/30/0·unit 136/0(+10), rojo build 성공. 완료 기준 추가 메모: **S5 GetSnapshot 응답에 `idle:getReturnReport(userId)` 포함**(표시 후 처리 방식은 S5에서 결정), **S8에 "귀환 수확 요약 화면(오프라인 1시간 이상, 자원별 + 정령별 기여, 버려진 시간)" 표시**.
- 2026-11-23 집 Windows 환경 준비·Studio 첫 확인(메인·사용자): Rojo 7.7.1·Lune 0.11.1 windows-x86_64를 `.tools/bin/`에 설치, Lune 매핑 오류 0·vectors 123/30/0·unit 136/0, rojo build 성공(새 clone에 없던 `game/src/client`를 `.gitkeep`으로 유지, e902698), econ_sim unittest 229 OK·validate ERROR 0·gen-tables 최신. 사용자가 Roblox Studio 설치·Rojo 플러그인 설치 후 `rojo serve` → Connect → Play: 출력 `[vectors] PASS 123 / SKIP 30 / FAIL 0`, `[unit] UNIT PASS 136 / FAIL 0 (18 suites)`, `GameData OK (17 files)`, `저장소: Mock`, `불러오기 성공(Mock, new)`, `심지 21, 정령 3, 시설 2`, 정지 시 `저장 성공(Mock)`. 이로써 **S1·S2(Rojo JSON 변환 경로 포함)·S4 Mock 흐름은 Studio에서 확인 완료**(S2 보류 해제). 실제 DataStore 재접속 확인(S4 마지막 항목)은 S10에서 사용자가 한다. 다음: S5.
- 2026-11-23 S5 구현(roblox-feature, Studio 미검증): server `Net/{Validate, RateLimiter, PushThrottle, Remoting, Snapshot}`, `Services/PlotService`, `World/MeadowBuilder`, Config(`REMOTE_RATES`·인자 상한·push 간격·`WORLD` 좌표 표), Main 결선(GameData → 서비스 → 월드·부지 → Remoting.start → PlayerAdded/Removing → 자동 저장·push 루프), shared `HudFormat`·`Net.Directions`·`Net.ErrorCode.NOT_IMPLEMENTED`·`Text`(HUD·월드·`Error.NotImplemented` 키, `Text.format`), client `Main.client`·`Controllers/{State, Hud}`. 계획과 다른 점: 스냅샷 생성은 `Net/Snapshot.luau` 순수 함수, StateChanged 묶음 전송은 `Net/PushThrottle.luau`로 분리, HUD 숫자 함수는 shared `HudFormat`(클라이언트 State도 순수, Lune·TestRunner가 StarterPlayer에서 읽어 테스트). 결정: ① **C→S 입구는 Remoting 하나**(레이트 → 검증 → 불러오기 확인(NOT_READY) → 같은 플레이어 처리 중(BUSY) → pcall 처리(INTERNAL)), lune_run이 `game/src` 전체에서 OnServerInvoke·OnServerEvent가 Remoting 밖에 없음을 검사. 레이트 초과·잘못된 인자 로그는 1·10·100…회째만. ② **S6~S9 Remote는 처리 미결선**(검증·레이트까지 통과 후 `NOT_IMPLEMENTED`) — 서비스 결선은 1초 루프·거리 계산·SessionCleanup·접속 시 일일 자동 지급과 함께 해야 안전해서 각 단계로 미룸. 변경 처리는 `bind(..., {mutates=true})`면 성공 시 StateChanged 표시. ③ **방치 생산 화면 반영 = 정산 미리보기 + 생산률 보간**: 서버는 저장 데이터를 바꾸지 않고 사본으로 지금 분까지 정산한 지갑(milli)·walletAt·자원별 milli/시·집 재료 milli/일을 보내고, 분이 바뀔 때 전원 표시 + 변경 시 표시 → 최대 4회/초 묶음 전송, 클라이언트는 최대 120초 보간(표시 전용). 매초 실제 정산(save 변경)은 저장 경합·부분 실패 면이 늘고 IdleCalc가 분 단위라 매초 갱신 효과도 없어 채택하지 않음. 스냅샷에 seq(플레이어별 증가)를 넣어 응답·push 도착 순서가 바뀌어도 되돌아가지 않음. ④ **귀환 요약**: 서버는 세션 동안 메모리에 유지하고 GetSnapshot 응답에만 넣음(StateChanged 제외), 클라이언트 State가 한 번만 꺼냄. 새 Remote(확인 후 삭제) 없이 응답 유실에도 다시 받을 수 있음. ⑤ 부지: 접속 순 가장 작은 빈 번호, 같은 사용자는 같은 번호, 퇴장 반납, 만원(9번째)이면 광장 스폰·로그. 스폰은 CharacterAdded 후 `task.defer`로 자기 부지(집·받침대 쪽을 봄). ⑥ 월드: `Workspace.MeadowWorld`(Rojo 비관리)를 매 실행 새로 만듦, 지면 윗면 y=1(템플릿 Baseplate와 겹침 방지), 부지 8개 = 광장 남쪽 반원(반지름 185, 64×64, 광장을 바라봄), 노드 2개(id·Resource·GatherRadius 속성), 야생 구역·출현 지점 6개(S7용), 숲 관문 "Forest - Coming soon", 받침대 dew_spring·bloom_garden + crystal_forge 예약 + 전시대 3칸 + 이름표. ProximityPrompt는 만들지 않음(S6~S8 클라이언트). HUD: `ScreenInsets = CoreUISafeInsets`, 왼쪽 위 지갑 4종(축약 표기 버림, 1999 → 1.9K), 오른쪽 위 Daily 받음/준비 + UTC 0시 카운트다운. 검증(cwd roblox-game): `.tools/bin/lune run game/tests/lune_run.luau` → 매핑 17/오류 0, Remote 입구 검사 통과, vectors PASS 123/SKIP 30/FAIL 0, unit PASS 192/FAIL 0(24 suites, 새 Spec 6개 Validate·RateLimiter·Remoting·Snapshot·Plot·HudFormat + Net·Text 보강). `rojo build` 성공(Client/Controllers·Server/Net·World 포함 확인), luau.compile 구문 OK(Main.server·Main.client·Hud·State·MeadowBuilder·Remoting·TestRunner), @lune/roblox 스모크(MeadowBuilder 생성 → 부품 332·부지 8·노드 속성·이름표 교체·재생성·NaN/비고정 0) OK. 돌연변이 22종 중 20종 검출(남은 2종은 NaN 검사·배열 빈 칸 검사를 각각 하나만 뺀 것으로, 정수 검사·원소 타입 검사가 같은 입력을 거부하는 동등 변이). data·저장 스키마·경제 계약 무변경. **Studio 미검증**: 월드 모양·스폰 위치·HUD 배치(모바일 safe area)·Remote 직렬화·클라이언트 require-by-string·GameData 복제 대기. 사용자 작업: Game Settings에서 Max Players = 8.
- 2026-11-23 S5 Studio 1차 확인(사용자, 부분): 확인됨 = `[World] MeadowWorld 생성: 부지 8개`, 자기 부지 스폰(집을 바라봄), 받침대 2개·전시대 "Showcase - Coming soon" 표시, Mock 불러오기·저장. **미확인** = HUD·클라이언트 로그·Remote 거부(체크리스트 1·5·6·7). 원인: S5 작업 중 `rojo serve`가 파일 생성·삭제 경합으로 종료(Rojo 7.7.1 `change_processor.rs:172` unwrap 패닉 "파일을 찾을 수 없음")해, Studio에는 수정된 기존 파일(Main·TestRunner)만 들어가고 새 파일(client 전체·Net·새 Spec)은 빠졌다(출력 `[unit] UNIT PASS 136 / FAIL 0 (18 suites)`, S5 기준 192/24). 코드 문제 아님. 대처: 파일 대량 변경 뒤에는 `rojo serve` 재시작 → Studio에서 Connect 다시 → 편집 상태 Explorer에 `StarterPlayerScripts.Client`·`ServerStorage.Tests.ValidateSpec` 존재 확인 후 Play. 발견한 문제: **crystal_forge 예약 자리 "Coming soon" 표지가 스폰 위치와 겹쳐 캐릭터를 가림**(MeadowBuilder 좌표 조정 필요, S5 재확인 뒤 수정). 참고: Play 중 `[Rojo-Warn] ... Http requests can only be executed by game server`는 클라이언트 쪽 플러그인 경고로 무시. 남은 사용자 결정: HUD 이동 버튼(`Travel` Remote 신설 여부), 귀환 요약 확인 후 삭제(Ack Remote) 필요 여부, Experience Max Players = 8 설정(Studio Game Settings, 사용자).
- 2026-11-24 S5 Studio 재확인(메인이 Studio 직접 조작, Glimmerkins Test 장소, Rojo 재연결 후 Play Solo): 출력 `[vectors] PASS 123 / SKIP 30 / FAIL 0`, `[unit] UNIT PASS 192 / FAIL 0 (24 suites)`, `GameData OK (17 files)`, `[World] MeadowWorld 생성: 부지 8개`, `[Client] GameData OK (17 files)`, Mock 불러오기·자동 저장 성공. 화면: 자기 부지 스폰(집·받침대를 바라봄), HUD 왼쪽 위 `Dew 0 · Bloom 0 · Wick 21 · Meadow Materials 0`, 오른쪽 위 `Daily ready`. 클라이언트 명령 바: 잘못된 인자 `Craft(…, NaN)`·`GatherStart(123)`·`Craft(…, "5")` → `BAD_ARG ×3`, `GatherStart("meadow_dew")` → `NOT_IMPLEMENTED`, `GetSnapshot().ok` → `true`, 서버 경고 `[Net] … Craft 잘못된 인자 거부: 인자 2: NaN(누적 1회)`. 레이트: `ClaimDaily` 5연속 → `NOT_IMPLEMENTED RATE_LIMITED ×4`, 서버 `레이트 초과 버림(누적 1회)`, 추방 없음. 수정: crystal_forge 예약 자리를 부지 로컬 (0, −4) → **(22, 22)**(집 오른쪽 뒤)로 옮겨 "Coming soon" 표지가 스폰 정면에서 캐릭터를 가리던 문제 해결(`Config.WORLD.plotLayout.reserved`, PlotSpec 범위 검사 통과, Studio 화면 확인). **S5 완료 기준 충족**(초원·노드·부지·받침대 표시, HUD 지갑, 잘못된 인자 거부). 남은 확인(선택, S10 전): Device Emulator 휴대폰 가로에서 HUD가 Roblox 메뉴·조이스틱·점프와 겹치지 않는지(PC 화면에서는 왼쪽 위 Roblox 자동 번역 안내 토스트가 Dew 알약을 잠깐 덮음 — 일시적). 남은 사용자 결정: `Travel` Remote(HUD 이동 버튼), 귀환 요약 Ack Remote, Max Players = 8 설정. 다음: S6(직접 채집).
- 사용자 결정(2026-11-24, S5 인계 메모 4절 대기 항목): ① HUD "Meadow"·"Home" 이동은 **`Travel(dest)` Remote 신설**(C2S RF, dest ∈ {"meadow","home"}, 목적지 좌표는 서버 `Config.WORLD`가 정함 — `world_hud_design_20261112.md` 38행 설계의 계약 반영). 함께 넣는 제약: 포획 진행 중이면 거부(BUSY), 이동하면 진행 중인 직접 채집을 멈춤. ② 귀환 수확 요약은 **현행 유지**(서버 세션 보관·퇴장 시 삭제, 클라이언트 1회 표시, Ack Remote 없음). ③ 최대 인원 8명은 W1로 이미 결정 — 다음 Studio 확인 때 사용자가 Game Settings에 설정(게시 전 설정 가능 여부는 미확인).
- 2026-11-24 S6 직접 채집 결선(roblox-feature, 사용자 승인 계획·옵션 A): server `Services/GatherLoop.luau`(순수: 수평 XZ 거리 — 노드 좌표는 `Config.WORLD.nodes`, 위치 없음/NaN은 무한대, `start`, 1초 `tickAll`(플레이어별 pcall, 범위 밖 → onEnded·Notify TOO_FAR, 산출 → StateChanged 표시), `beforeSave` = 채집 정산 → 방치 정산), Main: Activity·GatherService 생성, `GatherStart`/`GatherStop` `{mutates=true}` 결선, `PlayerDataService` beforeSave 훅에 userId 인자 추가(기존 2인자 호환), **SessionCleanup 결선**(PlayerRemoving `leave` = run → releaseAsync, BindToClose `closeAll` = 전원 run → closeAll, capture·wild는 S7까지 no-op stub), Snapshot `gather {nodeId, resource, rate, accruedAt}`. client `Controllers/Gather.luau`(노드에 ProximityPrompt, Gather/Stop, HoldDuration 0, RequiresLineOfSight false), Hud 아래 가운데 칩 `Gathering {resource} +{rate}/h`·위쪽 토스트(3초), State 채집 보간(accruedAt 기준, 120초 상한), Notify 수신. Text 키 9개, HudFormat `errorTextKey`·`noticeTextKey`. 검증: Lune 매핑 오류 0·vectors 123/30/0·**unit 204/0 (25 suites)**(+12), 돌연변이 10종 전부 검출, rojo build 성공, data·저장 스키마·Remote 목록 무변경. 기대 채집률(새 저장·도구 Lv1, 도감 포함): meadow_dew 160800 milli/시(동행 없음) / 211612(시작 3종 동행), meadow_bloom 161600 / 212665. **Studio**: Play 시 `[unit] UNIT PASS 204 / FAIL 0 (25 suites)`·`[Client] GameData OK`·오류 없음까지 확인(첫 Play의 `Gather:102 missing method 'resourceName'`은 이전 세션에서 남은 rojo serve가 수정 파일을 보내지 못한 동기화 문제 — rojo 재시작·Accept 후 해소). **채집 상호작용(Prompt·칩·지갑 증가·범위 이탈·연타·퇴장 저장)은 미확인**(Studio 창 포커스 문제로 메인 조작 중단). 남은 사용자 판단(권장 = 현행 유지): HUD 표기 "/h"(설계 문서 3절 "/s"와 다름), 캐릭터 없음·사망 시 GatherStart 거부 코드 BAD_ARG, 잠금 상실 추방 시 채집 세션 메모리 잔류(같은 서버 재입장 시 최대 3초 중복 적립 가능 — S10 리뷰에서 판단), 토스트·칩 위치 임시값.
- 2026-11-24~25 S5 마무리(roblox-feature, 회사 Mac, Studio 미검증): ① 사용자 결정에 따라 `Travel(dest)` RF 신설(Net·default.project.json·Validate `oneOf`·`Validate.schemas(gd, config, net)`·REMOTE_RATES 1/s·Remoting.bind mutates). 판단은 `Services/TravelService`(조우 중 BUSY, 캐릭터/HRP 없으면 NOT_READY로 저장 불변, 이동 시 GatherService.stop), 좌표는 서버(`Config.WORLD.meadowEntry`, home = 자기 부지 스폰·부지 없으면 광장), HUD 오른쪽 위 Daily 아래 Meadow·Home 버튼과 실패 안내. **S6·S7에서 Gather·Capture·Activity를 TravelService에 주입해야 두 제약이 작동**(현재 nil, Main TODO). ② crystal_forge 예약 표지가 스폰 정면에서 캐릭터를 가리던 문제를 로컬에서 배치 변경(예약 (24,20)·스폰 (0,-6)·전시대 z -22·`showcaseLabelSlot`)과 `MeadowBuilder.spawnLabelIssues`·PlotSpec 검사로 고쳤으나, **집 버전 채택으로 병합 시 제거**(2026-11-25 사용자 결정 — 집 PC 3c15af1의 예약 (22,22)·스폰 (0,-12)·전시대 z -20, Studio 확인 완료 배치를 씀). 검증(메인 재실행, cwd roblox-game): Lune 매핑 오류 0·vectors 123/30/0·unit 208/0(25 suites, +16), rojo build 성공. data·저장 스키마·경제 계약 무변경. code-reviewer: Blocker·Major 0, 머지 가능. **사용자 판단 대기(Minor)**: (1) 주입 누락 시 제약이 조용히 꺼지는 위험 대책 — 권장 = 세션 서비스 묶음 테이블을 TravelService·SessionCleanup이 공유 + S6·S7 완료 기준에 "조우 중 Travel BUSY·채집 중 Travel 시 세션 종료·지갑 반영" Studio 확인 추가. (2) 버튼 연타 시 두 번째 요청이 RATE_LIMITED로 "can't travel" 안내가 뜸 — 응답 대기 중 누름 무시·RATE_LIMITED 무표시(UI 디바운스) 여부. (3) 사망 후 리스폰 대기 중 Travel이 성공 처리됨(데이터 영향 없음) — 유지 또는 Health 조건 추가. (4) 작은 가로 모바일 화면에서 버튼·안내가 점프 버튼과 겹칠 가능성(추정) — Studio Device Emulator로 확인 후 안내를 위쪽 토스트로 옮길지. Nit: pivot 예외 시 push 누락, plotLabels 주석과 build 불일치, 부지 내 물체 겹침 검사 없음.
- 2026-11-25 회사 Mac 로컬 S5 마무리(456a48f)와 집 PC origin/main(3c15af1 표지 수정·S5 Studio 확인, ce421ee S6) **merge**(roblox-feature, 사용자 결정 "병합 + 표지는 집 버전", Studio 미검증): 부지 배치는 집 버전, 로컬의 `plotToWorld`·`plotLabels`·`spawnLabelIssues`·`showcaseLabelSlot`·`labelClearance`·`viewLane`과 관련 PlotSpec 4건은 제거(Travel이 쓰는 `meadowEntry`·`meadowEntryFrame`/`meadowEntryCFrame`·초원 입구 테스트는 유지). Travel은 S6 위에 유지하고 **TravelService에 Main의 `gather`·`activity` 같은 인스턴스를 주입**(이동 시 GatherStop과 같은 `gather:stop` = 정산 → 세션 종료 → `activity:clear("gather")`). Capture는 S7 전이라 nil(Main TODO(S7)). HUD는 오른쪽 위 Daily 아래 이동 버튼·안내, 위 가운데 토스트, 아래 가운데 채집 칩으로 위치가 겹치지 않음. 검증(cwd roblox-game): Lune 매핑 오류 0·vectors 123/30/0·**unit 216/0 (26 suites)**(원격 204 + 로컬 Travel 등 +16 − 제거한 PlotSpec 4), rojo build 성공. data·저장 스키마·경제 계약 무변경.
