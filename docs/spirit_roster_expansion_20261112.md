# 정령 20종 확장 초안 (2026-11-12, 사용자 승인 대기)

- 기준: 저장소 `roblox-game` main `b157fd2`, `data/spirits.json`·`data/fields.json`(capture.table)·`data/releases.json` 현행값. 수치는 모두 placeholder 가안.
- 목적: 10종 → 20종. 숲·능선은 고유 종이 1종뿐이라 새 지역에 가도 새 정령이 거의 없다.

## 사용자 결정 (2026-11-12)
- 총 **20종**(+10).
- **상위호환 금지 원칙 폐지.** 도감·외형 수집 목적의 플레이어가 있고, 쓰지 않는 하위 종은 나중에 교배 등 새 시스템으로 활용을 검토한다(아이디어 단계, 미설계).
- **초원(MVP1) 5종과 초원 출현표는 유지**한다. 추가는 숲·동굴·능선에만 한다.

## 현재 (확장 전)
| 지역 | 출현 종 | 고유 종 |
|---|---|---|
| meadow | 5 | 5 (★1 반짝이·이슬방울·꽃등, ★2 노을새·조각빛) |
| forest | 6 | 1 (★3 무지개 나비) |
| cave | 7 | 3 (★3 등대곰·달빛 여우, ★4 그림자 등불) |
| ridge | 8 | 1 (★4 오로라 사슴) |

## 설계 원칙 (안정성 기준)
1. **새 특성 유형을 만들지 않는다.** 이미 구현된 5가지(`special_node`, `companion_hunt_drop_bps`, `facility_output_bps`, `mixed_placement_bps`, `night_output_bps`)만 쓴다. 이유는 econ_sim·Luau에 새 로직이 생기지 않아 data 추가와 검증만으로 끝나기 때문이다.
2. **지역별 등급 출현 비율을 유지한다.** 새 종은 같은 등급 기존 종의 가중치를 나눠 갖는다. 이렇게 하면 지역별 성공률·심지 소비·★별 획득 속도(econ 계약)가 거의 그대로이고, 차이는 sim으로 확인한다.
3. 새 시스템(교배 등)이 쓸 수 있게 종마다 **외형 콘셉트와 역할을 분명히** 한다.

## 추가 10종 (가안)
적성은 dew/bloom/crystal 순서이고 S>A>B>C>D>X다. cb는 전투, ga는 채집이다.

| 지역 | id(가칭) | 이름 | ★ | 적성 | cb | ga | 특성(기존 유형) | 외형 콘셉트(귀엽게) |
|---|---|---|---|---|---|---|---|---|
| forest | moss_puff | 이끼뭉치 | 1 | B/A/X | 2 | 6 | — | 솜사탕 같은 동그란 이끼 공, 머리에 새싹 |
| forest | mushroom_lamp | 버섯등 | 1 | C/B/B | 3 | 5 | — | 발광 버섯 갓을 쓴 꼬마, 갓에서 포자 반짝 |
| forest | leaf_bunny | 잎새 토끼 | 2 | B/A/C | 5 | 6 | — | 잎사귀 귀 토끼, 귀 끝이 빛남 |
| forest | firefly_squirrel | 반딧불 다람쥐 | 2 | C/B/B | 6 | 5 | companion_hunt_drop_bps +1000 | 꼬리에 반딧불이 모여 빛나는 다람쥐 |
| cave | crystal_turtle | 수정 거북 | 2 | X/C/A | 7 | 4 | special_node(big_crystal) | 등껍질이 수정 결정인 아기 거북 |
| cave | starlight_bat | 별빛 박쥐 | 2 | C/C/B | 8 | 3 | night_output_bps(달빛 여우와 같은 placeholder 0) | 동그란 몸에 작은 날개, 날개막에 별 무늬 |
| ridge | snow_penguin | 눈꽃 펭귄 | 2 | A/X/C | 6 | 5 | — | 눈꽃 결정 볏을 단 통통한 펭귄 |
| ridge | cloud_sheep | 구름 양 | 2 | B/B/B | 4 | 7 | mixed_placement_bps +800(min 3종) | 구름 털 양, 털 사이로 오로라 빛 |
| ridge | wind_hawk | 바람 매 | 3 | C/C/B | 13 | 3 | companion_hunt_drop_bps +2000, facility_output_bps −2000 | 둥근 꼬마 매, 바람 리본 꼬리 |
| ridge | star_whale | 별무리 고래 | 4 | A/A/A | 10 | 10 | — | 하늘을 헤엄치는 작은 고래, 몸에 별자리 |

### 확장 후
| 지역 | 고유 종 | 등급 구성 |
|---|---|---|
| meadow | 5 (변경 없음) | ★1×3, ★2×2 |
| forest | 5 | ★1×2(새), ★2×2(새), ★3×1 |
| cave | 5 | ★2×2(새), ★3×2, ★4×1 |
| ridge | 5 | ★2×2(새), ★3×1(새), ★4×2(새 1) |
| 합계 20 | | ★1×5, ★2×8, ★3×4, ★4×3 |

- star_whale(★4, 전 자원 A, cb·ga 10)은 상위호환 폐지 결정에 따라 다른 종을 수치상 지배해도 된다. ★4 포획률 10%가 희소성을 맡는다.
- 출시 단계(`releases.json`): week2(meadow+forest)는 6종에서 10종으로, week4는 20종이 된다.

## 반영할 때 바뀌는 것 (구현 단계)
- data: `spirits.json` 10건 추가, `fields.json` forest·cave·ridge 출현표(등급 비율 유지로 가중치 재분배), `releases.json`.
- 검증기: `WARN_DOMINANCE`(`tools/econ_sim/econ_sim/validate.py:1202`)는 원칙 폐지에 맞춰 **INFO로 낮추고 지배표 보고는 유지**하는 것을 권장한다(참고 자료로 남김). 완전 삭제도 가능하다.
- 도감 보너스(`rules.json:82-84`): 지금은 종을 등록할 때마다 +1%, 상한 10%라서 20종에서는 10종째에 끝난다. → 아래 "도감 보너스 개편 결정"으로 대체한다. 20종 data 반영 단계에서는 dex_bonus를 바꾸지 않는다.

## 도감 보너스 개편 결정 (2026-11-12 사용자, 상세 설계는 /cross-check 토론 후 확정)
- 종마다 도감 보너스 **종류**가 다르다:
  - ① 특정 기본 자원(이슬·꽃빛·결정) 방치 생산 +
  - ② 지역 사냥 재료 방치 생산 +
  - ③ ★4 특수: 포획 확률 +, 시설 강화 비용 −, 제작 재료 − 등
- 등급별 수치: ★1 0.5% / ★2 1% / ★3 2% / ★4 특수 효과.
- 상한: 보너스 종류별 10%.
- 포획 확률 보너스: 특별한 ★4에만 준다(지금 1종, 나중에 이벤트 ★4마다 1개). 시도 성공률에 **+0.5%p**를 더하고 **안전 상한 +3%p**. 확률표에 반영하고, "성공률 등급별 고정" 원칙의 두 번째 예외(첫 번째는 포획 도구)로 기록한다.
- 비용 감소는 정수 비용의 반올림 규칙이 필요하다(권장: 할인 후 올림, 단일 함수와 테스트로 고정).
- 적용 범위: **초원 5종 포함 20종 전부**. MVP1의 도감 로직(`Economy.dexBps`·IdleCalc)과 테스트도 고친다.
- 진행: 사용자 요청으로 `/cross-check` 토론(Codex)을 거친 뒤 설계를 확정한다.
- 토론 전 확인(2026-11-12 사용자):
  - ①② 생산 보너스는 **방치(시설) 생산과 직접 채집 모두**에 적용한다.
  - **종마다 보너스 1개**.
  - 포획 확률 보너스를 줄 ★4는 토론에서 후보와 이유를 받은 뒤 사용자가 고른다.
  - 토론 방식은 기본 debate.
  - 같은 토론에서 20종 확장 뒤 생긴 사냥 재료 지역 이동, light_1h 연구 지연, 도감 기록 가격(종마다 20/40/80)도 다룬다.
- 20종 반영 후속 결정(같은 날): converge의 14종 초과 정확 해 생략은 리뷰 통과를 조건으로 수용, 같은 등급 안 가중치 배분 규칙은 확정.
- 그 밖에 확인할 econ 영향: 연구 포인트(놓아주기 등급별) 공급량, 지역별 ★별 획득 속도와 심지 부족.
- 검증: econ_sim `unittest`·`validate`·`gen-tables --check`, quick 실행을 기존 기준 run(`outputs/20261111_no_material_products_q`)과 비교, Luau Lune(GameData 매핑·vectors·unit). test_vectors는 초원 계약만 담고 있으면 영향이 없다(구현 시 확인).
- 외형: 새 10종 + 외형이 아직 없는 4종(무지개 나비·등대곰·달빛 여우·그림자 등불)을 해당 지역 구현 단계에서 만든다. MVP1에는 필요 없다.
- 표시 이름 영어화(Localization)에 10건이 추가된다.

## 구현 기록 (2026-11-12, roblox-feature)
- 기준: `roblox-game` main `b157fd2` + 미커밋 작업트리(Git). 이 절은 data 반영·검증 기록이며 위 결정 절은 바꾸지 않았다.
- data: `spirits.json` 10종 추가(표 그대로, level_cost_curve는 등급별 기존 곡선, max_owned 0·placement_cost 1·upkeep 없음), notes의 "지배 경고 0건"을 11/12 폐지 결정으로 교체. `releases.json` week2 10종·week4 20종. dex_bonus·초원 data는 변경 없음.
- 출현표(`fields.json`): 지역별 **등급 가중치 합을 그대로** 두고 같은 등급 안에서 나눴다(새 종 = 등급 합/종 수, 기존 종 = 기존 가중치 × 기존 종 수/전체 종 수, 정수화는 최대 잉여, 동률은 그 필드 고유 종 → 표 순서). 등급 비율은 4지역 모두 전후 동일(가중치 합 meadow 115·forest 106·cave 78·ridge 79 유지).
  - forest ★1 70: sparkle 12·dewdrop 12·flower_lamp 18·moss_puff 14·mushroom_lamp 14 / ★2 30: shard_light 7·sunset_bird 7·leaf_bunny 8·firefly_squirrel 8 / ★3 rainbow_butterfly 6
  - cave ★2 35: shard_light 12·sunset_bird 5·crystal_turtle 9·starlight_bat 9 (★1·★3·★4 그대로)
  - ridge ★2 15: sunset_bird·snow_penguin·cloud_sheep 각 5 / ★3 24: rainbow_butterfly·lighthouse_bear·moon_fox·wind_hawk 각 6 / ★4 10: shadow_lantern 3·aurora_deer 4·star_whale 3 (★1 그대로)
- econ_sim: 검증 이슈에 INFO 수준 추가(합격·WARN 건수에 미포함), `WARN_DOMINANCE` → `INFO_DOMINANCE`(dominance.csv·리포트 지배표는 유지, 현재 15건). converge의 "종마다 1마리" 부분집합 DP는 14종까지라 15종 이상인 cave·ridge 대표 상태는 정확 해를 생략하고 휴리스틱만 기록(gap 미측정 건수를 판정 note·리포트에 표시). 수렴 판정(무제한 재고 모드)은 그대로 정확 계산.
- 검증: unittest 206 OK, validate ERROR 0·WARN 0·INFO 15, gen-tables --check 최신, Lune 매핑 오류 0·vectors PASS 100/SKIP 30/FAIL 0·unit 119 PASS, rojo build 성공. quick run `outputs/20261112_roster20_q`(기준 `outputs/20261111_no_material_products_q`와 data·config 해시 일치 확인 후 비교): approved 판정 전부 유지(PASS→PASS, star_whale ★4 p99 6일 PASS 추가).
- 관찰: 집 방치 사냥 재료(home material) 공급이 지역별로 이동(숲 +20~40%, 동굴 −30~37%, 초원 −4~20%). 새 숲 ★1·★2가 시설에 많이 배치되기 때문(저등급 시설 점유 0.3→0.5). light_1h는 hunt_cave가 필요한 연구 a3를 60일 안에 끝낸 런이 11/20→4/20. 도감 기록(연구 포인트 소비처)이 종 수만큼 늘어 balanced 연구 소비 1682→3082.

## 도감 보너스 개편 설계 초안 (2026-11-12, Claude 단독 — Codex 크레딧 소진으로 /cross-check 중단, 사용자 결정으로 토론 없이 진행. 승인 대기)
기준: 작업트리(20종 반영, 미커밋). 현행 공식은 `tools/econ_sim/econ_sim/economy.py:136-147`(시설 생산 전체에 `dex_bps`를 곱함, 상한 1000), `formulas.py:161-183`(직접 채집·연구 적용 순서), `formulas.py:347-472`(포획 시도 확률·도구 배율).

### 1. 20종 배정표 (종마다 1개)
| 종 | ★ | 보너스 종류 | 대상 | bps |
|---|---|---|---|---|
| sparkle 반짝이 | 1 | 자원 생산 | bloom | 50 |
| dewdrop 이슬방울 | 1 | 자원 생산 | dew | 50 |
| flower_lamp 꽃등 | 1 | 자원 생산 | bloom | 50 |
| shard_light 조각빛 | 2 | 자원 생산 | crystal | 100 |
| sunset_bird 노을새 | 2 | 사냥 재료 생산 | hunt_meadow | 100 |
| moss_puff 이끼뭉치 | 1 | 자원 생산 | bloom | 50 |
| mushroom_lamp 버섯등 | 1 | 사냥 재료 생산 | hunt_forest | 50 |
| leaf_bunny 잎새 토끼 | 2 | 자원 생산 | bloom | 100 |
| firefly_squirrel 반딧불 다람쥐 | 2 | 사냥 재료 생산 | hunt_forest | 100 |
| rainbow_butterfly 무지개 나비 | 3 | 자원 생산 | crystal | 200 |
| crystal_turtle 수정 거북 | 2 | 자원 생산 | crystal | 100 |
| starlight_bat 별빛 박쥐 | 2 | 사냥 재료 생산 | hunt_cave | 100 |
| lighthouse_bear 등대곰 | 3 | 사냥 재료 생산 | hunt_cave | 200 |
| moon_fox 달빛 여우 | 3 | 자원 생산 | dew | 200 |
| snow_penguin 눈꽃 펭귄 | 2 | 자원 생산 | dew | 100 |
| cloud_sheep 구름 양 | 2 | 사냥 재료 생산 | hunt_ridge | 100 |
| wind_hawk 바람 매 | 3 | 사냥 재료 생산 | hunt_ridge | 200 |
| shadow_lantern 그림자 등불 | 4 | 특수: 시설 강화 비용 − | 시설 Lv 강화·칸 해금 | 100 |
| aurora_deer 오로라 사슴 | 4 | 특수: 포획 확률 + (후보 1안) | 시도 성공률 | +50 (상한 합계 300) |
| star_whale 별무리 고래 | 4 | 특수: 제작 재료 − | stock 레시피 재료 | 100 |

- 배정 기준: ★1~★3은 적성이 가장 높은 자원으로 정했다. 사냥 특성이 있는 종이나 그 지역 사냥 재료가 부족한 종은 사냥 재료 생산으로 정했다.
- 다 모았을 때 종류별 합계: dew 350, bloom 250, crystal 400, hunt_meadow 100, hunt_forest 150, hunt_cave 300, hunt_ridge 300, 강화 비용 −100, 제작 재료 −100, 포획 +50. **모두 상한(1000/300) 아래**다.
- 포획 확률 ★4 후보
  - **aurora_deer(권장)**: 게임의 상징이고 능선 고유 종이라 늦게 얻는다. 경제 영향이 가장 작다.
  - star_whale: 이미 전 자원 A·고스탯이라 보상이 몰린다.
  - shadow_lantern: 동굴에서 일찍 얻어 영향 기간이 가장 길다.

### 2. data 스키마
- `rules.json` `dex_bonus`를 교체한다.
  - `{"grade_bps": {"1":50,"2":100,"3":200}, "special_bps": {"upgrade_cost_down":100,"craft_cost_down":100,"capture_attempt_up":50}, "cap_bps": {"resource_output":1000,"upgrade_cost_down":1000,"craft_cost_down":1000,"capture_attempt_up":300}}`
  - `resource_output` 상한은 자원별로 적용한다.
- `spirits.json` 각 종에 `"dex_bonus": {"type": "resource_output"|"upgrade_cost_down"|"craft_cost_down"|"capture_attempt_up", "resource": "<id>"(resource_output만)}`.
  - 수치는 rules에서 등급·종류로 찾는다. 수치를 한 곳에서만 관리해서 종별로 값이 어긋날 수 없게 하기 위해서다.
- 검증 규칙(ERROR)
  - 종마다 정확히 1개
  - ★1~★3은 resource_output만
  - resource는 basic 또는 hunt 자원
  - ★4는 special 종류만
  - 알 수 없는 type이나 키는 거부
- 기존 `per_species_bps`·`max_bps`는 삭제한다.
- `home_material.apply_dex_to_home_material`은 의미가 "사냥 재료 생산 보너스를 집 방치 사냥 재료에 적용"으로 바뀌므로 true로 하거나 키를 정리한다(결정 Q4).

### 3. 계산 규칙 (Python·Luau 같은 식, 정수 bps, 내림)
- `dexMap(등록 종 집합)` → 자원별 bps(종류별 상한으로 자름), 강화 비용 bps, 제작 bps, 포획 bps. 순수 함수 하나로 두고 모든 경로가 이 함수를 쓴다.
- 시설 방치: `rate × (10000 + dex[생산 자원]) // 10000`. 기존 전체 dex를 대체하고, 순서는 혼합 보너스 → 도감 → 연구로 기존과 같다.
- 집 방치 사냥 재료: `milli × (10000 + dex[hunt_x]) // 10000`
- 직접 채집: `direct × (10000 + dex[자원]) // 10000` → 연구(기존 `research_scaled_milli`). 사냥 드롭도 같은 방식이다(사냥은 sim에만 있음).
- 포획: `p = capture_attempt_bps`(등급 × 빛). 도구 배율을 적용한 뒤 `p > 0`일 때만 `min(10000, p + dex.capture)`를 한다.
  - 빛이 흩어짐 한계 이하(0)이면 보너스도 0이다.
  - 도망 확률은 바꾸지 않는다.
  - 확률표·`EncounterEvent`의 bps는 최종값을 보여 준다.
- 비용 감소: 항목마다 `cost − (cost × r // 10000)`이다. 할인액을 내림하므로 비용은 올림이 된다. cost ≥ 1이면 결과도 ≥ 1이다.
  - 제작은 `amount × times` 합계에 적용한다. 그래서 한 번에 많이 제작할 때만 효과가 있다(결정 Q3).

### 4. 바꿀 곳(순서)
1. data(rules·spirits) + 검증기·스키마 테스트
2. Python `formulas`(dexMap·할인·포획 보정) → `economy`(facility_rate·home_material) → `sim`(dex_bps 호출 4곳, 직접 채집·사냥·포획·강화·제작 비용) → `policy`(비용 평가) → static·report
3. `test_vectors.json`에 새 벡터 추가: dexMap 상한, 할인 반올림, 포획 보정(도구와의 결합·0 경계·10000 상한)
4. Luau
   - `Economy.dexBps/facilityRate/homeMaterialDetail`
   - `IdleCalc`(dexCount 대신 등록 종 목록)
   - `GatherCalc.rate`
   - `Formulas.resolveEncounterTool`(포획 보정 인자)
   - `CaptureLogic`/`CaptureService`(확률 표시)
   - `FacilityRules`·`CraftRules`(할인)
   - 저장 스키마는 이미 도감 종 목록을 갖고 있으면 변경이 없다(구현 시 확인).
5. Lune 벡터·단위 테스트, econ_sim 단위 테스트

### 5. 밸런스 (R9)와 핵심 위험
- **총 보너스 감소**: 지금은 10종 등록 시 모든 시설 생산 +10%다. 새 방식은 다 모아도 자원별 +2.5~4%이고, 직접 채집이 추가된다. 초반(초원 5종)도 지금 +5%(전체)에서 자원별 0.5~1%로 줄어 **진행이 느려질 수 있다**. → sim으로 approved 기준을 확인하고, 미달이면 등급별 수치를 조정한다(결정 Q1).
- 동굴 사냥 재료 감소(−30~37%)는 주로 새 숲 종이 시설 칸을 차지해서 생긴다. 이번 배정(등대곰·별빛 박쥐 = hunt_cave 합계 3%)만으로는 회복되지 않는다. → 개편 뒤 quick에서 light_1h a3 완료율을 다시 보고, 여전히 낮으면 a3의 hunt_cave 요구량 조정을 별도 제안한다(이번에는 바꾸지 않음).
- 도감 기록 가격(종마다 20/40/80, 합계 2800): 60일 공급(4305)보다 작은 유한 소비처라서 유지를 권장한다. 개편 뒤 연구 잔고를 확인한다.

### 6. 검증 계획
- econ_sim: unittest 전체 + 새 단위 테스트(dexMap·할인·포획 보정·검증 규칙). validate ERROR 0, gen-tables --check.
- Luau: Lune vectors(새 벡터 포함)·unit 전부 PASS, rojo build.
- quick 비교(기준 `outputs/20261112_roster20_q`): approved 전부 PASS 유지, ★4 첫 포획 p99, 심지 막힘, 등급별 하루 포획, 60일 방치 생산 총량, 연구 공급·소비, light_1h a3 완료율. 최종 확정 전 full 200시드는 사용자 지정 시 실행한다.
- 구현 후 code-reviewer 리뷰를 받는다.

### 사용자 결정 (2026-11-12, 초안 승인)
- 초안대로 구현한다. 수치는 정한 대로(★1 50 / ★2 100 / ★3 200bps) 넣고 quick sim으로 판단한다. approved 기준에 못 미치면 수치 조정안을 따로 낸다.
- 포획 확률 +0.5%p ★4 = **오로라 사슴**. 그림자 등불은 시설 강화 비용 −1%, 별무리 고래는 제작 재료 −1%.
- 제작 재료 할인은 **한 번에 제작하는 총량(재료 × 횟수)**에 적용한다.
- `home_material`: 사냥 재료 생산 보너스를 집 방치 사냥 재료에 적용한다(R3 방치 적용의 귀결).

## 도감 개편 구현 기록 (2026-11-12~13, roblox-feature)
- 기준: `roblox-game` main `c6d2811` + 미커밋 작업트리(Git). 같은 작업트리의 `game/src/shared/SpiritVisuals/AuroraStag.luau`·`docs/previews/aurora_stag_v5_*`는 다른 작업의 변경이라 이 기록에 포함하지 않는다.

### 사용자 결정 (2026-11-13)
- 시설 강화 비용 감소(그림자 등불)와 제작 재료 감소(별무리 고래)를 **−1% → −5%**(`rules.json` `dex_bonus.special_bps` upgrade_cost_down·craft_cost_down 100 → 500, 상한 `cap_bps` 1000 유지)로 바꾼다.
- 근거: −1%는 시설 강화 비용 항목 대부분이 100 미만이라 할인액이 내림으로 0이 되어 실효가 없다(예: dew_spring Lv10 dew 141 → 140, bloom 71 → 71). −5%면 141 → 134, 71 → 68, 제작 5×20=100 → 95.

### 변경 요약
- data: `spirits.json` 종마다 `dex_bonus`(배정표 그대로), `rules.json` `dex_bonus`를 `grade_bps`·`special_bps`·`cap_bps`로 교체(`per_species_bps`·`max_bps` 삭제), `home_material.apply_dex_to_home_material` = true. `test_vectors.json` 새 벡터 23건(dexMap 5·도감 배율 2·할인 7·포획 보정 5·포획 결합 4, 기존 벡터 변경 없음). 할인 벡터는 비율 r을 인자로 받으므로 −5% 결정의 영향이 없다.
- econ_sim: `formulas.dex_bonus_map`(Python·Luau 같은 식)을 모든 경로가 쓴다. 검증기 `RULE_DEX_BONUS`(★1~3은 resource_output·대상은 기본/사냥 재료, ★4는 특수·resource 없음, 포획 상한 ≤300, 비용 감소 상한 <10000)와 스키마(종마다 필수·알 수 없는 type/키 거부), broken fixture 10개. 비용 감소는 `upgrade_cost_down`·`craft_cost_down`만 허용(그 밖은 오류).
- Luau: `Formulas`(dexBonusMap·할인·포획 보정)·`Economy.dexMap/dexCosts`·`IdleCalc`(입력 `dex` = save.dex)·`GatherCalc.rate`·`CaptureLogic`(plan에 보정 저장, `EncounterEvent` attempt.bps는 최종값)·`CaptureService`(engage 시점 save.dex)·`FacilityRules`·`CraftRules/CraftService`. 저장 스키마는 이미 `dex = {[종]=첫 등록 시각}`이 있어 변경 없음.
- 포획 확률 적합도: 보정이 걸린 조우는 `capture_rule_conformance`·`capture_tool_conformance`에서 빼고(제외 건수는 note), 도구 없는 조우를 `capture_dex_conformance`(등급×bps별, Q_dex = `encounter_expectation(capture_bonus_bps)`, Wilson CI, draft)로 따로 검사한다(리뷰 Minor 1).

### 설계와 달라진 점·구현 판단
1. 포획 보정 조우를 기존 적합도에서 빼고 bps별 적합도 행을 새로 둔 것(설계에 없음, 기존 Q와 섞이면 잘못된 WARN이 나기 때문).
2. 사냥 드롭(sim)의 적용 순서는 **활력 축소 → 도감**(설계는 "직접 채집과 같은 방식"만 명시). policy의 계획용 사냥 효율에도 같은 식을 쓴다.
3. 정책(sim 자동 플레이)의 정적 기대값(Q·심지 소요 추정)과 제작 횟수 계산에는 할인·포획 보정을 넣지 않았다(보수적). 실제 지불·판정만 반영한다.
4. 강화 할인은 sim에서 시설 Lv 강화(hunt_gates 포함)와 칸 해금에, Luau는 MVP1에 칸 해금이 없어 Lv 강화에만 건다. 제작 할인은 stock 레시피만(atomic 제외).

### 검증 (2026-11-13)
- cwd `tools/econ_sim`: unittest 229건 OK, validate ERROR 0·WARN 0·INFO 15, gen-tables --check 최신.
- cwd `roblox-game`: Lune 매핑 17개·오류 0, vectors PASS 123 / SKIP 30 / FAIL 0(합계 153), unit PASS 126 / FAIL 0(18 suites), rojo build 성공. Studio 미검증.
- 돌연변이 확인(새 구현 사본): 상한 제거·할인 올림·흩어짐 보정·보정 무시·도구 앞 가산·중복 등록·시설 전체 dex·직접/집 방치 dex 누락·제작 단위 할인·강화 할인 누락·적합도 미제외·검증기 무력화 등 Python 14건·Luau 13건 모두 테스트가 검출.

### quick run 비교
- `20261112_roster20_q`(개편 전) → `20261112_dex_redesign_q`(개편, 할인 −1%): approved 36행 중 35행 판정 유지, `research_cap_shortening` cave→ridge PASS→INCONCLUSIVE(중앙값 0.106→0.122 ≤0.15, CI 상단 0.129→0.169, 20시드). balanced ★4 첫 포획 p99 그림자 등불 3→4·오로라 사슴 5→6·별무리 고래 6→6일(≤14 PASS). 시설 방치 생산 −4~7%, 직접 채집 증가, 하루 포획 거의 동일, 동굴 사냥 재료 공급 +12~30%, light_1h a3 완료율 0.20→0.45, balanced 연구 공급/소비 4,305/3,082 → 4,353/3,082, 심지 막힘 변화 없음(hardcore 4→5분).
- `20261112_dex_redesign_q` → `20261113_dex_redesign_q2`(할인 −5%, 적합도 분리): approved 판정 변화 없음(PASS 24·INFO 10·INCONCLUSIVE 2). 새 `capture_dex_conformance` 4행(★1~4, +50bps) 모두 PASS. 시설 Lv 합 진행(D10·15·20·30, Lv 합 90 도달일)은 할인 전후 같다. 시설 레벨은 필드별 상한이 진행을 막아서 할인의 진행 효과는 작고, 절약분은 소비처 지출로 간다(hardcore 기본 재료 지출 +3~4%).
- 200시드 full로 cave→ridge 판정을 확정하는 것은 메인이 실행한다.
