# 자원 소비처·포획 규칙 econ_sim 반영 — 구현 계획서

- 작성: 2026-11-10. architect 계획 본문을 메인이 저장했다(architect는 읽기 전용이라 파일을 쓰지 못함). 단계 0은 troubleshooter 진단 결과로 메인이 갱신했다.
- 상태: **사용자 승인 대기**

## 0. 기준 상태·출처
- 대상: `/Users/leeseunghak/project/roblox-game/`(Git 미사용). 명령의 cwd는 `tools/econ_sim`이다.
- 기준(2026-11-10 확인)
  - unittest 119 OK, validate ERROR 0
  - 최신 200시드 run `outputs/20261109T065330Z_full_q985`: PASS 99 / WARN 13 / FAIL 3
  - FAIL 3건은 모두 G2 꼬리다: balanced 0.0010, hardcore 0.0032, balanced_paid 0.0011.
- 설계 출처의 우선순위
  1. 각 토론 문서 끝의 "사용자 결정"
     - `resource_sinks_debate_20261109.md`
     - `capture_rules_debate_20261109.md`(2026-11-10 누락 결정을 보충)
  2. synthesis
- 대체된 결정: 소비처 결정 I1의 "ridge 이후 연구 포인트 심지 레시피"는 포획 결정 "연구 포인트 레시피 없음"으로 대체됐다.
- 구현 지침
  - 표준 라이브러리만 쓴다.
  - **코드 주석은 일본어**, README·문서는 한국어로 쓴다.
  - 기존 outputs를 덮어쓰거나 삭제하지 않는다. 실행마다 새 run_id를 쓴다.
  - `roblox-game/` 밖은 수정하지 않는다.
- 리뷰 기준본: Git이 없으므로 단계 1 전에 `tools/econ_sim`과 `data`를 기준본 폴더로 복사한다. 리뷰는 diff로 한다.

## 1. 단계 0 — 기준선에서 G2 원인 수정

### 1.1 진단 결과 (troubleshooter, 2026-11-10)
- 분석 범위: daily.csv를 스트리밍으로 집계하고, 위반이 난 반복 28건을 단일 재실행해 재현했다. 진단 스크립트는 `/private/tmp/claude-502/-Users-leeseunghak-project/8e2238c3-cff3-40ca-89c4-7975bf70f68b/scratchpad/g2diag/diag.py`(임시 위치)다.
- **위반 분포**
  - 위반은 100% bloom 자원에서 났다.
  - 모두 aurora_deer(★4, bloom S)를 아직 얻지 못한 상태다.
  - flower_lamp(★1, bloom A)는 항상 1마리만 남아 있었다.
  - 도구·시설은 대부분 필드 상한에 도달해 있었다. 예외는 balanced_paid rep73의 1일차뿐이다.
- **분모 휴리스틱 오차(원인 1, 일부)**
  - `sim.py:356-357` `best_idle_rate`는 후보를 slot_power 상위 `slots+3`마리로 자른다.
  - 그래서 Lv1 rainbow_butterfly(혼합 배치 +10%)가 후보에서 빠지고, 분모가 최적보다 최대 7.9% 작다.
  - 분모를 최적으로 바꿔도 위반의 일부가 남는다(보정 후 R 최대 3.247).

    | 페르소나 | 남는 위반 비율 | 보정 후 비중 |
    |---|---|---|
    | balanced | 55% | ≈0.00054 |
    | hardcore | 18% | ≈0.00056 |
    | balanced_paid | 58% | ≈0.00064 |

- **근본 원인(원인 2): bloom 중간 전문 정령 부재 + 정책**
  - 데이터 구조
    - bloom 적성 A/S는 flower_lamp(★1)와 aurora_deer(★4)뿐이다.
    - dew에는 moon_fox(★3 S)가, crystal에는 shard_light(★2 A)와 shadow_lantern(★4 S)가 있다.
    - 즉 bloom만 중간 등급 전문 정령이 없다.
  - 놓아주기 규칙(`sim.py:564-566`): 중복 종 → 낮은 등급 → 낮은 레벨 순서라서 flower_lamp가 항상 1마리로 고정된다.
  - 배치 후보 제한(`policy.py:591-592`, 시설별 `slots+1`)과 레벨업 후보 제한(`policy.py:299`, 배치·전투 상위만)이 겹친다. 그래서 butterfly는 배치되지 않고, 배치되지 않으니 레벨도 오르지 않는다.
  - 사례: balanced rep145의 17일차 최선 방치량은 dew 10166/h, crystal 6433/h, bloom 4060/h다.

### 1.2 수정 분기 (사용자 결정 필요)
- **A. 분모 정확화(측정 수정)**
  - `best_idle_rate`의 후보에 종별 최상위 1마리를 추가하거나, 축소한 후보 안에서 정확 탐색한다.
  - 시뮬 궤적은 바뀌지 않고 G2 열만 바뀐다. 회귀 위험이 낮다.
  - 단위 테스트: 혼합 특성이 있는 작은 로스터에서 결과가 `placement.exact`와 같아야 한다.
- **B. 정책 수정(플레이어 행동 모델)**
  - 놓아주기에서 자원별 시설 기여 상위 개체를 보호한다.
  - 배치 후보에 종별 최상위를 포함한다.
  - 궤적 전체가 바뀌므로 모든 판정을 다시 검증해야 한다.
- **C. 데이터·기준 수정**
  - 데이터: bloom 중간 등급 전문 정령을 보강한다(예: butterfly의 bloom 적성 상향 또는 ★2/★3 bloom 정령 추가).
  - 기준: 3배 판정에 허용 폭을 둔다. approved 기준이라 사용자 결정이다.
- 권장 순서: A → 재측정 → B → 재측정 → 필요하면 C.
- 완료 기준
  - 기준선 200시드에서 approved 3개 페르소나의 `g2_r_over_max`가 모두 0이다.
  - 나머지 approved 판정이 기존과 같다.
  - 어긋나면 사용자 결정으로 넘긴다.
- 병행: 단계 1은 데이터를 추가만 하고 결과를 바꾸지 않으므로 단계 0과 동시에 진행할 수 있다. 단계 2는 단계 0 수정 뒤에 시작한다.

## 2. 단계 1 — 데이터·검증기 (추가만, 시뮬 결과 불변)

### 2.1 스키마 초안
새 파일 3개는 `data/manifest.json`에 role `source`로 등록한다.

- **`resources.json`**
  - `kind` enum에 `craft`를 추가한다(`validate.py:87`).
  - 선택 키를 추가한다.
    - `stack`: `stock` | `atomic`
    - `trade_class`: MVP에서는 `untradable`만
    - `bind`: `account`
    - `origin`: `base` | `craft` | `event`
  - 새 자원
    - `wick`(빛 심지): craft, stock, purchasable false
    - `key_meadow`·`key_forest`·`key_cave`: craft, atomic
    - `comp_meadow`·`comp_forest`·`comp_cave`: craft, atomic
- **`capture.json`**(새 파일, 전역 포획 규칙)
  ```json
  {"schema_version":1,
   "lantern":{"id":"call_lantern","permanent":true,"start_granted":true,"upgradable":false},
   "attempt_cost":[{"resource":"wick","amount":1}],
   "base_success_bps_by_grade":[{"grade":1,"bps":10000},{"grade":2,"bps":5000},{"grade":3,"bps":2500},{"grade":4,"bps":1000}],
   "light":{"max":100,"standard_attack":{"damage":20,"seconds":2},
            "bands":[{"above":60,"mult_bps":10000},{"above":20,"mult_bps":12500},{"above":0,"mult_bps":15000}],
            "scatter_at_or_below":0},
   "easy_mode":{"stop_at_light":20},
   "flee_after_failure":{"first_bps":300,"step_bps":1200,"max_bps":10000},
   "time":{"encounter_base_seconds":60,"attempt_seconds":4},
   "supply":{"start":[{"resource":"wick","amount":21}],"unlock_grants":[]},
   "placeholder":true}
  ```
- **`crafting.json`**(새 파일)
  - `recipes[]`: `{id, output:{resource,amount}, inputs:[COST], mode:"stock"|"atomic", group}`
  - atomic 품목은 레시피가 정확히 1개여야 한다.
- **`sinks.json`**(새 파일)
  - `items[]`: `{id, category: house|furniture|outfit, field_id, requires_fields, requires_items, requires_hub_rank?, costs, effects:[], trade_class, bind, origin}`
  - `repeat_sinks[]`: `{id, category: altar|basic_module, requires_fields, cost_curve, reward_every, reward_until_level, effects:[]}`
  - `dex_records`: `{pages_cost:[20,40,80], resource:"research", requires:"research_tree_complete"}`(질문 Q3)
- **`curves.json`**
  - `exp_ceil_capped`(`cap_level`)와 `linear_ceil_capped`(`step`, `cap_steps`)를 추가한다.
  - gen-tables가 `generated/sink_tables.json`을 생성하고 sha를 검사한다(`tables.py:22-63` 패턴).
- **`fields.json`**: 이 단계에서는 바꾸지 않는다.

### 2.2 placeholder 수치
- **심지 레시피**
  - A(기본 비교 후보): hunt_meadow 5→25 / hunt_forest 4→24 / hunt_cave 4→32 / hunt_ridge 3→30
  - B(Codex 비교안): 아무 hunt 1개→30. 패치 파일 `variants/wick_recipe_codex.json`으로 둔다.
  - 연구 포인트 레시피는 없다.
- **시작 심지 21개**: 초원에서 조우당 포획 0.997, 조우당 심지 1.040이다. 20마리 × 1.043 ≈ 20.9이므로 21개로 정했다. 사용자 결정에서 나온 값이라 반올림 ±1만 허용한다.
- **해금 보급 0 / 일일 심지 0**: 초기값이다. 시뮬로 확정하며, 심지가 부족할 때 가장 먼저 늘리는 손잡이다.
- **길표**: 전개하면 현행 해금 비용과 정확히 같다.
  - key_meadow = hunt_meadow 15
  - key_forest = hunt_forest 24 + key_meadow×2
  - key_cave = hunt_cave 20 + key_forest
- **부품**: comp_\<field\> = hunt_\<field\> 2
- **가구**(필드당 3개, 효과 없음)
  - meadow: dew 100, bloom 100, hunt_meadow 3
  - forest: dew 1k, bloom 1k, crystal 200, hunt_forest 4, comp_meadow 1
  - cave: dew 20k, bloom 20k, crystal 8k, hunt_cave 5, comp_forest 1
  - ridge: dew 200k, bloom 200k, crystal 300k, hunt_ridge 12, comp_cave 2
- **의상 4종**: hunt_\<field\> 10 + 앞 필드 부품 1(meadow는 부품 없음)
- **집**
  - 1~3단계는 hub rank 1~3 그대로다(질문 Q5).
  - 4~9단계(ridge 이후)
    - dew·bloom: 각 250k×1.6^(t−4)
    - crystal: 그 절반
    - 단계마다 hunt_ridge 8, hunt_cave 12, hunt_forest 6, hunt_meadow 6
- **유한 소비처 합계**: dew 약 7.27M, bloom 약 7.27M, crystal 약 4.23M, hunt는 meadow 63 / forest 75 / cave 120 / ridge 94
  - 완료일 추정: 약 D47~D52. 현행 balanced의 dew 잔고 중앙값은 D45 6.93M, D59 10.10M이다.
  - 주 손잡이: 집 성장률 1.6
- **반복 소비처**(비용 상한)
  - 제단(필드별, ridge 이후)
    - 레벨 L 비용: base×1.08^min(L,20)
    - base: meadow 2k / forest 10k / cave 50k / ridge 100k(dew·bloom 각각, crystal은 절반)
    - hunt: ceil(3×1.03^min(L,20))
    - 보상: 5레벨마다, L50까지
  - 기본 재료 전용 모듈
    - 첫 비용(dew, bloom, crystal): meadow (200, 200, 0) / forest (2k, 2k, 500) / cave (10k, 10k, 5k) / ridge (150k, 180k, 120k)
    - n번째 비용 = 첫 비용 × (1+0.05×min(n−1,10)), 상한 1.5배
- **거래**: 모든 자원·품목을 `trade_class: untradable`로 둔다. 필드만 예약한다.

### 2.3 검증기 (`econ_sim/validate.py`, 규칙마다 broken fixture 1개)
- 스키마 3종을 추가한다(기존 SCHEMAS L83-219).
- **RULE_CAPTURE_PARAMS**
  - ★1~4 성공률이 모두 있다.
  - 밴드 배율은 H가 낮아질수록 줄지 않으며, 모두 10000 이상이다.
  - `stop_at_light`가 흩어짐 한계보다 크다.
  - 도망 확률은 줄지 않고, K_max ≤ 20 안에 10000에 도달한다.
  - 시간 값은 0보다 큰 정수다.
- **RULE_CAPTURE_NO_PITY**: pity·ceiling·guarantee·success_bonus·fail_bonus 계열 키가 있거나, 필드별 성공률 override가 있으면 ERROR다.
- **RULE_PAID_CAPTURE** 확장(L486-508)
  - attempt_cost와 심지 레시피 입력을 끝까지 전개했을 때, 구매 가능 자원·상품이 지급하는 자원·그 제작물이 있으면 금지한다.
  - 상품이 wick이나 craft 자원을 지급해도 금지한다.
  - `FORBIDDEN_EFFECT_TYPES`(L54-76)에 `grant_wick`·`capture_supply`를 추가한다.
- **RULE_WICK_RECIPE_INPUT**: 심지 레시피 입력은 kind hunt만 허용한다.
- **RULE_CRAFT_GRAPH**: 다음을 잡는다.
  - 레시피 순환
  - 존재하지 않는 참조
  - 레시피가 1개가 아닌 atomic 품목
  - 보급·보상으로 지급되는 atomic 품목
- **RULE_SINK_EFFECT**: 소비처의 effects가 비어 있지 않으면 ERROR다.
- **RULE_SINK_REPEAT**
  - 반복 소비처는 capped 공식만 쓴다.
  - 기본 재료만 쓰는 반복 소비처가 1개 이상 있어야 한다.
- **RULE_TRADE_RESERVED**: `trade_class`가 `untradable`이 아니면 ERROR다.
- **`model.py`**
  - `expand_costs`를 추가한다. atomic 품목을 재귀적으로 전개한다.
  - `iter_requirements`(L96-124)의 field_unlock은 전개한 비용을 쓴다.
  - 소비처는 `source_kind="sink"`로 둔다. G3 approved 대상에서 빼고 INFO로만 보고한다.
- 완료 기준
  - unittest OK, validate ERROR 0, `gen-tables --check` 최신
  - broken fixture마다 해당 오류가 검출된다.
- 체크포인트: 단계 1 전후 같은 quick 실행에서 checks.csv와 capture_stats.csv가 바이트 단위로 같다.

## 3. 단계 2 — 포획 상태 기계

### 순수 함수 (`formulas.py`, 현행 포획 공식 L201-225)
- `capture_attempt_bps(grade, light, rule)`
- `flee_bps(failures, rule)` = min(max, first + step×(failures−1))
- `resolve_encounter(grade, rule, uniforms, wicks_available, mode="easy") -> Outcome(result, attempts, wicks_used, seconds)`
  - result: success / flee / wick_out / scatter
  - 간편 모드: 표준 공격 4회(8초)로 H=20에서 멈추고, 성공률에 ×1.5를 적용한다.
  - seconds = 60 + 8 + 4×attempts
  - **입력에 성장·개체값·상품·연구가 없다.**
- `encounter_expectation(grade, rule) -> (Q, E[A])`: Fraction으로 계산한다.
- `test_vectors.json` 골든 값(Q, E[A])

  | 등급 | Q | E[A] |
  |---|---|---|
  | ★4 | 0.4638520 | 3.0923464 |
  | ★3 | 0.8074060 | 2.1530826 |
  | ★2 | 0.9787972 | 1.3050629 |
  | ★1 | 1 | 1 |

### 공통 난수
- stream `capture:day<N>`은 유지한다(`sim.py:498-503`).
- **조우마다 고정 블록 B = 1 + 2·K_max(K_max=10이면 21개)를 항상 소비한다.**
  - 구성: 종 1개, 시도 성공 K_max개, 실패 후 도망 K_max개
  - 효과: 같은 날 i번째 조우는 시도 수와 상관없이 항상 블록 i를 쓴다.
- 짝이 어긋나는 원인은 두 가지뿐이다: 필드 선택 차이, 심지 0이라 조우를 시작하지 못한 경우. stream을 날마다 새로 만들므로 어긋남이 다음 날로 번지지 않는다.

### 시간 이월 (`sim.py:516-555` `_capture` 재작성, `enc_carry` L73 대체)
- 포획 활성 단계는 300초 단위다.
- 미완료 조우는 pending으로 보존한다. 세션이나 날짜가 바뀌어도 버리지 않는다(C3).
- 처리 시점
  - 종은 시작 시각의 표로 정한다.
  - 심지는 시작할 때 차감한다.
  - 포획 성공, 첫 포획 기록, 놓아주기는 **완료 시각**에 적용한다.
- 기간이 끝날 때 남은 pending은 `capture_pending_at_horizon`으로 보고한다.

### 심지 부족·필드 선택·놓아주기
- 심지 부족
  - 심지가 1개 이상 없으면 새 조우를 시작하지 않는다.
  - 조우 진행 중에 떨어지면 wick_out으로 끝나고, 블록은 끝까지 소비한다.
- 필드 선택: `policy.capture_field`(L688-706)의 점수는 Σ미보유 (w/W)·Q_grade로 바꾼다.
- 놓아주기: `_release_one`(L557-578)에서 무료로 자동 놓아준다. 보관함이 가득 차도 포획은 멈추지 않는다(C2).

### 데이터 이동과 함께 고칠 곳
- `fields[].capture`에서 `encounters_per_hour`·`success_bps_by_grade`·`costs`를 빼고 capture.json을 쓴다.
- 함께 고칠 코드
  - `static_analysis.capture_quantiles`(L183-227)
  - `metrics.capture_stats` 해석 열(L845-881)
  - `validate._check_capture_rules`
  - `tests/test_sim_rules.py:60`, `tests/test_rules_f.py:29-54`, fixture `broken_paid_capture.json`
- 시작 지급(`Simulator.__init__`): `earned_grant_wick`으로 기록한다.

### 완료 기준·체크포인트
- 완료 기준
  - unittest OK, validate ERROR 0
  - 시간 보존: 하루 사용 초 ≤ 예산 + 이월
  - 같은 블록이면 성장·구매 상태와 무관하게 결과가 같다.
- 체크포인트: `wick_mode: unlimited` + 소비처 off로 quick을 돌린다. 확인 대상은 ★4, storage_full_day, 연구 판정, 필드별 조우 평균 초(해석값 72.2 / 72.6 / 74.1 / 74.3초)다.

## 4. 단계 3 — 심지·제작·소비처 동작
- **`sim.craft`**
  - stock 레시피만 처리한다.
  - 기록: 투입은 `spent_<hunt>`, 산출은 `earned_craft_wick`
  - runner `SOURCES`(L20)에 `craft`·`grant`·`sink`를 추가한다.
- **`sim.unlock_field`(L164-172)**
  - 길표를 원자적으로 제작해 바로 소비한다. 해금할 때마다 새로 만든다.
  - `unlock_grants`를 지급한다.
- **`policy.goal`(L260-264)**: 비용과 ETA를 전개 비용 기준으로 계산한다(I6).
- **`fields.json` 해금 비용 치환**
  - forest: dew 1500, bloom 1500, key_meadow 1
  - cave: dew 15000, bloom 15000, crystal 3000, key_forest 1
  - ridge: dew 600k, bloom 600k, crystal 240k, key_cave 1
  - `_check_unlock_graph`(L455-483)도 전개 비용으로 검사한다.
- **`sim.buy_sink`**
  - atomic 부품을 전개해 지출한다.
  - 상태: `sinks_owned`, `repeat_levels`, `finite_completed_time`
  - **`policy.is_exhausted`(L709-726)는 바꾸지 않는다.** 이 값은 economic_exhausted 의미로 유지한다.
- **일일 심지**: `daily_quests.json`에 wick 행을 추가한다. 초기값 0이므로 조정할 때 추가한다.
- 완료 기준
  - 길표 전개 비용 = 기준본 해금 비용
  - static `g3_hunt_minutes.csv`가 기준본과 같다.
- 체크포인트: 소비처 off·심지 무제한 quick의 checks.csv가 단계 2와 같다.

## 5. 단계 4 — 정책 (`policy.py`, `sim_config.py`)
- **페르소나 키**
  - `wick_mode`: `required`(기본) | `unlimited`
  - `sink_preference`: `none` | `normal`(기본) | `high`
- **예약 우선순위**
  - 순서: 진행(해금 목표·`hunt_targets`·연구, L218-250·L469-474) > 심지 > 소비처
  - 진행 예약분은 심지 제작에 쓰지 않는다.
- **심지 제작**(`manage` 앞뒤, L351-370)
  - 조건: 재고 < 다음 하루 예상 사용량
  - 예상 사용량: 포획 예산 × 필드별 E[A]/E[초]
  - 원료: 예약을 넘는 여유분이 가장 큰 hunt 재료
- **조달 사냥**
  - `bottleneck`(L185-216)에 심지 부족분을 hunt 목표로 더한다.
  - `purpose="wick"` 태그로 `wick_procure_min`을 집계한다.
  - 포획 예산이 남았는데 심지가 없어 포획하지 못한 분은 `wick_blocked_min`으로 잡는다.
- **소비처 구매**(`manage` 안, 강화 구매 뒤)
  - 구매 조건
    - 마지막 필드 전: 목표 ETA가 같아야 하고, hunt 잔고가 심지 예약(3일분) 이상이어야 한다.
    - 마지막 필드 후: 회수 7일 이내 강화 후보(L413-422)의 비용과 심지 예약이 남아야 한다.
  - 구매 순서
    - normal: 유한 품목을 카탈로그 순으로 산다(집은 hub rank 2·3 → 4~9). 유한 품목을 다 산 뒤에는 반복 소비처의 가장 싼 다음 레벨을 산다.
    - high: 유한 품목과 반복 소비처를 함께 산다.
    - none: 구매하지 않는다.
  - 도감 기록(Q3)은 연구 트리를 마친 뒤에만 산다.
- `_try_hub_rank`(L538-549)는 바꾸지 않는다.
- 완료 기준
  - unittest OK
  - 기본 quick에서 부족·조달 열이 정상 집계된다.
- 체크포인트: quick 3종(기본 / 소비처 none / 심지 unlimited)

## 6. 단계 5 — 지표·판정
- **daily 열**(`runner.py` L26-35, `sim.py:644-661`)
  - 포획: `attempts_cum`, `capture_flee_cum`, `capture_wick_out_cum`, `capture_scatter_cum`, `capture_seconds`, `capture_carry_seconds`
  - 심지: `wick_blocked_min`, `wick_procure_min`
  - 소비처: `sink_spent_basic`, `finite_sink_done`, `repeat_sink_levels`, `repeat_sink_open`
- **events**: `finite_cosmetic_completed`(미도달이면 observed=false), 유한 품목 `sink_purchase`
- **기존 approved 판정은 코드·임계값·check_id를 바꾸지 않는다.**
  - 대상: G2 3배, ridge p50 11.2~16.8·p90≤21, 과금 ≤50%, ★4 p98.5≤14, 연구 4종
  - ★4 첫 획득 시각은 "조우 완료 시각"이 된다. README에 적는다.
- **새 지표**(전부 draft 또는 INFO)

  | check_id | 내용 | 상태 |
  |---|---|---|
  | `capture_rule_conformance` | 등급별 실측과 해석값(Q, E[A])의 차이. Wilson CI 밖이면 WARN | draft |
  | `capture_time_conservation` | 시간 보존 위반 일수, 0이어야 함 | draft, 위반 시 FAIL |
  | `encounter_seconds_mean` | 필드별 조우 평균 초 | INFO |
  | `capture_outcome_share` | 등급별 성공·도망·심지 소진·흩어짐 비율 | INFO |
  | `wick_shortage_share` | 심지 부족으로 잃은 포획 분 비율(D1~14 / D15+), balanced·hardcore ≤0.01 | draft |
  | `wick_procure_minutes` | 하루 조달 사냥 분 | INFO |
  | `wick_paid_free_gap` | paid 대 free 짝 차이: 부족 분, 조달 분, 필드별 시도, 종별 첫 획득일 | INFO, 사용자 판단 자료 |
  | `wick_vs_unlimited` | 심지 무제한 기준 대비 차이 | INFO |
  | `star4_exposure` | ★4 필드 체류 분, ★4 조우 수, 종료 사유 | INFO |
  | `finite_cosmetic_completed_day` | balanced p50이 D45~D60 안인가 | draft |
  | `finite_cosmetic_progress` | D30/D60 진척 | INFO |
  | `sink_absorption` | D21 이후 소비처 지출 ÷ 획득 | INFO |
  | `repeat_sink_available_rate` | 반복 소비처 이용 가능률 | INFO |
  | `capture_pending_at_horizon` | 기간 끝 미완료 조우 수 | INFO |

- `storage_full_day`는 기존 기준 ≥5(draft)로 먼저 비교한다(C4).
- 보고서에 "정책 비대상"이라는 표현은 쓰지 않는다.
- 함께 갱신할 것
  - static: `sink_catalog.csv` 추가, `capture_quantiles.csv` 방법 변경
  - report: "포획·심지"와 "소비처" 절
  - `assumptions.py`
  - README

## 7. 단계 6 — 테스트 (각 단계에서 작성, 여기서 누락 점검)
- **순수 함수**: 골든 벡터, 흩어짐 경계, 밴드 경계(60/20), 도망 100% 도달 시 종료
- **속성**: 같은 블록이면 roster·레벨·개체값·구매·연구가 달라도 결과가 같다.
- **공통 난수**
  - balanced와 balanced_paid가 같은 날 같은 블록을 쓴다.
  - 시도 수가 달라도 다음 조우는 블록 i를 쓴다.
- **시간 보존**
  - 50초 남은 상태에서 73초 조우를 시작하면 다음 단계에서 완료된다.
  - 날짜를 넘겨 이월된다.
  - 성공은 완료 전에 지급하지 않는다.
- **심지**: 부족하면 조우를 시작하지 않는다, 진행 중 소진은 wick_out, unlimited 모드
- **길표**: 전개 등가, 해금 직후 재고 0, 해금마다 새로 제작
- **소비처**: ETA를 악화시키지 않는다, 심지 예약을 지킨다, `is_exhausted`가 변하지 않는다, 유한 품목을 다 사면 이벤트가 나온다.
- **기타**: 검증기 fixture(규칙마다), e2e의 새 열·지표 존재
- 완료 기준: unittest 전부 OK

## 8. 단계 7 — 실행·조정
- **공통 명령**(cwd `tools/econ_sim`)
  - `python3 -m unittest discover -s tests`
  - `python3 -m econ_sim validate`
  - `python3 -m econ_sim gen-tables --check`
  - `python3 -m econ_sim all --quick --workers 8`
- **비교 실행 준비**
  - `run`/`all`에 `--patch` 지원을 추가한다. 현행 `cli.py:306-316` `sim_opts`는 patch=False다.
  - 비교 personas: `config/personas_wick_compare.json`, `config/personas_sink_pref.json`
- **실행 순서**
  1. quick
  2. 조정 루프
  3. 100시드 비교 3종: 레시피 A 대 B, 심지 무제한, 장식 선호 민감도
  4. 최종 `all --seeds 200 --workers 8`(기존 실측 약 60분, 실행 시간을 보고)
- **조정 가능한 값**(placeholder)
  - 심지: 해금 보급, 일일 심지, 레시피 산출, 예약 일수, 제작 기준
  - 소비처: 집 base·성장률, 가구 비용·개수, 의상, 제단, 모듈, 도감 기록 비용, 구매 정책
- **조정 불가**(바꾸려면 사용자 결정)
  - 포획 규칙 전부(성공률, H 모델, 도망 3%/+12%p, 60/8/4초, 시도당 심지 1개, 천장 없음)
  - 시작 21개(±1만 허용)
  - 레시피 입력 kind
  - 소비처 효과 0
  - approved 임계값, 포획표 가중치
  - 기존 진행 밸런스
- **루프 규칙**
  - 문제군별로 손잡이 1군만 바꾼다.
  - 문제군당 최대 3회, 100시드 확인은 최대 2회다.
  - 심지 부족 대응 순서: 일일 → 해금 보급 → 레시피 산출. 확률 상향이나 천장은 금지한다.
  - 유한 완료일 대응 순서: 집 성장률 → 집 base → ridge 가구 비용
- **즉시 사용자 질문으로 넘기는 지점**
  - ★4 p98.5 > 14가 심지 부족 때문이 아닌 경우
  - 새 G2 FAIL
  - 연구 approved 실패(동굴→능선 CI 상단 0.142로 경계에 가까움)
  - 과금 >50%, ridge p50/p90 이탈
  - storage_full_day FAIL
  - free/paid 심지 차이 허용 여부
  - 레시피 A/B 최종 선택
- **해석 참고값**
  - 30분 조우 수: 초원 24.9 / 숲 24.8 / 동굴 24.3 / 능선 24.2
  - 30분 심지 사용: 25.9 / 28.5 / 37.3 / 38.2
  - ★4 조우당 획득: 약 0.0297(현행 0.0127)
  - 레시피 A면 balanced D15 이후 hunt 수입의 약 20~25%가 심지로 간다(추정).

## 9. 회귀 위험
| 위험 | 원인 | 확인 |
|---|---|---|
| ridge p50/p90 지연 | 조달 사냥이 flex 시간을 씀 | 단계 2·4 체크포인트 |
| ★4 꼬리 | 심지 부족, 필드 배분 | `star4_exposure`, `wick_shortage_share` |
| G2 | 조달 시간, 개체값 선별 강화 | 단계 0 이후 기준선 대비 |
| 과금 단축 | 유료 사냥 효율 → 심지 여유 | `paid_unlock_shortening`, `wick_paid_free_gap` |
| 연구 판정 | 놓아주기 연구 포인트 증가(동굴·능선 포획 약 1.5배) | 연구 4종 |
| storage_full_day | 초원 포획 약 +9% | draft 비교 |
| 실행 시간 | 조우 루프·소비처 평가 | timing_seconds |

## 10. 구현 담당·규모
- **구현**: `roblox-feature` 1개가(2026-11-10 사용자 결정으로 `script-feature`에서 변경) 단계 0(승인된 분기) → 1 → 6을 순차로 진행한다. 서로 얽혀 있고 Git이 없어 병합 위험이 크기 때문이다.
- **리뷰**: `code-reviewer`를 두 번 쓴다. ① 단계 2·3 뒤, ② 단계 6 뒤(최종 200시드 전).
- **규모**: 약 2,500줄(테스트 약 600, JSON 약 250 포함)
- **실행 시간**: 합계 3~4시간(기준선 200시드 + 100시드 3종 + 최종 200시드)

## 11. 사용자 질문(권장안 포함)
1. **G2 수정 범위**: A(분모 정확화)만으로는 FAIL이 남는다.
   - 권장: A + B(놓아주기·배치 정책을 "쓸모 있는 정령은 남긴다"로)를 적용하고 재측정한다. 그래도 남으면 C(bloom 중간 전문 정령 데이터)를 검토한다.
2. **간편 모드에서 ★1도 8초 약화를 하는가**
   - 권장: 결정한 시간 모델대로 항상 약화한다(보수적).
3. **도감 기록(연구 포인트 140/종)을 MVP 시뮬 소비처에 넣는가**
   - 권장: 넣되, 연구 트리를 완료한 뒤에만 구매한다.
4. **실행 예산**
   - 권장: 기준선 200시드 + 100시드 비교 3종 + 최종 200시드, 합계 3~4시간
5. **집 1~3단계 = 기존 hub rank 1~3(효과 0)으로 보는가**
   - 권장: 그렇다.

- 측정 후에 물을 항목: storage_full_day 기준, free/paid 심지 차이 허용 여부, 레시피 A/B, 조정 상한에 도달한 문제군

## 12. 개정 (2026-11-10, 약화 차등·배고픔 결정 반영 — docs/weaken_hunger_debate_20261110.md)
- 단계 2 계약 변경: 약화 시간 함수를 분리한다. `weaken_seconds(attacker_grade, attacker_level, target_grade, vigor, rule)`는 피로를 포함한 최종 시간을 [2, 12]초로 둔다. 간편 모드의 '고정 8초'는 이 함수 결과로 대체한다. 확률 함수(성공률·H 밴드·도망)는 성장·피로와 무관하게 유지한다. 골든 Q·E[A]는 바뀌지 않는다.
- 불변성 테스트 조건: 대상·H·심지 수·난수·시도 정책을 고정하면 result·attempts가 같고 seconds만 다르다(C5).
- 신규 상태: 정령별 활력(vigor) 0~100.
  - 소모: 약화에 참여할 때 등급 차 기반 비용, 사냥은 5분 단계 비용. 수치는 Codex 안 C=4+2×max(gap,0)와 사냥 분당 2를 출발점으로 조정한다.
  - 회복: 비활동(휴식·오프라인) 시간당 20.
  - 효율: 50 이하는 약화 속도·사냥 산출 75%, 0이면 활동 불가.
  - 사냥 저하는 전투력이 아니라 산출에 곱해 0.5배 문턱 문제를 피한다.
- 전원 활동 불가: 플레이어 보조 약화(등롱)로 포획을 계속한다. 시간은 상한 12초 이내의 느린 값이다.
- 먹이(`food`, kind craft, 비매, untradable): **사냥 재료 레시피**, +25, 개체당 최근 60분 최대 2개, 무료 자동 급식·자동 교대.
  - 예약 우선순위: 진행 > 심지 > 먹이 > 소비처.
  - 검증기: 먹이 레시피 입력은 hunt만 허용, 상품의 food·vigor·회복 효과는 금지, 방치 생산에 vigor 미적용.
- 신규 지표: `weaken_seconds_mean`, `vigor_low_share`, `food_per_day`, `food_shortage`, `assist_weaken_share`, 그리고 과금·무과금 짝 비교와 ablation(레벨 효과 off·피로 off).
- 확률표 UI는 게임 구현 단계에서 만든다. 플랫폼 분류는 출시 전 사용자가 공식 확인한다.

## 13. 진행 메모 (2026-11-10)
- 단계 0~3 완료(handoff 참조), 1차 코드 리뷰 Blocker 0.
- 사용자 결정: ★1은 약화 생략(간편 모드 skip_when_no_gain), storage_full_day draft 기준 ≥5 → ≥4.
- 리뷰 반영 지시: 심지 조달 사냥의 시간 우선순위를 '진행 > 심지'로 수정, G2 도구 규칙은 전환 구간에 적용 안 함, 잠재 결함·테스트 공백 보완. 이어서 단계 4~6 진행 중.
- 메모(2026-11-10, 단계 0~3 리뷰 반영): 단계 7 "조정 가능한 값"(placeholder)에 다음을 추가한다 — 간편 모드 자동 공격자 조건(`capture.weaken.auto_attacker`: 활력 > 50, 약화 ≤ 10초), 등롱 보조 약화 12초(`assist_seconds`), 먹이 레시피(필드별 사냥 재료 1 → 먹이 2). 사용자 결정(2026-11-10): ★1 약화 생략 유지, storage_full_day draft 기준 ≥5 → ≥4, 단계 2·3에서 앞당긴 심지·먹이 제작·조달 사냥은 유지하고 단계 4에서 다듬는다.
- 단계 7 결과(2026-11-11 기록, 상세는 `docs/sinks_capture_handoff.md`):
  - 조정 값(placeholder): 일일 심지 meadow 40·forest 25·cave 35·ridge 25(`daily_quests.json`), 해금 보급 forest 120·cave 200(`capture.json supply.unlock_grants`), 시작 21 고정. 소비처 수치(집 성장률·base·ridge 가구)는 유한 완료 balanced p50 D48로 범위 안이라 바꾸지 않음.
  - 100시드 비교: 레시피 A 대 B는 판정·심지 부족·★4·해금이 같고(공급이 의뢰·보급으로 충분해 제작량 하루 balanced 약 10·hardcore 약 52개), 차이는 사냥 재료 잔고(B가 hardcore 기간 끝 hunt_cave 96→181·hunt_ridge 75→203). 심지 무제한 대비 손실 없음(★4·해금·포획 수 동일). 소비처 선호: none/normal/high 모두 ridge p50 12.9일, normal 유한 완료 D48·흡수 0.834, high는 반복 소비처가 흡수 0.866을 가져가 유한 D60 진척 0.785(미완료). ablation: 레벨 효과 off → 약화 평균 6.19→7.70초·포획 1360→1343·★4 aurora p98.5 6→7, 활력 off → 판정 변화 없음.
  - 최종 200시드 `outputs/20261110_s7_final200`(2832초): approved 전부 PASS(G2 approved 3종 0 포함), WARN 5건은 전부 draft.
  - 사용자 결정 대기: 심지 레시피 A/B 최종 선택, 무과금·과금 심지 차이 허용 여부, (조정 한도 도달 항목 없음).
- 사용자 결정(2026-11-11): ① 심지 레시피 A 유지 ② 무과금·과금 포획 차이는 현행 허용 ③ 소비처 high 선호의 유한 미완료는 게임 쪽에서 보완(시뮬 판정 대상 아님) ④ 일일 의뢰 심지 축소·제작 비중 확대(시작 21·해금 보급 유지).
  - 결과(④, `outputs/20261111_wick_final200`): 일일 심지 meadow 40·forest 20·cave 30·ridge 18로 balanced D15+ 심지 획득 중 제작 비중 12~42% → 49%, approved 전부 PASS, 심지 부족 balanced 0·hardcore D1-14 0.004. 레시피 A 수율이 높아 사냥 재료 적체는 D60 잔고 9% 감소에 그침(상세 `docs/sinks_capture_handoff.md`).
- 사용자 결정(2026-11-11, ④ 결과 후): ⑤ 일일 심지 meadow 40·forest 20·cave 30·ridge 18 확정(placeholder, meadow 40은 hardcore 1일차 부족 방지) ⑥ 해금 보급 forest 120·cave 200 유지(D15-30 제작 비중이 낮은 것은 수용) ⑦ D15 이후 사냥 재료 적체는 레시피 A를 유지한 채 별도 과제로 검토(방치 사냥 재료 획득량·소비처 쪽 조정, 미착수).
- 포획 보조 도구(2026-11-11, 결정 원문 `docs/late_sinks_showcase_debate_20261111.md` 끝): econ_sim 반영·리뷰(Blocker 0) 반영 완료. 최종 200시드 `outputs/20261111_tool_on_final200` approved 전부 off와 동일. 사용자 결정: 재고 하한 설정 기본 0, 도구 on일 때만 심지 제작 정책 보정, meadow·forest 적체 수용, hardcore 유한 완료 지연(D52→D56) 수용, 레시피 사냥 재료 1 → 도구 2 유지(1 → 3 quick 시험 `outputs/20261111_tool_on_q3`은 미채택). Luau 미구현(새 공식·test_vectors 도구 벡터, 확률 표시는 도구 적용 후 성공률).
