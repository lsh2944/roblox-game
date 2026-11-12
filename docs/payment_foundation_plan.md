# 결제 기반(BM 도입 순서 ①) 구현 계획서

- 대상: `/Users/leeseunghak/project/roblox-game`. Git은 없다. 2026-11-12에 `git status`를 실행하면 `not a git repository`가 나온다. `roblox-game/CLAUDE.md`에는 "Git 저장소(2026-11-11 결정)"라고 적혀 있어 현재 상태와 다르다.
- 리뷰 기준본은 기존 관례대로 `baselines/<날짜>_pre_payment/`를 쓴다.
- 코드 확인일은 2026-11-12다. MVP1 진행 기록은 S4까지(`docs/game_mvp1_impl_plan.md` 진행 기록 절)다. `baselines/20261112_pre_s6_s9_logic/`가 있어서 S6~S9 로직 작업이 진행 중인 것으로 보인다(추정).
- 근거 우선순위는 `docs/bm_monetization_debate_20261111.md` 끝의 사용자 결정 두 절(2026-11-11, "유사 장르 조사 후"가 우선)이다.

## 1. 요약
- 외형·편의 상품을 안전하게 팔기 위한 공통 기반을 만든다.
  - 상품 카탈로그(내부 id → Roblox 수단·ID)
  - 권한·영수증 원장(저장 스키마 v2)
  - 멱등 ProcessReceipt
  - 게임패스·구독 확인
  - PolicyService 판정 모듈
- 실제 외형 적용·상점 UI는 ②단계 몫이다. ①에서는 "권한이 정확히 지급·복구·저장되는 것"까지만 다룬다.
- data 계약(products.json)과 econ_sim은 바꾸지 않는 것을 권장한다.

## 2. 영향 범위
- 대상은 Luau 게임 본체(`game/src/{server,shared}`, `game/tests`, `default.project.json`)뿐이다. 담당은 `roblox-feature`다.
- data 계약은 넘지 않는다(권장안 기준). 근거는 다음과 같다.
  - Roblox 게임패스는 특정 게임(experience)에 속한다. 개발자 상품도 "현재 게임 소속만 prompt 가능"하다. 그래서 테스트 Experience와 라이브의 ID가 다르다. 환경마다 다른 운영값을 econ_sim 계약에 넣지 않는다.
  - `products.json`에 키를 추가하면 econ_sim 검증기가 `SCHEMA_UNKNOWN_KEY`로 거부한다. `tools/econ_sim/econ_sim/schema.py:12`(META_KEYS는 placeholder·notes만), `:199`, 상품 스키마는 `validate.py:217-231`이다.
  - 상한(`purchase_limit_total`)·효과(`storage_capacity` amount)는 지금처럼 `products.json`을 단일 출처로 쓴다. 상품 데이터는 `data/products.json:5-14`, 보관함 상한 검증은 `validate.py:1116-1126`, sim의 구매 반영은 `sim.py:602-616`이다.
- Roblox 실환경에 닿는 부분은 상품·게임패스 생성, 가격 설정, 테스트 Experience 게시다. 모두 사용자가 실행한다.

## 3. 수정 항목 (모두 roblox-feature)

### 3.1 상품 카탈로그 (계약 경계)
- **`game/src/shared/StoreCatalog.luau`(신규, 순수)**
  - 형태: `StoreCatalog.ENVS = { [universeId(GameId)] = { env="test"|"live", items = { [productId] = Entry } } }`
  - `Entry = { instrument = "game_pass"|"dev_product"|"subscription", ids = { number|string } }`. 구독 ID는 문자열이다.
  - 보관함을 게임패스 10개로 하는 경우(Q1 권장안)는 `storage_plus_10 → ids` 10개가 된다.
  - `StoreCatalog.resolve(gameId)`: 미게시 Studio(GameId 0)나 미등록 universe에서는 빈 카탈로그를 돌려준다. 이때 구매 UI는 비활성이다.
  - 역색인 `byRobloxId(instrument, id) → productId, tierIndex`.
  - shared에 두는 이유: 클라이언트가 가격을 표시하려면 ID가 필요하다. ID는 비밀이 아니다.
- **`game/src/shared/Data/GameData.luau`**: 지금은 products를 파싱하지 않는다(`:109-135`에 resources~quests만 있음). `gd.products, gd.productOrder = byId(docs.products.products, "products")`를 추가한다.
- **가격 표시 규칙**
  - `products.json`의 `price_robux`는 sim용 placeholder다. 화면에 표시하지 않는다.
  - 실제 가격은 클라이언트에서 `MarketplaceService:GetProductInfoAsync(id, Enum.InfoType.Product | GamePass)`의 `PriceInRobux`로 얻는다.
  - 구독은 `GetSubscriptionProductInfoAsync`(클라이언트 전용, `PriceInRobux`·`DisplayPrice`)로 얻는다.
  - 조회에 실패하면 구매 버튼을 비활성으로 하고 placeholder 가격으로 대체하지 않는다.
  - 가격 최적화를 쓰면 공식 문서가 클라이언트 조회를 권장한다. `GetProductInfo`는 Deprecated다.

### 3.2 권한·원장 — 저장 스키마 v2
- **`game/src/server/Data/SaveSchema.luau`**
  - `VERSION = 2`(`:13`). `newSave`(`:105-128`)에 다음을 추가한다.
    ```
    ent = { [productId] = int },            -- 지급 단위 수(영구 권한=1, 보관함=보유 단계 수)
    passes = { [productId] = { [tier] = first_confirmed_at } }, -- 게임패스 소유 확인 캐시(API 실패 시 사용)
    receipts = { [PurchaseId] = { p = productId, t = lockNow, r = "granted"|"overflow"|"test" } },
    receipt_n = int,                        -- receipts 항목 수(상한 판정용)
    subs = { [productId] = { active = bool, renewing = bool, checked_at = int } },
    ```
  - `check`(`:188`)에 형태 검사를 추가한다.
  - 불변식: `storage_bonus == Σ amount × ent[storage 상품]`. 깨진 경우 corrupt로 추방할지 수정만 하고 기록할지는 Q5다.
  - `storage_bonus`(`:119`, INT_FIELDS `:183-186`)는 sim 대응 필드라 유지한다.
- **`Migrations.luau`**: `CURRENT = 2`(`:11`), `STEPS[1]`(`:16-18` 주석 절차)에서 위 필드를 빈 값으로 넣고 `ent`는 비운다(v1에는 구매가 없다). 라이브 세이브는 아직 없지만 마이그레이션 경로를 한 번 실제로 검증하려고 v2로 올린다.
- **`shared/Types.luau`**: `PlayerSaveV2` 타입을 추가한다. `PlayerSaveV1`은 `:33`에 있다.
- **원장 상한·보존**
  - 개발자 상품 영수증만 기록한다.
  - 상한(capped) 상품·영구 상품 영수증은 삭제하지 않는다. 수량이 상한으로 제한되기 때문이다.
  - 소모성(장래 광고 보상 상품 등)은 `receipt_n > 300`일 때 오래된 것부터 지운다.
  - 크기는 300 × 약 100B ≈ 30KB로 키 한도(계획서 4.4의 4,194,304자)에 비해 작다.
  - PurchaseId 길이·형식은 미확인이다. 문자열 1~128자로 검사한다.
  - 위험: 공식 문서상 재호출에 시간 기한이 없다(아래 출처). 그래서 지워진 소모성 영수증이 다시 오면 이중 지급이 될 수 있다. 소모성에만 해당하는 잔여 위험으로 수용한다.

### 3.3 순수 권한 로직
- **`game/src/server/Store/Entitlements.luau`(신규, 순수)**
  - `applyReceipt(save, receipt, entry, product, lockNow) → "granted"|"duplicate"|"overflow"|"unknown"`
    - 중복은 `receipts`에 이미 있는 경우다.
    - 상한 검사: `ent[p] >= purchase_limit_total`이면 overflow다(Q1 처리 방침에 따름).
    - 지급은 `ent += 1`, storage 효과면 `storage_bonus += amount`, 원장 기록까지 한 번에 하며 사본 위에서 계산한다.
  - `applyPassOwnership(save, productId, tier, owned|nil, now)`
    - nil은 API 실패다. 이때 `passes` 캐시를 쓴다.
    - true면 캐시에 기록한다.
    - 명시적인 false는 소유하지 않은 것으로 본다. 보관함 칸이 줄어도 정령은 지우지 않고 포획만 막는다(MVP1 Q4 동작).
  - `subscriptionActive(save, productId, status|nil, now, graceSec)`
    - API 응답이 있으면 그대로 쓰고 캐시를 갱신한다.
    - 실패하면 `checked_at + grace > now`이고 마지막 값이 active일 때만 active다.
  - `capacityBonus(save, gd)`, `owns(save, productId)`.
- **`game/src/server/Store/PolicyGate.luau`(신규, deps 주입)**
  - `fetch(player)`(pcall로 감싼 `GetPolicyInfoForPlayerAsync`), 플레이어별 캐시, 실패 시 2회 백오프 재시도를 둔다.
  - 끝내 실패하면 **보수적 기본값**을 쓴다.
    - `ArePaidRandomItemsRestricted=true`, `IsPaidItemTradingAllowed=false`, `AreAdsAllowed=false`, `IsEligibleToPurchaseSubscription=false`
  - ①에서 실제로 쓰는 곳은 `canPromptSubscription`뿐이다. 구독 결선은 Q3에 따른다.
  - `canUsePaidRandom`·`canTradePaidItems`·`canShowAds`는 hook만 둔다. 지금은 유료 랜덤·거래 기능이 없으므로 호출하는 곳도 없다.
  - 생성 제한과 거래 제한은 별도 판정으로 둔다(토론 결정 C1). 필드명은 공식 문서로 확인했다(출처 참조). C1의 "필드명 미확인" 항목은 해소됐다.

### 3.4 서비스·결선
- **`PlayerDataService.luau`에 `commitAsync(userId)`를 추가한다.**
  - 지금의 `saveAsync`는 저장 중이면 `"busy"`로 건너뛴다(`:342-344`). 결제 확정에는 쓸 수 없다.
  - `commitAsync`는 `p.saving`이 끝날 때까지 기다린 뒤(상한 `CLOSE_WAIT_SECONDS`) `_write(p,false)`(`:283`)를 호출한다. `state ~= "active"`면 `"inactive"`를 돌려준다.
- **`game/src/server/Store/PurchaseService.luau`(신규, deps 주입: players, playerData, marketplace 래퍼, wait, log)**
  - `processReceipt(info)`의 처리 순서:
    1. `PlayerId`로 플레이어를 찾는다. 없으면 `NotProcessedYet`.
    2. 프로필이 loading이면 플레이어가 있는 동안 기다린다. 콜백은 서버 수명 동안 yield할 수 있다.
    3. `state ~= "active"`(releasing/lost 등)면 `NotProcessedYet`이다. 다른 서버로 옮겨 가는 중이면 그쪽에서 처리된다.
    4. `byRobloxId`로 상품을 찾지 못하면 `NotProcessedYet`과 오류 로그를 남긴다. 환경 혼동이 원인일 수 있으므로 돈만 받고 지급 없이 끝내지 않는다.
    5. `applyReceipt`가 duplicate면 즉시 `PurchaseGranted`.
    6. granted/overflow면 메모리 save에 반영한 뒤 `commitAsync`를 부른다. 결과가 `"saved"`일 때만 `PurchaseGranted`, 그 밖에는 `NotProcessedYet`.
  - 저장이 실패해도 메모리 반영은 되돌리지 않는다. 다음 자동 저장이나 퇴장 저장에 원장째 들어가므로, 재호출 때 duplicate가 되어 이중 지급이 없다. lost_lock이면 기록되지 않으므로 다음 서버에서 정상 지급된다.
  - 두 서버 동시 실행 문제(공식 문서에 명시)는 세션 잠금이 "active 프로필만 지급"으로 직렬화한다.
  - 게임패스 처리:
    - `onPlayerLoaded`: 카탈로그의 모든 게임패스에 대해 `UserOwnsGamePassAsync`를 병렬 spawn으로 확인한다. 공식 문서상 엔진이 배치 처리하고 결과는 캐시된다.
    - `onPromptGamePassFinished(player, passId, wasPurchased)`: 서버에서만 듣는다. true면 즉시 소유로 반영한다. 외부 구매는 세션 중 캐시 반영에 몇 분 걸릴 수 있다고 문서에 있다. 재입장 시에는 true가 보장된다.
  - 구독은 PlayerAdded 시 `GetUserSubscriptionStatusAsync`, `Players.UserSubscriptionStatusChanged` 때 재확인한다.
  - 구매 요청 RF `StorePurchase(productId)`
    - 서버 사전검사: 카탈로그 존재, 보유/상한, 프로필 active, 구독이면 PolicyGate.
    - 통과하면 해당 Prompt를 호출한다.
    - **서버에서 Prompt*Purchase를 호출할 수 있는지는 미확인**이다. 안 되면 사전검사 결과만 돌려주고 클라이언트가 prompt한다.
    - 사전검사는 보조 수단이다. 외부 구매가 있을 수 있으므로 최종 판정은 항상 ProcessReceipt·소유 확인이 한다.
- **`Main.server.luau`**
  - `MarketplaceService.ProcessReceipt`는 이 Script에서 한 번만 설정한다(공식 규칙).
  - `PromptGamePassPurchaseFinished`와 `Players.UserSubscriptionStatusChanged`를 연결한다.
  - `onLoaded`(`:118-125`) 뒤에 소유 확인을 spawn한다.
- **`shared/Net.luau`**(`:14-29`)과 `default.project.json` Remotes에 `StorePurchase`(RF)를 추가한다. NetSpec이 둘의 일치를 검사한다.
- 권한 상태는 S5의 스냅샷(`GetSnapshot`/`StateChanged`)에 `ent`·소유 요약으로 싣는다.
- **`shared/Text.luau`**(`:16-22`): `Store.Unavailable`, `Store.AlreadyOwned`, `Store.LimitReached`, `Store.Granted`, `Store.PriceUnavailable` 등 영어 키를 추가한다.
- **`Config.luau`**: `RECEIPT_LEDGER_MAX=300`, `SUB_GRACE_SECONDS`(가안 6시간, Q4), `POLICY_RETRY=2`, `RECEIPT_PROFILE_WAIT_SECONDS`를 추가한다.

## 4. 수정 순서와 마일스톤 위치
- 권장: MVP1 S10(통합·리뷰) 완료 직후 첫 후속 마일스톤 **P1 결제 기반**에 넣는다.
- 이유: MVP1 S5~S9 동안 v1 저장 필드가 바뀔 수 있다. 그 전에 v2를 올리면 마이그레이션을 다시 해야 한다. 또 S5의 스냅샷·Remote 결선이 있어야 한다. 이 일정은 Q6이다.

| 단계 | 내용 | 완료 기준 |
|---|---|---|
| P1a (Lune) | StoreCatalog, GameData products 파싱, Entitlements, SaveSchema v2·Migrations, Types | 새 Spec PASS, 기존 vectors 100/SKIP 30·unit 전부 PASS |
| P1b (Lune+mock) | PolicyGate, PurchaseService, `commitAsync`, Net/Remotes, Text, Config, Main 결선 | MockStore·가짜 marketplace로 서비스 흐름 Spec PASS, `rojo build` 성공 |
| P1c (사용자) | 테스트 Experience에 상품 생성, 카탈로그에 ID 기입(Claude), Studio 모의 구매 확인 | 아래 체크리스트 통과 |

## 5. 리스크·검증

### Lune 테스트 목록
- 대상 Spec: `EntitlementsSpec`, `PurchaseServiceSpec`, `PolicyGateSpec`, `StoreCatalogSpec`, 그리고 기존 `SaveSchemaSpec`·`PlayerDataSpec` 확장. 새 Spec은 `lune_run.luau` SPECS(`:34-46`)에 등록한다.
- 멱등
  - 같은 PurchaseId 2회 → 1회만 지급, 2회째 duplicate·Granted.
  - 지급 후 저장 실패 → NotProcessedYet, 자동 저장 뒤 재호출 → duplicate.
  - lost_lock → 기록 없음, 다음 프로필에서 정상 지급.
- 프로필 상태
  - 미로드 대기 후 지급.
  - 대기 중 퇴장 → NotProcessedYet.
  - releasing/lost 상태 → NotProcessedYet.
  - stale 프로필(재입장) → 지급 없음.
- 상한: 9→10 지급, 10에서 overflow(Q1 방침대로), `storage_bonus` 불변식, 200 상한(hub max_capacity, `data/hub.json:4`).
- 미등록 ID → NotProcessedYet.
- 원장: 상한 300 초과 시 소모성만 오래된 것부터 삭제, capped·영구 항목은 남는다. PurchaseId 형식 위반은 거부한다.
- 마이그레이션: v1 세이브 → v2 필드 추가·`save_schema=2`. v3 세이브 → newer_schema 추방(기존 경로). v2 형태 이상 → corrupt.
- 게임패스: API 실패 시 캐시 사용, 명시적 false면 소유 해제·정령 보존, 구매 직후 이벤트로 반영.
- 구독: active 응답, 실패 + 유예 이내 → 마지막 값 유지, 유예 경계 정각과 초과 → inactive, 한 번도 확인 못 한 경우 → inactive.
- PolicyGate: 성공 시 캐시, 실패 2회 후 보수적 기본값, 필드 누락 시 보수적 값.
- 카탈로그: 모든 `products.json` id가 각 env에 있거나 명시적으로 미판매다. kind와 instrument가 맞아야 한다(cosmetic/placement_preset → game_pass, storage_expand → Q1 결과, subscription → subscription). 보관함 단계 수가 `purchase_limit_total`과 같아야 한다.

### 필수 검증 (완료 시, cwd `roblox-game`)
- `.tools/bin/lune run game/tests/lune_run.luau`: vectors PASS 100/SKIP 30, unit 전부 PASS, 매핑 오류 0.
- `.tools/bin/rojo build default.project.json -o <scratchpad>/test.rbxlx`
- `tools/econ_sim`에서 `python3 -m econ_sim validate`와 `gen-tables --check`를 시작과 끝에 실행해 data가 바뀌지 않았음을 확인한다. Python을 고치지 않으므로 전체 unittest·시뮬은 생략한다.
- 기준본 diff로 code-reviewer 리뷰.

### 사용자 Studio·테스트 Experience 확인 (P1c)
1. 테스트 Experience에서 상품을 만든다(라이브와 별도).
   - 외형·프리셋 게임패스 각 1개.
   - 보관함(Q1 결과에 따라 게임패스 10개 또는 개발자 상품 1개).
   - 영수증 경로 검증용 테스트 전용 개발자 상품 1개(지급 효과 없음, 테스트 env에만 등록).
   - 상품 ID와 universe ID(GameId)를 Claude에게 전달한다.
2. 그 Experience에 게시한 place를 Studio로 열고 모의 구매를 한다. 다음을 확인한다.
   - 지급과 로그.
   - 같은 세션 재구매 시 상한/보유 안내.
   - Play를 멈췄다 다시 시작했을 때 상태(Mock은 사라지므로 `STUDIO_USE_REAL_DATASTORE=true` + API Access로 dev 스토어에서 확인).
3. ProcessReceipt에서 일부러 NotProcessedYet을 내게 하는 디버그 스위치를 켜고 재입장했을 때 재호출되는지 확인한다.
4. 가격이 GetProductInfoAsync 값으로 표시되고, 실패하면 버튼이 비활성인지 확인한다.
5. Team Test에서는 ProcessReceipt가 호출되지 않는다는 커뮤니티 보고가 있다(비공식). 단독 Play로 확인한다.

### 위험
- 모의 구매가 Studio에서 과금되지 않는다는 근거는 DevForum뿐이다. 공식 레퍼런스에는 "Studio의 모의 구매는 상품이 현재 게임 소속인지 검사하지 않는다"만 있다. 그래서 라이브 게시 전에 카탈로그 ID가 라이브 universe 소속인지 사용자가 확인해야 한다.
- PurchaseGranted를 반환한 뒤에도 백엔드 기록이 실패하면 재호출될 수 있다(공식). 원장으로 막는다. 소모성 원장 삭제의 잔여 위험은 3.2에 적었다.
- 개발자 상품은 게임 밖에서도 팔릴 수 있다. 그래서 사전검사만으로는 상한을 넘는 구매를 막을 수 없다(Q1). 게임 밖 판매를 상품별로 끌 수 있는지는 미확인이다.
- 공식 문서상 Roblox는 ProcessReceipt 구현을 상시 점검하고, 문제가 있으면 게임 밖 노출을 중단한다. 멱등·NotProcessedYet 규칙을 지켜야 하는 이유다.
- 구독 API는 만료 시각을 주지 않는다(IsSubscribed/IsRenewing만). 그래서 "기간 권한"은 실시간 확인과 유예 캐시로만 표현한다.
- `UserSubscriptionStatusChanged`는 Players 클래스 레퍼런스 원문으로는 확인하지 않았다. 구독 가이드 페이지의 언급만 있다.

## 6. 사용자 질문 (판단을 바꾸는 것만)
1. **Q1 보관함 +10의 Roblox 수단**
   - 권장: (A) 게임패스 10개("Storage +10 I~X")를 내부 id `storage_plus_10` 하나에 단계로 매핑한다.
   - 이유: 구조상 상한 초과가 생기지 않는다. 데이터가 사라져도 Roblox 소유로 복구된다. products.json·sim 계약(한도 10)도 그대로다.
   - 단점: 상점 항목이 10개가 되고 가격 변경도 10번 해야 한다.
   - (B) 개발자 상품 1개 + 서버 상한을 쓰면 초과 구매 처리를 정해야 한다.
     - b1: 지급 없이 Granted. Robux만 소비되므로 비권장.
     - b2: NotProcessedYet 유지. 공식 문서상 미해결 구매는 escrow 기간 뒤에도 환불되지 않는다.
     - b3: 동등한 외형으로 보상. 보상 카탈로그가 필요하다.
   - (A)를 택해도 ProcessReceipt 기반은 장래 광고 보상(토론 I8의 개발자 상품)을 위해 구현한다. ①에서는 테스트 전용 상품으로 검증한다.
2. **Q2 게임패스 소유가 명시적 false로 바뀐 경우(환불·회수 추정)**
   - 권장: 권한 해제, 정령·배치 데이터는 보존, 포획만 차단.
   - 이유: Roblox를 소유의 진실 공급원으로 둔다. 회수가 실제로 일어나는지는 미확인이다.
3. **Q3 구독 경로를 ①에 어디까지 넣을지**
   - 권장: 순수 로직·PolicyGate hook·테스트까지만 넣고 Main 결선과 상품 등록은 하지 않는다.
   - 이유: 사용자 결정상 시즌 패스가 우선이고 반복 상품은 외형 비축 뒤 하나만 운영한다.
4. **Q4 구독 확인 실패 시 유예 시간**
   - 권장: 6시간.
   - 이유: 일시적인 API 장애로 구독자 혜택이 빠지는 것은 막고, 해지 뒤 혜택이 길게 남지는 않게 한다. 가안이다.
5. **Q5 `storage_bonus` 불변식이 깨진 세이브**
   - 권장: `ent`에서 다시 계산해 고치고 로그를 남긴다. 추방하지 않는다.
   - 이유: 결제 권한을 잃는 쪽보다 복구 쪽이 안전하다.
6. **Q6 착수 시점**
   - 권장: MVP1 S10 뒤(P1).
   - 대안: 순수 부분(P1a)만 S9와 병행하고 v2 승격은 S10 뒤에 한다.

## memory 기록 제안
`project_roblox_idle_game.md`에 다음을 추가할 것을 제안한다.
- 결제 기반 설계 요지: 카탈로그는 Luau shared에 universe별로 두고 data 계약은 바꾸지 않는다. 원장은 플레이어 세이브 v2와 같은 키에 둔다. 지급 순서는 active 프로필에서만 지급 → commit 성공 시 Granted다. PolicyService 필드명은 확인됨.
- 계획서 경로: `docs/payment_foundation_plan.md`.

## 출처 (확인일 2026-11-12)
- MarketplaceService 레퍼런스 원문(yaml): https://raw.githubusercontent.com/Roblox/creator-docs/main/content/en-us/reference/engine/classes/MarketplaceService.yaml
  - ProcessReceipt: Script 하나에서 한 번만 설정, 시간 기반 재시도 없음(같은 서버의 다음 구매나 재입장 시 재호출), 두 서버 동시 실행 가능, 호출 순서 비결정, 타임아웃 없음, 사용자가 서버에 있어야 호출됨, Granted 뒤 백엔드 기록 실패 가능, 미해결 구매는 escrow 뒤에도 환불되지 않음, ReceiptInfo 키 `PurchaseId, PlayerId, ProductId, PlaceIdWherePurchased, CurrencySpent, CurrencyType, ProductPurchaseChannel`.
  - UserOwnsGamePassAsync: 결과가 캐시되고, 세션 중 외부 구매는 반영에 몇 분, 구매 뒤 첫 입장 시에는 true.
  - PromptGamePassPurchaseFinished: 서버에서 듣는다.
  - GetUserSubscriptionStatusAsync: `IsSubscribed`/`IsRenewing`.
  - GetSubscriptionProductInfoAsync: 클라이언트 전용.
  - PromptProductPurchase: 현재 게임의 상품만 prompt 가능.
  - Studio 모의 구매: 상품 소속을 검사하지 않음.
  - GetProductInfo: Deprecated, GetProductInfoAsync로 대체.
- https://create.roblox.com/docs/reference/engine/classes/MarketplaceService (위와 같은 내용의 렌더링 판)
- https://create.roblox.com/docs/production/monetization/developer-products: 지급 후 Granted, 실패 시 NotProcessedYet, 구매 이력 저장은 개발자 책임, ProcessReceipt 상시 점검, 가격 최적화 시 클라이언트 가격 조회.
- https://create.roblox.com/docs/production/monetization/game-passes: 일회성 결제, 게임별 생성, PlayerAdded 소유 확인, 서버 PromptGamePassPurchaseFinished.
- https://create.roblox.com/docs/production/monetization/subscriptions: Robux 구독 49 Robux 이상, 지역 가격 강제, 해지 시 결제 주기 끝까지 혜택, Robux 구독은 환불 불가, 서버에서 확인, PlayerAdded와 UserSubscriptionStatusChanged 때 재확인.
- PolicyService 레퍼런스 원문(yaml): https://raw.githubusercontent.com/Roblox/creator-docs/main/content/en-us/reference/engine/classes/PolicyService.yaml
  - 필드: `AreAdsAllowed, ArePaidRandomItemsRestricted, IsContentSharingAllowed, IsEligibleToPurchaseCommerceProduct, IsEligibleToPurchaseSubscription, IsPaidItemTradingAllowed, IsPhotoToAvatarAllowed, IsSubjectToChinaPolicies, AllowedExternalLinkReferences(레거시, 항상 빈 배열), IsEndlessContentLoadAllowed, IsEndlessContentAutoplayAllowed`.
  - pcall 권장, 응답 전 100회를 넘게 호출하면 오류. 캐시·Studio 동작은 기재 없음.
- 비공식(DevForum, 참고만)
  - Studio 구매 비과금: https://devforum.roblox.com/t/how-to-test-the-purchase-of-a-developer-product/2205622
  - Team Test에서 ProcessReceipt 미호출: https://devforum.roblox.com/t/marketplaceserviceprocessreceipt-is-not-called-in-team-test/3983692
- 미확인으로 남은 것: 서버에서 Prompt*Purchase 호출 가능 여부, 게임 밖 개발자 상품 판매를 상품별로 끌 수 있는지, PurchaseId 형식·길이, 게임패스 환불 시 소유 회수 여부, 게임패스·개발자 상품 생성 비용(기존 C4), 광고 보상 자격 API.

## 주요 근거 파일
- `/Users/leeseunghak/project/roblox-game/data/products.json`
- `/Users/leeseunghak/project/roblox-game/game/src/server/Data/SaveSchema.luau`
- `/Users/leeseunghak/project/roblox-game/game/src/server/Data/Migrations.luau`
- `/Users/leeseunghak/project/roblox-game/game/src/server/Data/PlayerDataService.luau`
- `/Users/leeseunghak/project/roblox-game/game/src/server/Main.server.luau`
- `/Users/leeseunghak/project/roblox-game/game/src/shared/Data/GameData.luau`
- `/Users/leeseunghak/project/roblox-game/game/src/shared/Net.luau`
- `/Users/leeseunghak/project/roblox-game/game/src/shared/Text.luau`
- `/Users/leeseunghak/project/roblox-game/tools/econ_sim/econ_sim/validate.py`
- `/Users/leeseunghak/project/roblox-game/tools/econ_sim/econ_sim/schema.py`
- `/Users/leeseunghak/project/roblox-game/docs/bm_monetization_debate_20261111.md`
- `/Users/leeseunghak/project/roblox-game/docs/game_mvp1_impl_plan.md`

## 사용자 결정 (2026-11-12)
- Q1 보관함 +10: **게임패스 10개**("Storage +10 I~X", 내부 id `storage_plus_10`의 단계 1~10). products.json·sim 계약(한도 10) 유지. ProcessReceipt 기반은 장래 광고 보상용으로 구현하고 ①에서는 테스트 전용 개발자 상품으로 검증.
- Q2 게임패스 소유가 명시적 false: **권한 해제, 정령·배치 데이터 보존, 새 포획만 차단**(Roblox 소유를 진실 공급원으로).
- Q6 착수 시점: **MVP1 S10 완료 뒤** 첫 후속 마일스톤 P1.
- Q3 구독: **순수 로직·테스트까지만**(Main 결선·상품 등록 없음, 시즌 패스 우선 결정). Q4 구독 확인 실패 유예: **6시간**. Q5 보관함 보너스 불일치: **구매 기록(게임패스 소유) 기준으로 재계산해 고치고 로그만 남김**(추방 안 함).
