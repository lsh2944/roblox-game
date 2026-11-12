# 소비처·포획 구현 — 진행 체크포인트

- 계획서: `docs/sinks_capture_impl_plan.md`. 이번 위임 범위: 단계 0·1.
- 대상: `/Users/leeseunghak/project/roblox-game/`(Git 미사용). 명령 cwd: `tools/econ_sim`.
- 기준본: `baselines/20261110_pre_sinks/`(econ_sim, data). 2026-11-10 시작 시점에 `diff -rq`로 현행과 동일함을 확인(`__pycache__` 제외).

## 단계 0 — G2 원인 수정 (사용자 결정 A + B)

### 0-0. 기준 quick (기준본 코드, 수정 전)
- 명령(cwd `baselines/20261110_pre_sinks/econ_sim`, `PYTHONDONTWRITEBYTECODE=1`):
  `python3 -m econ_sim all --quick --workers 8 --data <기준본>/data --config <기준본>/econ_sim/config --out outputs/20261110_s0_base_quick`
- 결과: 129초. quick(20시드)은 기준본에서도 G2 3종 0.0000 PASS라 G2 방향 확인에는 둔감하다.
  → G2 방향은 위반 반복 21건(approved 3종, troubleshooter `jobs.txt`)을 60일 재실행해 집계했다(스크립트: 스크래치패드 `g2target.py`).

### 0-1. A — 분모 정확화
- `placement.best_single`(1 시설 엄밀 최적, 종별 DP) 추가, `Economy.mixed_traits()` 접근자 추가.
- `sim.best_idle_rate`가 전 보유 정령을 대상으로 `best_single`을 쓴다(이전: 기여 상위 slots+3 휴리스틱).
- 테스트: `tests/test_placement.py` `test_best_single_matches_exact_with_mixed`(120 사례 == `placement.exact`), `test_best_single_includes_low_power_mixed_spirit`.
- 위반 21건 over_outside 분(기준본 → A): balanced 1255→690, balanced_paid 1415→825, hardcore 9725→1730. 최대 R 3.447→3.247.
- quick `outputs/20261110_s0A_quick`: approved 판정 변화 없음(분모만 바뀜).

### 0-2. B — 정책
- `sim.facility_keepers()`: 시설별 최대 슬롯에서 `best_single`에 드는 개체의 합집합. `_release_one` 우선순위에 "시설에 유용하지 않음"을 중복 종 다음 2순위로 추가.
- `policy.reassign` 후보에 종별 최상위 1마리 추가(기여 > 0). 레벨업 후보(`policy.py` L299)는 배치된 정령을 이미 포함하므로 코드 변경 없음(배치되면 레벨업 후보가 됨).
- 위반 21건(A+B): balanced 0, hardcore 0, balanced_paid 35분(rep73 1일차, R=3.0014. 최적 배치 = 실제 배치, 도구 Lv9·시설 Lv3·3슬롯 상태라 배치 문제가 아님).
- quick `outputs/20261110_s0B_quick`(141.7초, 기준 129.1초): approved 전부 PASS 유지. research_natural_gain 0.048→0.037(기준 ≥0.03), star4 shadow_lantern p98.5 14→10, ridge p90 15→14.
- unittest 121 OK.

### 0-3. 최종 200시드 (A+B)
- 코드·data·config 스냅샷(스크래치패드 `s0B/`, 현행과 diff 동일 확인)으로 실행: `python3 -m econ_sim all --seeds 200 --workers 8 --data s0B/data --config s0B/config --out outputs/20261110_s0AB_full`
- 결과: 2501.7초(약 42분, 도중 quick·unittest 동시 실행). PASS 109 / WARN 5 / FAIL 1 (기존 q985: 99 / 13 / 3).
- G2 `g2_r_over_max`(기존 → A+B): balanced 0.0010 FAIL → 0.0000 PASS(최대 R 2.687), hardcore 0.0032 FAIL → 0.0000 PASS(2.724), **balanced_paid 0.0011 FAIL → 0.0000(반올림) FAIL**(35분/1,292,880분, 최대 R 3.0014).
  - 남은 위반은 balanced_paid rep73 1일차(meadow, forest 해금 1290분 이전, 전환 구간 대상 아님) 1건뿐. 시작 시 재료팩·패스로 도구 Lv9, bloom 시설 Lv3·3슬롯. 실제 배치 = 1시설 엄밀 최적(flower_lamp Lv6·5·5)이라 배치·놓아주기 문제가 아님. 같은 짝 balanced rep73은 위반 없음.
- 나머지 approved: 전부 PASS 유지. 변화: ridge p90 15→14, ★4 p98.5 aurora 14→11·shadow 13→11, 과금 단축 cave 0.119→0.109·ridge 0.077→0.075, research_natural_gain 0.047→0.037(기준 ≥0.03), cap cave→ridge 0.131→0.103(CI 상단 0.142→0.108), noresearch ridge p50 15→14·p90 16→15.
- **완료 기준 미충족(balanced_paid G2)** → 지시대로 데이터는 바꾸지 않고 멈춤. 사용자 결정 C(또는 과금 1일차 도구 구매 정책) 검토 필요.

## 단계 1 — 데이터·검증기 (추가만)

### 변경
- data: `resources.json`(kind craft, 선택 키 stack·trade_class·bind·origin, 새 자원 7종), `capture.json`·`crafting.json`·`sinks.json` 신규, `curves.json` `sink_curves` 8개(제단 4 `exp_ceil_capped`, 모듈 4 `linear_ceil_capped`), `manifest.json`(새 파일 3 + `generated/sink_tables.json`), `generated/upgrade_tables.json`(curves 해시 헤더만 갱신, 본문·tables_sha256 동일), `generated/sink_tables.json` 신규, `test_vectors.json`(벡터 7개), `variants/wick_recipe_codex.json`(레시피 B 패치).
- 코드: `formulas`(상한 공식 2개), `tables`(소비처 표 생성·검사·조회), `cli gen-tables`(두 표), `model`(capture_rules·recipes·sinks·sink_curves, `recipes_for`, `expand_costs`, `iter_requirements(include_sinks=False)`), `validate`(스키마 4종 + 규칙 8종, 해금 그래프는 전개 비용), `assumptions`·README.
- fixture 9개: capture_params, capture_pity, paid_wick, grant_wick_product, wick_recipe_input, craft_graph, sink_effect, sink_repeat, trade_reserved. 테스트 `tests/test_sinks_data.py` 16개.
- 보류(다음 단계): sink 요구량의 G3 INFO 보고(단계 5), `fields[].capture.success_bps_by_grade` 금지(단계 2 데이터 이동 시), 정책·시뮬 사용(단계 2~4).

### 체크포인트
- `python3 -m econ_sim all --quick --workers 8 --out outputs/20261110_s1_quick`(200시드 실행과 동시라 458초)
- `outputs/20261110_s0B_quick` 대비 checks.csv·capture_stats.csv **바이트 동일**(allocation·events·spirit_daily·static g3_hunt_minutes도 동일. daily.csv는 craft 자원 열 추가로 다름).

## 단계 0 잔여 — G2 구매 순서 규칙 (2026-11-10, 사용자 결정)
- 이번 위임 범위: 단계 0 잔여 + 단계 2 + 단계 3. 작업 전 기준본 `baselines/20261110_pre_stage23/`(econ_sim·data, 단계 0·1 반영 상태) 추가 복사.
- 변경: `policy._pick`이 도구 강화를 고르면 `tool_r_exceeds`로 가적용 후 기본 재료별 직접 채집 ÷ 최선 방치(`best_idle_rate`, 낮·밤)를 보고, `r_threshold`(3.0) 초과면 그 도구 강화를 후보에서 빼고 다시 고른다(시설 강화 등 차점). 데이터·approved 기준 불변.
- 확인: 위반 반복 21건(troubleshooter `jobs.txt`, approved 3종) 60일 재실행(스크래치패드 `g2target.py`) → over_outside balanced 0 / hardcore 0 / **balanced_paid 0**(rep73 포함), 최대 R 2.548 / 2.615 / 2.966.
- quick `outputs/20261110_s23_g2rule_quick`(188초, 구 포획 방식): approved 전부 PASS 유지(`20261110_s1_quick` 대비 값 변화: ★4 p98.5 aurora 5→11·shadow 10→13, paid cave 0.115→0.077, research_natural_gain 0.037→0.035 등, 판정 변화 없음). unittest 137 OK.

## 단계 2 — 포획 상태 기계 (2026-11-10)
### 변경
- data: `capture.json`에 `weaken`(등급 차 배율 0.5/0.65/0.8/1.0/1.2/1.4/1.6, 레벨 +200bps/Lv 상한 4000, 2~12초, 등롱 12초, ★1 약화 생략, 자동 공격자 활력>50·≤10초)·`vigor`(최대 100, applies_to weaken·hunt, 약화 4+2×gap, 사냥 분당 2, 회복 20/시, ≤50 ×0.75, 먹이 +25·60분 2개·≤50 자동 급식) 추가. `resources.json` `food`(craft stock, 비매, untradable). `crafting.json` 먹이 레시피 4개(필드별 hunt 1 → 먹이 2, placeholder). `fields.json` `capture`에서 `encounters_per_hour`·`costs`·`success_bps_by_grade` 제거(출현 표만). `test_vectors.json` 벡터 40개 추가(손계산, 골든 Q·E[A] 분수 포함). `data_load` 필수 파일에 capture 추가.
- 코드: `formulas`(포획·약화·활력 순수 함수 10개), `sim`(조우 상태 기계 `_capture`/`_start_encounter`/`_complete_encounter`, pending 이월, 고정 21개 난수 블록, 활력 tick 지연 평가·급식·공격자 선택·사냥 산출 배율, 시작 심지 `earned_grant_wick`), `policy`(포획 필드 점수 Σ(w/W)·Q, 포획·사냥 동행 활력 반영, 심지·먹이 제작, 심지 조달 사냥 최소 구현), `state`, `runner`(daily 열·SOURCES craft/grant/sink), `model`(`field_encounter_expectation`, 시도 비용 Requirement), `static_analysis.capture_quantiles`·`metrics.capture_stats`(Q 기반), `validate`(필드 성공률 키 금지, RULE_WEAKEN_PARAMS·RULE_VIGOR_PARAMS·RULE_VIGOR_SCOPE·RULE_FOOD_RECIPE_INPUT, 상품 food·vigor 효과 금지), `sim_config`(`wick_mode`), `assumptions`·README.
- 테스트: `tests/test_capture_sm.py` 신규, fixture 6개 신규(`broken_weaken_params`·`broken_vigor_params`·`broken_vigor_scope`·`broken_food_recipe_input`·`broken_food_product`·`broken_field_success_override`), `broken_paid_capture` 갱신(capture.json attempt_cost), 기존 테스트 4개 갱신(test_sim·test_sim_rules·test_stage4·test_sinks_data), e2e 열 검사 추가.
- 진행 중 발견·수정: 같은 포획 단계 안에서 놓아주기로 동행이 로스터에서 빠지면 `KeyError`(첫 체크포인트 run `outputs/20261110_s2_unlimited_quick`이 이 오류로 중단, static만 생성됨 — 삭제하지 않고 남김). `_start_encounter`에서 로스터에 없는 동행을 제외.

### 체크포인트 (심지 unlimited·소비처 구매 없음, 임시 personas 스크래치패드 `s23/personas_unlimited.json`)
- `outputs/20261110_s2_unlimited_quick2`(250초): approved 전부 PASS(research_cap_shortening meadow→forest는 기존과 같이 INCONCLUSIVE). ★4 p98.5 balanced shadow 3·aurora 6(기존 구 방식 13·11). ridge p50 14·p90 14. 과금 단축 forest 0.069·cave 0.120·ridge 0.077. research_natural_gain 0.048. **storage_full_day balanced 5→4 WARN(draft, 기준 ≥5)**, hardcore 2 PASS.
- 필드별 실측 조우 평균 초: 초원 65.2·숲 67.1·동굴 71.1·능선 70.4(해석값 65.2/67.3/72.1/71.7 — ★1 약화 생략 반영. 계획서 72.2~74.3은 ★1도 8초 가정). 약화 평균 6.1초, 등롱 보조 0%. 하루 사용 초 ≤ 예산(위반 0일). 먹이 하루 0.15~0.55개, 활력 ≤50 사냥 분 하루 1~9분.

## 단계 3 — 심지·제작·소비처 동작 (2026-11-10)
- data: `fields.json` 해금 비용 사냥 재료를 길표로 치환(forest key_meadow 1, cave key_forest 1, ridge key_cave 1).
- 코드: `sim.craft`(stock), `sim.craft_atomic`(재귀), `sim.unlock_field`(길표 원자 제작·소비, unlock_grants 지급), `sim.sink_costs`·`sim.buy_sink`(효과 없음, `sinks_owned`·`repeat_levels`·`finite_completed_time`, 이벤트 `sink_purchase`), `policy.goal` 전개 비용. `policy.is_exhausted` 불변. 소비처 구매 정책은 없음(단계 4).
- 체크포인트 `outputs/20261110_s3_unlimited_quick`(264초): `20261110_s2_unlimited_quick2` 대비 checks·capture_stats·events·spirit_daily·allocation·static 전부 **바이트 동일**, daily는 key_* 열 제외 동일. static `g3_hunt_minutes.csv`는 `20261110_s1_quick`(기준본 코드)과도 동일. 길표 제작 120회분 key_meadow 600·key_forest 240·key_cave 120, 해금 후 재고 0.

## 기본 설정 quick (심지 required, 소비처 구매 없음 — 단계 4 전)
- `outputs/20261110_s3_default_quick`(249초, config/personas.json 그대로). 심지 제작·조달 사냥은 단계 4 선행 최소 구현(`policy.ensure_wick`·`wick_hunt_need`·`ensure_food`).
- approved 전부 PASS. ridge p50 13·p90 14, ★4 p98.5 balanced shadow 4·aurora 5, research_natural_gain 0.049, noresearch ridge 14/14.
- 주의: **paid_unlock_shortening forest 0.479(기준 ≤0.5, unlimited 0.069)** — 무과금은 1일차 심지 조달 사냥이 길표용 사냥 재료와 겹쳐 forest가 늦다(짝 중앙값 기준). cave 0.082·ridge 0.046.
- 심지 부족으로 포획 예산을 못 쓴 분(capture_min 부족, 스크래치패드 집계): light_1h D1-14 37.3%, balanced 3.1%, balanced_paid 5.8%, hardcore 0.1%, D15+ 전원 0%. 계획서 draft 목표(balanced·hardcore ≤0.01) 대비 balanced 초과 → 단계 7 손잡이(일일 심지 → 해금 보급 → 레시피 산출) 대상.
- 심지 제작 하루 평균 38~84개, 먹이 하루 0~0.34개, 등롱 보조 0%, 약화 평균 6.1~6.2초, storage_full_day balanced 4 WARN(draft).

## 최종 검증 (cwd tools/econ_sim, 2026-11-10)
- `python3 -m unittest discover -s tests` → 160 OK(기존 137 + 신규 23). `python3 -m econ_sim validate` → ERROR 0·WARN 0. `python3 -m econ_sim gen-tables --check` → 최신.
- 리뷰 기준본: `baselines/20261110_pre_stage23/`(이번 작업 직전, econ_sim·data). 단계 0·1까지는 `baselines/20261110_pre_sinks/`.
- 미구현(단계 4·5 범위): 소비처 구매 정책(`sink_preference`), `wick_blocked_min`·`wick_procure_min` 열, 새 지표(check_id) 전부, `capture_pending_at_horizon`, ablation 플래그.

## 리뷰 반영(A)·단계 4~6(B) — 2026-11-10 (사용자 결정: ★1 약화 생략 유지, storage_full_day draft ≥5→≥4, 선행 심지·먹이 정책 유지)
- 재개 시점 상태(사용량 한도 중단 후): Major 1(bottleneck 심지 하위 칸)·Minor 8(전환 구간 도구 규칙 면제)·Minor 1(craft_atomic 사전 전개 검사)·Minor 6(완료 분 = 완료 초를 포함한 분)·Minor 7(급식 실패 카운터 state/sim)까지 코드 반영, 테스트 기대값 갱신만 남은 상태에서 재개. 나머지(Minor 4·5·2·3, 테스트 공백 9, placeholder 메모, criteria) 미착수.
- (A) 반영 완료: Major 1 — bottleneck에서 심지 사냥 재료를 진행 부족분 뒤(진행 부족이 없을 때만 앞)로 내림. 그대로면 1~10일차 포획이 거의 멈춰(단일 반복 확인) **심지가 없어 포획할 수 없는 포획 예산을 심지 재료 조달 사냥에 쓰는** `policy.wick_procure_action`(Action.purpose="wick", budget_kind="capture")을 추가. Minor 8(전환 구간 도구 규칙 면제), Minor 1(craft_atomic 사전 전개 검사), Minor 4(applies_to 정확히 weaken·hunt 강제), Minor 5(먹이 재료 closure 유료 검사, RULE_PAID_CAPTURE), Minor 6(완료 분 = 완료 초를 포함한 분, 자정 경계도 단계의 날), Minor 7(food_short_window·food_short_stock), Minor 2·3(README·assumptions 근사 명시), 테스트 공백 9 a~d, placeholder 메모(계획서 12절 끝), criteria storage_full_day balanced 4.
- 검증: unittest 167 OK, validate ERROR 0, gen-tables 최신. quick `outputs/20261110_sA_review_quick`(175초): **research_natural_gain 0.030 FAIL(approved, 95% CI 0.022~0.034, 직전 0.049)** → 지시대로 단계 4 진입 전 중단·보고. 그 밖 approved PASS, paid forest 0.479→0.069, cave 0.077, ridge 0.078, storage_full_day balanced 8 PASS(≥4), ★4 p98.5 balanced 4/6. 심지 부족으로 포획에 못 쓴 포획 예산(D1-14/D15+): light_1h 0.280/0.001, balanced 0.235/0, hardcore 0.181/0, balanced_paid 0.203/0(직전 정책: 0.373·0.031·0.001·0.058).
- 단계 4 기준본(baselines/20261110_pre_stage46/)은 단계 4를 시작하지 않아 아직 만들지 않음.

### 심지 공급 조정 (메인 결정: Q1 (가) 유지 + 단계 7 손잡이 앞당김, quick 최대 3회)
| 회 | 일일 심지(daily_quests, 필드 공통) | 해금 보급(capture.supply.unlock_grants) | run | research_natural_gain(CI) | forest/cave/ridge 과금 단축 | 심지 부족 D1-14 balanced / hardcore / light_1h / balanced_paid (D15+ 전원) | approved |
|---|---|---|---|---|---|---|---|
| 0(기준) | 0 | 없음 | 20261110_sA_review_quick | 0.030 (0.022~0.034) FAIL | 0.069/0.077/0.078 | 0.235 / 0.181 / 0.280 / 0.203 (0) | research_natural_gain FAIL |
| 1 | 15 | 없음 | 20261110_tune1_quick | 0.039 (0.034~0.052) | 0.069/0.148/0.093 | 0.109 / 0.129 / 0.156 / 0.097 (0) | 전부 PASS |
| 2 | 25 | 없음 | 20261110_tune2_quick | 0.050 (0.039~0.055) | 0.069/0.077/0.081 | 0.039 / 0.123 / 0.065 / 0.040 (0) | 전부 PASS |
| **3(채택)** | 25 | forest 50, cave 100 | 20261110_tune3_quick | 0.055 (0.054~0.071) | 0.069/0.120/0.077 | **0.000 / 0.063** / 0.000 / 0.000 (0) | 전부 PASS |
- 3회차에서 멈춤(루프 상한). hardcore D1-14 0.063은 목표(≤0.01) 미달 — 1~4일차(초원·숲, 하루 포획 60분) 집중. ★4 p98.5 balanced 4/6, ridge p50 13·p90 14.

## 단계 4~6 (2026-11-10, 기준본 baselines/20261110_pre_stage46/ — 심지 공급 조정까지 반영한 상태)
### 변경
- 단계 4: `sim_config` 페르소나 키 `sink_preference`(none|normal 기본|high)·`ablation`(weaken_level_off·vigor_off). `policy.buy_sinks`(관리 시점 끝, 예약 = 진행 + 심지 3일분 + 먹이 6개분 재료, ridge 전 목표 ETA 불변, ridge 후 회수 7일 이내 강화 비용도 예약), `_next_sinks`(normal: 카탈로그 순 대기 → 유한 완료 후 반복 최저가 / high: 유한 카탈로그 순(못 사면 건너뜀) + 반복 최저가), `buy_dex_records`(연구 트리 완료 후). `sim.finite_catalog`(필드 순, 거점 등급 2·3 = 집 2·3단계를 그 재료 필드에 배치), `sink_available`·`sink_owned`·`house_rank_field`, `buy_sink`(house_rank·dex 지원, `sink_spent` 기록, 유한 완료 시각), ablation 플래그. 일 끝 `wick_blocked` = 포획 예산 − 포획 분.
- 단계 5: daily 열(wick_blocked_min·wick_procure_min·food_short_*·hunt_party_min·sink_spent_basic/hunt·finite_sink_done·repeat_sink_levels·repeat_sink_open·dex_pages·g1~4_{enc,success,flee,wick_out,scatter,attempts}), 이벤트 `finite_cosmetic_completed`·유한 품목 `sink_purchase`, `metrics_capture.py`(새 check_id 19종, 전부 draft/INFO), criteria `sim.capture_sinks`, report "포획·심지·활력"·"소비처" 절, static `sink_catalog.csv`, `run`/`all --patch`, 비교 personas 3파일(`personas_wick_compare`·`personas_sink_pref`·`personas_ablation`).
- 단계 6: `test_capture_sm.py`(소비처 정책 5·ablation 1·기존 소비처 테스트 갱신), e2e(새 check_id·열·sink_catalog 존재, --patch run manifest). 진행 중 수정: 확률 적합도 검사가 같은 비교군(같은 난수 블록) 페르소나를 중복 합산해 표본을 부풀림 → 비교군별 첫 페르소나만 합산.

### 기본 quick `outputs/20261110_s46_default_quick`(217초)
- approved 전부 PASS: research_natural_gain 0.055(CI 0.054~0.071), 과금 단축 forest 0.069·cave 0.120·ridge 0.077, ridge p50 13·p90 14, ★4 p98.5 balanced shadow 4·aurora 6, G2 0. 판정 PASS 80 / WARN 6 / FAIL 0 / INCONCLUSIVE 39 / INFO 223.
- 심지 부족 D1-14/D15+: balanced 0/0 PASS, hardcore 0.063/0 WARN(draft), light_1h·balanced_paid 0/0.
- 소비처: 유한 완료 p50 balanced D48 PASS(D45~60), hardcore D50, balanced_paid D45, light_1h D54. 진척 D30/D60 balanced 0.679/0.969. D21+ 흡수율 balanced 0.716(반복 소비처 module_meadow가 상한 300 dew·bloom 비용으로 대량 구매됨).
- 포획 적합도 ★1~4 전부 PASS(★4 0.465 vs Q 0.464), 시간 보존 위반 0. 조우 평균 초 65.3/67.0/71.1/70.4.
- 활력·먹이(balanced/hardcore): 약화 평균 6.19/6.15초, 등롱 0, 저활력 사냥 비율 0.158/0.200, 먹이 0.19/0.26개/일, 급식 실패/일 상한 0.13/0.33·재고 1.05/1.64. 과금−무과금 약화 초 합 D1-14 −38초(중앙값).
- 최종 검증(cwd tools/econ_sim): unittest 175 OK, validate ERROR 0·WARN 0, gen-tables --check 최신.

## 2차 리뷰 반영·단계 7 (2026-11-10, 기준본 baselines/20261110_pre_stage7/)
- (A) 2차 리뷰 반영: M1 반복 소비처 = 해금 최고 필드의 모듈·제단 중 예약 초과 잔여로 다음 레벨을 가장 많이 살 수 있는 것, `policy.max_sinks_per_manage`(personas 4파일 50), sink_absorption 합계/유한/반복 분리(daily `sink_spent_*_repeat`). Minor 1 다음 연구 노드 비용 예약(progress_reserve), Minor 3 ridge 후 회수 예약에서 R 초과 도구 제외(전환 구간 면제), Minor 2 house_rank 구매 후 예약 재계산·주석, Minor 4 적합도 = 시작 시 심지 ≥ K_max 조우만(daily `g*_full_enc/full_success`), Minor 5 필드별 시도(`attempts_<field>`)를 wick_paid_free_gap에, Minor 6 report 단독 실행 시 manifest patch 자동 적용·불일치 경고, Minor 7 house_rank는 storage_bonus 0일 때만 소비처, Minor 8 테스트(SinkReserveTest 4, Ablation C5, e2e finite 이벤트·approved 기준 대조 fixture `approved_thresholds_ref.json`, PatchRunTest 적용·원본 해시), Nit(주석, dex 상한 ValueError, repeat 가용성 검사, report 0 나눗셈, 조우 초 비교군 중복 제거, 활력 off 먹이 예약 없음, manifest personas에 wick_mode·sink_preference·ablation).
- 검증: unittest 181 OK, validate OK, gen-tables 최신. quick `outputs/20261110_s7_q0`(175초): approved 전부 PASS(research 0.055, paid 0.069/0.120/0.077, ridge 13/14, ★4 4/6, storage 4), 심지 부족 hardcore D1-14 0.065, 유한 완료 balanced D48, 흡수율 balanced 0.829(유한 0.582·반복 0.247).

### 단계 7 조정 루프 (quick)
| 문제군·회 | 바꾼 값 | run | hardcore 심지 부족 D1-14/D15+ | balanced 유한 완료 p50 | research_gain | 과금 단축 f/c/r | approved |
|---|---|---|---|---|---|---|---|
| 기준 | 일일 25 공통, 해금 보급 forest 50·cave 100 | 20261110_s7_q0 | 0.065 / 0 | D48 | 0.055 | 0.069/0.120/0.077 | 전부 PASS |
| (i)-1 해금 보급 | forest 120·cave 200 | 20261110_s7_q1 | 0.020 / 0(1일차 10분·8~9일차 잔여) | D48 | 0.055 | 0.069/0.120/0.077 | 전부 PASS |
| **(i)-2 일일 심지(채택)** | meadow 40·forest 25·cave 35·ridge 25 | 20261110_s7_q2 | **0.001 / 0** | D48 | 0.055 | 0.069/0.077/0.077 | 전부 PASS |
- (ii) 유한 소비처 완료일은 M1 수정 후에도 balanced p50 D48(D45~60 안)이라 조정하지 않음(0회). 흡수율 balanced 0.860(유한 0.599·반복 0.261).

### 100시드 비교 4종 (2026-11-10 실행, 2026-11-11 분석. 스크래치패드 로그는 정리돼 없어짐 — 각 run의 manifest·checks.csv로 완결 확인)
| run | personas | 시드·실행 | 시간 | 판정 |
|---|---|---|---|---|
| `20261110_s7_c100_recipeA` | personas_wick_compare(light_1h·balanced·hardcore·balanced_paid + **balanced_wick_unlimited·hardcore_wick_unlimited**) | 100·600 | 1308초 | PASS 114/WARN 4/FAIL 0 |
| `20261110_s7_c100_recipeB` | 같음 + `--patch variants/wick_recipe_codex.json` | 100·600 | 1373초 | PASS 113/WARN 5/FAIL 0 |
| `20261110_s7_c100_sinkpref` | balanced·balanced_sink_none·balanced_sink_high | 100·300 | 578초 | PASS 60/WARN 3/FAIL 0 |
| `20261110_s7_c100_ablation` | balanced·balanced_paid·balanced_level_off·balanced_vigor_off | 100·400 | 800초 | PASS 80/WARN 3/FAIL 0 |
- 심지 무제한 비교는 레시피 run에 포함(위 굵은 페르소나, criteria `wick_unlimited_pairs`).
- 레시피 A 대 B: 심지 부족(전원 0~0.001)·조달 0분·★4 p98.5(balanced 7/6, hardcore 3/3)·ridge p50 13·p90 14·과금 단축 0.069/0.088/0.077 모두 동일. 하루 심지 제작 balanced 9.8·hardcore 52.4(A) 대 9.8·52.5(B). 차이는 사냥 재료 잔고: 기간 끝 hardcore hunt_cave 96→181·hunt_ridge 75→203, balanced hunt_ridge 205→245(B가 사냥 재료를 덜 씀). B의 WARN 1건 추가는 capture_rule_conformance ★1(관측 1.0000 = Q 1.0)인데, k=n일 때 Wilson 상단이 부동소수로 1보다 살짝 작아지는 판정 결함이었다 → 허용오차 1e-9로 수정(2026-11-11, 판정 로직만, 최종 200시드는 ★1 PASS로 영향 없음).
- 심지 무제한 대비: balanced ★4 7/7·6/6, ridge 13/13, 포획 1360/1360; hardcore aurora 3/4, 포획 2712/2711 → 손실 없음.
- 소비처 선호: ridge p50 none 12.88·normal 12.88·high 12.90일, ★4 동일. normal 유한 완료 D48·D60 진척 0.967·흡수 0.834(유한 0.582·반복 0.252). high는 반복 소비처(최고 필드 모듈·제단)를 유한과 함께 사서 흡수 0.966(반복 0.866)·유한 D60 진척 0.785로 기간 내 미완료. none 흡수 0.
- ablation: 레벨 효과 off → 약화 평균 6.19→7.70초, 포획 중앙값 1360→1343, ★4 aurora p98.5 6→7(shadow 7/7), ridge 동일. 활력 off → 약화 6.19 동일, 포획 1359, ★4·ridge 동일(활력은 현 수치에서 판정에 영향 없음). 과금−무과금 약화 초 합 D1-14 −30초.
- free/paid 심지 차이(wick_paid_free_gap): 심지 부족·조달 분 차이 0, 시도 수 D1-14 +6(동굴 −37·능선 +42는 과금 쪽 능선 진입이 빠른 탓), ★4 첫 획득 중앙값 차이 없음.

### 최종 200시드 `outputs/20261110_s7_final200` (기본 personas, 레시피 A, 2832초 ≈ 47분)
- approved 전부 PASS: rule_validation 0, G2 over_max balanced·hardcore·balanced_paid 0.0000(평균 R 1.926/1.688/1.873), g3 52/52, ridge p50 13·p90 14, 과금 단축 forest 0.069·cave 0.098·ridge 0.077, ★4 p98.5 balanced shadow 7·aurora 6, research_cap_shortening 0.000/0.000/0.116(CI 상단 0.124), research_natural_gain 0.054(CI 0.054~0.055), noresearch ridge p50 14·p90 15.
- draft/INFO: storage_full_day balanced 4 PASS·hardcore 2, 적합도 ★1~4 PASS(★4 0.4647 대 Q 0.4639), 시간 보존 위반 0, 조우 평균 초 65.3/67.0/71.1/70.4, 심지 부족 balanced 0/0·hardcore 0.001/0, 유한 완료 balanced D48 PASS(hardcore 50·paid 45·light_1h 54), 흡수 balanced 0.827(유한 0.576·반복 0.251), 약화 평균 6.13~6.20초, 등롱 0, 저활력 사냥 0.04~0.20, 먹이 0.07~0.30개/일. WARN 5건은 전부 draft(g2_r_field_band light_1h:meadow 1.242·balanced:forest 1.497, convergence_species_role 3종).
- 판정 수: PASS 120 / WARN 5 / FAIL 0 / INFO 227 (기존 `20261110_s0AB_full`: PASS 109 / WARN 5 / FAIL 1).
- 최종 검증(2026-11-11, Wilson 허용오차 수정 후): unittest 181 OK, validate ERROR 0, gen-tables 최신.

## 일일 심지 축소·제작 비중 확대 (2026-11-11 사용자 결정, 기준본 baselines/20261111_pre_wick_supply/)
- 결정: 레시피 A 유지, 시작 21·해금 보급 forest 120·cave 200 유지, 일일 의뢰 심지를 balanced 사용량의 약 절반으로 낮춰 사냥 재료로 만드는 심지 비중을 늘린다(심지가 사냥 재료를 두고 경쟁하게).
- 코드: 분석용 daily 열 `craft_hunt_wick`(그날 심지 제작에 넣은 사냥 재료 수) 추가(`state.py` DayAcc.wick_craft_hunt, `sim.py` craft, `runner.py` CAPTURE_COLS 끝). 판정·정책 변경 없음.
- 정책 확인(변경 없음): `ensure_wick`는 심지 재고가 1일 견적 미만일 때 진행 예약을 넘는 사냥 재료로 제작, 재료도 예약에 묶이면 포획 예산을 조달 사냥(`wick_procure_action`, 예산 capture)에 쓴다. hardcore D7~10 부족은 동굴 재료가 ridge 해금 예약에 묶여 생긴 것으로 '진행 > 심지' 의도대로 동작.

### 조정 루프 (quick 20시드, balanced 심지 하루 평균, 제작 비중 = 제작/획득)
| 회 | 일일 심지 meadow/forest/cave/ridge | run | 심지 부족 hardcore D1-14 | balanced 제작 비중 D15-30/D31-60 | balanced 사냥 재료 사용 D15-30/D31-60·D60 잔고 | approved |
|---|---|---|---|---|---|---|
| 기준(final200) | 40/25/35/25 | 20261110_s7_final200 | 0.001 | 12% / 42% | 12.4 / 8.1 · 519 | 전부 PASS |
| q1 | 25/20/20/20 | 20261111_wick_q1 | 0.027 WARN(1일차 10분·D7~10 동굴) | 49% / 53% | 12.8 / 9.4 · 483 | quick CI로 research_cap 2건 INCONCLUSIVE |
| q2 | 40/20/30/20 | 20261111_wick_q2 | 0.005 | 38% / 54% | 12.3 / 9.5 · 488 | research_cap meadow->forest INCONCLUSIVE(기준 quick과 동일) |
| **q3(채택)** | **40/20/30/18** | 20261111_wick_q3 | 0.005 | 44% / 58% | 12.6 / 9.7 · 478 | 위와 같음 |

### 최종 200시드 `outputs/20261111_wick_final200` (3330초)
- approved 전부 PASS: G2 over_max balanced·hardcore·balanced_paid 0.0000(평균 R 1.924/1.686/1.871), ridge p50 13·p90 14, 과금 단축 forest 0.069·cave 0.098·ridge 0.077, ★4 p98.5 shadow 7·aurora 6, research_natural_gain 0.054(CI 0.054~0.055), research_cap 0.000/0.000/0.116(CI 상단 0.124), noresearch ridge 14/15. 판정 PASS 120 / WARN 5(전부 draft, 기준과 같은 항목) / FAIL 0 / INFO 227.
- 심지 부족: balanced 0/0, hardcore D1-14 0.004(조달 0.25분/일)·D15+ 0, light_1h·balanced_paid 0. 과금·무과금 부족·조달 차이 0.
- 소비처: 유한 완료 balanced D48 PASS(hardcore 50→52), 흡수 balanced 0.829.

| 페르소나 | 기간 | 심지 의뢰/제작/보급/사용(하루) | 제작 비중 | 사냥 재료 획득/사용(심지·먹이·소비처·진행) | 기간 끝 잔고(기준) |
|---|---|---|---|---|---|
| balanced | D1-14 | 28.5 / 0 / 24.4 / 36.7 | 0% | 38.1 / 35.0 (0·0.2·1.9·32.8) | 43 (43) |
| balanced | D15-30 | 18.0 / 14.2 / 0 / 42.8 | 44% | 20.7 / 13.7 (1.8·0.2·9.4·2.4) | 156 (176) |
| balanced | D31-60 | 18.0 / 24.8 / 0 / 42.8 | 58% | 19.5 / 8.9 (2.8·0·6.1·0) | 473 (519) |
| hardcore | D1-14 | 27.2 / 30.6 / 24.4 / 75.2 | 37% | 43.1 / 41.3 (4.6·0.5·0.5·35.6) | 25 (30) |
| hardcore | D15-30 | 18.0 / 67.3 / 0 / 85.3 | 79% | 19.6 / 13.4 (7.7·0·5.7·0) | 124 (132) |
| hardcore | D31-60 | 18.0 / 67.6 / 0 / 85.6 | 79% | 20.5 / 16.6 (7.8·0·8.8·0) | 243 (282) |
| light_1h | D1-14 | 28.9 / 0 / 24.4 / 33.7 | 0% | 29.5 / 25.4 (0·0.1·0·25.3) | 58 (58) |
| light_1h | D15-30 | 20.5 / 8.0 / 0 / 42.1 | 28% | 20.6 / 18.0 (1.0·0·8.0·8.9) | 100 (107) |
| light_1h | D31-60 | 18.0 / 24.8 / 0 / 42.8 | 58% | 20.3 / 10.7 (2.6·0·8.0·0) | 389 (431) |
- balanced D15+ 제작 비중 49%(목표 약 50%). 다만 레시피 A는 사냥 재료 1개당 심지 5~10개라 제작 23개/일에 재료 2~3개만 쓴다. D60 사냥 재료 잔고는 기준 대비 9% 감소에 그쳐 적체는 여전하다(일일 심지를 0으로 해도 balanced 사용 43개 = 재료 약 4~9개/일로 하루 획득 약 20개를 흡수하지 못함). 적체 해소에는 레시피 수율·소비처 등 별도 결정이 필요하다.
- 검증(cwd tools/econ_sim, 최종 데이터): unittest 181 OK, validate ERROR 0·WARN 0, gen-tables --check 최신.

## 포획 보조 도구 시뮬 반영 (2026-11-11 사용자 결정, 기준본 baselines/20261111_pre_capture_tool/)
- 결정 근거: `docs/late_sinks_showcase_debate_20261111.md` 끝 "사용자 결정(2026-11-11)"과 메인 위임(시도당 1개, home_field, 전역 ridge 후·직접 포획 이력, 레시피 hunt 1 → lure 2, persona `capture_tool` off|star4, 예약 진행 > 심지 > 먹이 > 유한 외형 > 도구 > 반복, 재고 2일분 가안).
- data: `capture.json` `capture_tool`(배율 ★2 11000·★3 11500·★4 12000, ★1 없음, max_bps 10000, per_attempt 1, applies_to home_field, unlock_after_field ridge, requires_prior_direct_capture true), `resources.json` `lure_meadow/forest/cave/ridge`, `crafting.json` `lure_from_<필드>`, `test_vectors.json` 도구 벡터 22건(★4 Q_tool 0.52905·★3 0.85420 등, 도망 규칙 포함 손계산).
- 코드: `formulas`(capture_tool_mult_bps·capture_tool_attempt_bps·capture_tool_item·resolve_encounter_tool, encounter_expectation with_tool; resolve_encounter는 도구 0 호출), `validate`(RULE_CAPTURE_TOOL, RULE_PAID_CAPTURE 확장), `sim`(tool_for, `_start_encounter` 난수 블록 그대로 확률만 변경, 도구 조우는 기존 적합도 full_*에서 제외), `policy`(lure_per_day·tool_reserve·craft_lures, manage에서 심지 제작 뒤·소비처 앞), `runner` daily 열(TOOL_COLS·lure_craft/used_<필드>), `metrics_capture`(capture_tool_* 5종), report "포획 보조 도구" 절, `config/personas_tool_star4.json`.
- off 완전 회귀 `outputs/20261111_tool_off_q`(184초) 대 `20261111_wick_q3`: daily 7200행 공통 297열 전부 동일, checks 공통 352행 전부 동일(새 열 74·새 check 37만 추가). 참고: wick_q3 manifest의 daily_quests.json 해시가 현 데이터와 다르나(final200과는 같음) 결과는 완전 일치.
- on quick `outputs/20261111_tool_on_q1`(전원 star4, 260초): approved 판정 off와 동일(PASS 24·INFO 10·INCONCLUSIVE 1 = research_cap meadow->forest, off·wick_q3와 같음). 감시 check capture_tool_first_capture_zero 0 PASS, capture_tool_conformance ★4 0.5414 PASS(Q_tool 0.5291), 기존 적합도 ★4 0.4675 PASS.

| persona | ★4 획득/일(ridge 후) off→on | 도구 시도/일 | 도구 제작/소비/일 cave · ridge | hunt_cave D14/30/60 off→on | hunt_ridge D14/30/60 off→on | meadow·forest D60 off→on |
|---|---|---|---|---|---|---|
| balanced | 1.478→1.587 | 4.61 | 2.19/1.99 · 2.82/2.62 | 24/52/139→24/51/85 | 1/53/157→1/47/98 | 99→98 · 83→77 |
| hardcore | 2.945→3.078 | 5.30 | 1.90/1.67 · 4.02/3.63 | 9/47/100→9/47/34 | 6/34/77→6/34/23 | 51→33 · 35→18 |
| light_1h | 1.524→1.624 | 3.85 | 1.69/1.49 · 2.59/2.37 | 6/23/91→6/23/53 | 0/23/132→0/23/81 | 63→62 · 88→83 |
| balanced_paid | 1.493→1.604 | 4.81 | 2.08/1.88 · 3.13/2.93 | 22/37/124→22/36/73 | 1/57/176→1/48/109 | 92→92 · 110→98 |
- 변화 없음: 심지 부족(balanced 0/0, hardcore D1-14 0.005/D15+ 0)·조달 분, 첫 ★4 p98.5(balanced shadow 4·aurora 6, 전 페르소나 동일), ridge p50 13·p90 14, 과금 단축 0.069/0.077/0.077, G2 over_max 0(평균 R 차 ≤0.005), 유한 외형 완료 p50 balanced D48·paid 45·light 54. 변화: hardcore 유한 완료 p50 D51→D57(INFO), hardcore 흡수율 0.769→0.740.
- 해석: star4는 ★4 고유 필드가 cave(shadow_lantern)·ridge(aurora_deer)뿐이라 lure_meadow/forest는 쓰이지 않는다. cave·ridge D60 잔고는 balanced 기준 약 38~39% 감소. 도구 시도는 ★4 조우 시도의 약 절반(재고는 관리 시점에만 보충, 예약 초과분만 제작). hardcore는 D31 이후에야 예약을 넘는 잔여가 생겨 도구를 만들기 시작하며, 이후 도구가 cave·ridge 잔여를 쓰자 심지 제작(진행 예약만 지킴)이 meadow·forest·유한 예약분까지 끌어써 유한 완료가 늦어진 것으로 추정(D31-60 cave·ridge 지출 > 획득, 심지 제작 재료 7.67→8.34/일).
- 조정: 판정 항목에 문제가 없어 수치 조정 0회. 최종 200시드는 미실행(메인 지시 대기).

### 리뷰(Blocker 0)·사용자 결정 반영과 최종 200시드 (2026-11-11)
- 결정 M1: personas `policy.capture_tool_min_stock`(기본 0). 조우에서는 '재고 − 하한'만 쓴다(`sim.py` `_start_encounter`, 난수 순서 불변). 지역별 사용 한도는 넣지 않았고, 2일분 제작 상한은 유지했다.
- 결정 M2: 도구 on 페르소나에서만 `policy.ensure_wick`이 먼저 '진행 + 미구매 유한 외형 사냥 재료(`finite_hunt_reserve`)'를 남기는 잉여로 심지를 만들고, 모자라면 진행 예약 기준으로 폴백한다. (a)안을 택한 이유: 폴백이 기존 호출 그대로라 진행 > 심지와 심지 부족 0을 보장하고, off는 코드 경로가 바뀌지 않는다.
- 결정 3: 초원·숲 적체는 수용한다(★4 전용 유지).
- 리뷰 Minor 반영:
  - m1: 도구 check·report 절은 manifest personas에 capture_tool ≠ off가 있을 때만 나온다.
  - m2: README·지표 비고에 집계 시점 차이(lure_used는 시작일, tool_*는 완료일)와 @u 근사를 적었다.
  - m3: lure_per_day 근사를 assumptions에 적었다.
  - m4: 테스트 4종(full_tool 분리, 놓아주기 후 이력 유지, min_stock, M2 off 무변화)과 broken fixture 4개(tradable·max_bps·per_attempt·필드 누락)를 추가했다.
  - Nit: capture_tool_field 비고를 고쳤다.
- 검증(cwd tools/econ_sim): unittest 200 OK, validate ERROR 0·WARN 0, gen-tables --check 최신.
- off 회귀 `outputs/20261111_tool_off_q2` 대 `20261111_wick_q3`: daily 7200행·공통 297열 동일, checks 352행 동일, 새 check 0개.
- on quick `outputs/20261111_tool_on_q2`: approved는 off와 같다. hardcore 유한 완료 p50은 off D51 → on D58(이전 on_q1은 D57)로, M2로 회복되지 않았다.
  - 원인: hardcore는 D31 이후 사냥 재료 수지가 적자다(획득 약 20.9개/일, off 사용 16.4 + 도구 4.8).
  - 도구가 cave·ridge 잉여를 쓰면, 그 뒤 심지(우선순위가 더 높음)가 보호 잉여로 부족해 폴백한다. 이때 집 4~9단계에 필요한 meadow·forest·cave 재료를 쓴다.
  - D60 미완료 반복의 예: dew 6.7M을 보유하고도 사냥 재료가 모자라 23/24에서 멈췄다.
- 최종 200시드 `outputs/20261111_tool_on_final200`(전원 star4, 3204초)을 `20261111_wick_final200`(off)과 비교:
  - approved 25 PASS / INFO 10으로 off와 같다. 전체 판정은 PASS 122 / WARN 5 / FAIL 0 / INFO 263이며, WARN 5건은 off와 같은 draft 항목이다.
  - ridge p50 13·p90 14, 과금 단축 0.069/0.098/0.077, research_natural 0.054, research_cap 0/0/0.116, G2 over_max 0(평균 R 차 ≤0.005)이 모두 같다.
  - 감시 0 PASS, 도구 적합도 ★4 0.5328 PASS(Q 0.5291), 기존 ★4 0.4644 PASS.

| persona | ★4/일(ridge 후) off→on | 도구 시도/일 | 제작/소비 cave · ridge (/일) | hunt_meadow D14/30/60 | hunt_forest | hunt_cave | hunt_ridge | 유한 완료 p50 | 첫 ★4 p98.5 shadow/aurora |
|---|---|---|---|---|---|---|---|---|---|
| balanced | 1.489→1.587 | 4.57 | 2.12/1.93 · 2.84/2.64 | 13/44/99→13/36/90 | 8/24/88→8/22/82 | 22/41/132→22/42/82 | 1/46/154→1/45/98 | 48→48 | 7/6 → 7/6 |
| hardcore | 2.996→3.108 | 5.07 | 1.42/1.28 · 4.19/3.80 | 5/26/54→5/26/27 | 6/24/36→6/24/17 | 9/42/84→9/42/32 | 6/33/69→6/33/22 | 52→56 | 3/3 → 3/3 |
| light_1h | 1.473→1.561 | 3.81 | 1.68/1.48 · 2.56/2.34 | 32/27/63→32/26/59 | 20/18/91→20/18/85 | 6/28/99→6/28/62 | 0/27/135→0/27/87 | 54→54 | 5/6 → 5/6 |
| balanced_paid | 1.495→1.599 | 4.93 | 2.26/2.07 · 3.06/2.87 | 9/36/86→9/31/81 | 7/24/96→7/21/89 | 23/42/149→23/41/92 | 1/54/175→1/49/111 | 45→45 | 7/5 → 7/5 |
| balanced_noresearch | 1.490→1.594 | 4.83 | 2.34/2.15 · 2.88/2.68 | 36/44/99→36/35/89 | 20/21/88→20/20/83 | 37/45/143→37/46/89 | 0/43/161→0/42/103 | 52→52 | 7/5 → 7/5 |
| balanced_research_cap | 1.490→1.595 | 4.87 | 2.25/2.06 · 3.01/2.81 | 11/42/100→11/34/91 | 8/20/88→8/19/82 | 28/43/138→28/43/84 | 1/51/170→1/48/108 | 47→47 | 7/7 → 7/7 |
- 심지 부족은 off와 같다: balanced 0/0, hardcore D1-14 0.004 / D15+ 0, 나머지 0.
- hardcore 흡수율은 0.835에서 0.742로 내려갔다.
- 남은 결정: hardcore 유한 완료 지연(D52→D56, INFO)을 수용할지, 또는 '도구 제작 억제'(예: 심지 폴백이 일어난 날은 도구를 제작하지 않음, 정책 변경) 같은 추가 보정을 할지.

## 2026-11-11 메인 기록: 도구 레시피 1→3 시험과 결정
- 시험: `data/crafting.json` lure_from_* 산출 2→3, quick `outputs/20261111_tool_on_q3`(353초). approved 동일, hardcore 유한 완료 p50 D54(off q3 D51, on q2 D58), balanced D60 hunt_cave/ridge 106/120(off 139/157, on q2 86/101).
- 사용자 결정: 1 → 2 유지. `data/crafting.json`은 `baselines/20261111_pre_lure_recipe3/`에서 복원(최종 200시드와 같은 데이터). 테스트 `tests/test_capture_tool.py` PolicyTest는 레시피 산출량을 데이터에서 읽도록 일반화해 유지(현 데이터에서 19 OK, 전체 200 OK는 1→3 상태에서 확인).

## 재료 상자·초심자 패스 제거 (2026-11-11 사용자 결정, 기준본 baselines/20261111_pre_remove_material_products/)
- 근거: `docs/bm_monetization_debate_20261111.md` 끝 '사용자 결정(유사 장르 조사 후)'. 시작 시 기준본과 현행 동일 확인(`.DS_Store` 제외).
- data: `products.json`에서 basic_pack_4h·beginner_pass 삭제(notes에 결정 기록), `resources.json` dew·bloom·crystal `purchasable` false.
- 검증기: `basic_material_pack`·`beginner_pass` kind를 허용→금지(`FORBIDDEN_PRODUCT_KINDS`, 사유 문구 `FORBIDDEN_PRODUCT_KIND_REASONS`), 재료팩·패스 효과 검사 분기 삭제. 규칙 로직은 그대로라 기본 재료가 비매가 되면서 '기본 재료를 포획 투입물에 직접 넣는' 경우는 RULE_PAID_CAPTURE가 더는 안 나온다(심지·먹이·도구 레시피는 각 hunt 입력 규칙이 계속 막음). 해당 broken fixture·테스트는 dew를 purchasable=true로 되돌리는 op를 앞에 붙여 같은 규칙을 검증.
- 시뮬: balanced_paid(personas 4개 파일)를 외형·편의 구매자로 재정의(1일차 외형·배치 프리셋, day 4~13 보관함 +10×10). 재료팩·패스 처리 분기는 휴면(daily.csv `pass_claims_cum` 열 유지).
- quick `outputs/20261111_no_material_products_q`(212초) 대 `20261111_night_clock_q`: balanced_paid 외 daily·events·spirit_daily·capture_stats·checks 완전 동일. approved 35행(PASS 24·INFO 10·INCONCLUSIVE 1) 동일. paid_unlock_shortening forest 0.069→0.000, cave 0.077→0.000, ridge 0.077→−0.018(모두 PASS). paid_basic_income_gap D30 0.090→−0.004, D60 0.065→−0.001. 보관함 확장으로 놓아주기가 늦어져 연구 포인트가 늦게 쌓임(D14 research_done 중앙값 4 대 balanced 10, D30부터 같음).
